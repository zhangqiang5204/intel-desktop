"""One authorized focus claim ignores only historical pre-claim activity."""
import unittest

from test_chat_workflows import FeishuFake, WeChatFake
from chat_workflows import ChatSession, Stopped, WECHAT, execute_chat


class TakeoverFake(WeChatFake):
    def __init__(self, after_focus=None):
        super().__init__()
        self.interrupted = "manual_before_claim"
        self.after_focus = after_focus
        self.focus_count = 0

    def __call__(self, request):
        response = super().__call__(request)
        if request["command"] == "focus" and not request.get("restore_previous"):
            self.focus_count += 1
            self.interrupted = self.after_focus
        return response


class TakeoverStartTests(unittest.TestCase):
    def test_historical_activity_allows_one_focus_then_normal_read(self):
        fake = TakeoverFake()
        result = execute_chat({"app": WECHAT, "action": "read"}, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(fake.focus_count, 1)
        self.assertEqual([call["command"] for call in fake.calls[:4]], ["status", "inspect", "focus", "status"])
        self.assertFalse(any(call["command"] in {"visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_new_activity_after_focus_stops_without_input_or_refocus(self):
        fake = TakeoverFake(after_focus="manual_after_claim")
        result = execute_chat({"app": WECHAT, "action": "draft", "text": "禁止新活动时输入"}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "user_interrupted")
        self.assertEqual(fake.focus_count, 1)
        self.assertEqual([call["command"] for call in fake.calls], ["status", "inspect", "focus", "status"])
        self.assertEqual(fake.draft, "")
        self.assertFalse(result["automatic_replay_allowed"])

    def test_activity_during_reply_refresh_keeps_strict_stop_and_no_reclaim(self):
        fake = TakeoverFake()
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_read":
                fake.interrupted = "manual_after_capture"
            return response
        result = execute_chat({"app": WECHAT, "action": "read", "reply_contains": "不存在的回复",
                               "wait_timeout_ms": 1000}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "user_interrupted")
        self.assertEqual(fake.focus_count, 1)
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_read"]), 1)
        self.assertFalse(any(call["command"] in {"visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_strict_status_cannot_bypass_interruption_with_initial_ignore_flag(self):
        fake = TakeoverFake()
        session = ChatSession({"app": WECHAT, "action": "read"}, fake)
        session.pid = fake.pid
        with self.assertRaises(Stopped) as failure:
            session.status(strict=True, ignore_prior_interruption=True)
        self.assertEqual(failure.exception.code, "user_interrupted")
        self.assertEqual([call["command"] for call in fake.calls], ["status"])

    def test_feishu_uses_the_same_single_initial_claim_rule(self):
        for new_activity in (None, "manual_after_claim"):
            fake = FeishuFake()
            claimed = False
            def callback(request):
                nonlocal claimed
                response = fake(request)
                if request["command"] == "status":
                    response["result"]["interrupted"] = new_activity if claimed else "manual_before_claim"
                if request["command"] == "focus":
                    claimed = True
                return response
            result = execute_chat({"app": fake.app, "action": "read"}, callback, recipe_store=False)
            self.assertEqual(len([call for call in fake.calls if call["command"] == "focus" and not call.get("restore_previous")]), 1)
            if new_activity:
                self.assertEqual(result["error"]["code"], "user_interrupted")
                self.assertFalse(any(call["command"] in {"press", "click", "type_text", "key"} for call in fake.calls))
            else:
                self.assertTrue(result["ok"], result)


if __name__ == "__main__":
    unittest.main()
