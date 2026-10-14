"""Synthetic file-assistant layout, with explicit fake foreground proofs.

No helper, capture, HID or real send is executed. Function/name bounds and readonly binding are generated offline.
Network/history ordering and all coordinates are synthetic.
Foreground flags, subsequent snapshots and event effects are simulated only.
"""
import copy
import itertools
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from test_chat_workflows import WeChatFake, bounds
from chat_workflows import ChatSession, Stopped, WECHAT, _inside, _norm, execute_chat


FILE_ASSISTANT = "文件传输助手"
# Synthetic popup geometry; no real PID/window/rows are retained.
OBSERVED = {
    "window_frame": bounds(329, 41, 855, 1079), "target_pid": 123, "window_id": 100,
    "display_topology_signature": "synthetic-one-display",
    "captured_regions": [bounds(329, 41, 855, 1079)],
    "search_overlay_frame": bounds(329, 90, 326, 600), "search_overlay_window_id": 101,
    "search_overlay_query_verified": True, "search_lane_frame": bounds(420, 55, 156, 25),
    "input_eligible": False, "read_only_background": True,
    "ocr": [{"text": "功能", "bounds": bounds(412, 280, 28, 16)},
            {"text": FILE_ASSISTANT, "bounds": bounds(454, 326, 84, 17)}],
}


class FileAssistantFake(WeChatFake):
    def __init__(self):
        super().__init__()
        self.frame = copy.deepcopy(OBSERVED["window_frame"])
        self.pid = OBSERVED["target_pid"]
        self.search = FILE_ASSISTANT
        self.names = [FILE_ASSISTANT]
        self.foreground_changes = {}
        self.panel_truncated = False
        self.after_header = None
        self.after_partial_composer = False
        self.after_stale_snapshot = False
        self.after_changed_window = False
        self.last_panel_snapshot = None

    def panel_rows(self):
        # These nearby test bounds illustrate the observed category order.
        network = [{"text": "搜索网络结果", "bounds": bounds(412, 140, 105, 16)},
                   {"text": FILE_ASSISTANT, "bounds": bounds(454, 190, 84, 17)}]
        rows = network + [copy.deepcopy(OBSERVED["ocr"][0])]
        for index, name in enumerate(self.names):
            row = copy.deepcopy(OBSERVED["ocr"][1])
            row["text"] = name
            row["bounds"]["y"] += index * 35
            rows.append(row)
        return rows + [{"text": "聊天记录", "bounds": bounds(412, 420, 58, 16)},
                       {"text": FILE_ASSISTANT, "bounds": bounds(454, 468, 84, 17)}]

    def visual(self, request, region_only=False):
        value = super().visual(request, region_only)
        # These flags are a fake new foreground native read, not the historical
        # readonly observation retained in OBSERVED.
        value.update({key: copy.deepcopy(OBSERVED[key]) for key in
                      ("target_pid", "window_id", "display_topology_signature", "captured_regions")})
        value.update(content_available=True, input_eligible=True, read_only_background=False,
                     focused_window_frame=copy.deepcopy(self.frame), target_identity_verified=True)
        regions = [request["control_rect"]] if region_only else request.get("regions", [request.get("region")])
        value["ocr_regions"] = [copy.deepcopy(r) for r in regions if r] or [copy.deepcopy(self.frame)]
        value["ocr_scope"] = "requested_regions" if "regions" in request else "requested_region_and_top_footer_anchor_bands"
        if self.search:
            value.update({key: copy.deepcopy(OBSERVED[key]) for key in
                          ("search_overlay_frame", "search_overlay_window_id", "search_overlay_query_verified", "search_lane_frame")})
            value["search_lane_text"] = self.search
            current = super().visual({})["ocr"]
            controls = [r for r in current if r["bounds"]["x"] >= self.frame["x"] + 326]
            query = {"text": self.search, "bounds": copy.deepcopy(OBSERVED["search_lane_frame"])}
            source = controls + [query] + self.panel_rows()
            selected = [r for r in source if any(region and _inside(r, region) for region in regions)] if any(regions) else source
            value["ocr"] = copy.deepcopy(selected)
            value["anchor_matches"] = [{"anchor_text": anchor, "matching_ocr": [copy.deepcopy(r) for r in source
                                        if _norm(anchor) in _norm(r["text"])]} for anchor in request.get("anchor_texts", [])]
            value["target_visible_verified"] = all(m["matching_ocr"] for m in value["anchor_matches"])
            if "region" in request:
                value["ocr_truncated"] = self.panel_truncated
                self.last_panel_snapshot = value["snapshot_id"]
            value.update(copy.deepcopy(self.foreground_changes))
        else:
            if self.after_partial_composer:
                value["captured_regions"] = [bounds(329, 41, 855, 600)]
            if self.after_stale_snapshot:
                value["snapshot_id"] = self.last_panel_snapshot
            if self.after_changed_window:
                value["window_id"] += 1
        return value

    def __call__(self, request):
        response = super().__call__(request)
        if request["command"] == "visual_click" and request["control_kind"] == "navigation" and self.after_header is not None:
            self.title = self.after_header
        return response


