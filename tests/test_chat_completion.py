"""Authorized-send and bounded-observation tests. All desktop calls are fakes."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_chat_workflows import WeChatFake, FeishuFake
from chat_workflows import execute_chat, ChatSession, WECHAT, FEISHU, STRUCTURE, VOICE_HINT, CHAT_TOOL
from recipe_store import RecipeStore


def authorization(fake, text, chat=None):
    return {"source": "current_user", "app": fake.app, "chat": chat or fake.title, "text": text}


def send_request(fake, text="获授权的完整指令", **extra):
    return {"app": fake.app, "action": "send", "chat": fake.title, "text": text,
            "send_authorization": authorization(fake, text), **extra}


class WeChatSendFake(WeChatFake):
    def __init__(self):
        super().__init__()
        self.no_echo = False
        self.submit_error = None

    def __call__(self, request):
        if request["command"] != "visual_key" or request.get("key") != "return":
            return super().__call__(request)
        self.calls.append(copy.deepcopy(request))
        if (request.get("allow_submit") is not True or request.get("control_kind") != "chat_composer"
                or request.get("expected_message") != self.draft or request.get("chat_title") != self.title):
            return {"ok": False, "error": {"code": "submit_precondition_failed", "message": "Exact submit guard", "details": {"events_posted": 0, "submit_events_posted": False}}}
        if self.submit_error:
            return {"ok": False, "error": copy.deepcopy(self.submit_error)}
        text, self.draft = self.draft, ""
        if not self.no_echo:
            self.pages[self.page].append(text)
        value = self.visual(request, True)
        value.update(submit_events_posted=True, submit_preconditions_verified=True, send_verified=False, events_posted=2)
        return {"ok": True, "result": value}


class FeishuSendFake(FeishuFake):
    def __init__(self):
        super().__init__()
        self.history_web_area = True
        self.focused_id = None
        self.no_echo = False
        self.submit_error = None

    def __call__(self, request):
        if request["command"] != "submit_text":
            result = super().__call__(request)
            if request["command"] == "click" and request.get("element_id") == "composer":
                self.focused_id = "composer"
            return result
        self.calls.append(copy.deepcopy(request))
        if (request.get("allow_submit") is not True or self.focused_id != "composer"
                or request.get("element_id") != "composer" or request.get("recipient_element_id") != "header"
                or request.get("expected_recipient") != self.title or request.get("expected_value") != self.composer_value()):
            return {"ok": False, "error": {"code": "submit_precondition_failed", "message": "Exact AX submit guard", "details": {"events_posted": 0, "submit_events_posted": False}}}
        if self.submit_error:
            return {"ok": False, "error": copy.deepcopy(self.submit_error)}
        text, self.draft = self.draft, ""
        if not self.no_echo:
            self.pages[self.page].append(text)
        return {"ok": True, "result": {"target_pid": self.pid, "submit_events_posted": True,
                                        "submit_preconditions_verified": True, "send_verified": False, "events_posted": 2}}


class Clock:
    def __init__(self):
        self.now = 0

    def __call__(self):
        self.now += 1
        return self.now


class CompletionTests(unittest.TestCase):
    def execute(self, request, fake):
        return execute_chat(request, fake, recipe_store=False)

    def assert_ok(self, response):
        self.assertTrue(response["ok"], response)
        return response["result"]

    def test_send_requires_exact_current_human_assertion_before_any_native_call(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            for field in (None, "source", "app", "chat", "text", "extra"):
                fake = factory()
                request = send_request(fake)
                if field is None:
                    del request["send_authorization"]
                elif field == "extra":
                    request["send_authorization"][field] = True
                else:
                    request["send_authorization"][field] += " changed"
                response = self.execute(request, fake)
                self.assertEqual(response["error"]["code"], "send_denied")
                self.assertEqual(fake.calls, [])

    def test_single_authorized_send_requires_app_visible_acceptance_not_native_posted_flag(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            fake = factory()
            text = "完整获授权消息"
            result = self.assert_ok(self.execute(send_request(fake, text), fake))
            self.assertTrue(result["sent"])
            self.assertTrue(result["send_verified"])
            self.assertFalse(result["delivery_verified"])
            self.assertEqual(result["submission_state"], "observed_in_chat")
            self.assertEqual(fake.draft, "")
            self.assertEqual(fake.pages[0].count(text), 1)
            submits = [call for call in fake.calls if call["command"] == "submit_text" or call.get("key") == "return"]
            self.assertEqual(len(submits), 1)
            self.assertTrue(submits[0]["allow_submit"])
            self.assertFalse(result["automatic_replay_allowed"])
            if fake.app == FEISHU:
                self.assertEqual(submits[0]["expected_value"], text + STRUCTURE)
                self.assertEqual(submits[0]["recipient_element_id"], "header")
            else:
                self.assertEqual(submits[0]["expected_message"], text)
                self.assertEqual(submits[0]["chat_title"], fake.title)

    def test_existing_exact_authorized_draft_is_sent_without_retyping(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            fake = factory()
            fake.draft = "现有同一完整指令"
            result = self.assert_ok(self.execute(send_request(fake, fake.draft), fake))
            self.assertTrue(result["sent"])
            self.assertFalse(any(call["command"] in {"type_text", "visual_type_text", "clear_text", "batch"} for call in fake.calls))

    def test_different_existing_draft_is_preserved_without_input_or_submit(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            fake = factory()
            fake.draft = "用户自己的草稿"
            response = self.execute(send_request(fake), fake)
            self.assertEqual(response["error"]["code"], "draft_present")
            self.assertFalse(any(call["command"] in {"submit_text", "click", "visual_click", "type_text", "visual_type_text", "batch"} for call in fake.calls))
            self.assertEqual(fake.draft, "用户自己的草稿")

    def test_changed_draft_at_focus_is_not_sent(self):
        fake = WeChatSendFake()
        fake.draft = "已授权消息"
        fake.change_on_click = "用户的新消息"
        response = self.execute(send_request(fake, "已授权消息"), fake)
        self.assertEqual(response["error"]["code"], "draft_changed")
        self.assertFalse(any(call.get("key") == "return" for call in fake.calls))
        self.assertEqual(fake.draft, "用户的新消息")

    def test_specific_unknown_kind_blocks_draft_clear_and_send_in_both_apps(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            for action in ("draft", "clear", "send"):
                fake = factory()
                request = {"app": fake.app, "action": action, "chat_kind": "person"}
                if action == "draft":
                    request["text"] = "指令"
                elif action == "clear":
                    fake.draft = "已有草稿"
                    request["expected_draft"] = fake.draft
                else:
                    request.update(send_request(fake))
                    request.pop("chat")
                    # Send always requires explicit recipient; use the already
                    # selected chat and let current-type classification run.
                    request["chat"] = fake.title
                    if fake.app == WECHAT:
                        fake.search_category = "最常使用"
                with patch("chat_workflows.time.monotonic", side_effect=Clock()), patch("chat_workflows.time.sleep"):
                    response = self.execute(request, fake)
                self.assertFalse(response["ok"])
                self.assertFalse(any(call["command"] == "submit_text" or call.get("key") == "return" or call.get("control_kind") == "chat_composer" or call.get("element_id") == "composer" for call in fake.calls))

    def test_empty_normalized_send_content_is_denied_before_native(self):
        fake = WeChatSendFake()
        response = self.execute(send_request(fake, " \u200b "), fake)
        self.assertEqual(response["error"]["code"], "send_denied")
        self.assertEqual(fake.calls, [])

    def test_native_ax_recipient_or_value_change_at_commit_blocks_all_send_events(self):
        for changed in ("recipient", "draft"):
            fake = FeishuSendFake()
            fake.draft = "已授权消息"
            request = send_request(fake, fake.draft)
            def callback(payload):
                if payload["command"] == "submit_text":
                    if changed == "recipient":
                        fake.title = "另一位收件人"
                    else:
                        fake.draft = "另一段草稿"
                return fake(payload)
            response = self.execute(request, callback)
            self.assertEqual(response["error"]["code"], "submit_precondition_failed")
            self.assertFalse(response["sent"])
            self.assertEqual(len([call for call in fake.calls if call["command"] == "submit_text"]), 1)

    def test_takeover_after_submit_preserves_unknown_state_and_stops_without_replay(self):
        for factory in (WeChatSendFake,):
            fake = factory()
            fake.no_echo = True
            posted = False
            def callback(request):
                nonlocal posted
                result = fake(request)
                if posted and request.get("restore_previous"):
                    result["result"].update(focus_restored=False, focus_restore_attempted=False, restore_reason="user_takeover")
                posted |= request["command"] == "submit_text" or request.get("key") == "return"
                return result
            with patch("chat_workflows.time.monotonic", side_effect=Clock()), patch("chat_workflows.time.sleep"):
                response = self.execute(send_request(fake), callback)
            self.assertEqual(response["error"]["code"], "user_interrupted")
            self.assertIsNone(response["sent"])
            self.assertEqual(len([call for call in fake.calls if call["command"] == "focus"]), 2)
            self.assertEqual(len([call for call in fake.calls if call["command"] == "submit_text" or call.get("key") == "return"]), 1)

    def test_user_activity_after_feishu_focus_return_keeps_readonly_reply_wait(self):
        from test_feishu_focus_restore import FocusFeishuFake
        fake = FocusFeishuFake()
        returned = False
        def callback(request):
            nonlocal returned
            if returned:
                self.assertEqual(request["command"], "inspect")
            result = fake(request)
            if request.get("restore_previous"):
                returned = True
                fake.front = ("com.example.user-app", 901)
                fake.interrupted = "manual_keyboard"
            return result
        with patch("chat_workflows.time.monotonic", side_effect=Clock()), patch("chat_workflows.time.sleep"):
            response = self.execute(send_request(fake, reply_contains="尚未出现的回复", wait_timeout_ms=60000), callback)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["sent"])
        self.assertEqual(response["result"]["submission_state"], "observed_in_chat")
        self.assertTrue(response["result"]["observation_timed_out"])
        self.assertEqual(fake.restore_calls, 1)
        self.assertEqual(len([call for call in fake.calls if call["command"] == "submit_text"]), 1)

    def test_native_zero_event_denial_is_not_replayed_and_reports_not_sent(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            fake = factory()
            fake.submit_error = {"code": "submit_precondition_failed", "message": "Changed before commit", "details": {"events_posted": 0, "submit_events_posted": False}}
            response = self.execute(send_request(fake), fake)
            self.assertFalse(response["sent"])
            self.assertEqual(response["submission_state"], "not_posted")
            self.assertEqual(len([call for call in fake.calls if call["command"] == "submit_text" or call.get("key") == "return"]), 1)

    def test_uncertain_native_post_or_transport_never_reports_false_or_replays(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            fake = factory()
            fake.submit_error = {"code": "after_post_failed", "message": "Completion uncertain", "details": {"events_posted": 1, "submit_events_posted": True}}
            response = self.execute(send_request(fake), fake)
            self.assertIsNone(response["sent"])
            self.assertEqual(response["submission_state"], "unknown")
            self.assertEqual(len([call for call in fake.calls if call["command"] == "submit_text" or call.get("key") == "return"]), 1)
            transport_calls = []
            def transport(request):
                if request["command"] == "submit_text" or request.get("key") == "return":
                    transport_calls.append(request)
                    raise RuntimeError("Connection lost after possible posting")
                return fake(request)
            response = self.execute(send_request(fake), transport)
            self.assertEqual(len(transport_calls), 1)
            self.assertIsNone(response["sent"])
            self.assertFalse(response["automatic_replay_allowed"])

    def test_posted_without_new_message_evidence_remains_unknown_and_recipe_candidate(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            fake = factory()
            fake.no_echo = True
            with tempfile.TemporaryDirectory() as directory, patch("chat_workflows.time.monotonic", side_effect=Clock()), patch("chat_workflows.time.sleep"):
                store = RecipeStore(Path(directory) / "recipes.json")
                response = execute_chat(send_request(fake), fake, recipe_store=store)
                result = self.assert_ok(response)
                self.assertIsNone(result["sent"])
                self.assertFalse(result["send_verified"])
                self.assertEqual(result["submission_state"], "posted_unverified")
                row = store.list()["recipes"][0]
                self.assertEqual(row["verified_successes"], 0)
                self.assertFalse(row["reusable"])
                self.assertEqual(len([call for call in fake.calls if call["command"] == "submit_text" or call.get("key") == "return"]), 1)

    def test_send_acceptance_requires_new_complete_exact_text_not_old_substring_or_cross_row_join(self):
        for fragments in (["完整消息 已在引用中"], ["完整", "消息"], ["完整消息"]):
            fake = WeChatSendFake()
            fake.pages[0] = list(fragments)
            fake.no_echo = True
            with patch("chat_workflows.time.monotonic", side_effect=Clock()), patch("chat_workflows.time.sleep"):
                result = self.assert_ok(self.execute(send_request(fake, "完整消息"), fake))
            self.assertIsNone(result["sent"])
        fake = WeChatSendFake()
        fake.pages[0] = ["完整消息"]
        result = self.assert_ok(self.execute(send_request(fake, "完整消息"), fake))
        self.assertTrue(result["sent"])
        self.assertEqual(fake.pages[0], ["完整消息", "完整消息"])

    def test_send_echo_marker_is_not_a_reply_and_timeout_preserves_verified_send(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            fake = factory()
            result = self.assert_ok(self.execute(send_request(fake, "指令含 MARKER", reply_contains="MARKER", wait_timeout_ms=0), fake))
            self.assertTrue(result["sent"])
            self.assertTrue(result["observation_timed_out"])
            self.assertFalse(result["reply_evidence"]["requested_text_visible"])
            self.assertTrue(result["reply_evidence"]["requested_text_visible_in_current_view"])
            self.assertEqual(result["new_visible_lines"], [])

    def test_send_waits_for_changed_text_after_echo_baseline_without_claiming_sender(self):
        fake = FeishuSendFake()
        posted = False
        reads_after_post = 0
        def callback(request):
            nonlocal posted, reads_after_post
            if request["command"] == "inspect" and posted:
                reads_after_post += 1
                if reads_after_post == 4:
                    fake.pages[0].append("实际新可见回复 MARKER")
            envelope = fake(request)
            posted |= request["command"] == "submit_text"
            return envelope
        with patch("chat_workflows.time.monotonic", side_effect=Clock()), patch("chat_workflows.time.sleep"):
            result = self.assert_ok(self.execute(send_request(fake, "指令 MARKER", reply_contains="MARKER", wait_timeout_ms=60000), callback))
        self.assertTrue(result["sent"])
        self.assertEqual(result["new_visible_lines"], ["实际新可见回复 MARKER"])
        self.assertTrue(result["reply_evidence"]["requested_text_visible"])
        self.assertFalse(result["reply_evidence"]["sender_verified"])
        self.assertIsNone(result["reply_evidence"]["new_since_request"])
        self.assertEqual(len([call for call in fake.calls if call["command"] == "submit_text"]), 1)

    def test_long_bounded_read_waits_past_five_seconds_and_uses_only_baseline_difference(self):
        fake = FeishuFake()
        baseline = "新消息\n最后回复"
        def callback(request):
            if request["command"] == "inspect" and fake.inspections >= 10:
                fake.pages[0].append("新响应 MARKER")
            return fake(request)
        with patch("chat_workflows.time.monotonic", side_effect=Clock()), patch("chat_workflows.time.sleep"):
            result = self.assert_ok(self.execute({"app": FEISHU, "action": "read", "previous_visible_text": baseline,
                                                 "reply_contains": "MARKER", "wait_timeout_ms": 60000}, callback))
        self.assertGreater(result["observation_waited_ms"], 5000)
        self.assertTrue(result["reply_evidence"]["requested_text_visible"])
        self.assertFalse(result["reply_evidence"]["sender_verified"])
        self.assertIsNone(result["reply_evidence"]["new_since_request"])

    def test_baseline_old_same_value_and_whitespace_reflow_do_not_claim_new_reply(self):
        for baseline in ("新消息\n最后回复", " 新 消 息 \n 最后 回复 "):
            fake = WeChatFake()
            result = self.assert_ok(self.execute({"app": WECHAT, "action": "read", "baseline_text": baseline,
                                                 "reply_contains": "最后回复", "wait_timeout_ms": 0}, fake))
            self.assertFalse(result["visible_text_changed"])
            self.assertFalse(result["reply_evidence"]["requested_text_visible"])
            self.assertEqual(result["new_visible_lines"], [])
        fake.pages[0].append("引用 MARKER 原文")
        result = self.assert_ok(self.execute({"app": WECHAT, "action": "read", "baseline_text": "新消息\n最后回复", "reply_contains": "MARKER"}, fake))
        self.assertTrue(result["reply_evidence"]["requested_text_visible"])
        self.assertFalse(result["reply_evidence"]["sender_verified"])
        self.assertIsNone(result["reply_evidence"]["new_since_request"])

    def test_observation_validates_sixty_second_bound_and_conflicting_aliases_before_native(self):
        for extra in ({"wait_timeout_ms": 60001}, {"baseline_text": "A", "previous_visible_text": "B"}):
            fake = WeChatFake()
            response = self.execute({"app": WECHAT, "action": "read", **extra}, fake)
            self.assertFalse(response["ok"])
            self.assertEqual(fake.calls, [])
        self.assertEqual(CHAT_TOOL["inputSchema"]["properties"]["wait_timeout_ms"]["maximum"], 60000)

    def test_send_recipe_retains_no_authorization_recipient_or_message_content(self):
        fake = FeishuSendFake()
        fake.title = "保密收件人"
        with tempfile.TemporaryDirectory() as directory:
            store = RecipeStore(Path(directory) / "recipes.json")
            response = execute_chat(send_request(fake, "保密正文内容"), fake, recipe_store=store)
            self.assertTrue(response["ok"], response)
            row = store.list()["recipes"][0]
            self.assertTrue(row["reusable"])
            self.assertEqual(row["verification_criterion"], "same_chat_empty_composer_and_new_visible_message")
            serialized = store.path.read_text()
            self.assertNotIn("保密收件人", serialized)
            self.assertNotIn("保密正文内容", serialized)
            self.assertNotIn("current_user", serialized)


    def test_unclosed_local_section_expands_before_claiming_uniqueness(self):
        fake = WeChatFake()
        fake.search = "相同名称"
        fake.ambiguous = True
        # Move the second local same-name result below the first 320pt scout.
        def callback(request):
            envelope = fake(request)
            if request["command"] == "visual_read" and request["region"]["height"] > 900:
                envelope["result"]["ocr"].append({"text": "相同名称 AI", "bounds": {"x": fake.frame["x"] + 110, "y": 750, "width": 120, "height": 25}})
            return envelope
        fake.ambiguous = False
        session = ChatSession({"app": WECHAT, "action": "locate", "chat": "相同名称"}, callback)
        session.frame, session.pid, session.anchors = fake.frame, fake.pid, [fake.title, "发送"]
        result = session.wechat_search_read()
        self.assertEqual([call["region"]["height"] for call in fake.calls if call["command"] == "visual_read"], [320, fake.frame["height"] * .928])
        with self.assertRaisesRegex(Exception, "Multiple exact local"):
            session.wechat_result(result, "相同名称")


if __name__ == "__main__":
    unittest.main()
