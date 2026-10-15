"""A failed activation may return focus, never business success or a new claim."""
import copy
import unittest

from chat_workflows import ChatSession, Stopped, WECHAT, _focus_acquisition_return, execute_chat
from test_chat_completion import send_request
from test_chat_workflows import WeChatFake


def receipt(pid=123, restored=True):
    return {"failed_acquisition_return": True, "acquisition_same_command": True,
        "acquisition_target_pid": pid, "events_posted": 0,
        "focus_restored": restored, "focus_restore_attempted": restored,
        "restore_reason": "previous_window_verified" if restored else "user_takeover",
        "focus_restored_app": restored, "window_verified": restored,
        "previous_focus_scope": "exact_window", "restore_scope": "exact_window",
        "focus_return_materialized_uptime_ms": 123456.0}


class FailedFocusFake(WeChatFake):
    def __init__(self, native_receipt):
        super().__init__()
        self.native_receipt = native_receipt
        self.restore_calls = 0

    def __call__(self, request):
        if request["command"] == "focus":
            self.calls.append(copy.deepcopy(request))
            if request.get("restore_previous"):
                self.restore_calls += 1
                return {"ok": True, "result": {"focus_restored": False,
                    "focus_restore_attempted": False, "restore_reason": "no_previous_focus"}}
            return {"ok": False, "error": {"code": "window_mismatch", "message": "Actual focused window differs",
                "details": {"events_posted": 0, "focus_acquisition_return": self.native_receipt}}}
        return super().__call__(request)


class FailedFocusReturnTests(unittest.TestCase):
    def test_actual_return_receipt_keeps_original_error_without_second_restore(self):
        fake = FailedFocusFake(receipt())
        result = execute_chat(send_request(fake), fake, recipe_store=False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "window_mismatch")
        self.assertFalse(result["sent"])
        self.assertFalse(result["business_completed"])
        self.assertFalse(result["scope_completed"])
        self.assertTrue(result["focus_restored"])
        self.assertFalse(result["focus_claim_verified"])
        self.assertEqual(result["restore_reason"], "previous_window_verified")
        self.assertEqual(fake.restore_calls, 0)
        self.assertEqual([c["command"] for c in fake.calls], ["status", "inspect", "focus"])

    def test_user_takeover_receipt_yields_without_another_focus_request(self):
        fake = FailedFocusFake(receipt(restored=False))
        result = execute_chat(send_request(fake), fake, recipe_store=False)
        self.assertFalse(result["ok"])
        self.assertFalse(result["focus_restored"])
        self.assertEqual(result["focus_lifecycle"], "yielded_to_user")
        self.assertEqual(fake.restore_calls, 0)

    def test_incomplete_or_wrong_target_receipt_never_becomes_verified_return(self):
        for key, value in (("acquisition_target_pid", 999), ("events_posted", True), ("events_posted", 1),
                           ("focus_return_materialized_uptime_ms", float("nan")), ("window_verified", False),
                           ("acquisition_same_command", False), ("restore_reason", "arbitrary user text")):
            with self.subTest(key=key):
                changed = {**receipt(), key: value}
                self.assertIsNone(_focus_acquisition_return(changed, 123))
                fake = FailedFocusFake(changed)
                result = execute_chat(send_request(fake), fake, recipe_store=False)
                self.assertFalse(result["focus_restored"])
                self.assertEqual(result["error"]["code"], "window_mismatch")

    def test_receipt_does_not_apply_to_a_business_input_error(self):
        session = ChatSession({"app": WECHAT}, lambda _: {"ok": False,
            "error": {"code": "window_mismatch", "message": "fixture", "details": {"focus_acquisition_return": receipt()}}})
        session.pid = 123
        with self.assertRaises(Stopped):
            session.call("visual_type_text")
        self.assertIsNone(session.focus_acquisition_return)

    def test_native_transport_unknown_never_replays_focus(self):
        session = ChatSession({"app": WECHAT}, lambda _: (_ for _ in ()).throw(OSError("lost")))
        session.pid = 123
        with self.assertRaises(Stopped) as failure:
            session.call("focus")
        result = session.finish_focus(failure.exception)
        self.assertFalse(result["focus_restored"])
        self.assertEqual(len(session.calls), 1)


if __name__ == "__main__":
    unittest.main()
