"""Pure atomic-prefix backend contract tests; no native helper or desktop UI."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from test_chat_workflows import WeChatFake, bounds
from chat_workflows import CHAT_TOOL, FEISHU, WECHAT, execute_chat
from recipe_store import RecipeStore


PREFIX = "双屏微信验收20261012年"
CHAT = "前缀测试群"
SUFFIX = "额外业务文字  原样\n第二行＋引用"


class PrefixFake(WeChatFake):
    def __init__(self, suffix=SUFFIX):
        super().__init__()
        self.frame = bounds(1900, 33, 855, 1079)
        self.title = CHAT + "（178）"
        self.draft = PREFIX + suffix
        self.prefix_failure = None
        self.wrong_suffix = None
        self.false_verified = False

    def __call__(self, request):
        if request["command"] != "visual_key" or request.get("key") != "clear_prefix":
            return super().__call__(request)
        self.calls.append(copy.deepcopy(request))
        if self.title != request["chat_title"]:
            return {"ok": False, "error": {"code": "recipient_mismatch", "message": "Fresh header changed",
                                          "details": {"events_posted": 0, "delete_events_posted": 0}}}
        if self.draft != request["expected_draft"] or not self.draft.startswith(request["prefix"]):
            return {"ok": False, "error": {"code": "draft_changed", "message": "Fresh complete value changed",
                                          "details": {"events_posted": 0, "delete_events_posted": 0}}}
        if self.prefix_failure:
            return {"ok": False, "error": {"code": self.prefix_failure, "message": "Prefix guard stopped",
                                          "details": {"events_posted": 4, "delete_events_posted": 0,
                                                      "automatic_replay_allowed": False}}}
        expected = self.draft[len(request["prefix"]):]
        self.draft = expected if self.wrong_suffix is None else self.wrong_suffix
        value = self.visual(request, True)
        value.update(prefix_deleted=True, value_verified=not self.false_verified, expected_after=expected,
                     events_posted=4+2*len(request["prefix"]), delete_events_posted=2*len(request["prefix"]),
                     verification_source="fresh_complete_literal_suffix_OCR", automatic_replay_allowed=False)
        return {"ok": True, "result": value}


class ClearPrefixTests(unittest.TestCase):
    def request(self, **fields):
        return {"app": WECHAT, "action": "clear_prefix", "chat": CHAT, "chat_kind": "group", "prefix": PREFIX, **fields}

    def prefix_calls(self, fake):
        return [call for call in fake.calls if call["command"] == "visual_key" and call.get("key") == "clear_prefix"]

    def assert_no_input(self, fake):
        self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_key", "visual_type_text"} for call in fake.calls))

    def test_exact_prefix_removal_preserves_complete_literal_multiline_suffix(self):
        fake = PrefixFake()
        original = fake.draft
        result = execute_chat(self.request(), fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(fake.draft, SUFFIX)
        self.assertEqual(result["result"]["draft"], SUFFIX)
        self.assertTrue(result["result"]["prefix_cleared"])
        self.assertTrue(result["result"]["suffix_preserved"])
        self.assertFalse(result["result"]["draft_empty"])
        call, = self.prefix_calls(fake)
        self.assertEqual((call["prefix"], call["expected_draft"], call["chat_title"]), (PREFIX, original, CHAT + "（178）"))
        self.assertEqual(call["control_kind"], "chat_composer")
        self.assertFalse(any(call["command"] == "visual_type_text" or call.get("key") in {"a", "left", "backspace", "return", "enter"} for call in fake.calls))

    def test_exact_owned_prefix_only_can_be_removed_to_empty(self):
        fake = PrefixFake("")
        result = execute_chat(self.request(), fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["result"]["draft_empty"])
        self.assertEqual(result["result"]["draft"], "")
        self.assertEqual(len(self.prefix_calls(fake)), 1)

    def test_literal_single_pin_suffix_is_preserved(self):
        fake = PrefixFake("拼")
        result = execute_chat(self.request(), fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(fake.draft, "拼")
        self.assertEqual(result["result"]["draft"], "拼")

    def test_prefix_is_literal_and_must_start_the_complete_draft(self):
        for draft, prefix in (("业务文字" + PREFIX, PREFIX), (PREFIX[:-1] + SUFFIX, PREFIX),
                              ("授权 年" + SUFFIX, "授权年"), (PREFIX, "双屏微信验收20261012年多字")):
            fake = PrefixFake()
            fake.draft = draft
            result = execute_chat(self.request(prefix=prefix), fake, recipe_store=False)
            self.assertEqual(result["error"]["code"], "prefix_mismatch", result)
            self.assertEqual(fake.draft, draft)
            self.assert_no_input(fake)

    def test_changed_draft_during_click_posts_no_prefix_delete(self):
        fake = PrefixFake()
        fake.change_on_click = PREFIX + "用户刚改的完整后缀"
        result = execute_chat(self.request(), fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertEqual(fake.draft, fake.change_on_click)
        self.assertEqual(self.prefix_calls(fake), [])

    def test_same_window_recipient_change_is_rejected_by_native_fresh_guard(self):
        fake = PrefixFake()
        original = fake.draft
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_click":
                fake.title = "另一聊天"
            return response
        result = execute_chat(self.request(), callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "recipient_mismatch")
        self.assertEqual(result["error"]["details"]["delete_events_posted"], 0)
        self.assertEqual(fake.draft, original)
        self.assertEqual(len(self.prefix_calls(fake)), 1)

    def test_unverified_caret_or_grapheme_boundary_is_never_replayed(self):
        for failure in ("prefix_caret_unverified", "prefix_grapheme_boundary_unverified", "user_interrupted"):
            fake = PrefixFake()
            original = fake.draft
            fake.prefix_failure = failure
            result = execute_chat(self.request(), fake, recipe_store=False)
            self.assertEqual(result["error"]["code"], failure)
            self.assertEqual(result["error"]["details"]["delete_events_posted"], 0)
            self.assertEqual(fake.draft, original)
            self.assertEqual(len(self.prefix_calls(fake)), 1)
            self.assertFalse(result["automatic_replay_allowed"])

    def test_native_flags_do_not_replace_complete_literal_suffix_proof(self):
        for wrong in (SUFFIX + "未知字", SUFFIX.replace("  ", " "), SUFFIX.replace("业", "", 1)):
            fake = PrefixFake()
            fake.wrong_suffix = wrong
            result = execute_chat(self.request(), fake, recipe_store=False)
            self.assertEqual(result["error"]["code"], "prefix_clear_unverified")
            self.assertEqual(len(self.prefix_calls(fake)), 1)
            self.assertFalse(result["automatic_replay_allowed"])

    def test_prefix_removal_reflow_preserves_all_suffix_characters_and_spaces(self):
        fake = PrefixFake()
        reflowed = "额外业务\n文字  原样第二行＋引用"
        fake.wrong_suffix = reflowed
        result = execute_chat(self.request(), fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["result"]["draft"], reflowed)
        self.assertEqual(fake.draft, reflowed)
        self.assertTrue(result["result"]["suffix_preserved"])
        self.assertEqual(result["result"]["verification_source"], "complete_visible_suffix_with_layout_only_newline_normalization")
        self.assertIn("physical newline boundaries are unverified", result["result"]["draft_value_semantics"])
        self.assertEqual(len(self.prefix_calls(fake)), 1)

    def test_reflow_before_click_is_still_a_literal_change_and_posts_no_delete(self):
        fake = PrefixFake()
        fake.change_on_click = PREFIX + SUFFIX.replace("\n", "")
        result = execute_chat(self.request(), fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertEqual(self.prefix_calls(fake), [])

    def test_native_unverified_value_does_not_report_success(self):
        fake = PrefixFake()
        fake.false_verified = True
        result = execute_chat(self.request(), fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "prefix_clear_unverified")
        self.assertEqual(len(self.prefix_calls(fake)), 1)

    def test_final_full_read_detects_suffix_changed_after_native_verification(self):
        fake = PrefixFake()
        def callback(request):
            if request["command"] == "visual_read" and self.prefix_calls(fake):
                fake.draft = SUFFIX + "后来新增"
            return fake(request)
        result = execute_chat(self.request(), callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertEqual(fake.draft, SUFFIX + "后来新增")
        self.assertEqual(len(self.prefix_calls(fake)), 1)

    def test_transport_failure_during_prefix_delete_is_unknown_and_not_retried(self):
        fake = PrefixFake()
        def callback(request):
            if request["command"] == "visual_key" and request.get("key") == "clear_prefix":
                fake.calls.append(copy.deepcopy(request))
                fake.draft = fake.draft[1:]
                raise OSError("Fake lost completion")
            return fake(request)
        result = execute_chat(self.request(), callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "native_transport_error")
        self.assertFalse(result["automatic_replay_allowed"])
        self.assertEqual(len(self.prefix_calls(fake)), 1)
        self.assertFalse(any(call["command"] == "visual_type_text" for call in fake.calls))

    def test_schema_and_unsupported_prefixes_fail_before_native(self):
        self.assertIn("clear_prefix", CHAT_TOOL["inputSchema"]["properties"]["action"]["enum"])
        self.assertEqual(CHAT_TOOL["inputSchema"]["properties"]["prefix"]["maxLength"], 64)
        requests = [self.request(app=FEISHU), self.request(prefix=""), self.request(prefix=" " * 3),
                    self.request(prefix="字" * 65), self.request(prefix="emoji😀"), self.request(prefix="e\u0301"),
                    self.request(prefix="字\u200d"), self.request(prefix="字\n"), self.request(prefix="字\t"),
                    self.request(prefix="字\u2028"), self.request(chat=""), self.request(expected_draft=PREFIX + SUFFIX),
                    self.request(prefix="标记 "), self.request(prefix="字￥"), self.request(prefix="字☀"),
                    {"app": WECHAT, "action": "clear_prefix", "chat": CHAT},
                    {"app": WECHAT, "action": "clear_prefix", "prefix": PREFIX},
                    {"app": WECHAT, "action": "read", "prefix": PREFIX}]
        for request in requests:
            fake = PrefixFake()
            result = execute_chat(request, fake, recipe_store=False)
            self.assertFalse(result["ok"], request)
            self.assertEqual(fake.calls, [], request)

    def test_64_bmp_character_prefix_is_supported_without_rewriting_suffix(self):
        fake = PrefixFake()
        prefix = "字" * 64
        fake.draft = prefix + SUFFIX
        result = execute_chat(self.request(prefix=prefix), fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(fake.draft, SUFFIX)

    def test_other_selected_chat_draft_is_preserved_without_search_or_input(self):
        fake = PrefixFake()
        fake.title = "其他群（178）"
        original = fake.draft
        result = execute_chat(self.request(), fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_present")
        self.assertEqual(fake.draft, original)
        self.assert_no_input(fake)

    def test_requested_kind_requires_positive_evidence_before_prefix_delete(self):
        fake = PrefixFake()
        fake.title = CHAT
        result = execute_chat(self.request(), fake, recipe_store=False)
        self.assertFalse(result["ok"])
        self.assert_no_input(fake)

    def test_recipe_records_result_metadata_without_chat_prefix_draft_or_suffix(self):
        with tempfile.TemporaryDirectory() as directory:
            store = RecipeStore(Path(directory) / "recipes.json")
            success = execute_chat(self.request(), PrefixFake(), recipe_store=store)
            self.assertTrue(success["ok"], success)
            failure = PrefixFake()
            failure.draft = "不同的业务草稿"
            stopped = execute_chat(self.request(), failure, recipe_store=store)
            self.assertFalse(stopped["ok"])
            saved = store.path.read_text()
            for sensitive in (PREFIX, CHAT, SUFFIX, "不同的业务草稿", "expected_draft=", "clear_prefix=当前"):
                self.assertNotIn(sensitive, saved)
            row, = json.loads(saved)["recipes"].values()
            self.assertEqual(row["action"], "clear_prefix")
            self.assertIn("prefix", row["parameter_names"])
            self.assertEqual((row["successes"], row["verified_successes"], row["failures"]), (1, 1, 1))
            self.assertEqual(row["template_safety_tests"], "tests/test_wechat_clear_prefix.py")


if __name__ == "__main__":
    unittest.main()
