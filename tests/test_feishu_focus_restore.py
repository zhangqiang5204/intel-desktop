"""Foreground chat completion includes one guarded return to the saved origin.

All focus, keyboard, message and handoff behavior below is a fake native owner.
"""
import copy
import unittest
from unittest.mock import patch

from chat_workflows import ChatSession, FEISHU, SEARCH_MODAL, Stopped, _focus_claim_receipt, execute_chat
from test_chat_completion import FeishuSendFake, send_request


class FocusFeishuFake(FeishuSendFake):
    def __init__(self):
        super().__init__()
        self.origin = ("com.example.origin", 900)
        self.front = self.origin
        self.saved_origin = None
        self.claimed_window = None
        self.origin_overwritten = False
        self.interrupted = None
        self.restore_reason = None
        self.restore_error = None
        self.focus_denial = None
        self.restore_calls = 0

    def __call__(self, request):
        command = request["command"]
        if command == "focus":
            self.calls.append(copy.deepcopy(request))
            if request.get("restore_previous"):
                self.restore_calls += 1
                if self.restore_error:
                    raise OSError("Fake restoration transport failure")
                reason = "user_takeover" if self.interrupted else self.restore_reason or ("no_previous_focus" if self.saved_origin is None else None)
                if reason:
                    return {"ok": True, "result": {"focus_restored": False,
                        "focus_restore_attempted": False, "restore_reason": reason,
                        "previous_focus_scope": "exact_window", "events_posted": 0}}
                self.front = self.saved_origin or self.front
                return {"ok": True, "result": {"focus_restored": True,
                    "focus_restore_attempted": True, "restore_reason": "previous_window_verified",
                    "focus_restored_app": True, "window_verified": True,
                    "previous_focus_scope": "exact_window", "restore_scope": "exact_window",
                    "owned_navigation_focus_updated": self.claimed_window == SEARCH_MODAL and not self.modal,
                    "target_pid": self.front[1], "events_posted": 0}}
            if self.focus_denial:
                return {"ok": False, "error": {"code": self.focus_denial,
                    "message": "Fake handoff denied while origin stays active", "details": {"events_posted": 0}}}
            # Mirrors the real native record invalidation: after the owned modal
            # closes, a second claim would capture Feishu itself as the origin.
            if self.saved_origin is None or self.claimed_window == SEARCH_MODAL and not self.modal:
                self.origin_overwritten |= self.saved_origin is not None
                self.saved_origin = self.front
            self.claimed_window = request["window_title"]
            self.front = (self.app, self.pid)
            return {"ok": True, "result": {"target_pid": self.pid,
                "window_title": request["window_title"], "foreground_verified": True,
                "previous_focus_recorded": True, "previous_focus_scope": "exact_window",
                "handoff_notice_shown": True, "handoff_wait_ms": 1250.0,
                "continuous_task_focus_claim": False, "takeover_baseline": "before_target_activation"}}
        response = super().__call__(request)
        if command == "status":
            response["result"].update(frontmost_app_bundle_id=self.front[0],
                frontmost_pid=self.front[1], interrupted=self.interrupted)
        return response


