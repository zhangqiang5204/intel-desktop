"""A single completed clear's final empty UI can prove its outcome, never replay."""
import copy
import unittest

from test_chat_workflows import WeChatFake, bounds
from chat_workflows import WECHAT, execute_chat


class ClearOutcomeFake(WeChatFake):
    def __init__(self):
        super().__init__()
        self.frame = bounds(50, 41, 855, 1079)
        self.title = "测试自有群（178）"
        self.draft = "命令 自有清空草稿"
        self.failure_code = "postcondition_failed"
        self.event_count = 4
        self.draft_cleared = False
        self.failed = False
        self.native_success = False
        self.proof_change = None

    def visual(self, request, region_only=False):
        value = super().visual(request, region_only)
        value.update(window_id=33789, display_topology_signature="synthetic-one-display",
                     focused_window_frame=dict(self.frame), captured_regions=[dict(self.frame)],
                     ocr_regions=request.get("regions", [request.get("region", dict(self.frame))]),
                     ocr_scope="requested_regions" if "regions" in request else "requested_region_and_top_footer_anchor_bands",
                     read_only_background=False, input_eligible=value["target_visible_verified"], target_identity_verified=True)
        if self.failed:
            if self.proof_change == "window": value["window_id"] += 1
            elif self.proof_change == "topology": value["display_topology_signature"] += "-changed"
            elif self.proof_change == "focus": value["focused_window_frame"] = bounds(51, 41, 855, 1079)
            elif self.proof_change == "truncated": value["ocr_truncated"] = True
            elif self.proof_change == "composer_scan": value["ocr_regions"] = value["ocr_regions"][:3]
            elif self.proof_change == "header_capture": value["captured_regions"] = [bounds(50, 100, 855, 1020)]
            elif self.proof_change == "anchor": value["target_visible_verified"] = False
            elif self.proof_change == "eligible": value["input_eligible"] = False
            elif self.proof_change == "background": value["read_only_background"] = True
            elif self.proof_change == "identity": value["target_identity_verified"] = False
            elif self.proof_change == "final_takeover": self.interrupted = "post-proof-human-input"
        return value

    def __call__(self, request):
        if request["command"] == "visual_key" and request.get("key") == "clear_draft" and not self.native_success:
            # Simulate the one posted Cmd+A/Backspace; the error is its native
            # final OCR outcome, not permission for another delete.
            super().__call__(request)
            self.failed = True
            if self.proof_change == "takeover": self.interrupted = "human-input"
            elif self.proof_change == "pid": self.pid += 1
            elif self.proof_change == "frame": self.frame = bounds(51, 41, 855, 1079)
            elif self.proof_change == "other_title": self.title = "不同群（178）"
            elif self.proof_change == "alias": self.title += "AI"
            elif self.proof_change == "members": self.title = "测试自有群（179）"
            elif self.proof_change == "draft": self.draft = "后来的草稿必须保留"
            elif self.proof_change == "placeholder": self.draft = "输入消息"
            return {"ok": False, "error": {"code": self.failure_code, "message": "Original native clear final OCR failed",
                    "details": {"events_posted": self.event_count, "draft_cleared": self.draft_cleared,
                                "input_may_be_partial": True, "automatic_replay_allowed": False}}}
        if request["command"] == "visual_read" and self.failed and self.proof_change == "capture":
            self.calls.append(copy.deepcopy(request))
            return {"ok": False, "error": {"code": "visual_capture_unavailable", "message": "No target frame"}}
        return super().__call__(request)


