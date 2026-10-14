"""Optional menu failures cannot contaminate a complete chat Send baseline."""
import copy
import unittest
from unittest.mock import patch

from chat_workflows import execute_chat
from test_chat_completion import authorization, send_request
from test_chat_workflows import ax
from test_feishu_send_latency import SendLatencyFake


class OptionalMenuFake(SendLatencyFake):
    def __init__(self, *, menu_failure=False, chat_incomplete=False, menu_only=False, change=None):
        super().__init__()
        self.menu_failure = menu_failure
        self.chat_incomplete = chat_incomplete
        self.menu_only = menu_only
        self.change = change

    def __call__(self, request):
        if request["command"] == "inspect" and request.get("include_menus"):
            if self.change == "draft": self.draft = "用户已有草稿"
            if self.change == "recipient": self.title = "其他当前聊天"
        effective = request
        if request["command"] == "press" and request.get("element_id") == "exact-search-menu":
            effective = {**request, "element_id": "search-button"}
        response = super().__call__(effective)
        if effective is not request:
            self.calls[-1] = copy.deepcopy(request)
        if request["command"] == "inspect" and response["ok"]:
            tree = response["result"]
            if self.menu_only:
                tree["elements"] = [row for row in tree["elements"] if row["element_id"] != "search-button"]
                if request.get("include_menus"):
                    tree["menu_elements"] = [ax("exact-search-menu", "AXMenuItem", 0, 0, 80, 20,
                                               title="搜索", actions=["AXPress"])]
            if (request.get("include_menus") and self.menu_failure) or self.chat_incomplete:
                tree.update(truncated=True, truncation_reasons=["child_read_failed"])
        return response


class FeishuOptionalMenuTests(unittest.TestCase):
    def send(self, fake, chat=None):
        request = send_request(fake)
        if chat:
            request.update(chat=chat, send_authorization=authorization(fake, request["text"], chat=chat))
        with patch("chat_workflows.time.perf_counter", side_effect=lambda: fake.now), \
             patch("chat_workflows.time.monotonic", side_effect=lambda: fake.now), \
             patch("chat_workflows.time.sleep", side_effect=fake.sleep):
            return execute_chat(request, fake, recipe_store=False)

    def test_same_recipient_send_uses_complete_no_menu_initial_tree_without_extra_inspect(self):
        fake = OptionalMenuFake(menu_failure=True)
        response = self.send(fake)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        inspections = [call for call in fake.calls if call["command"] == "inspect"]
        self.assertEqual(len(inspections), 2)  # Initial reused tree + post-submit proof.
        self.assertTrue(all(call["include_menus"] is False for call in inspections))
        self.assertEqual(response["result"]["full_AX_body_proof"]["baseline_text_node_occurrences"], 0)
        self.assertEqual(fake.restore_calls, 1)

    def test_incomplete_actual_chat_still_refuses_before_any_input(self):
        fake = OptionalMenuFake(chat_incomplete=True)
        response = self.send(fake)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "send_state_unknown")
        self.assertFalse(response["sent"])
        self.assertTrue(all(call["include_menus"] is False for call in fake.calls if call["command"] == "inspect"))
        self.assertFalse(any(call["command"] in {"press", "click", "type_text", "batch", "submit_text"} for call in fake.calls))
        self.assertEqual(fake.restore_calls, 1)

    def test_actual_exact_search_button_navigates_without_optional_menu_acquisition(self):
        fake = OptionalMenuFake(menu_failure=True)
        response = self.send(fake, chat="另一个离线联系人")
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertTrue(all(call["include_menus"] is False for call in fake.calls if call["command"] == "inspect"))
        self.assertEqual(sum(call["command"] == "press" for call in fake.calls), 1)
        self.assertEqual(sum(call["command"] == "submit_text" for call in fake.calls), 1)

    def test_missing_button_acquires_menu_once_then_uses_fresh_no_menu_chat_baseline(self):
        fake = OptionalMenuFake(menu_only=True)
        response = self.send(fake, chat="另一个离线联系人")
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        inspections = [call for call in fake.calls if call["command"] == "inspect"]
        self.assertEqual(sum(call["include_menus"] is True for call in inspections), 1)
        press = next(i for i, call in enumerate(fake.calls) if call["command"] == "press")
        self.assertEqual(fake.calls[press]["element_id"], "exact-search-menu")
        self.assertTrue(all(call["include_menus"] is False for call in fake.calls[press + 1:] if call["command"] == "inspect"))
        self.assertEqual(sum(call["command"] == "submit_text" for call in fake.calls), 1)

    def test_lazy_menu_refresh_rechecks_current_draft_and_recipient_before_press(self):
        for change in ("draft", "recipient"):
            with self.subTest(change=change):
                fake = OptionalMenuFake(menu_only=True, change=change)
                response = self.send(fake, chat="另一个离线联系人")
                self.assertFalse(response["ok"], response)
                self.assertFalse(response["sent"])
                self.assertFalse(any(call["command"] in {"press", "click", "type_text", "batch", "submit_text"} for call in fake.calls))
                self.assertEqual(fake.restore_calls, 1)


if __name__ == "__main__":
    unittest.main()