class FeishuFocusRestoreTests(unittest.TestCase):
    def execute(self, fake, action="read", **kwargs):
        return execute_chat({"app": FEISHU, "action": action, **kwargs}, fake, recipe_store=False)

    def claims(self, fake):
        return [c for c in fake.calls if c["command"] == "focus" and not c.get("restore_previous")]

    def test_locate_read_draft_clear_and_send_finish_with_exact_origin(self):
        for action in ("locate", "read", "draft", "clear", "send"):
            with self.subTest(action=action):
                fake = FocusFeishuFake()
                kwargs = {"chat": fake.title}
                if action == "draft": kwargs["text"] = "离线草稿"
                if action == "clear":
                    fake.draft = "离线草稿"
                    kwargs["expected_draft"] = fake.draft
                request = send_request(fake) if action == "send" else {"app": FEISHU, "action": action, **kwargs}
                response = execute_chat(request, fake, recipe_store=False)
                self.assertTrue(response["ok"], response)
                self.assertTrue(response["scope_completed"])
                self.assertTrue(response["focus_return_required"])
                self.assertEqual(response["focus_lifecycle"], "restored")
                self.assertEqual(fake.front, fake.origin)
                self.assertEqual(response["result"]["target_pid"], fake.pid)
                self.assertTrue(response["result"]["focus_restored"])
                self.assertEqual(fake.restore_calls, 1)
                self.assertEqual(len(self.claims(fake)), 1)
                self.assertTrue(fake.calls[-1].get("restore_previous"))

    def test_existing_modal_read_keeps_first_origin_without_second_claim(self):
        fake = FocusFeishuFake()
        fake.modal = True
        response = self.execute(fake)
        self.assertTrue(response["ok"], response)
        self.assertFalse(fake.modal)
        self.assertFalse(fake.origin_overwritten)
        self.assertEqual(fake.front, fake.origin)
        self.assertEqual([c["window_title"] for c in self.claims(fake)], [SEARCH_MODAL])
        self.assertTrue(response["owned_navigation_focus_updated"])
        self.assertEqual(len([c for c in fake.calls if c["command"] == "key" and c.get("key") == "escape"]), 1)

    def test_business_failure_restores_without_draft_mutation(self):
        fake = FocusFeishuFake()
        fake.draft = "已有草稿"
        response = self.execute(fake, "clear", expected_draft="不同草稿")
        self.assertEqual(response["error"]["code"], "draft_changed")
        self.assertTrue(response["focus_restored"])
        self.assertFalse(response["scope_completed"])
        self.assertEqual(fake.front, fake.origin)
        self.assertEqual(fake.draft, "已有草稿")
        self.assertFalse(any(c["command"] in {"type_text", "clear_text", "submit_text"} for c in fake.calls))

    def test_unverified_or_partial_draft_still_requests_guarded_return_once(self):
        for mode in ("readback", "partial", "transport"):
            with self.subTest(mode=mode):
                fake = FocusFeishuFake()
                fake.extra_postcondition_text = mode == "readback"
                fake.fail_on_type = mode == "partial"
                def callback(request):
                    if mode == "transport" and request["command"] == "batch":
                        fake(request)
                        raise OSError("Fake lost completion")
                    return fake(request)
                response = execute_chat({"app": FEISHU, "action": "draft", "text": "完整离线请求"}, callback, recipe_store=False)
                self.assertFalse(response["ok"])
                self.assertTrue(response["focus_restored"], response)
                self.assertFalse(response["automatic_replay_allowed"])
                self.assertEqual(fake.restore_calls, 1)
                self.assertEqual(len([c for c in fake.calls if c["command"] == "type_text"]), 1)
                self.assertEqual(fake.front, fake.origin)

    def test_native_ok_with_failed_return_is_not_whole_scope_success(self):
        for reason in ("no_previous_focus", "task_focus_changed", "previous_activation_failed", "restore_unverified"):
            with self.subTest(reason=reason):
                fake = FocusFeishuFake()
                fake.restore_reason = reason
                response = self.execute(fake, "draft", text="只输入一次")
                self.assertFalse(response["ok"], response)
                self.assertEqual(response["error"]["code"], "focus_restore_unverified")
                self.assertTrue(response["business_completed"])
                self.assertTrue(response["result"]["draft_verified"])
                self.assertFalse(response["scope_completed"])
                self.assertEqual(response["focus_lifecycle"], "unverified")
                self.assertTrue(response["focus_restore_requested"])
                self.assertFalse(response["focus_restore_attempted"])
                self.assertFalse(response["automatic_replay_allowed"])
                self.assertEqual(fake.restore_calls, 1)
                self.assertEqual(len(self.claims(fake)), 1)
                self.assertEqual(len([c for c in fake.calls if c["command"] == "type_text"]), 1)

    def test_verified_send_survives_focus_return_failure_without_resubmit(self):
        fake = FocusFeishuFake()
        fake.restore_reason = "task_focus_changed"
        response = execute_chat(send_request(fake), fake, recipe_store=False)
        self.assertFalse(response["ok"], response)
        self.assertTrue(response["result"]["sent"])
        self.assertTrue(response["result"]["send_verified"])
        self.assertTrue(response["sent"])
        self.assertTrue(response["send_verified"])
        self.assertEqual(response["submission_state"], "observed_in_chat")
        self.assertEqual(len([c for c in fake.calls if c["command"] == "submit_text"]), 1)
        self.assertEqual(fake.restore_calls, 1)

    def test_restore_transport_error_is_explicit_and_never_retried(self):
        fake = FocusFeishuFake()
        fake.restore_error = True
        response = self.execute(fake)
        self.assertFalse(response["ok"], response)
        self.assertTrue(response["business_completed"])
        self.assertEqual(response["restore_reason"], "native_transport_error")
        self.assertEqual(fake.restore_calls, 1)
        self.assertEqual(len(self.claims(fake)), 1)
        self.assertIsNone(response["focus_restore_attempted"])

    def test_lost_initial_claim_receipt_still_uses_native_original_guard_once(self):
        fake = FocusFeishuFake()
        def callback(request):
            response = fake(request)
            if request["command"] == "focus" and not request.get("restore_previous"):
                raise OSError("Fake lost claim receipt")
            return response
        response = execute_chat({"app": FEISHU, "action": "read"}, callback, recipe_store=False)
        self.assertEqual(response["error"]["code"], "native_transport_error")
        self.assertFalse(response["focus_claim_verified"])
        self.assertTrue(response["focus_restored"])
        self.assertEqual(fake.front, fake.origin)
        self.assertEqual(fake.restore_calls, 1)
        self.assertEqual(len(self.claims(fake)), 1)

    def test_clear_recovery_with_actual_takeover_never_returns(self):
        fake = FocusFeishuFake()
        session = ChatSession({"app": FEISHU, "action": "read"}, fake)
        session.start()
        session.clear_recovery = {"verified": False, "stop_code": "user_interrupted"}
        response = session.finish_focus(Stopped("clear_unverified", "Clear result unknown"))
        self.assertEqual(response["restore_reason"], "user_interrupted")
        self.assertFalse(response["focus_restore_attempted"])
        self.assertEqual(fake.restore_calls, 0)

    def test_real_post_claim_takeover_never_returns_or_reclaims(self):
        fake = FocusFeishuFake()
        original = fake.__call__
        def callback(request):
            response = original(request)
            if request["command"] == "focus" and not request.get("restore_previous"):
                fake.interrupted = "physical_keyboard_after_claim"
            return response
        response = execute_chat({"app": FEISHU, "action": "read"}, callback, recipe_store=False)
        self.assertEqual(response["error"]["code"], "user_interrupted")
        self.assertEqual(response["focus_lifecycle"], "yielded_to_user")
        self.assertEqual(fake.restore_calls, 0)
        self.assertEqual(len(self.claims(fake)), 1)

    def test_late_native_takeover_yields_and_does_not_report_scope_completed(self):
        fake = FocusFeishuFake()
        fake.restore_reason = "user_takeover"
        response = self.execute(fake, "draft", text="草稿已验证")
        self.assertFalse(response["scope_completed"])
        self.assertEqual(response["focus_lifecycle"], "yielded_to_user")
        self.assertTrue(response["result"]["draft_verified"])
        self.assertEqual(fake.restore_calls, 1)
        self.assertEqual(len(self.claims(fake)), 1)

    def test_partial_business_error_cannot_override_native_takeover_guard(self):
        fake = FocusFeishuFake()
        fake.fail_on_type = True
        def callback(request):
            response = fake(request)
            if request["command"] == "batch":
                fake.interrupted = "physical_keyboard_during_input"
            return response
        response = execute_chat({"app": FEISHU, "action": "draft", "text": "离线草稿"}, callback, recipe_store=False)
        self.assertEqual(response["error"]["code"], "postcondition_failed")
        self.assertFalse(response["focus_restored"])
        self.assertEqual(response["focus_lifecycle"], "yielded_to_user")
        self.assertFalse(response["focus_restore_attempted"])
        self.assertEqual(fake.front, (fake.app, fake.pid))
        self.assertEqual(fake.restore_calls, 1)
        self.assertEqual(len(self.claims(fake)), 1)

    def test_actual_foreground_loss_never_requests_restore(self):
        fake = FocusFeishuFake()
        def callback(request):
            response = fake(request)
            if request["command"] == "focus" and not request.get("restore_previous"):
                fake.front = ("com.example.userselected", 901)
            return response
        response = execute_chat({"app": FEISHU, "action": "read"}, callback, recipe_store=False)
        self.assertEqual(response["error"]["code"], "foreground_mismatch")
        self.assertFalse(response["scope_completed"])
        self.assertFalse(response["focus_restore_requested"])
        self.assertEqual(fake.front, ("com.example.userselected", 901))
        self.assertEqual(fake.restore_calls, 0)

    def test_keyboard_busy_handoff_retains_origin_and_never_posts_input(self):
        fake = FocusFeishuFake()
        fake.focus_denial = "user_interrupted"
        response = self.execute(fake, "draft", text="不要输入")
        self.assertEqual(response["error"]["code"], "user_interrupted")
        self.assertFalse(response["focus_return_required"])
        self.assertEqual(fake.front, fake.origin)
        self.assertEqual(fake.restore_calls, 0)
        self.assertFalse(any(c["command"] in {"type_text", "click", "submit_text"} for c in fake.calls))

    def test_first_handoff_receipt_is_safe_typed_and_survives_completion(self):
        fake = FocusFeishuFake()
        response = self.execute(fake)
        self.assertTrue(response["focus_claim_verified"])
        self.assertEqual(response["focus_claim_receipt"], {"previous_focus_recorded": True,
            "previous_focus_scope": "exact_window", "handoff_notice_shown": True,
            "handoff_wait_ms": 1250.0, "continuous_task_focus_claim": False,
            "takeover_baseline": "before_target_activation"})
        self.assertNotIn("com.example.origin", str(response["focus_claim_receipt"]))

    def test_claim_receipt_drops_untyped_unbounded_and_content_fields(self):
        self.assertEqual(_focus_claim_receipt({"previous_focus_recorded": "true", "handoff_notice_shown": 1,
            "continuous_task_focus_claim": False, "handoff_wait_ms": float("nan"),
            "previous_focus_scope": "arbitrary", "takeover_baseline": "private content",
            "original_window_title": "private content", "origin_bundle": "com.example.origin"}),
            {"continuous_task_focus_claim": False})
        self.assertEqual(_focus_claim_receipt({"handoff_wait_ms": 5001}), {})

    def test_unexpected_business_exception_returns_unknown_and_returns_focus(self):
        fake = FocusFeishuFake()
        def stopped(session):
            session.start()
            raise ValueError("Private diagnostic must not be retained")
        with patch.object(ChatSession, "run", stopped):
            response = self.execute(fake)
        self.assertEqual(response["error"]["code"], "operation_completion_unknown")
        self.assertEqual(response["error"]["details"], {"exception_type": "ValueError"})
        self.assertTrue(response["focus_restored"])
        self.assertNotIn("Private diagnostic", str(response))
        self.assertEqual(fake.restore_calls, 1)

    def test_background_path_never_claims_or_restores(self):
        from test_background_chat_edit import BackgroundFake
        fake = BackgroundFake(FEISHU)
        response = self.execute(fake, "draft", background=True, text="后台草稿")
        self.assertTrue(response["ok"], response)
        self.assertNotIn("focus_return_required", response)
        self.assertFalse(any(c["command"] == "focus" for c in fake.base.calls))


if __name__ == "__main__":
    unittest.main()
