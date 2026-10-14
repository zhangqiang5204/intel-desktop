"""Offline regressions for a transient typing header after one verified send."""
import copy
import unittest
from unittest.mock import patch

from chat_workflows import ChatSession, Stopped, WECHAT, execute_chat
from test_chat_completion import WeChatSendFake, send_request
from test_chat_workflows import WeChatFake, bounds


TYPING_HEADERS = ("对方正在输入", "对方正在输入…", "对方正在输入⋯", "对方正在输入...")
MESSAGE = "离线发送验收消息"
MARKER = "离线回复验收标记"


class SleepClock:
    """Advance only on simulated sleeps, so the original deadline is observable."""

    def __init__(self):
        self.now = 0.0
        self.sleeps = []

    def __call__(self):
        return self.now

    def sleep(self, duration):
        if len(self.sleeps) >= 50:
            raise AssertionError("Reply observation exceeded its bounded fake wait")
        self.sleeps.append(duration)
        self.now += duration


class WeChatReplyFake(WeChatSendFake):
    """Apply one frame per visual_read after Return; repeat the final frame."""

    def __init__(self, frames):
        super().__init__()
        self.original_title = self.title
        self.frames = copy.deepcopy(frames)
        self.posted = False
        self.post_submit_reads = 0
        self.current_frame = {}
        self.frame_results = []
        self.interrupt_after_reads = None
        self.first_typing_call = None

    def visual(self, request, region_only=False):
        value = super().visual(request, region_only)
        state = self.current_frame
        if state.get("extra_header"):
            value["ocr"].append({"text": state["extra_header"],
                                 "bounds": bounds(self.frame["x"] + 338, self.frame["y"] + 19, 130, 20)})
        if state.get("omit_header"):
            value["ocr"] = [row for row in value["ocr"] if row["text"] != self.title]
            for match in value["anchor_matches"]:
                match["matching_ocr"] = [row for row in match["matching_ocr"] if row["text"] != self.title]
        if "ocr_truncated" in state:
            if state["ocr_truncated"] is None:
                value.pop("ocr_truncated", None)
            else:
                value["ocr_truncated"] = state["ocr_truncated"]
        return value

    def __call__(self, request):
        if (request["command"] in {"status", "background_visual_read"} and self.posted
                and self.interrupt_after_reads is not None
                and self.post_submit_reads >= self.interrupt_after_reads):
            self.interrupted = "manual_keyboard"
        if request["command"] in {"visual_read", "background_visual_read"} and self.posted:
            if self.post_submit_reads >= 40:
                raise AssertionError("Unbounded read-only typing refresh")
            index = min(self.post_submit_reads, len(self.frames) - 1)
            self.current_frame = self.frames[index]
            self.title = self.current_frame.get("header", self.original_title)
            self.post_submit_reads += 1
            if "draft" in self.current_frame:
                self.draft = self.current_frame["draft"]
            if self.current_frame.get("reply") and self.current_frame["reply"] not in self.pages[self.page]:
                self.pages[self.page].append(self.current_frame["reply"])
            if self.current_frame.get("pid_changed"):
                self.pid += 1
            if self.current_frame.get("geometry_changed"):
                self.frame["x"] += 1
            if self.title in TYPING_HEADERS and self.first_typing_call is None:
                self.first_typing_call = len(self.calls)
        response = super().__call__(request)
        if request["command"] == "visual_key" and request.get("key") == "return" and response["ok"]:
            self.posted = True
        if request["command"] in {"visual_read", "background_visual_read"} and self.posted and response["ok"]:
            value = response["result"]
            self.frame_results.append({"header": self.title,
                                       "target_visible_verified": value.get("target_visible_verified"),
                                       "ocr_truncated": value.get("ocr_truncated")})
        return response


