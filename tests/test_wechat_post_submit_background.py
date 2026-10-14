"""One posted Return returns focus once, then confirms only background OCR."""
import copy
import itertools
import unittest
from unittest.mock import patch

from chat_workflows import execute_chat
from test_chat_completion import send_request
from test_wechat_send_focus_reuse import RetainedSendFake


class PostSubmitWeChatFake(RetainedSendFake):
    def __init__(self, change=None, delay=0):
        super().__init__()
        self.change, self.delay = change, delay
        self.returned = False
        self.background_reads = 0
        self.restore_calls = 0
        self.text = send_request(self)["text"]
        self.user_app = "com.example.original"
        self.front = self.user_app

    def __call__(self, request):
        command = request["command"]
        if self.returned:
            assert command == "background_visual_read", "No foreground checks, input or focus after the return request"
        if command == "focus" and request.get("restore_previous"):
            self.calls.append(copy.deepcopy(request))
            self.restore_calls += 1
            self.returned = True
            if self.change == "return_transport":
                raise RuntimeError("Lost restoration response")
            reason = "user_takeover" if self.change == "takeover" else "task_focus_changed" if self.change == "return_failed" else "previous_window_verified"
            restored = reason == "previous_window_verified"
            if restored:
                self.front = self.user_app
            if self.change == "user_activity":
                self.front = "com.example.user-chosen"
                self.interrupted = "manual_keyboard"
            return {"ok": True, "result": {"focus_restored": restored,
                "focus_restore_attempted": restored, "restore_reason": reason, "events_posted": 0}}
        response = super().__call__(request)
        if command == "focus":
            self.front = self.app
        if request.get("key") == "return" and response["ok"]:
            if self.change in {"submit_events_posted", "submit_preconditions_verified"}:
                response["result"].pop(self.change)
            if self.change == "missing_submit_window":
                response["result"].pop("window_id")
        if command == "background_visual_read" and response["ok"]:
            self.background_reads += 1
            value = response["result"]
            if self.background_reads <= self.delay:
                value["ocr"] = [row for row in value["ocr"] if row["text"] != self.text]
            if self.change == "PID": value["target_pid"] += 1
            if self.change == "window": value["window_id"] += 1
            if self.change == "frame": value["window_frame"]["x"] += 1
            if self.change == "topology": value["display_topology_signature"] = "another-screen"
            if self.change == "recipient":
                for row in value["ocr"]:
                    if row["text"] == self.title: row["text"] = "其他联系人"
                value["anchor_matches"] = []
            if self.change == "truncated": value["ocr_truncated"] = True
            if self.change == "capture": value["captured_regions"] = []
            if self.change == "scan": value["ocr_regions"] = []
            if self.change == "composer_capture":
                value["captured_regions"] = request["regions"][:2] + request["regions"][3:]
            if self.change == "body_capture": value["captured_regions"] = request["regions"][:3]
            if self.change == "input_eligible": value["input_eligible"] = True
            if self.change == "not_readonly": value["read_only_background"] = False
            if self.change == "identity": value["target_identity_verified"] = False
            if self.change == "content": value["content_available"] = False
            if self.change == "new_draft" or self.change == "transient_draft_ocr" and self.background_reads == 1:
                changed = "用户后来输入的新草稿"
                if self.change == "new_draft": self.draft = changed
                value["ocr"].append({"text": changed, "bounds": {
                    "x": self.frame["x"] + 336, "y": self.frame["y"] + self.frame["height"] * .88,
                    "width": 300, "height": 25}})
            # Exact target OCR is sufficient for a read-only capture. A hidden
            # background target must never be promoted to input eligibility.
            value["target_visible_verified"] = False
        return response


