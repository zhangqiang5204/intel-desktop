"""A complete non-chat AX page can navigate, never prove an empty draft."""
import unittest

from chat_workflows import ChatSession, FEISHU, execute_chat
from test_chat_completion import authorization
from test_feishu_focus_restore import FocusFeishuFake


class NonChatFake(FocusFeishuFake):
    wanted = "目标个人"

    def __call__(self, request):
        response = super().__call__(request)
        if request["command"] == "inspect" and not self.modal and self.title != self.wanted:
            response["result"]["elements"] = [r for r in response["result"]["elements"]
                                              if r.get("role") != "AXTextArea"]
        return response


class FeishuNonChatNavigationTests(unittest.TestCase):
    def test_explicit_destination_searches_once_then_requires_complete_actual_chat(self):
        fake = NonChatFake()
        text = "离线消息"
        response = execute_chat({"app": FEISHU, "action": "send", "chat": fake.wanted,
            "text": text, "send_authorization": authorization(fake, text, chat=fake.wanted)}, fake, recipe_store=False)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertTrue(response["focus_restored"])
        self.assertEqual(sum(c["command"] == "press" and c.get("element_id") == "search-button" for c in fake.calls), 1)
        self.assertEqual(sum(c["command"] == "submit_text" for c in fake.calls), 1)

    def test_no_composer_is_never_empty_draft_or_general_navigation_authority(self):
        fake = NonChatFake()
        tree = fake({"command": "inspect", "app": FEISHU})["result"]
        session = ChatSession({"app": FEISHU, "action": "locate", "chat": fake.wanted}, fake)
        self.assertTrue(session.feishu_navigation_bootstrap(tree))
        for change in ("truncated", "missing_chat", "ambiguous", "unknown"):
            with self.subTest(change=change):
                import copy
                changed = copy.deepcopy(tree)
                session.request["chat"] = fake.wanted
                button = next(r for r in changed["elements"] if r.get("element_id") == "search-button")
                if change == "truncated": changed["truncated"] = True
                elif change == "missing_chat": session.request.pop("chat")
                elif change == "ambiguous": changed["elements"].append({**button, "element_id": "other-search"})
                else: button["description"] = "搜索未知范围"
                self.assertFalse(session.feishu_navigation_bootstrap(changed))


if __name__ == "__main__":
    unittest.main()
