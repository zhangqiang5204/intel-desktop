"""A literal user draft 拼 is content; visual input-source hints are native."""
import unittest

from test_chat_workflows import WeChatFake
from chat_workflows import ChatSession, WECHAT, execute_chat


class LiteralDraftTests(unittest.TestCase):
    def test_drafting_single_character_pin_requires_and_returns_complete_value(self):
        fake = WeChatFake()
        result = execute_chat({"app": WECHAT, "action": "draft", "text": "拼"}, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["result"]["draft"], "拼")
        self.assertTrue(result["result"]["draft_verified"])
        self.assertFalse(result["result"]["draft_empty"])
        self.assertEqual(fake.draft, "拼")
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_type_text"]), 1)

    def test_read_recognizes_literal_existing_pin_and_preserves_it(self):
        fake = WeChatFake()
        fake.draft = "拼"
        observations = []
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_read":
                observations.append(response["result"])
            return response
        result = execute_chat({"app": WECHAT, "action": "read"}, callback, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["result"]["draft_preserved"])
        session = ChatSession({"app": WECHAT, "action": "read"}, fake)
        session.frame = fake.frame
        self.assertEqual(session.wechat_draft(observations[-1]), "拼")
        self.assertEqual(fake.draft, "拼")
        self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_existing_pin_prevents_overwrite_and_mismatching_empty_clear(self):
        for request, expected in (({"action": "draft", "text": "另一个字"}, "draft_present"),
                                  ({"action": "clear", "expected_draft": ""}, "draft_changed")):
            fake = WeChatFake()
            fake.draft = "拼"
            result = execute_chat({"app": WECHAT, **request}, fake, recipe_store=False)
            self.assertEqual(result["error"]["code"], expected)
            self.assertEqual(fake.draft, "拼")
            self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_single_pin_appearing_after_focus_stops_input_instead_of_overwriting(self):
        fake = WeChatFake()
        fake.change_on_click = "拼"
        result = execute_chat({"app": WECHAT, "action": "draft", "text": "新增内容"}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertEqual(fake.draft, "拼")
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_click"]), 1)
        self.assertFalse(any(call["command"] in {"visual_type_text", "visual_key"} for call in fake.calls))
        self.assertFalse(result["automatic_replay_allowed"])

    def test_reply_read_refresh_detects_single_pin_as_changed_draft(self):
        fake = WeChatFake()
        reads = 0
        def callback(request):
            nonlocal reads
            if request["command"] == "visual_read":
                reads += 1
                if reads == 2:
                    fake.draft = "拼"
            return fake(request)
        result = execute_chat({"app": WECHAT, "action": "read", "reply_contains": "不存在的回复",
                               "wait_timeout_ms": 1000}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertEqual(fake.draft, "拼")
        self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_exact_owned_single_pin_can_be_cleared_without_ignoring_it(self):
        fake = WeChatFake()
        fake.draft = "拼"
        result = execute_chat({"app": WECHAT, "action": "clear", "expected_draft": "拼"}, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["result"]["draft_empty"])
        self.assertEqual(fake.draft, "")
        self.assertEqual([call["key"] for call in fake.calls if call["command"] == "visual_key"], ["clear_draft"])


if __name__ == "__main__":
    unittest.main()
