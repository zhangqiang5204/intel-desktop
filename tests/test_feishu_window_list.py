"""Readiness polls accept an unavailable window list, without action replay."""
import unittest
from unittest.mock import patch

from chat_workflows import FEISHU, execute_chat
from test_feishu_focus_restore import FocusFeishuFake


class TransientWindowListFake(FocusFeishuFake):
    def __init__(self, unavailable_reads):
        super().__init__()
        self.unavailable_reads = unavailable_reads
        self.empty_reads = 0
        self.now = 0.0

    def __call__(self, request):
        response = super().__call__(request)
        self.now += .01
        if request["command"] == "inspect" and "window_title" not in request and self.modal and self.unavailable_reads:
            self.unavailable_reads -= 1
            self.empty_reads += 1
            response["result"].update(windows=[], elements=[], truncated=True,
                window_list_available=False, window_list_complete=False,
                window_list_count_result={"code": -25204, "name": "cannot_complete"},
                menu_elements=[], menus_skipped=True, menu_window_available=False)
        return response


class FeishuWindowListTests(unittest.TestCase):
    def locate(self, fake):
        with patch("chat_workflows.time.monotonic", side_effect=lambda: fake.now), \
             patch("chat_workflows.time.sleep", side_effect=lambda duration: setattr(fake, "now", fake.now + duration)):
            return execute_chat({"app": FEISHU, "action": "locate", "chat": "离线测试联系人"}, fake, recipe_store=False)

    def test_transient_all_window_list_retries_read_only_then_uses_fresh_modal(self):
        fake = TransientWindowListFake(1)
        response = self.locate(fake)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["located"])
        self.assertEqual(fake.empty_reads, 1)
        self.assertEqual(sum(c["command"] == "press" for c in fake.calls), 1)
        first_press = next(i for i, c in enumerate(fake.calls) if c["command"] == "press")
        first_modal_probe = next(c for c in fake.calls[first_press + 1:] if c["command"] == "inspect")
        self.assertNotIn("window_title", first_modal_probe)
        self.assertFalse(first_modal_probe["include_menus"])
        self.assertEqual(sum(c["command"] == "type_text" for c in fake.calls), 1)
        self.assertFalse(any(c["command"] == "submit_text" or c.get("key") == "return" for c in fake.calls))

    def test_unavailable_list_until_original_deadline_posts_no_query_or_repeat_press(self):
        fake = TransientWindowListFake(100)
        response = self.locate(fake)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "search_modal_timeout")
        self.assertGreater(fake.empty_reads, 1)
        self.assertLess(fake.empty_reads, 30)
        self.assertEqual(sum(c["command"] == "press" for c in fake.calls), 1)
        self.assertFalse(any(c["command"] in {"type_text", "submit_text", "clear_text"} or c.get("key") == "return" for c in fake.calls))


if __name__ == "__main__":
    unittest.main()