class FileTransferFunctionTests(unittest.TestCase):
    def session_and_panel(self, fake=None, *, kind="any", wanted=FILE_ASSISTANT):
        fake = fake or FileAssistantFake()
        session = ChatSession({"app": WECHAT, "action": "locate", "chat": wanted, "chat_kind": kind}, fake)
        session.frame, session.pid, session.title = fake.frame, fake.pid, fake.title
        session.anchors = [FILE_ASSISTANT, "发送"]
        full = session.wechat_regions()["results"]
        value = fake.visual({"region": full, "anchor_texts": session.anchors})
        value.update(search_scope_complete=True, search_panel_height_read=full["height"])
        return session, value, fake

    def run_locate(self, fake, *, kind="any"):
        clock = itertools.count(0, 1)
        with patch("chat_workflows.time.monotonic", side_effect=lambda: next(clock)), patch("chat_workflows.time.sleep"):
            return execute_chat({"app": WECHAT, "action": "locate", "chat": FILE_ASSISTANT, "chat_kind": kind}, fake, recipe_store=False)

    def navigation(self, fake):
        return [r for r in fake.calls if r["command"] == "visual_click" and r["control_kind"] == "navigation"]

    def test_observed_complete_function_row_beats_network_and_history_same_name(self):
        session, value, fake = self.session_and_panel()
        row, category = session.wechat_result(value, FILE_ASSISTANT)
        self.assertEqual(row, OBSERVED["ocr"][1])
        self.assertEqual(category, "功能")
        self.assertEqual(session.wechat_category_kind(category), "unknown")
        self.assertEqual(fake.calls, [])

    def test_exact_target_reads_full_scope_once_then_requires_a_new_full_chat_proof(self):
        fake = FileAssistantFake()
        answer = self.run_locate(fake)
        self.assertTrue(answer["ok"], answer)
        self.assertEqual(answer["result"]["chat_title"], FILE_ASSISTANT)
        self.assertTrue(answer["result"]["recipient_verified"])
        self.assertFalse(answer["result"]["chat_kind_verified"])
        self.assertEqual(answer["result"]["chat_kind_evidence"]["kind"], "unknown")
        reads = [r for r in fake.calls if r["command"] == "visual_read" and "region" in r]
        self.assertEqual(len(reads), 1)
        self.assertEqual(reads[0]["region"]["height"], fake.frame["height"] * .928)
        navigation = self.navigation(fake)
        self.assertEqual(len(navigation), 1)
        self.assertEqual(navigation[0]["target_text"], FILE_ASSISTANT)
        self.assertNotIn("x", navigation[0])
        self.assertNotIn("y", navigation[0])
        self.assertFalse(any(r["command"] in {"visual_type_text", "visual_key"} for r in fake.calls))

    def test_actual_readonly_observation_is_not_navigation_authority(self):
        session, value, _ = self.session_and_panel()
        value.update(input_eligible=OBSERVED["input_eligible"], read_only_background=OBSERVED["read_only_background"])
        self.assertEqual(session.wechat_result(value, FILE_ASSISTANT), (None, None))

    def test_duplicate_exact_and_exact_plus_truncated_function_rows_are_ambiguous(self):
        for names in ([FILE_ASSISTANT, FILE_ASSISTANT], [FILE_ASSISTANT, "文件传输..."]):
            with self.subTest(names=names):
                fake = FileAssistantFake()
                fake.names = names
                answer = self.run_locate(fake)
                self.assertEqual(answer["error"]["code"], "ambiguous_target", answer)
                self.assertEqual(self.navigation(fake), [])

    def test_partial_ellipsis_AI_suffix_and_member_count_are_not_builtin_function_labels(self):
        for label in ("文件传输...", "文件传输", FILE_ASSISTANT + " AI", FILE_ASSISTANT + "（2）"):
            with self.subTest(label=label):
                fake = FileAssistantFake()
                fake.names = [label]
                session, value, _ = self.session_and_panel(fake)
                self.assertEqual(session.wechat_result(value, FILE_ASSISTANT), (None, None))

    def test_network_and_history_only_matches_never_authorize_navigation(self):
        fake = FileAssistantFake()
        fake.names = []
        answer = self.run_locate(fake)
        self.assertEqual(answer["error"]["code"], "target_not_found", answer)
        self.assertEqual(self.navigation(fake), [])

    def test_other_function_below_network_cutoff_is_not_reopened(self):
        fake = FileAssistantFake()
        fake.search, fake.names = "其他功能", ["其他功能"]
        session, value, _ = self.session_and_panel(fake, wanted="其他功能")
        self.assertEqual(session.wechat_result(value, "其他功能"), (None, None))

    def test_requested_person_or_group_is_never_fabricated(self):
        for kind in ("person", "group"):
            with self.subTest(kind=kind):
                session, value, _ = self.session_and_panel(kind=kind)
                self.assertEqual(session.wechat_result(value, FILE_ASSISTANT), (None, None))

    def test_complete_current_query_binding_and_coverage_are_required(self):
        for field, changed in (
            ("search_lane_text", "文件传输"), ("search_overlay_query_verified", False),
            ("search_overlay_window_id", 0), ("input_eligible", False), ("read_only_background", True),
            ("target_pid", 1), ("window_id", 0), ("display_topology_signature", ""),
            ("focused_window_frame", bounds(330, 41, 855, 1079)), ("captured_regions", []),
            ("ocr_regions", []), ("ocr_truncated", True), ("search_scope_complete", False),
            ("search_panel_height_read", 320), ("search_overlay_frame", bounds(377, 76, 368, 200))):
            with self.subTest(field=field):
                session, value, _ = self.session_and_panel()
                value[field] = changed
                self.assertEqual(session.wechat_result(value, FILE_ASSISTANT), (None, None))

    def test_full_search_truncation_stops_before_navigation(self):
        fake = FileAssistantFake()
        fake.panel_truncated = True
        answer = self.run_locate(fake)
        self.assertEqual(answer["error"]["code"], "search_results_truncated", answer)
        self.assertEqual(self.navigation(fake), [])

    def test_wrong_complete_header_including_AI_or_group_suffix_stops_after_one_probe(self):
        for title in ("别的会话", FILE_ASSISTANT + " AI", FILE_ASSISTANT + "（2）"):
            with self.subTest(title=title):
                fake = FileAssistantFake()
                fake.after_header = title
                answer = self.run_locate(fake)
                self.assertFalse(answer["ok"], answer)
                self.assertEqual(len(self.navigation(fake)), 1)
                self.assertFalse(any(r["command"] in {"visual_type_text", "visual_key"} for r in fake.calls))

    def test_stale_new_window_and_incomplete_composer_fail_after_one_probe(self):
        for field in ("after_stale_snapshot", "after_changed_window", "after_partial_composer"):
            with self.subTest(field=field):
                fake = FileAssistantFake()
                setattr(fake, field, True)
                answer = self.run_locate(fake)
                self.assertFalse(answer["ok"], answer)
                self.assertEqual(len(self.navigation(fake)), 1)
                self.assertFalse(any(r["command"] in {"visual_type_text", "visual_key"} for r in fake.calls))

    def test_automatic_locate_does_not_bypass_old_chat_quote_or_draft_for_current_exact_query(self):
        fake = FileAssistantFake()
        fake.draft = "合成引用上下文"
        answer = self.run_locate(fake)
        self.assertEqual(answer["error"]["code"], "draft_present", answer)
        self.assertEqual(fake.draft, "合成引用上下文")
        self.assertEqual(self.navigation(fake), [])
        self.assertFalse(any(r["command"] in {"visual_type_text", "visual_key", "batch"} for r in fake.calls))

    def test_explicit_existing_select_search_stage_is_navigation_only_with_new_full_binding(self):
        session, _, fake = self.session_and_panel()
        fake.draft = "合成引用上下文"
        selected = session.wechat_select_search(FILE_ASSISTANT)
        self.assertEqual(session.wechat_header(selected), FILE_ASSISTANT)
        self.assertTrue(session.wechat_complete_composer_capture(selected))
        self.assertNotEqual(selected["snapshot_id"], fake.last_panel_snapshot)
        self.assertEqual(session.kind_evidence["kind"], "unknown")
        self.assertEqual(len(self.navigation(fake)), 1)
        self.assertEqual(fake.draft, "合成引用上下文")
        self.assertFalse(session.submit_started)
        self.assertIsNone(session.edited_value)
        self.assertFalse(any(r["command"] in {"visual_type_text", "visual_key", "batch"} for r in fake.calls))
        # Fake retention proves only that the adapter issues no content edits.
        # A real explicit stage must separately verify original UI state retention.


if __name__ == "__main__":
    unittest.main()
