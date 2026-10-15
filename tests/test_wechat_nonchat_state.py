"""Feed content in a composer-shaped rectangle is not a chat draft."""
import unittest

from chat_workflows import ChatSession, WECHAT, execute_chat
from test_chat_workflows import WeChatFake


class FeedFake(WeChatFake):
    def __init__(self):
        super().__init__()
        self.title = "公众号"
        self.draft = "文章正文"
        self.hide_send = True


class WeChatNonChatStateTests(unittest.TestCase):
    def test_no_send_never_interprets_articles_as_a_draft_or_posts_input(self):
        fake = FeedFake()
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": "文件传输助手"}, fake, recipe_store=False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "wechat_chat_controls_unavailable")
        self.assertEqual(fake.draft, "文章正文")
        self.assertFalse(any(c["command"] in {"visual_click", "visual_type_text", "visual_key"} for c in fake.calls))


if __name__ == "__main__":
    unittest.main()
