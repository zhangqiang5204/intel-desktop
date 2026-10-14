"""Bounded search query tests; full recipient proof is never a prefix match."""
import copy
import unittest
from unittest.mock import patch

from test_chat_workflows import WeChatFake, bounds
from chat_workflows import WECHAT, _inside, _norm, _wechat_search_query, _wechat_truncated_result_matches, execute_chat


# Root's real MCP30 target; other names below are synthetic collision cases.
ACTUAL_LONG_NAME = "保利上城（东区）10-2单元业主群"
ACTUAL_QUERY = "保利上城（东区）10-2单元"
# Root's offline MCP32 popup shows this explicit ellipsis under 群聊. Geometry
# below is a fake backend, not a claim of a successful native capture/click.
ACTUAL_TRUNCATED_LABEL = ACTUAL_QUERY + "..."


class FullResultFake(WeChatFake):
    def __init__(self, names):
        super().__init__()
        self.names = names
        self.section = "群聊"
        self.frame = bounds(1900, 33, 855, 1079)
        self.search = "之前的搜索"  # No recent lookup while a search overlay is open.

    def visual(self, request, region_only=False):
        value = super().visual(request, region_only)
        if self.search and "region" in request:
            region = request["region"]
            value["ocr"] = [{"text": self.section, "bounds": bounds(self.frame["x"] + 85, 110, 70, 18)}]
            for index, name in enumerate(self.names):
                row = {"text": name, "bounds": bounds(self.frame["x"] + 110, 150 + index * 45, 250, 22)}
                if row["bounds"]["y"] + 11 < region["y"] + region["height"]:
                    value["ocr"].append(row)
            value["ocr"].append({"text": "聊天记录", "bounds": bounds(self.frame["x"] + 85, 320, 70, 18)})
        return value


class PopupResultFake(FullResultFake):
    """Native33 response shape with the actual query lane and visible header."""
    def __init__(self):
        super().__init__([ACTUAL_TRUNCATED_LABEL])
        self.search = ACTUAL_QUERY
        self.hide_header = False
        self.hide_header_after_type = False
        self.query_verified = True

    def visual(self, request, region_only=False):
        value = super().visual(request, region_only)
        if not self.search:
            return value
        query_row = {"text": self.search, "bounds": bounds(self.frame["x"] + 91, self.frame["y"] + 16, 156, 16)}
        send_row = {"text": "发送", "bounds": bounds(self.frame["x"] + self.frame["width"] - 59, self.frame["y"] + self.frame["height"] * .972, 23, 13)}
        if self.hide_header:
            value["ocr"] = [row for row in value["ocr"] if row["text"] != self.title]
        regions = [request["control_rect"]] if region_only else request.get("regions", [request.get("region")])
        if any(region and _inside(query_row, region) for region in regions):
            value["ocr"].append(query_row)
        anchor_source = value["ocr"] + [query_row, send_row]
        value["anchor_matches"] = [{"anchor_text": anchor, "matching_ocr": [copy.deepcopy(row) for row in anchor_source if _norm(anchor) in _norm(row["text"])]}
                                   for anchor in request.get("anchor_texts", [])]
        value["target_visible_verified"] = all(match["matching_ocr"] for match in value["anchor_matches"])
        value.update(search_overlay_window_id=333, search_overlay_frame=bounds(self.frame["x"] + 46, self.frame["y"] + 35, 368, 430),
                     search_overlay_query_verified=self.query_verified, search_lane_text=_norm(self.search), search_lane_frame=query_row["bounds"])
        return value

    def __call__(self, request):
        if request["command"] == "visual_type_text" and self.hide_header_after_type:
            self.hide_header = True
        response = super().__call__(request)
        if request["command"] == "visual_click" and request["control_kind"] == "navigation":
            self.title = ACTUAL_LONG_NAME
        return response