class WeChatReplyTypingTests(unittest.TestCase):
    def execute_send(self, fake, timeout_ms=1000):
        clock = SleepClock()
        request = send_request(fake, MESSAGE, reply_contains=MARKER, wait_timeout_ms=timeout_ms)
        with patch("chat_workflows.time.monotonic", side_effect=clock), patch("chat_workflows.time.sleep", side_effect=clock.sleep):
            response = execute_chat(request, fake, recipe_store=False)
        return response, clock

    def assert_one_submit(self, fake):
        submits = [call for call in fake.calls if call["command"] == "visual_key" and call.get("key") == "return"]
        self.assertEqual(len(submits), 1)
        self.assertEqual(fake.pages[0].count(MESSAGE), 1)

    def assert_verified_send(self, response, fake):
        self.assertTrue(response["ok"], response)
        result = response["result"]
        self.assertTrue(result["sent"])
        self.assertTrue(result["send_verified"])
        self.assertEqual(result["submission_state"], "observed_in_chat")
        self.assertFalse(result["delivery_verified"])
        self.assertFalse(result["automatic_replay_allowed"])
        self.assert_one_submit(fake)
        return result

    def assert_send_proof_preserved_on_error(self, response, fake, code):
        self.assertFalse(response["ok"], response)
        self.assertEqual(response["error"]["code"], code)
        self.assertTrue(response["sent"])
        self.assertEqual(response["submission_state"], "observed_in_chat")
        self.assertFalse(response["automatic_replay_allowed"])
        self.assert_one_submit(fake)

    def header_fixture(self, header, *, action="read", verified=False):
        fake = WeChatFake()
        session = ChatSession({"app": WECHAT, "action": action, "chat": fake.title,
                               "reply_contains": MARKER, "text": MESSAGE}, fake)
        session.frame = dict(fake.frame)
        session.pid = fake.pid
        session.title = fake.title
        session.target["window_title"] = "微信"
        session.send_verified = verified
        fake.title = header
        return session, fake, fake.visual({})

    def assert_header_rejected(self, session, value, *, typing=False):
        with self.assertRaises(Stopped) as failure:
            session.wechat_header(value, "测试群")
        error = failure.exception
        self.assertEqual(error.code, "target_not_found")
        self.assertEqual(error.details.get("header_status"), "typing" if typing else None)
        return error

    def test_transient_typing_recovers_only_after_exact_title_and_new_marker_return(self):
        for header in TYPING_HEADERS:
            with self.subTest(header=header):
                fake = WeChatReplyFake([{}, {"header": header}, {"reply": MARKER}])
                response, _ = self.execute_send(fake)
                result = self.assert_verified_send(response, fake)
                self.assertTrue(result["reply_evidence"]["requested_text_visible"])
                self.assertTrue(result["reply_evidence"]["newly_visible_since_baseline"])
                self.assertFalse(result["reply_evidence"]["sender_verified"])
                self.assertFalse(result["observation_timed_out"])
                self.assertEqual(result["observation_transient_header_count"], 1)
                self.assertIn(MARKER, result["new_visible_lines"])
                self.assertEqual(fake.title, fake.original_title)

    def test_typing_with_missing_original_title_anchor_can_wait_for_recovery(self):
        fake = WeChatReplyFake([{}, {"header": "对方正在输入⋯"}, {"reply": MARKER}])
        fake.search_label = ""
        response, _ = self.execute_send(fake)
        result = self.assert_verified_send(response, fake)
        typing_results = [frame for frame in fake.frame_results if frame["header"] == "对方正在输入⋯"]
        self.assertEqual(len(typing_results), 1)
        self.assertFalse(typing_results[0]["target_visible_verified"])
        self.assertEqual(result["observation_transient_header_count"], 1)
        self.assertTrue(result["reply_evidence"]["requested_text_visible"])

    def test_persistent_typing_times_out_without_downgrading_send_or_exposing_unverified_body(self):
        for header in TYPING_HEADERS:
            with self.subTest(header=header):
                fake = WeChatReplyFake([{}, {"header": header, "reply": MARKER}])
                response, clock = self.execute_send(fake, timeout_ms=600)
                result = self.assert_verified_send(response, fake)
                self.assertEqual(result["reply_observation_state"], "pending_typing")
                self.assertEqual(result["reply_header_status"], "typing")
                self.assertTrue(result["observation_timed_out"])
                self.assertFalse(result["current_recipient_verified"])
                self.assertFalse(result["recipient_verified"])
                self.assertIsNone(result["draft_empty"])
                self.assertIsNone(result["draft_preserved"])
                for field in ("requested_text_visible", "requested_text_visible_in_current_view",
                              "newly_visible_since_baseline", "new_since_request"):
                    self.assertIsNone(result["reply_evidence"][field])
                self.assertFalse(result["reply_evidence"]["sender_verified"])
                self.assertFalse(result["reply_evidence"]["new_reply_verified"])
                for field in ("visible_text", "rows", "visible_rows_returned", "new_visible_text", "new_visible_lines"):
                    self.assertNotIn(field, result)
                self.assertAlmostEqual(clock.now, .6)
                self.assertEqual(result["observation_waited_ms"], 600)
                self.assertEqual(result["observation_transient_header_count"], 5)
                after_typing = fake.calls[fake.first_typing_call:]
                self.assertTrue(all(call["command"] == "background_visual_read" for call in after_typing))

    def test_persistent_typing_with_a_new_draft_cannot_claim_the_current_composer_is_empty(self):
        changed_draft = "未确认的当前草稿"
        fake = WeChatReplyFake([{}, {"header": "对方正在输入⋯", "reply": MARKER, "draft": changed_draft}])
        response, _ = self.execute_send(fake, timeout_ms=600)
        result = self.assert_verified_send(response, fake)
        self.assertEqual(result["reply_observation_state"], "pending_typing")
        self.assertFalse(result["current_recipient_verified"])
        self.assertFalse(result["recipient_verified"])
        self.assertIsNone(result["draft_empty"])
        self.assertIsNone(result["draft_preserved"])
        self.assertIsNone(result["reply_evidence"]["requested_text_visible"])
        self.assertEqual(fake.draft, changed_draft)
        for field in ("draft", "visible_text", "rows", "new_visible_text", "new_visible_lines"):
            self.assertNotIn(field, result)
        after_typing = fake.calls[fake.first_typing_call:]
        self.assertFalse(any(call["command"] in {"visual_click", "visual_type_text", "visual_key", "batch"}
                             for call in after_typing))

    def test_typing_before_send_echo_is_verified_still_fails_unknown_once(self):
        fake = WeChatReplyFake([{"header": "对方正在输入⋯", "reply": MARKER}])
        response, _ = self.execute_send(fake)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "target_not_found")
        self.assertEqual(response["error"]["details"]["header_status"], "typing")
        self.assertIsNone(response["sent"])
        self.assertEqual(response["submission_state"], "unknown")
        self.assertFalse(response["automatic_replay_allowed"])
        self.assertEqual(fake.post_submit_reads, 1)
        self.assert_one_submit(fake)

    def test_real_different_recipient_after_verified_send_fails_and_preserves_proof(self):
        fake = WeChatReplyFake([{}, {"header": "另一位收件人", "reply": MARKER}])
        response, _ = self.execute_send(fake)
        self.assert_send_proof_preserved_on_error(response, fake, "target_not_found")
        self.assertNotIn("header_status", response["error"]["details"])
        self.assertEqual(fake.post_submit_reads, 2)

    def test_unknown_header_after_typing_is_not_swallowed_or_used_as_reply(self):
        for frame in ({"header": "未知状态", "reply": MARKER}, {"omit_header": True, "reply": MARKER}):
            with self.subTest(frame=frame):
                fake = WeChatReplyFake([{}, {"header": "对方正在输入…"}, frame])
                response, _ = self.execute_send(fake)
                self.assert_send_proof_preserved_on_error(response, fake, "target_not_found")
                self.assertNotIn("header_status", response["error"]["details"])
                self.assertEqual(fake.post_submit_reads, 3)

    def test_read_or_draft_observation_without_this_sessions_send_proof_stops_on_typing(self):
        for action in ("read", "draft"):
            with self.subTest(action=action):
                session, fake, initial = self.header_fixture("测试群", action=action)
                baseline = "\n".join(row["text"] for row in session.visible_rows(initial))
                fake.title = "对方正在输入..."
                clock = SleepClock()
                with patch("chat_workflows.time.monotonic", side_effect=clock), patch("chat_workflows.time.sleep", side_effect=clock.sleep):
                    with self.assertRaises(Stopped) as failure:
                        session.observe_reply(initial, baseline=baseline, timeout_ms=1000)
                self.assertEqual(failure.exception.code, "target_not_found")
                self.assertEqual(failure.exception.details["header_status"], "typing")
                self.assertFalse(session.send_verified)
                self.assertEqual([call["command"] for call in fake.calls], ["status", "visual_read"])

    def test_high_level_read_and_draft_cannot_use_typing_as_completion_proof(self):
        for action in ("read", "draft"):
            with self.subTest(action=action):
                fake = WeChatFake()
                read_count = 0

                def callback(request):
                    nonlocal read_count
                    if request["command"] == "visual_read":
                        read_count += 1
                        if read_count > 1:
                            fake.title = "对方正在输入⋯"
                    return fake(request)

                request = {"app": WECHAT, "action": action, "chat": fake.title}
                if action == "read":
                    request.update(baseline_text="\n".join(fake.pages[0]), reply_contains=MARKER,
                                   wait_timeout_ms=1000)
                else:
                    request["text"] = MESSAGE
                clock = SleepClock()
                with patch("chat_workflows.time.monotonic", side_effect=clock), patch("chat_workflows.time.sleep", side_effect=clock.sleep):
                    response = execute_chat(request, callback, recipe_store=False)
                self.assertFalse(response["ok"])
                self.assertEqual(response["error"]["code"], "target_not_found")
                self.assertEqual(response["error"]["details"]["header_status"], "typing")
                self.assertFalse(response["sent"])
                self.assertEqual(read_count, 2)
                self.assertFalse(any(call.get("key") == "return" for call in fake.calls))
                writes = [call for call in fake.calls if call["command"] == "visual_type_text"]
                self.assertEqual(len(writes), 1 if action == "draft" else 0)
                self.assertEqual(fake.draft, MESSAGE if action == "draft" else "")

    def test_literal_typing_status_still_fails_recipient_check_and_has_narrow_annotation(self):
        for header in TYPING_HEADERS:
            with self.subTest(header=header):
                session, _, value = self.header_fixture(header)
                self.assert_header_rejected(session, value, typing=True)
                self.assertEqual(session.wechat_header(value, header), header)
                self.assertFalse(session.send_verified)

    def test_status_found_only_in_body_or_sidebar_does_not_annotate_unknown_header(self):
        session, fake, value = self.header_fixture("另一位收件人")
        for x, y in ((fake.frame["x"] + 390, fake.frame["y"] + 220),
                     (fake.frame["x"] + 90, fake.frame["y"] + 120)):
            with self.subTest(position=(x, y)):
                frame = copy.deepcopy(value)
                frame["ocr"].append({"text": "对方正在输入⋯", "bounds": bounds(x, y, 130, 20)})
                self.assert_header_rejected(session, frame)

    def test_multiple_title_rows_do_not_qualify_as_transient_typing(self):
        session, fake, value = self.header_fixture("对方正在输入⋯")
        value["ocr"].append({"text": "另一标题", "bounds": bounds(fake.frame["x"] + 338, fake.frame["y"] + 19, 130, 20)})
        self.assert_header_rejected(session, value)
        with self.assertRaises(Stopped) as failure:
            session.wechat_header(value)
        self.assertEqual(failure.exception.code, "ambiguous_target")
        fake = WeChatReplyFake([{}, {"header": "对方正在输入⋯", "extra_header": "另一标题"}])
        response, _ = self.execute_send(fake)
        self.assert_send_proof_preserved_on_error(response, fake, "target_not_found")
        self.assertNotIn("header_status", response["error"]["details"])

    def test_truncated_or_missing_ocr_completeness_does_not_qualify_as_typing(self):
        for truncated in (True, None):
            with self.subTest(truncated=truncated):
                session, _, value = self.header_fixture("对方正在输入…")
                if truncated is None:
                    value.pop("ocr_truncated")
                else:
                    value["ocr_truncated"] = truncated
                self.assert_header_rejected(session, value)
                fake = WeChatReplyFake([{}, {"header": "对方正在输入…", "ocr_truncated": truncated}])
                response, _ = self.execute_send(fake)
                self.assert_send_proof_preserved_on_error(response, fake, "send_state_unknown")
                self.assertNotIn("header_status", response["error"]["details"])

    def test_typing_without_send_footer_does_not_qualify_as_status(self):
        session, _, value = self.header_fixture("对方正在输入...")
        value["ocr"] = [row for row in value["ocr"] if row["text"] != "发送"]
        self.assert_header_rejected(session, value)

    def test_similar_statuses_and_literal_name_suffixes_do_not_change_name_matching(self):
        for header in ("对方正在输入中", "对方正在输入....", "某人对方正在输入⋯", "测试群 对方正在输入⋯"):
            with self.subTest(header=header):
                session, _, value = self.header_fixture(header)
                self.assert_header_rejected(session, value)
                self.assertEqual(session.wechat_header(value, header), header)
        for label, wanted in (("姓名D>", "姓名D>"), ("短群（12）", "短群"), ("助手 AI", "助手")):
            with self.subTest(label=label):
                session, _, value = self.header_fixture(label)
                self.assertEqual(session.wechat_header(value, wanted), label)
                with self.assertRaises(Stopped):
                    session.wechat_header(value, wanted + "其他")

    def test_user_activity_after_return_during_typing_wait_is_preserved_without_reclaim(self):
        fake = WeChatReplyFake([{}, {"header": "对方正在输入⋯"}])
        fake.interrupt_after_reads = 2
        response, _ = self.execute_send(fake)
        result = self.assert_verified_send(response, fake)
        self.assertEqual(result["reply_observation_state"], "pending_typing")
        self.assertEqual(fake.interrupted, "manual_keyboard")
        self.assertTrue(response["focus_restored"])
        self.assertEqual(sum(call.get("restore_previous") is True for call in fake.calls), 1)

    def test_pid_change_in_typing_frame_is_not_swallowed(self):
        fake = WeChatReplyFake([{}, {"header": "对方正在输入⋯", "pid_changed": True}])
        response, _ = self.execute_send(fake)
        self.assert_send_proof_preserved_on_error(response, fake, "target_changed")
        self.assertTrue(response["focus_restored"])  # The earlier real return is historical proof.

    def test_geometry_change_in_typing_frame_is_not_swallowed(self):
        fake = WeChatReplyFake([{}, {"header": "对方正在输入⋯", "geometry_changed": True}])
        response, _ = self.execute_send(fake)
        self.assert_send_proof_preserved_on_error(response, fake, "target_geometry_changed")
        self.assertTrue(response["focus_restored"])  # No second return after a changed background frame.

    def test_typing_retries_use_original_deadline_including_prior_normal_wait(self):
        fake = WeChatReplyFake([{}, {}, *[{"header": "对方正在输入…"}] * 12, {"reply": MARKER}])
        response, clock = self.execute_send(fake, timeout_ms=600)
        result = self.assert_verified_send(response, fake)
        self.assertEqual(result["reply_observation_state"], "pending_typing")
        self.assertEqual(result["observation_waited_ms"], 600)
        self.assertAlmostEqual(clock.now, .6)
        self.assertEqual(result["observation_transient_header_count"], 4)
        self.assertEqual(fake.post_submit_reads, 6)
        self.assertNotIn(MARKER, fake.pages[0])

    def test_header_recovery_does_not_treat_an_old_marker_as_a_new_reply(self):
        fake = WeChatReplyFake([{}, {"header": "对方正在输入…"}, {}])
        fake.pages[0].append(MARKER)
        response, _ = self.execute_send(fake, timeout_ms=600)
        result = self.assert_verified_send(response, fake)
        self.assertTrue(result["observation_timed_out"])
        self.assertEqual(result["observation_transient_header_count"], 1)
        self.assertFalse(result["reply_evidence"]["requested_text_visible"])
        self.assertTrue(result["reply_evidence"]["requested_text_visible_in_current_view"])
        self.assertFalse(result["reply_evidence"]["newly_visible_since_baseline"])
        self.assertEqual(result["new_visible_lines"], [])


if __name__ == "__main__":
    unittest.main()
