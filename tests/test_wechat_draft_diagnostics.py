"""Exercise the three edit refusal sites without desktop or message input."""
import json
import unittest

from chat_workflows import WECHAT, execute_chat
from test_chat_completion import send_request
from test_wechat_atomic_send import AtomicSendFake
from test_wechat_focus_restore import RestoreFake
from test_wechat_post_action_reuse import PostActionFake


class DraftMismatchDiagnosticsTests(unittest.TestCase):
    def assert_content_free(self, details, *private_values):
        self.assertTrue(all(type(value) in {str, int, float, bool} for value in details.values()))
        self.assertEqual([key for key, value in details.items() if type(value) is str], ["phase"])
        serialized = json.dumps(details, ensure_ascii=False)
        for value in private_values:
            self.assertNotIn(value, serialized)
        self.assertFalse(any("hash" in key for key in details))

    def test_before_edit_reports_mismatch_without_typing_or_new_return_authority(self):
        fake = RestoreFake()
        fake.change_on_click = "秘密新草稿"
        response = execute_chat(send_request(fake), fake, recipe_store=False)
        self.assertEqual(response["error"]["code"], "draft_changed")
        details = response["error"]["details"]
        self.assertEqual(details["phase"], "before_edit")
        self.assertEqual((details["observed_length"], details["expected_length"]), (len(fake.draft), 0))
        self.assertFalse(details["complete_exact_equal"])
        self.assertFalse(details["observed_is_voice_placeholder"])
        self.assertEqual(details["text_events_posted"], 0)
        self.assertNotIn("safe_origin_restore", details)
        self.assertFalse(any(c["command"] in {"visual_type_text", "visual_key"} for c in fake.calls))
        self.assertTrue(response["focus_restored"])
        self.assert_content_free(details, fake.draft)

    def test_atomic_post_click_reports_exact_placeholder_and_known_zero_text_boundary(self):
        for observed, is_placeholder in (("按住鼠标 语音输入文字", True), ("按住鼠标 语音输入文字I", False)):
            with self.subTest(is_placeholder=is_placeholder):
                fake = AtomicSendFake(mismatch=observed, broken_receipt={
                    "empty_composer_hint": {"verified": False, "text": "禁止保留的提示正文"},
                    "frame_age_ms": 1900, "complete_frame_age_ms": 1950})
                response = execute_chat(send_request(fake), fake, recipe_store=False)
                self.assertEqual(response["error"]["code"], "draft_changed")
                details = response["error"]["details"]
                self.assertEqual(details["phase"], "atomic_post_click")
                self.assertEqual(details["observed_is_voice_placeholder"], is_placeholder)
                self.assertEqual((details["events_posted"], details["text_events_posted"],
                                  details["composer_focus_events_posted"]), (2, 0, 2))
                self.assertFalse(details["input_may_be_partial"])
                self.assertTrue(details["safe_origin_restore"])
                self.assertTrue(details["empty_composer_hint_present"])
                self.assertFalse(details["empty_composer_hint_verified"])
                self.assertEqual((details["frame_age_ms"], details["complete_frame_age_ms"]), (1900, 1950))
                self.assertFalse(details["complete_exact_equal"])
                self.assertTrue(response["focus_restored"])
                self.assertFalse(any(c.get("key") == "return" for c in fake.calls))
                self.assert_content_free(details, observed, "禁止保留的提示正文")

    def test_complete_post_edit_keeps_exact_refusal_for_layout_and_unknown_glyph(self):
        expected = "秘密完整草稿"
        for observed, normalized_equal in (("秘密完整\n草稿", True), (expected + "I", False)):
            with self.subTest(normalized_equal=normalized_equal):
                fake = PostActionFake()
                def callback(request):
                    response = fake(request)
                    if request["command"] == "visual_type_text":
                        value = response["result"]
                        for row in value["ocr"]:
                            if row["text"] == expected:
                                row["text"] = observed
                        value.update(events_posted=2, text_events_posted=2,
                                     frame_age_ms=True, complete_frame_age_ms=float("nan"))
                    return response
                response = execute_chat({"app": WECHAT, "action": "draft", "text": expected}, callback, recipe_store=False)
                self.assertEqual(response["error"]["code"], "draft_changed")
                details = response["error"]["details"]
                self.assertEqual(details["phase"], "complete_post_edit")
                self.assertFalse(details["complete_exact_equal"])
                self.assertEqual(details["complete_normalized_equal"], normalized_equal)
                self.assertEqual(details["complete_line_sequence_equal"], normalized_equal)
                self.assertEqual((details["observed_length"], details["expected_length"]), (len(observed), len(expected)))
                self.assertEqual(details["text_events_posted"], 2)
                self.assertNotIn("safe_origin_restore", details)
                self.assertNotIn("frame_age_ms", details)
                self.assertNotIn("complete_frame_age_ms", details)
                self.assertEqual(sum(c["command"] == "visual_type_text" for c in fake.calls), 1)
                self.assertFalse(any(c.get("key") == "return" for c in fake.calls))
                self.assert_content_free(details, observed, expected)


if __name__ == "__main__":
    unittest.main()