class SearchPrefixTests(unittest.TestCase):
    def test_existing_verified_popup_query_is_reused_with_current_header_visible(self):
        fake = PopupResultFake()
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME, "chat_kind": "group"}, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["result"]["chat_title"], ACTUAL_LONG_NAME)
        reads = [call for call in fake.calls if call["command"] == "visual_read"]
        self.assertEqual(reads[1]["anchor_texts"], ["测试群", "发送"])
        self.assertTrue(all(call["anchor_texts"] == [ACTUAL_QUERY, "发送"] for call in reads if "region" in call))
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_click"]), 1)
        self.assertFalse(any(call["command"] in {"batch", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_new_query_readback_replaces_popup_covered_header_anchor(self):
        fake = PopupResultFake()
        fake.search, fake.hide_header, fake.hide_header_after_type = "旧关键词", False, True
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME}, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        panel_reads = [call for call in fake.calls if call["command"] == "visual_read" and "region" in call]
        self.assertTrue(panel_reads)
        self.assertTrue(all(call["anchor_texts"] == [ACTUAL_QUERY, "发送"] for call in panel_reads))
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_type_text"]), 1)

    def test_popup_reuse_preserves_existing_draft_before_any_navigation(self):
        fake = PopupResultFake()
        fake.draft = "现有未发送草稿"
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_present")
        self.assertEqual(fake.draft, "现有未发送草稿")
        self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_other_verified_popup_query_read_preserves_search_and_real_header(self):
        fake = PopupResultFake()
        fake.search = "不同的已验证查询"
        result = execute_chat({"app": WECHAT, "action": "read"}, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["result"]["chat_title"], "测试群")
        self.assertEqual(fake.search, "不同的已验证查询")
        self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_missing_actual_header_stops_without_search_recovery_events(self):
        fake = PopupResultFake()
        fake.hide_header = True
        result = execute_chat({"app": WECHAT, "action": "read"}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "target_not_found")
        self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_unverified_popup_query_does_not_authorize_recovery(self):
        fake = PopupResultFake()
        fake.query_verified, fake.hide_header = False, True
        result = execute_chat({"app": WECHAT, "action": "read"}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "target_not_found")
        self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_actual_ellipsized_local_result_probes_once_then_requires_full_header(self):
        for label in (ACTUAL_TRUNCATED_LABEL, ACTUAL_QUERY + "…", ACTUAL_QUERY + "⋯", ACTUAL_QUERY + "⋯."):
            fake = FullResultFake([label])
            def callback(request):
                response = fake(request)
                if request["command"] == "visual_click" and request["control_kind"] == "navigation":
                    fake.title = ACTUAL_LONG_NAME
                return response
            result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME, "chat_kind": "group"}, callback, recipe_store=False)
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["result"]["chat_title"], ACTUAL_LONG_NAME)
            self.assertTrue(result["result"]["recipient_verified"])
            navigation = [call for call in fake.calls if call["command"] == "visual_click" and call["control_kind"] == "navigation"]
            self.assertEqual(len(navigation), 1)
            self.assertEqual(navigation[0]["target_text"], ACTUAL_QUERY)
            self.assertIn("x", navigation[0])
            self.assertIn("y", navigation[0])
            self.assertFalse(any(call.get("key") in {"return", "enter", "backspace"} for call in fake.calls))

    def test_ellipsis_requires_a_proper_prefix_consistent_with_bounded_query(self):
        for label in (ACTUAL_QUERY + "...", ACTUAL_QUERY[:-2] + "…", ACTUAL_QUERY + "业…", ACTUAL_QUERY + "⋯", ACTUAL_QUERY + "⋯."):
            self.assertTrue(_wechat_truncated_result_matches(label, ACTUAL_LONG_NAME), label)
        for label in (ACTUAL_QUERY, "...", "…", "⋯", "⋯.", "利上城...", ACTUAL_QUERY + "邻里...", ACTUAL_LONG_NAME + "...", ACTUAL_QUERY + ")", ACTUAL_QUERY + "•", ACTUAL_QUERY + "•."):
            self.assertFalse(_wechat_truncated_result_matches(label, ACTUAL_LONG_NAME), label)

    def test_exact_and_ellipsized_local_candidates_share_ambiguity_check(self):
        for names in ([ACTUAL_LONG_NAME, ACTUAL_TRUNCATED_LABEL],
                      [ACTUAL_TRUNCATED_LABEL, ACTUAL_QUERY + "业…"]):
            fake = FullResultFake(names)
            result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME, "chat_kind": "group"}, fake, recipe_store=False)
            self.assertEqual(result["error"]["code"], "ambiguous_target")
            self.assertEqual(result["error"]["details"]["matching_count"], 2)
            self.assertFalse(any(call["command"] == "visual_click" and call["control_kind"] == "navigation" for call in fake.calls))

    def test_requested_kind_cannot_hide_another_matching_ellipsized_local_row(self):
        fake = FullResultFake([ACTUAL_LONG_NAME])
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_read" and "region" in request:
                response["result"]["ocr"] = [
                    {"text": "群聊", "bounds": bounds(fake.frame["x"] + 85, 110, 70, 18)},
                    {"text": ACTUAL_LONG_NAME, "bounds": bounds(fake.frame["x"] + 110, 150, 250, 22)},
                    {"text": "联系人", "bounds": bounds(fake.frame["x"] + 85, 190, 70, 18)},
                    {"text": ACTUAL_TRUNCATED_LABEL, "bounds": bounds(fake.frame["x"] + 110, 225, 250, 22)},
                    {"text": "聊天记录", "bounds": bounds(fake.frame["x"] + 85, 320, 70, 18)},
                ]
            return response
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME, "chat_kind": "group"}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "ambiguous_target")
        self.assertEqual(result["error"]["details"]["matching_count"], 2)
        self.assertFalse(any(call["command"] == "visual_click" and call["control_kind"] == "navigation" for call in fake.calls))

    def test_ellipsized_name_without_local_category_never_posts_navigation(self):
        for section in ("", "聊天记录", "搜索网络结果"):
            fake = FullResultFake([ACTUAL_TRUNCATED_LABEL])
            fake.section = section
            with patch("chat_workflows.time.monotonic", side_effect=range(20)):
                result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME}, fake, recipe_store=False)
            self.assertEqual(result["error"]["code"], "target_not_found", result)
            self.assertFalse(any(call["command"] == "visual_click" and call["control_kind"] == "navigation" for call in fake.calls))

    def test_wrong_header_after_ellipsis_preserves_draft_and_blocks_all_edits(self):
        for action in ("locate", "draft", "clear", "send"):
            fake = FullResultFake([ACTUAL_TRUNCATED_LABEL])
            request = {"app": WECHAT, "action": action, "chat": ACTUAL_LONG_NAME, "chat_kind": "group"}
            if action in {"draft", "send"}:
                request["text"] = "未发送测试内容"
            if action == "clear":
                request["expected_draft"] = "保留已有草稿"
            if action == "send":
                request["send_authorization"] = {"source": "current_user", "app": WECHAT, "chat": ACTUAL_LONG_NAME, "text": request["text"]}
            def callback(native_request):
                response = fake(native_request)
                if native_request["command"] == "visual_click" and native_request["control_kind"] == "navigation":
                    fake.title, fake.draft = ACTUAL_QUERY + "邻里群", "保留已有草稿"
                return response
            result = execute_chat(request, callback, recipe_store=False)
            self.assertEqual(result["error"]["code"], "target_not_found", result)
            self.assertEqual(fake.draft, "保留已有草稿")
            self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_click" and call["control_kind"] == "navigation"]), 1)
            self.assertFalse(any(call.get("control_kind") == "chat_composer" or call["command"] == "visual_key" for call in fake.calls))
            self.assertFalse(result["automatic_replay_allowed"])

    def test_existing_draft_blocks_ellipsized_lookup_before_search(self):
        fake = FullResultFake([ACTUAL_TRUNCATED_LABEL])
        fake.draft = "当前会话草稿"
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_present")
        self.assertEqual(fake.draft, "当前会话草稿")
        self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for call in fake.calls))

    def test_actual_long_name_uses_bounded_query_without_modifying_wanted(self):
        self.assertEqual(_wechat_search_query(ACTUAL_LONG_NAME), ACTUAL_QUERY)
        self.assertLess(len(ACTUAL_QUERY), len(ACTUAL_LONG_NAME))
        fake = FullResultFake([ACTUAL_QUERY + "邻里群", ACTUAL_QUERY, ACTUAL_LONG_NAME])
        request = {"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME, "chat_kind": "group"}
        original = copy.deepcopy(request)
        result = execute_chat(request, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(request, original)
        typed = [call for call in fake.calls if call["command"] == "visual_type_text"]
        self.assertEqual(len(typed), 1)
        self.assertEqual((typed[0]["text"], typed[0]["expected_text"]), (ACTUAL_QUERY, ACTUAL_QUERY))
        navigation = [call for call in fake.calls if call["command"] == "visual_click" and call["control_kind"] == "navigation"]
        self.assertEqual(len(navigation), 1)
        self.assertEqual(navigation[0]["target_text"], ACTUAL_LONG_NAME)
        self.assertEqual(result["result"]["chat_title"], ACTUAL_LONG_NAME)
        self.assertTrue(result["result"]["recipient_verified"])
        self.assertFalse(any(call.get("key") in {"return", "enter"} for call in fake.calls))

    def test_short_names_ascii_and_common_emoji_clusters_remain_unchanged(self):
        for name in ("助手", "2026示例讨论组", "示例酒店服务助手", "A" * 24, "中国🇨🇳", "👩🏽‍💻" * 12, "e\u0301" * 24, "1\ufe0f\u20e3" * 12):
            self.assertEqual(_wechat_search_query(name), name)
        self.assertEqual(_wechat_search_query("A" * 25), "A" * 24)
        self.assertEqual(_wechat_search_query("中" * 13), "中" * 12)
        self.assertEqual(_wechat_search_query("中" * 11 + "AB" + "🏡"), "中" * 11 + "AB")

    def test_query_never_splits_flag_skin_tone_zwj_or_combining_cluster_at_limit(self):
        for cluster in ("🇨🇳", "👩🏽‍💻", "👨‍👩‍👧‍👦", "e\u0301", "1\ufe0f\u20e3"):
            wide = cluster != "e\u0301"
            prefix = "中" * 11 + "A" if wide else "中" * 12
            self.assertEqual(_wechat_search_query(prefix + cluster), prefix)

    def test_same_prefix_without_complete_target_posts_no_navigation(self):
        fake = FullResultFake([ACTUAL_QUERY, ACTUAL_QUERY + "邻里群"])
        with patch("chat_workflows.time.monotonic", side_effect=range(20)):
            result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "target_not_found")
        self.assertFalse(any(call["command"] == "visual_click" and call["control_kind"] == "navigation" for call in fake.calls))
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_type_text"]), 1)

    def test_two_complete_same_names_remain_ambiguous_despite_query_prefix(self):
        fake = FullResultFake([ACTUAL_LONG_NAME, ACTUAL_LONG_NAME])
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "ambiguous_target")
        self.assertFalse(any(call["command"] == "visual_click" and call["control_kind"] == "navigation" for call in fake.calls))

    def test_final_header_prefix_is_rejected_after_one_exact_target_click(self):
        fake = FullResultFake([ACTUAL_LONG_NAME])
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_click" and request["control_kind"] == "navigation":
                fake.title = ACTUAL_QUERY
            return response
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "target_not_found")
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_click" and call["control_kind"] == "navigation"]), 1)
        self.assertFalse(any(call.get("key") in {"enter", "return"} for call in fake.calls))

    def test_uncertain_prefix_input_is_not_retyped_or_submitted(self):
        fake = FullResultFake([ACTUAL_LONG_NAME])
        fake.fail_on_type = True
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": ACTUAL_LONG_NAME}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "user_interrupted")
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_type_text"]), 1)
        self.assertFalse(any(call["command"] == "visual_click" and call["control_kind"] == "navigation" for call in fake.calls))


if __name__ == "__main__":
    unittest.main()