class WeChatPostSubmitBackgroundTests(unittest.TestCase):
    def send(self, fake, **kwargs):
        clock = itertools.count(0, .5)
        with patch("chat_workflows.time.monotonic", side_effect=lambda: next(clock)), patch("chat_workflows.time.sleep"):
            return execute_chat(send_request(fake, **kwargs), fake, recipe_store=False)

    def assert_once_and_readonly(self, fake):
        self.assertEqual(fake.restore_calls, 1)
        self.assertEqual(sum(c.get("key") == "return" for c in fake.calls), 1)
        submit = next(i for i, c in enumerate(fake.calls) if c.get("key") == "return")
        self.assertTrue(fake.calls[submit + 1].get("restore_previous"))
        self.assertTrue(all(c["command"] == "background_visual_read" for c in fake.calls[submit + 2:]))
        self.assertEqual(sum(c["command"] == "focus" and not c.get("restore_previous") for c in fake.calls), 1)

    def test_return_precedes_delayed_confirmation_and_only_background_reads_follow(self):
        fake = PostSubmitWeChatFake(delay=2)
        response = self.send(fake)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertTrue(response["business_completed"])
        self.assertTrue(response["scope_completed"])
        self.assertEqual(fake.background_reads, 3)
        self.assertEqual(fake.front, fake.user_app)
        self.assert_once_and_readonly(fake)

    def test_user_activity_after_return_preserves_readonly_reply_wait_and_focus(self):
        fake = PostSubmitWeChatFake("user_activity")
        response = self.send(fake, reply_contains="尚未出现的回复", wait_timeout_ms=3000)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertEqual(fake.front, "com.example.user-chosen")
        self.assertEqual(fake.interrupted, "manual_keyboard")
        self.assertGreater(fake.background_reads, 1)
        self.assert_once_and_readonly(fake)

    def test_changed_background_identity_and_recipient_fail_without_reclaim(self):
        for change in ("PID", "window", "frame", "topology", "recipient"):
            with self.subTest(change=change):
                fake = PostSubmitWeChatFake(change)
                response = self.send(fake)
                self.assertFalse(response["ok"], response)
                self.assertIsNone(response["sent"])
                self.assertTrue(response["completion_unknown"])
                self.assertFalse(response["business_completed"])
                self.assertTrue(response["focus_restored"])
                self.assert_once_and_readonly(fake)

    def test_complete_header_composer_body_capture_and_readonly_proof_are_required(self):
        for change in ("truncated", "capture", "scan", "composer_capture", "body_capture",
                       "input_eligible", "not_readonly", "identity", "content"):
            with self.subTest(change=change):
                fake = PostSubmitWeChatFake(change)
                response = self.send(fake)
                self.assertFalse(response["ok"], response)
                self.assertIsNone(response["sent"])
                self.assertTrue(response["completion_unknown"])
                self.assertFalse(response["scope_completed"])
                self.assert_once_and_readonly(fake)

    def test_new_draft_is_preserved_without_cleanup_or_second_submit(self):
        fake = PostSubmitWeChatFake("new_draft")
        response = self.send(fake)
        self.assertEqual(response["error"]["code"], "draft_changed")
        self.assertIsNone(response["sent"])
        self.assertFalse(response["business_completed"])
        self.assertEqual(fake.background_reads, 2)
        self.assertEqual(fake.draft, "用户后来输入的新草稿")
        self.assert_once_and_readonly(fake)

    def test_one_foreign_looking_ocr_frame_can_resolve_only_through_strict_empty_plus_body_proof(self):
        fake = PostSubmitWeChatFake("transient_draft_ocr")
        response = self.send(fake)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["sent"])
        self.assertTrue(response["result"]["send_verified"])
        self.assertTrue(response["result"]["draft_empty"])
        self.assertEqual(fake.background_reads, 2)
        self.assertEqual(fake.draft, "")
        self.assert_once_and_readonly(fake)

    def test_foreign_draft_reobservation_cannot_extend_the_original_deadline(self):
        fake = PostSubmitWeChatFake("transient_draft_ocr")
        clock = {"now": 0.0}
        def invoke(request):
            response = fake(request)
            if request["command"] == "background_visual_read":
                clock["now"] = 4.95
            return response
        def sleep(duration):
            clock["now"] += duration
        with patch("chat_workflows.time.monotonic", side_effect=lambda: clock["now"]), patch("chat_workflows.time.sleep", side_effect=sleep):
            response = execute_chat(send_request(fake), invoke, recipe_store=False)
        self.assertEqual(response["error"]["code"], "draft_changed")
        self.assertIsNone(response["sent"])
        self.assertEqual(fake.background_reads, 1)
        self.assertEqual(clock["now"], 5)
        self.assert_once_and_readonly(fake)

    def test_missing_submit_proof_never_starts_early_return_or_background_confirmation(self):
        for flag in ("submit_events_posted", "submit_preconditions_verified"):
            with self.subTest(flag=flag):
                fake = PostSubmitWeChatFake(flag)
                response = self.send(fake)
                self.assertFalse(response["ok"])
                self.assertIsNone(response["sent"])
                self.assertEqual(response["restore_reason"], "unknown_input_outcome")
                self.assertEqual(fake.restore_calls, 0)
                self.assertEqual(fake.background_reads, 0)
                self.assertEqual(sum(c.get("key") == "return" for c in fake.calls), 1)

    def test_missing_window_binding_still_returns_once_but_never_invents_confirmation(self):
        fake = PostSubmitWeChatFake("missing_submit_window")
        response = self.send(fake)
        self.assertEqual(response["error"]["code"], "send_state_unknown")
        self.assertIsNone(response["sent"])
        self.assertEqual(fake.background_reads, 0)
        self.assert_once_and_readonly(fake)

    def test_no_echo_remains_unknown_after_original_deadline_without_replay(self):
        fake = PostSubmitWeChatFake()
        fake.no_echo = True
        response = self.send(fake)
        self.assertTrue(response["ok"], response)
        self.assertIsNone(response["result"]["sent"])
        self.assertFalse(response["business_completed"])
        self.assertFalse(response["scope_completed"])
        self.assertTrue(response["focus_restored"])
        self.assertEqual(fake.background_reads, 10)
        self.assert_once_and_readonly(fake)

    def test_guarded_return_time_consumes_the_original_confirmation_deadline(self):
        clock = {"now": 0.0}
        fake = PostSubmitWeChatFake()
        fake.no_echo = True
        def invoke(request):
            response = fake(request)
            if request.get("restore_previous"):
                clock["now"] += 6
            return response
        with patch("chat_workflows.time.monotonic", side_effect=lambda: clock["now"]), patch("chat_workflows.time.sleep"):
            response = execute_chat(send_request(fake), invoke, recipe_store=False)
        self.assertTrue(response["ok"], response)
        self.assertIsNone(response["result"]["sent"])
        self.assertEqual(fake.background_reads, 1)
        self.assert_once_and_readonly(fake)

    def test_old_exact_body_occurrence_cannot_replace_a_new_send_echo(self):
        fake = PostSubmitWeChatFake()
        fake.pages[0].append(fake.text)
        fake.no_echo = True
        response = self.send(fake)
        self.assertIsNone(response["result"]["sent"])
        self.assertFalse(response["result"]["send_verified"])
        self.assert_once_and_readonly(fake)

    def test_native_restore_failure_and_transport_uncertainty_are_cached_scope_failures(self):
        for change in ("return_failed", "return_transport"):
            with self.subTest(change=change):
                fake = PostSubmitWeChatFake(change)
                response = self.send(fake)
                self.assertFalse(response["ok"])
                self.assertEqual(response["error"]["code"], "focus_restore_unverified")
                self.assertTrue(response["sent"])
                self.assertTrue(response["business_completed"])
                self.assertFalse(response["scope_completed"])
                self.assertFalse(response["focus_restored"])
                self.assert_once_and_readonly(fake)

    def test_true_takeover_at_return_yields_without_resetting_user_activity(self):
        fake = PostSubmitWeChatFake("takeover")
        response = self.send(fake)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "user_interrupted")
        self.assertEqual(response["focus_lifecycle"], "yielded_to_user")
        self.assertTrue(response["sent"])
        self.assertFalse(response["scope_completed"])
        self.assert_once_and_readonly(fake)


if __name__ == "__main__":
    unittest.main()
