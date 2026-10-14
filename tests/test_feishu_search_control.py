"""Exact search labels agree with native ownership; all desktop calls are fakes."""
import unittest

from chat_workflows import FEISHU, _feishu_search_open_control_allowed, execute_chat
from test_chat_completion import authorization
from test_feishu_focus_restore import FocusFeishuFake


class FeishuSearchControlTests(unittest.TestCase):
    def test_observed_button_uses_empty_title_and_fullwidth_plus_description(self):
        self.assertTrue(_feishu_search_open_control_allowed({"role": "AXButton", "title": "",
            "description": "搜索（⌘＋K）"}))

    def test_existing_native_button_forms_remain_supported_in_either_label(self):
        for label in ("搜索", "搜索(⌘ K)", "搜索（⌘K）", "搜索（⌘＋K）"):
            for field in ("title", "description"):
                with self.subTest(label=label, field=field):
                    self.assertTrue(_feishu_search_open_control_allowed({"role": "AXButton", field: label}))

    def test_prefix_unknown_shortcut_and_unobserved_ascii_plus_are_not_exact(self):
        for label in ("搜索消息", "搜索(其他)", "搜索网络", "搜索（⌘K）其他", "搜索(⌘+K)",
                      "搜索（⌘＋J）", "搜索（⌘＋K）其他", "搜索（⇧⌘＋K）"):
            with self.subTest(label=label):
                self.assertFalse(_feishu_search_open_control_allowed({"role": "AXButton", "description": label}))

    def test_menu_requires_exact_title_and_role_and_buttons_require_string_labels(self):
        self.assertTrue(_feishu_search_open_control_allowed({"role": "AXMenuItem", "title": "搜索"}))
        for row in ({"role": "AXMenuItem", "description": "搜索"},
                    {"role": "AXMenuItem", "title": "搜索（⌘＋K）"},
                    {"role": "AXStaticText", "title": "搜索"},
                    {"title": "搜索"}, {"role": "AXButton", "title": True, "description": ["搜索"]}):
            with self.subTest(row=row):
                self.assertFalse(_feishu_search_open_control_allowed(row))

    def test_observed_button_atomic_send_navigates_once_submits_once_and_returns_focus(self):
        fake = FocusFeishuFake()
        fake.search_button_description = "搜索（⌘＋K）"
        wanted, text = "目标个人", "离线完整消息"
        response = execute_chat({"app": FEISHU, "action": "send", "chat": wanted, "text": text,
            "send_authorization": authorization(fake, text, chat=wanted)}, fake, recipe_store=False)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertTrue(response["scope_completed"])
        self.assertEqual(sum(c["command"] == "press" and c.get("element_id") == "search-button" for c in fake.calls), 1)
        self.assertEqual(sum(c["command"] == "type_text" and c.get("element_id") == "search-field" for c in fake.calls), 1)
        self.assertEqual(sum(c["command"] == "submit_text" for c in fake.calls), 1)
        self.assertEqual(fake.restore_calls, 1)
        self.assertEqual(fake.front, fake.origin)

    def test_unknown_button_stops_before_search_press_or_input_and_returns_focus(self):
        fake = FocusFeishuFake()
        fake.search_button_description = "搜索（任意未知快捷键）"
        response = execute_chat({"app": FEISHU, "action": "locate", "chat": "目标个人"}, fake, recipe_store=False)
        self.assertFalse(response["ok"])
        self.assertTrue(response["focus_restored"])
        self.assertEqual(fake.restore_calls, 1)
        self.assertFalse(any(c["command"] in {"press", "type_text", "batch", "submit_text"} for c in fake.calls))


if __name__ == "__main__":
    unittest.main()