class ClearOutcomeTests(unittest.TestCase):
    def run_clear(self, fake):
        return execute_chat({"app": WECHAT, "action": "clear", "expected_draft": fake.draft}, fake, recipe_store=False)

    def after_key(self, fake):
        key = next(call for call in fake.calls if call["command"] == "visual_key")
        return fake.calls[fake.calls.index(key) + 1:]

    def assert_no_replay(self, fake):
        self.assertEqual(sum(call["command"] == "visual_key" for call in fake.calls), 1)
        self.assertFalse(any(call["command"] in {"visual_type_text", "visual_click", "visual_scroll", "batch"}
                             or call["command"] == "focus" and not call.get("restore_previous") for call in self.after_key(fake)))

    def test_complete_four_events_one_fresh_final_proof_reports_true_empty(self):
        fake = ClearOutcomeFake()
        result = self.run_clear(fake)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["result"]["draft_empty"])
        self.assertTrue(result["result"]["draft_verified"])
        receipt = result["clear_recovery"]
        self.assertTrue(receipt["verified"])
        self.assertEqual(receipt["original_error_code"], "postcondition_failed")
        self.assertIs(receipt["native_draft_cleared"], False)
        self.assertEqual(receipt["events_posted"], 4)
        self.assertEqual(receipt["capture_attempts"], 1)
        reads = [call for call in self.after_key(fake) if call["command"] == "visual_read"]
        self.assertEqual(len(reads), 1)
        self.assertEqual(len(reads[0]["regions"]), 4)
        self.assertEqual(reads[0]["anchor_texts"], ["测试自有群（178）", "发送"])
        self.assert_no_replay(fake)

    def test_normal_native_success_keeps_existing_one_final_read(self):
        fake = ClearOutcomeFake()
        fake.native_success = True
        result = self.run_clear(fake)
        self.assertTrue(result["ok"], result)
        self.assertNotIn("clear_recovery", result)
        self.assertEqual(sum(call["command"] == "visual_read" for call in self.after_key(fake)), 1)
        self.assert_no_replay(fake)

    def test_partial_unknown_counts_flags_and_user_error_are_not_recoverable(self):
        cases = [("postcondition_failed", count, False) for count in (0, 1, 2, 3, 5, 4.0, True, "4")]
        cases += [("user_interrupted", 4, False), ("visual_target_changed", 4, False),
                  ("postcondition_failed", 4, None), ("postcondition_failed", 4, True)]
        for code, count, flag in cases:
            with self.subTest(code=code, count=count, flag=flag):
                fake = ClearOutcomeFake()
                fake.failure_code, fake.event_count, fake.draft_cleared = code, count, flag
                result = self.run_clear(fake)
                self.assertFalse(result["ok"], result)
                self.assertEqual(result["error"]["code"], code)
                self.assertNotIn("clear_recovery", result)
                self.assertFalse(any(call["command"] == "visual_read" for call in self.after_key(fake)))
                self.assert_no_replay(fake)

    def test_changed_identity_focus_title_or_incomplete_empty_preserves_original_error(self):
        for change in ("pid", "frame", "window", "topology", "focus", "truncated", "composer_scan", "header_capture",
                       "anchor", "eligible", "background", "identity", "other_title", "alias", "members", "draft", "placeholder", "capture"):
            with self.subTest(change=change):
                fake = ClearOutcomeFake()
                fake.proof_change = change
                result = self.run_clear(fake)
                self.assertFalse(result["ok"], result)
                self.assertEqual(result["error"]["code"], "postcondition_failed")
                self.assertEqual(result["error"]["message"], "Original native clear final OCR failed")
                self.assertIs(result["clear_recovery"]["verified"], False)
                self.assertEqual(result["clear_recovery"]["capture_attempts"], 0 if change == "pid" else 1)
                self.assertIn("clear_recovery_stop_code", result["error"]["details"])
                self.assertFalse(result["focus_restore_attempted"])
                self.assertLessEqual(sum(call["command"] == "visual_read" for call in self.after_key(fake)), 1)
                self.assert_no_replay(fake)
                if change == "draft": self.assertEqual(fake.draft, "后来的草稿必须保留")

    def test_takeover_before_or_after_proof_does_not_restore_focus(self):
        for change, reads in (("takeover", 0), ("final_takeover", 1)):
            fake = ClearOutcomeFake()
            fake.proof_change = change
            result = self.run_clear(fake)
            self.assertEqual(result["error"]["code"], "postcondition_failed", result)
            self.assertEqual(result["clear_recovery"]["stop_code"], "user_interrupted")
            self.assertFalse(result["focus_restore_attempted"])
            self.assertEqual(sum(call["command"] == "visual_read" for call in self.after_key(fake)), reads)
            self.assert_no_replay(fake)


if __name__ == "__main__":
    unittest.main()
