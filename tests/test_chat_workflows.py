"""Pure fake-backend safety/contract tests. No native helper or real UI calls."""
import copy
from collections import Counter
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from chat_workflows import execute_chat, ChatSession, Stopped, WECHAT, FEISHU, STRUCTURE, VOICE_HINT, SEARCH_MODAL, _history_alignment, _feishu_search_query
from recipe_store import RecipeStore, execute_recipe


def _norm_for_fake(value):
    return "".join(value.split()).replace("\u200b", "")


def bounds(x, y, width, height):
    return {"x": x, "y": y, "width": width, "height": height}


def ax(identifier, role, x, y, width, height, **fields):
    # Preserve the legacy cap-boundary fixture's unknown completeness; callers
    # can still supply the real native positive flag for exactly 4000 chars.
    proof = {"value_complete": True, "value_truncated": False} if isinstance(fields.get("value"), str) and len(fields["value"]) < 4000 else {}
    return {"element_id": identifier, "role": role, "position": {"x": x, "y": y},
            "size": {"width": width, "height": height}, "secure": False, "enabled": True, **proof, **fields}


class WeChatFake:
    def __init__(self):
        self.app, self.pid = WECHAT, 123
        self.frame = bounds(211, 25, 932, 1079)
        self.title = "测试群"
        self.draft = ""
        self.search = ""
        self.pages = [["新消息", "最后回复"], ["较早消息", "新消息"], ["最早可见", "较早消息"]]
        self.page = 0

        self.calls = []
        self.interrupted = None
        self.change_on_click = None
        self.ambiguous = False
        self.fail_on_type = False
        self.switch_chat_on_scroll = False
        self.search_category = "联系人"
        self.search_heading_offset = 85
        self.search_result_offset = 120
        self.recent_chats = []
        self.scrolled_header_sender = False
        self.long_body_rows = 0
        self.search_label = "搜索"
        self.hide_send = False
        self.stale_search_click = False
        self.promoted_bot = False
        self.recent_category_row = False
        self.toggle_same_recent = False
        self.recent_ocr = []
        self.timeout_missing_anchors = False

    def window(self):
        f = self.frame
        return ax("window", "AXWindow", f["x"], f["y"], f["width"], f["height"], title="微信")

    def visual(self, request, region_only=False):
        f = self.frame
        rows = [
            {"text": self.title, "bounds": bounds(f["x"] + 336.392, f["y"] + 18, 110, 20)},
            {"text": "发送", "bounds": bounds(f["x"] + f["width"] - 59, f["y"] + f["height"] * .972, 23, 13)},
        ] if self.title else []
        if not self.search:
            rows.append({"text": self.search_label, "bounds": bounds(f["x"] + 85, f["y"] + 18, 55, 18)})
        if self.hide_send:
            rows = [row for row in rows if row["text"] != "发送"]
        for i, chat in enumerate(self.recent_chats if not self.search else []):
            rows.append({"text": chat, "bounds": bounds(f["x"] + 90, f["y"] + 120 + i * 90, 170, 25)})
        if self.recent_category_row and not self.search:
            rows += [{"text": "公众号", "bounds": bounds(f["x"] + 118, f["y"] + 350, 41, 15)},
                     {"text": "23:09", "bounds": bounds(f["x"] + 280, f["y"] + 351, 30, 10)},
                     {"text": "［5条］最近可见预览", "bounds": bounds(f["x"] + 118, f["y"] + 371, 185, 13)}]
        if not self.search:
            rows += copy.deepcopy(self.recent_ocr)
        for i, text in enumerate(self.pages[self.page] if self.title else []):
            rows.append({"text": text, "bounds": bounds(f["x"] + 390, f["y"] + 150 + i * 35, 180, 25)})
        for i in range(self.long_body_rows):
            rows.append({"text": f"长正文片段{i}", "bounds": bounds(f["x"] + 335 + i % 6 * 85, f["y"] + 220 + i // 6 * 24, 70, 16)})
        if self.scrolled_header_sender and self.page:
            rows.append({"text": "上卷后的消息发送者", "bounds": bounds(f["x"] + 350, f["y"] + 65, 160, 20)})
        if self.draft:
            rows.append({"text": self.draft, "bounds": bounds(f["x"] + 336, f["y"] + f["height"] * .88, 300, 25)})
        if self.search:
            if self.promoted_bot:
                rows += [{"text": self.search + " AI", "bounds": bounds(f["x"] + 127.8, f["y"] + 88.5, 44.6, 14.5)},
                         {"text": "微信 ClawBot", "bounds": bounds(f["x"] + 126.7, f["y"] + 113.5, 75, 12.2)},
                         {"text": "联系人", "bounds": bounds(f["x"] + 83.2, f["y"] + 149.5, 35.9, 13.1)},
                         {"text": "示例酒店服务助手", "bounds": bounds(f["x"] + 127.8, f["y"] + 195.3, 121.8, 15.2)}]
            else:
                rows.append({"text": self.search_category, "bounds": bounds(f["x"] + 85, f["y"] + self.search_heading_offset, 80, 18)})
                rows.append({"text": self.search + " AI", "bounds": bounds(f["x"] + 110, f["y"] + self.search_result_offset, 120, 25)})
            if self.ambiguous:
                rows.append({"text": self.search + " AI", "bounds": bounds(f["x"] + 110, f["y"] + 170, 120, 25)})
        all_rows = rows
        def in_region(row, region):
            rect = row["bounds"]
            return (region["x"] <= rect["x"] + rect["width"] / 2 <= region["x"] + region["width"]
                    and region["y"] <= rect["y"] + rect["height"] / 2 <= region["y"] + region["height"])
        if region_only or "region" in request or "regions" in request:
            regions = [request["control_rect"]] if region_only else request.get("regions", [request.get("region")])
            rows = []
            for region in regions:
                rows.extend(r for r in all_rows if in_region(r, region) and r not in rows)
        # Explicit multi-region native reads do not attach any anchor ROI.
        # Singles/control readbacks still have the fresh native anchor bands.
        anchor_source = rows if "regions" in request else all_rows
        confirmed = True
        if request.get("confirm_target"):
            confirmed = all(any(_norm_for_fake(anchor) in _norm_for_fake(r["text"]) for r in anchor_source) for anchor in request.get("anchor_texts", []))
        anchor_matches = [{"anchor_text": anchor, "matching_ocr": [copy.deepcopy(r) for r in anchor_source if _norm_for_fake(anchor) in _norm_for_fake(r["text"])]}
                          for anchor in request.get("anchor_texts", [])]
        truncated = len(rows) > request.get("max_text_rows", 100)
        rows = rows[:request.get("max_text_rows", 100)]
        return {"target_pid": self.pid, "window_id": 91, "display_topology_signature": "one-screen",
                "window_frame": dict(self.frame), "snapshot_id": f"snapshot-{len(self.calls)}",
                "ocr": rows, "anchor_matches": anchor_matches, "target_visible_verified": confirmed, "ocr_truncated": truncated,
                **({"read_only_background": True, "input_eligible": False, "target_identity_verified": True,
                    "content_available": True, "captured_regions": [dict(self.frame)],
                    "ocr_regions": copy.deepcopy(request.get("regions", [self.frame])), "ocr_scope": "requested_regions"}
                   if request.get("command") == "background_visual_read" else {})}

    def __call__(self, request):
        self.calls.append(copy.deepcopy(request))
        command = request["command"]
        if command == "status":
            return {"ok": True, "result": {"frontmost_app_bundle_id": self.app, "frontmost_pid": self.pid, "interrupted": self.interrupted}}
        if command == "inspect":
            return {"ok": True, "result": {"target_pid": self.pid, "windows": [self.window()], "elements": [self.window()], "truncated": False}}
        if command == "focus":
            return {"ok": True, "result": {"target_pid": self.pid, "foreground_verified": True,
                    **({"focus_restored": True, "focus_restore_attempted": True, "restore_reason": "previous_window_verified"}
                       if request.get("restore_previous") else {})}}
        if command == "batch":
            results, latest = [], None
            for action in request["actions"]:
                effective = dict(action)
                if action.get("snapshot_id") == "latest":
                    if latest is None:
                        return {"ok": False, "error": {"code": "batch_snapshot_unavailable", "message": "No batch producer", "details": {"events_posted": 0}}}
                    effective["snapshot_id"] = latest
                response = self({"app": self.app, "window_title": "微信", **effective})
                if not response["ok"]:
                    response["error"].setdefault("details", {}).update(completed_results=results, completed_count=len(results))
                    return response
                results.append({"command": action["command"], "result": response["result"]})
                latest = response["result"].get("snapshot_id", latest)
            return {"ok": True, "result": {"target_pid": self.pid, "results": results, "completed_count": len(results)}}
        if command in {"visual_read", "background_visual_read"}:
            result = self.visual(request)
            if (self.timeout_missing_anchors and request.get("confirm_target") and not result["target_visible_verified"]
                    and request.get("anchor_wait_timeout_ms", 3000) > 0):
                return {"ok": False, "error": {"code": "visual_frame_timeout", "message": "Missing anchors waited for an unavailable frame"}}
            return {"ok": True, "result": result}
        if command == "visual_click":
            if self.stale_search_click and request["control_kind"] == "search":
                return {"ok": False, "error": {"code": "stale_visual_snapshot", "message": "Snapshot expired", "details": {"events_posted": 0}}}
            if request["control_kind"] == "chat_composer" and self.change_on_click is not None:
                self.draft = self.change_on_click
            if request["control_kind"] == "navigation":
                if self.ambiguous:
                    return {"ok": False, "error": {"code": "ambiguous_visual_navigation", "message": "Two exact targets", "details": {"events_posted": 0}}}
                self.title = "" if self.toggle_same_recent and not self.search and request["target_text"] == self.title else request["target_text"]
                self.search = ""
            return {"ok": True, "result": self.visual(request, True)}
        if command == "visual_type_text":
            if self.fail_on_type:
                return {"ok": False, "error": {"code": "user_interrupted", "message": "External input", "details": {"events_posted": 1, "input_may_be_partial": True}}}
            if request["control_kind"] == "search":
                self.search = request["text"] if request.get("replace_search") else self.search + request["text"]
            else:
                self.assert_no_search_replacement(request)
                self.draft = request["text"]
            result = self.visual(request, True)
            result["value_verified"] = True
            return {"ok": True, "result": result}
        if command == "visual_key":
            if request["key"] == "clear_draft":
                if request.get("expected_draft") != self.draft or request.get("chat_title") != self.title:
                    return {"ok": False, "error": {"code": "clear_draft_mismatch", "message": "Changed draft/recipient", "details": {"events_posted": 0}}}
                self.draft = ""
                result = self.visual(request, True)
                result.update(draft_cleared=True, value_verified=True, events_posted=4)
                return {"ok": True, "result": result}
            if request["key"] == "backspace":
                if request["control_kind"] == "search":
                    self.search = ""
                else:
                    self.draft = ""
            return {"ok": True, "result": self.visual(request, True)}
        if command == "visual_scroll":
            self.page = min(self.page + 1, len(self.pages) - 1)
            if self.switch_chat_on_scroll:
                self.title = "别的群"
            return {"ok": True, "result": self.visual(request, True)}
        raise AssertionError(command)

    @staticmethod
    def assert_no_search_replacement(request):
        if request.get("replace_search"):
            raise AssertionError("Search replacement must never reach a chat composer")


class FeishuFake:
    def __init__(self):
        self.app, self.pid = FEISHU, 456
        self.frame = bounds(200, 20, 1000, 900)
        self.title = "测试个人"
        self.draft = ""
        self.calls = []
        self.inspections = 0
        self.change_on_inspect = None
        self.tab = "messages"
        self.message_radio_id = "dynamic-message-radio"
        self.search_button_description = "搜索（⌘＋K）"
        self.duplicate_message_radio = False
        self.change_on_wait = False
        self.extra_postcondition_text = False
        self.history_web_area = False
        self.composer_width = 500
        self.history_blocked = False
        self.history_dialog = False
        self.ax_truncated = False
        self.modal = False
        self.pending_modal = False
        self.modal_delay_reads = 0
        self.search_input_role = "AXComboBox"
        self.results_delay_reads = 0
        self.results_delay_remaining = 0
        self.header_delay_reads = 0
        self.header_delay_remaining = 0
        self.pending_title = None
        self.header_counts = False
        self.group_result_index = 0
        self.empty_prefix = ""
        self.query = ""
        self.search_hint = False
        self.ambiguous = False
        self.fail_on_type = False
        self.pages = [["新消息", "最后回复"], ["较早消息", "新消息"], ["最早可见", "较早消息"]]
        self.page = 0

    def composer_value(self):
        return self.draft + STRUCTURE if self.draft else self.empty_prefix + "发送给 " + self.title + "\n" + STRUCTURE

    def search_value(self):
        return self.query + "\u200b\n" + ("\n回车查看答案" if self.query and self.search_hint else "")

    def tree(self):
        if self.modal:
            window = ax("modal", "AXWindow", 400, 100, 600, 600, title=SEARCH_MODAL)
            field = ax("search-field", self.search_input_role, 450, 150, 400, 30, value=self.search_value(), focused=True)
            rows = [window, field]
            if self.query:
                if self.results_delay_remaining:
                    rows.append(ax("search-history", "AXStaticText", 450, 260, 80, 20, value="历史"))
                else:
                    rows += [ax("contacts-category", "AXButton", 500, 230, 80, 30, title="联系人", actions=["AXPress"]),
                             ax("groups-category", "AXButton", 590, 230, 80, 30, title="群组", actions=["AXPress"])]
                rows.append(ax("result-1", "AXStaticText", 450, 300, 250, 30, value=self.query))
                rows.append({"element_id": "hidden-same-name", "role": "AXStaticText", "value": self.query})
                if self.ambiguous:
                    rows.append(ax("result-2", "AXStaticText", 450, 370, 250, 30, value=self.query))
                if self.group_result_index:
                    y = 300 if self.group_result_index == 1 else 370
                    rows.append(ax("group-subtitle", "AXStaticText", 450, y + 34, 230, 20, value="群消息更新于 9月30日"))
            return {"target_pid": self.pid, "windows": [window], "elements": rows, "truncated": False}
        f = self.frame
        window = ax("main", "AXWindow", f["x"], f["y"], f["width"], f["height"], title="飞书")
        if self.tab == "contacts":
            rows = [window, ax(self.message_radio_id, "AXRadioButton", 279, 246, 164, 32, description="消息", value="0", actions=["AXPress", "AXShowMenu"])]
            if self.duplicate_message_radio:
                rows.append(ax("other-radio", "AXRadioButton", 279, 300, 164, 32, description="消息", value="0", actions=["AXPress"]))
            return {"target_pid": self.pid, "windows": [window], "elements": rows, "truncated": False}
        value = self.composer_value()
        composer = ax("composer", "AXTextArea", 650, 800, self.composer_width, 35, value=value)
        rows = [window, composer, ax("header", "AXStaticText", 650, 60, 260, 25, value=self.title),
                ax("search-button", "AXButton", 250, 60, 80, 30, description=self.search_button_description, actions=["AXPress"]),
                ax("scroll", "AXScrollArea", 650, 155, 500, 600, actions=[])]
        if self.history_web_area:
            rows[-1] = ax("left-list-scroll", "AXScrollArea", 230, 155, 220, 600, actions=[])
            rows[2] = ax("header", "AXStaticText", 650, 180, 260, 25, value=self.title)
            if self.header_counts:
                rows[2]["parent_id"] = "header-line"
                rows += [ax("member-count", "AXStaticText", 935, 182, 8, 19, value="1", parent_id="header-line"),
                         ax("robot-count", "AXStaticText", 970, 182, 8, 19, value="5", parent_id="header-line")]
            rows.append(ax("current-chat-web", "AXWebArea", 620, 155, 560, 680, title="messenger-chat", actions=[]))
            rows.append(ax("agent-badge", "AXStaticText", 1070, 180, 30, 12, value="智能体"))
            rows.append(ax("clipped-header-history", "AXStaticText", 650, 186, 260, 1, value="已裁剪的旧消息标题"))
            rows.append(ax("clipped-body-history", "AXStaticText", 650, 240, 260, 1, value="已裁剪的旧消息正文"))
            rows.append(ax("wide-message", "AXStaticText", 1080, 330, 90, 30, value="右侧可见文本"))
            rows.append(ax("message-link", "AXLink", 620, 300, 80, 100, value="不可点击链接", actions=["AXPress"]))
            rows.append(ax("message-button", "AXButton", 620, 430, 100, 100, title="不可点击按钮", actions=["AXPress"]))
            if self.history_blocked:
                rows.append(ax("all-linked", "AXLink", 620, 155, 560, 680, value="链接覆盖正文", actions=["AXPress"]))
            if self.history_dialog:
                rows.append(ax("dialog", "AXSheet", 620, 155, 560, 680, actions=[]))
        for i, text in enumerate(self.pages[self.page]):
            rows.append(ax(f"message-{i}", "AXStaticText", 680, 220 + i * 40, 220, 30, value=text))
        if self.history_web_area:
            # Real native Send proof has explicit same-window chat ancestry;
            # flat legacy read fixtures are not a substitute for that binding.
            rows.append(ax("current-chat-body", "AXGroup", 620, 211, 560, 577,
                           parent_id="current-chat-web", actions=[]))
            if self.header_counts:
                rows.append(ax("header-line", "AXGroup", 620, 155, 560, 56,
                               parent_id="current-chat-web", actions=[]))
            for row in rows:
                if row["element_id"] in {"composer", "current-chat-web", "header"}:
                    row.setdefault("parent_id", "main" if row["element_id"] == "current-chat-web" else "current-chat-web")
                elif row["element_id"].startswith("message-") or row["element_id"] in {"wide-message", "clipped-body-history"}:
                    row.setdefault("parent_id", "current-chat-body")
        for row in rows:
            row["element_pid"] = self.pid
        return {"target_pid": self.pid, "windows": [window], "elements": rows, "truncated": self.ax_truncated, "menu_elements": []}

    def __call__(self, request):
        self.calls.append(copy.deepcopy(request))
        command = request["command"]
        if command == "status":
            result = {"frontmost_app_bundle_id": self.app, "frontmost_pid": self.pid, "interrupted": None}
        elif command == "inspect":
            self.inspections += 1
            if self.pending_modal and self.modal_delay_reads > 0 and "window_title" not in request:
                self.modal_delay_reads -= 1
                if not self.modal_delay_reads:
                    self.modal = True
            if self.change_on_inspect == self.inspections:
                self.draft = "用户刚编辑的草稿"
            result = self.tree()
            if self.modal and self.results_delay_remaining:
                self.results_delay_remaining -= 1
            if not self.modal and self.header_delay_remaining:
                self.header_delay_remaining -= 1
                if not self.header_delay_remaining:
                    self.title = self.pending_title
            if self.modal and "window_title" not in request:
                self.modal = False
                main = self.tree()
                self.modal = True
                result["windows"] += main["windows"]
                result["elements"] += main["elements"]
        elif command == "focus":
            if request.get("restore_previous"):
                return {"ok": True, "result": {"focus_restored": True,
                    "focus_restore_attempted": True, "restore_reason": "previous_window_verified",
                    "focus_restored_app": True, "window_verified": True,
                    "restore_scope": "exact_window", "previous_focus_scope": "exact_window", "events_posted": 0}}
            if self.modal and request["window_title"] != SEARCH_MODAL:
                return {"ok": False, "error": {"code": "window_mismatch", "message": "Known search modal is focused"}}
            result = {"target_pid": self.pid, "foreground_verified": True, "window_title": request["window_title"]}
        elif command == "press":
            if request["element_id"] == self.message_radio_id:
                self.tab = "messages"
            else:
                self.pending_modal = True
                self.modal = not self.modal_delay_reads
            result = {"action_accepted": True}
        elif command == "click":
            if request.get("element_id", "").startswith("result-"):
                self.modal = False
                self.pending_title = self.query
                self.header_delay_remaining = self.header_delay_reads
                if not self.header_delay_remaining:
                    self.title = self.query
                self.pending_modal = False
            result = {"action_accepted": True}
        elif command == "type_text":
            if self.fail_on_type:
                return {"ok": False, "error": {"code": "postcondition_failed", "message": "Final complete AXValue differs", "details": {"events_posted": 2, "input_may_be_partial": True}}}
            if self.modal:
                if request.get("replace_search") and request.get("expected_before") != self.search_value():
                    return {"ok": False, "error": {"code": "precondition_failed", "message": "Complete search value changed", "details": {"events_posted": 0, "input_may_be_partial": False}}}
                self.query = request["text"]
                self.results_delay_remaining = self.results_delay_reads
            else:
                self.draft = request["text"]
            result = {"value_verified": True, "value": self.search_value() if self.modal else request["expected_value"]}
        elif command == "clear_text":
            raw = self.query + "\u200b\n" if self.modal else self.draft + STRUCTURE
            if raw != request["expected_value"]:
                return {"ok": False, "error": {"code": "value_mismatch", "message": "Changed value", "details": {"events_posted": 0}}}
            self.query = "" if self.modal else self.query
            self.draft = self.draft if self.modal else ""
            result = {"clear_verified": True, "value": request["expected_empty_value"]}
        elif command == "wait_text":
            if self.change_on_wait and request["text"].startswith("发送给 "):
                self.draft = "用户刚编辑的草稿"
            current = self.composer_value()
            if self.extra_postcondition_text and request["text"] and not request["text"].startswith("发送给 "):
                current = "多出来的文本" + current
            # Match the actual Swift contains("") behavior: an empty expected
            # string does not establish a native substring match.
            if not request["text"] or request["text"] not in current:
                return {"ok": False, "error": {"code": "wait_text_timeout", "message": "No substring match"}}
            result = {"matched": True, "value": current, "waited_ms": 0}
        elif command == "key":
            if request["key"] == "pageup":
                self.page = min(self.page + 1, len(self.pages) - 1)
            elif request["key"] == "escape":
                self.modal = self.pending_modal = False
            result = {"action_accepted": True}
        elif command == "scroll":
            self.page = min(self.page + 1, len(self.pages) - 1)
            result = {"action_accepted": True, "events_posted": 2, "click_events_posted": 0}
        elif command == "batch":
            results = []
            for action in request["actions"]:
                response = self({"app": self.app, "window_title": request["window_title"], **action})
                if not response["ok"]:
                    return response
                results.append({"command": action["command"], "result": response["result"]})
            result = {"results": results, "completed_count": len(results), "target_pid": self.pid}
        else:
            raise AssertionError(command)
        return {"ok": True, "result": result}


class ChatTests(unittest.TestCase):
    def run_chat(self, backend, action, **kwargs):
        return execute_chat({"app": backend.app, "action": action, **kwargs}, backend, recipe_store=False)

    def assert_ok(self, value):
        self.assertTrue(value["ok"], value)
        return value["result"]

    def test_default_send_denial_and_multiline_denial_before_native(self):
        fake = WeChatFake()
        for request in [{"app": WECHAT, "action": "send", "text": "消息"},
                        {"app": WECHAT, "action": "draft", "text": "消息\n"},
                        {"app": WECHAT, "action": "draft", "text": "消息", "allow_submit": True}]:
            self.assertFalse(execute_chat(request, fake, recipe_store=False)["ok"])
        self.assertEqual(fake.calls, [])

    def test_app_whitelist(self):
        self.assertFalse(execute_chat({"app": "com.apple.TextEdit", "action": "read"}, lambda _: self.fail("Native called"), recipe_store=False)["ok"])

    def test_wechat_read_and_reply_evidence(self):
        fake = WeChatFake()
        result = self.assert_ok(self.run_chat(fake, "read", reply_contains="最后回复"))
        self.assertEqual(result["visible_text"], "新消息\n最后回复")
        self.assertTrue(result["reply_evidence"]["requested_text_visible"])
        self.assertFalse(result["reply_evidence"]["sender_verified"])
        self.assertFalse(result["complete_history"])
        confirmations = [c for c in fake.calls if c["command"] == "visual_read" and c.get("confirm_target")]
        self.assertEqual(confirmations[0]["anchor_texts"], ["搜索", "发送"])
        self.assertEqual(len(confirmations), 1)

    def test_wechat_two_observed_frames_preserve_fixed_sidebar_and_full_controls(self):
        # Exact title/Send OCR from accepted 932pt and resized 855pt windows.
        observations = [
            (bounds(211, 25, 932, 1079), bounds(547.3922411552061, 44.49999987475174, 48.32974243164063, 14.689188957214354),
             bounds(1083.99999995, 1063.9999999617646, 23, 13)),
            (bounds(67, 33, 855, 1079), bounds(403.5183198286436, 53.394736707604665, 48.37823183867182, 14.210526466369625),
             bounds(862.6976746576744, 1071.99999995, 23.906976744186046, 13)),
        ]
        def enclosed(inner, outer):
            self.assertGreaterEqual(inner["x"], outer["x"])
            self.assertGreaterEqual(inner["y"], outer["y"])
            self.assertLessEqual(inner["x"] + inner["width"], outer["x"] + outer["width"] + 1e-6)
            self.assertLessEqual(inner["y"] + inner["height"], outer["y"] + outer["height"] + 1e-6)
        for frame, title, send in observations:
            with self.subTest(frame=frame):
                session = ChatSession({"app": WECHAT, "action": "locate"}, WeChatFake())
                session.frame = frame
                regions = session.wechat_regions()
                for region in regions.values():
                    enclosed(region, frame)
                enclosed(title, regions["header"])
                enclosed(send, regions["send"])
                enclosed(bounds(frame["x"] + 79.3639, frame["y"] + 21.6052, 42.0553, 13.3075), regions["search"])
                enclosed(bounds(frame["x"] + 336, frame["y"] + 945, 20, 16), regions["composer"])
                self.assertEqual(regions["header"]["x"], frame["x"] + 326)
                self.assertEqual(regions["body"]["x"], frame["x"] + 326)
                self.assertEqual(regions["results"]["width"], 320)
                self.assertLess(regions["recent"]["x"] + regions["recent"]["width"], frame["x"] + 321)
                plus = {"text": "f", "bounds": bounds(frame["x"] + 290.50000017434576, frame["y"] + 19.21052666969701, 12.979525336383904, 17.763156890869137)}
                value = {"ocr": [plus, {"text": "助手 AI", "bounds": title}]}
                self.assertEqual(session.wechat_header(value), "助手 AI")
                # f is an ordinary OCR title if it occurs in the real title band;
                # the layout, rather than a character blacklist, excludes +.
                self.assertEqual(session.wechat_header({"ocr": [{"text": "f", "bounds": title}]}), "f")
                value["ocr"].append({"text": "首字草稿", "bounds": bounds(frame["x"] + 336, frame["y"] + 945, 60, 16)})
                self.assertEqual(session.wechat_draft(value), "首字草稿")

    def test_wechat_resized_window_read_draft_clear_and_recent_navigation(self):
        for frame in (bounds(211, 25, 932, 1079), bounds(67, 33, 855, 1079)):
            with self.subTest(frame=frame):
                fake = WeChatFake()
                fake.frame = frame
                self.assert_ok(self.run_chat(fake, "read", reply_contains="最后回复"))
                self.assert_ok(self.run_chat(fake, "draft", text="首字保留"))
                self.assert_ok(self.run_chat(fake, "clear", expected_draft="首字保留"))
                fake.recent_chats = ["精确最近群"]
                self.assert_ok(self.run_chat(fake, "locate", chat="精确最近群"))
                self.assertFalse(any(c["command"] == "batch" for c in fake.calls))
                # Search popup/input and current header/Send also survive resize.
                self.assert_ok(self.run_chat(fake, "locate", chat="搜索目标"))
                self.assertEqual(fake.search, "")

    def test_wechat_too_narrow_window_stops_before_focus_capture_or_input(self):
        fake = WeChatFake()
        fake.frame = bounds(67, 33, 391, 1079)
        result = self.run_chat(fake, "draft", text="不得输入")
        self.assertEqual(result["error"]["code"], "unsupported_window_geometry")
        self.assertEqual([c["command"] for c in fake.calls], ["status", "inspect"])
        self.assertEqual(fake.draft, "")

    def test_wechat_long_body_draft_explicitly_reads_both_anchor_regions(self):
        fake = WeChatFake()
        fake.long_body_rows = 150
        fake.search_label = "Q 搜索"
        result = self.assert_ok(self.run_chat(fake, "draft", text="未发送草稿"))
        self.assertTrue(result["draft_verified"])
        initial = next(c for c in fake.calls if c["command"] == "visual_read")
        self.assertEqual(len(initial["regions"]), 4)
        self.assertNotIn("region", initial)
        self.assertLess(initial["regions"][0]["height"], 50)
        self.assertLess(initial["regions"][1]["y"], fake.frame["y"] + 50)
        self.assertGreater(initial["regions"][2]["y"], fake.frame["y"] + fake.frame["height"] * .9)
        self.assertGreater(initial["regions"][3]["y"], fake.frame["y"] + fake.frame["height"] * .8)
        self.assertEqual(fake.draft, "未发送草稿")

    def test_wechat_multi_region_read_keeps_truthful_business_row_truncation(self):
        fake = WeChatFake()
        fake.long_body_rows = 150
        result = self.assert_ok(self.run_chat(fake, "read"))
        self.assertTrue(result["truncated"])
        self.assertEqual(result["visible_rows_returned"], len(result["rows"]))
        self.assertFalse(result["complete_history"])
        initial = next(c for c in fake.calls if c["command"] == "visual_read")
        self.assertEqual(len(initial["regions"]), 5)

    def test_wechat_observed_q_search_can_confirm_fallback_marker(self):
        fake = WeChatFake()
        fake.search_label = "Q 搜索"
        fake.hide_send = True
        self.assert_ok(self.run_chat(fake, "read"))
        reads = [c for c in fake.calls if c["command"] == "visual_read"]
        self.assertEqual(reads[-1]["anchor_texts"], ["测试群", "搜索"])
        self.assertFalse(any(c["command"] in {"visual_click", "visual_type_text", "visual_key"} for c in fake.calls))

    def test_wechat_header_send_evidence_survives_returned_business_cap(self):
        fake = WeChatFake()
        fake.search = "已填写的搜索"
        def callback(request):
            envelope = fake(request)
            if request["command"] == "visual_read" and request.get("anchor_texts") == [fake.title, "发送"]:
                value = envelope["result"]
                value["ocr"] = [r for r in value["ocr"] if r["text"] not in {fake.title, "发送"}]
            return envelope
        result = self.assert_ok(execute_chat({"app": WECHAT, "action": "read"}, callback, recipe_store=False))
        self.assertEqual(result["chat_title"], fake.title)
        self.assertEqual(result["visible_text"], "新消息\n最后回复")

    def test_wechat_draft_and_exact_clear(self):
        fake = WeChatFake()
        self.assert_ok(self.run_chat(fake, "draft", text="命令 草稿"))
        self.assertEqual(fake.draft, "命令 草稿")
        self.assert_ok(self.run_chat(fake, "clear", expected_draft="命令 草稿"))
        self.assertEqual(fake.draft, "")
        self.assertFalse(any(c.get("key") in {"enter", "return"} for c in fake.calls))

    def test_wechat_atomic_clear_retains_exact_precondition_and_final_read(self):
        fake = WeChatFake()
        fake.draft = "命令 自有草稿"
        result = self.assert_ok(self.run_chat(fake, "clear", expected_draft=fake.draft))
        self.assertTrue(result["draft_empty"])
        keys = [c for c in fake.calls if c["command"] == "visual_key"]
        self.assertEqual(len(keys), 1)
        self.assertEqual(keys[0]["key"], "clear_draft")
        self.assertEqual(keys[0]["expected_draft"], "命令 自有草稿")
        self.assertEqual(keys[0]["chat_title"], fake.title)
        self.assertFalse(keys[0].get("allow_submit", False))
        self.assertNotIn("modifiers", keys[0])
        self.assertTrue(any(c["command"] == "visual_read" for c in fake.calls[fake.calls.index(keys[0])+1:]))

    def test_wechat_atomic_clear_partial_failure_never_replays(self):
        for count in (1, 2, 3, 4):
            with self.subTest(events=count):
                fake = WeChatFake()
                fake.draft = "自有测试草稿"
                def callback(request):
                    if request["command"] == "visual_key" and request.get("key") == "clear_draft":
                        fake.calls.append(copy.deepcopy(request))
                        return {"ok": False, "error": {"code": "user_interrupted", "message": "Post-claim input", "details": {"events_posted": count, "input_may_be_partial": True}}}
                    return fake(request)
                result = execute_chat({"app": WECHAT, "action": "clear", "expected_draft": fake.draft}, callback, recipe_store=False)
                self.assertFalse(result["ok"])
                self.assertEqual(result["error"]["code"], "user_interrupted")
                self.assertEqual(sum(c["command"] == "visual_key" for c in fake.calls), 1)

    def test_wechat_atomic_clear_empty_rows_without_native_proof_stop(self):
        fake = WeChatFake()
        fake.draft = "自有测试草稿"
        def callback(request):
            envelope = fake(request)
            if request["command"] == "visual_key" and request.get("key") == "clear_draft":
                envelope["result"]["value_verified"] = False
            return envelope
        result = execute_chat({"app": WECHAT, "action": "clear", "expected_draft": fake.draft}, callback, recipe_store=False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "clear_unverified")
        self.assertEqual(sum(c["command"] == "visual_key" for c in fake.calls), 1)

    def test_wechat_changed_draft_stops_before_text(self):
        fake = WeChatFake()
        fake.change_on_click = "用户的新草稿"
        result = self.run_chat(fake, "draft", text="测试")
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertFalse(any(c["command"] == "visual_type_text" for c in fake.calls))
        self.assertEqual(fake.draft, "用户的新草稿")

    def test_wechat_existing_draft_preserved_on_navigation(self):
        fake = WeChatFake()
        fake.draft = "重要草稿"
        result = self.run_chat(fake, "locate", chat="其他群")
        self.assertEqual(result["error"]["code"], "draft_present")
        self.assertFalse(any(c["command"] == "batch" for c in fake.calls))

    def test_wechat_clear_requires_exact_whitespace(self):
        fake = WeChatFake()
        fake.draft = "a b"
        result = self.run_chat(fake, "clear", expected_draft="ab")
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertEqual(fake.draft, "a b")

    def test_truncated_window_ocr_reads_complete_composer_before_input(self):
        fake = WeChatFake()
        fake.draft = "未显示在截断窗口中的草稿"
        def callback(request):
            envelope = fake(request)
            if request["command"] == "visual_read":
                value = envelope["result"]
                if "region" in request:
                    region = request["region"]
                    value["ocr"] = [r for r in value["ocr"] if r["bounds"]["y"] >= region["y"]]
                else:
                    value["ocr"] = [r for r in value["ocr"] if r["text"] != fake.draft]
                    value["ocr_truncated"] = True
            return envelope
        result = execute_chat({"app": WECHAT, "action": "draft", "text": "新草稿"}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_present")
        self.assertTrue(any(c["command"] == "visual_read" and "region" in c for c in fake.calls))
        self.assertFalse(any(c["command"] == "visual_type_text" for c in fake.calls))

    def test_wechat_ambiguous_search_no_coordinate_navigation(self):
        fake = WeChatFake()
        fake.ambiguous = True
        result = self.run_chat(fake, "locate", chat="其他群")
        self.assertEqual(result["error"]["code"], "ambiguous_target")
        self.assertFalse(any(c["command"] == "visual_click" and c["control_kind"] == "navigation" for c in fake.calls))
        self.assertEqual(fake.title, "测试群")

    def test_wechat_ai_badge_uses_actual_unique_result_label(self):
        fake = WeChatFake()
        result = self.assert_ok(self.run_chat(fake, "locate", chat="助手"))
        typed = next(c for c in fake.calls if c["command"] == "visual_type_text")
        self.assertEqual(typed["text"], "助手")
        nav = next(c for c in fake.calls if c["command"] == "visual_click" and c["control_kind"] == "navigation")
        self.assertEqual(nav["target_text"], "助手 AI")
        self.assertNotIn("x", nav)
        self.assertNotIn("y", nav)
        self.assertTrue(result["chat_kind_verified"])
        batch = next(c for c in fake.calls if c["command"] == "batch")
        self.assertEqual([a["command"] for a in batch["actions"]], ["visual_click", "visual_type_text"])
        self.assertNotEqual(batch["actions"][0]["snapshot_id"], "latest")
        self.assertTrue(all(a["snapshot_id"] == "latest" for a in batch["actions"][1:]))
        self.assertTrue(batch["actions"][1]["replace_search"])
        reads = [c for c in fake.calls if c["command"] == "visual_read"]
        self.assertEqual(len(reads), 5)
        self.assertEqual(reads[2]["anchor_texts"], ["测试群", "发送"])

    def test_wechat_search_replaces_existing_query_in_two_action_batch(self):
        fake = WeChatFake()
        fake.search = "旧关键词"
        result = self.assert_ok(self.run_chat(fake, "locate", chat="新的精确目标"))
        self.assertEqual(result["chat_title"], "新的精确目标 AI")
        batches = [c for c in fake.calls if c["command"] == "batch"]
        self.assertEqual(len(batches), 1)
        click, replacement = batches[0]["actions"]
        self.assertEqual((click["command"], replacement["command"]), ("visual_click", "visual_type_text"))
        self.assertEqual((click["control_kind"], replacement["control_kind"]), ("search", "search"))
        self.assertNotEqual(click["snapshot_id"], "latest")
        self.assertEqual(replacement["snapshot_id"], "latest")
        self.assertTrue(replacement["replace_search"])
        self.assertEqual((replacement["text"], replacement["expected_text"]), ("新的精确目标", "新的精确目标"))
        self.assertFalse(any(c["command"] == "visual_key" and c["control_kind"] == "search" for c in fake.calls))
        self.assertEqual(fake.search, "")

    def test_wechat_stale_search_snapshot_stops_without_read_or_input_replay(self):
        fake = WeChatFake()
        fake.stale_search_click = True
        result = self.run_chat(fake, "locate", chat="助手")
        self.assertEqual(result["error"]["code"], "stale_visual_snapshot")
        self.assertEqual(result["error"]["details"]["events_posted"], 0)
        failed_batch = next(i for i, c in enumerate(fake.calls) if c["command"] == "batch")
        self.assertFalse(any(c["command"] == "visual_read" for c in fake.calls[failed_batch + 1:]))
        self.assertEqual(len([c for c in fake.calls if c["command"] == "batch"]), 1)
        self.assertFalse(any(c["command"] in {"visual_type_text", "visual_key"} for c in fake.calls))

    def test_wechat_initial_missing_search_anchor_confirms_observed_header(self):
        fake = WeChatFake()
        fake.search = "之前关键词"
        self.assert_ok(self.run_chat(fake, "read"))
        reads = [c for c in fake.calls if c["command"] == "visual_read"]
        self.assertEqual([c["anchor_texts"] for c in reads], [["搜索", "发送"], ["测试群", "发送"]])
        self.assertEqual(reads[0]["anchor_wait_timeout_ms"], 0)
        self.assertNotIn("anchor_wait_timeout_ms", reads[1])
        self.assertFalse(any(c["command"] in {"visual_click", "visual_key", "visual_type_text"} for c in fake.calls))

    def test_wechat_unique_recent_chat_skips_search_and_preserves_unknown_kind(self):
        fake = WeChatFake()
        fake.recent_chats = ["助手 AI", "2026示例讨论组"]
        result = self.assert_ok(self.run_chat(fake, "locate", chat="助手"))
        self.assertFalse(result["chat_kind_verified"])
        self.assertFalse(any(c["command"] in {"batch", "visual_type_text", "visual_key"} for c in fake.calls))
        nav = next(c for c in fake.calls if c["command"] == "visual_click")
        self.assertEqual(nav["target_text"], "助手 AI")
        self.assertNotIn("x", nav)








    def test_wechat_public_account_recent_row_does_not_disable_other_exact_recent_chats(self):
        fake = WeChatFake()
        fake.recent_chats = ["助手 AI", "2026示例讨论组"]
        fake.recent_category_row = True
        self.assert_ok(self.run_chat(fake, "locate", chat="助手"))
        self.assertFalse(any(c["command"] in {"batch", "visual_type_text", "visual_key"} for c in fake.calls))

    def test_wechat_actual_category_heading_keeps_recent_overlay_guard(self):
        fake = WeChatFake()
        fake.recent_chats = ["助手 AI", "公众号"]
        self.run_chat(fake, "locate", chat="助手")
        self.assertTrue(any(c["command"] == "batch" for c in fake.calls))


    def test_wechat_recent_group_requires_actual_header_member_count(self):
        fake = WeChatFake()
        fake.recent_chats = ["2026示例讨论组（12）"]
        result = self.assert_ok(self.run_chat(fake, "locate", chat="2026示例讨论组", chat_kind="group"))
        self.assertTrue(result["chat_kind_verified"])
        self.assertEqual(result["chat_kind_evidence"]["source"], "current_chat_header_member_count")
        self.assertEqual(result["chat_kind_evidence"]["member_count"], 12)
        self.assertFalse(any(c["command"] == "visual_type_text" for c in fake.calls))

    def test_wechat_current_chat_kind_classification_never_toggles_its_recent_row(self):
        fake = WeChatFake()
        fake.title = "测试个人"
        fake.recent_chats = [fake.title]
        fake.toggle_same_recent = True
        result = self.assert_ok(self.run_chat(fake, "locate", chat="测试个人", chat_kind="person"))
        self.assertTrue(result["chat_kind_verified"])
        self.assertEqual(result["chat_kind_evidence"]["category"], "联系人")
        first_batch = next(i for i, c in enumerate(fake.calls) if c["command"] == "batch")
        self.assertFalse(any(c["command"] == "visual_click" and c["control_kind"] == "navigation" for c in fake.calls[:first_batch]))

    def test_wechat_blank_start_locates_exact_recent_with_search_and_actual_label_anchors(self):
        fake = WeChatFake()
        fake.title = ""
        fake.timeout_missing_anchors = True
        fake.recent_chats = ["助手 AI", "2026示例讨论组"]
        result = self.assert_ok(self.run_chat(fake, "locate", chat="助手"))
        self.assertEqual(result["chat_title"], "助手 AI")
        self.assertFalse(result["chat_kind_verified"])
        reads = [c for c in fake.calls if c["command"] == "visual_read"]
        self.assertEqual(reads[1]["anchor_texts"], ["搜索", "发送"])
        self.assertEqual(reads[1]["anchor_wait_timeout_ms"], 0)
        self.assertEqual(reads[2]["anchor_texts"], ["搜索", "助手 AI"])
        self.assertEqual(reads[-1]["anchor_texts"], ["搜索", "发送"])
        self.assertEqual(len([c for c in fake.calls if c["command"] == "visual_click"]), 1)
        self.assertFalse(any(c["command"] in {"batch", "visual_type_text", "visual_key"} for c in fake.calls))

    def test_wechat_blank_start_ambiguous_recent_or_possible_draft_posts_no_click(self):
        for draft, recents, expected in [("", ["助手 AI", "助手 AI"], "ambiguous_target"),
                                         ("保留草稿", ["助手 AI"], "draft_unverified"),
                                         ("", ["其他会话"], "target_not_found")]:
            fake = WeChatFake()
            fake.title, fake.draft, fake.recent_chats = "", draft, recents
            result = self.run_chat(fake, "locate", chat="助手")
            self.assertEqual(result["error"]["code"], expected)
            self.assertFalse(any(c["command"] in {"visual_click", "visual_type_text", "visual_key"} for c in fake.calls))

    def test_wechat_blank_bootstrap_click_is_never_replayed_if_header_stays_blank(self):
        fake = WeChatFake()
        fake.title, fake.recent_chats = "", ["助手 AI"]
        def callback(request):
            envelope = fake(request)
            if request["command"] == "visual_click":
                fake.title = ""
            return envelope
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": "助手"}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "target_not_found")
        self.assertEqual(len([c for c in fake.calls if c["command"] == "visual_click"]), 1)
        self.assertFalse(result["automatic_replay_allowed"])







    def test_wechat_function_bot_near_panel_bottom_uses_region_read(self):
        fake = WeChatFake()
        fake.search_category = "功能"
        fake.search_heading_offset = fake.frame["height"] * .85
        fake.search_result_offset = fake.frame["height"] * .91
        result = self.assert_ok(self.run_chat(fake, "locate", chat="助手"))
        self.assertFalse(result["chat_kind_verified"])
        self.assertEqual(result["chat_kind_evidence"]["kind"], "unknown")
        self.assertEqual(result["chat_kind_evidence"]["category"], "功能")
        panel = next(c for c in fake.calls if c["command"] == "visual_read" and "region" in c and c["region"]["height"] > fake.frame["height"] * .9)
        self.assertLess(panel["region"]["width"], fake.frame["width"] * .35)
        self.assertGreater(panel["region"]["y"] + panel["region"]["height"], fake.frame["y"] + fake.search_result_offset + 25)
        nav = next(c for c in fake.calls if c["command"] == "visual_click" and c["control_kind"] == "navigation")
        self.assertEqual(nav["target_text"], "助手 AI")
        self.assertNotIn("x", nav)

    def test_wechat_promoted_headingless_bot_requires_actual_clawbot_subtitle(self):
        fake = WeChatFake()
        fake.promoted_bot = True
        result = self.assert_ok(self.run_chat(fake, "locate", chat="助手"))
        self.assertFalse(result["chat_kind_verified"])
        self.assertEqual(result["chat_kind_evidence"], {"kind": "unknown", "source": "local_OCR_search_result_subtitle", "subtitle": "微信 ClawBot"})
        nav = next(c for c in fake.calls if c["command"] == "visual_click" and c["control_kind"] == "navigation")
        self.assertEqual(nav["target_text"], "助手 AI")
        self.assertNotIn("x", nav)
        batch = next(c for c in fake.calls if c["command"] == "batch")
        self.assertEqual(batch["actions"][0]["command"], "visual_click")

    def test_wechat_promoted_bot_rejects_distant_subtitle_and_partial_name(self):
        fake = WeChatFake()
        fake.promoted_bot, fake.search = True, "助手"
        session = ChatSession({"app": WECHAT, "action": "locate", "chat": "助手"}, fake)
        session.frame = fake.frame
        original = fake.visual({})
        for label in ["distant", "partial"]:
            value = copy.deepcopy(original)
            for row in value["ocr"]:
                if label == "distant" and row["text"] == "微信 ClawBot":
                    row["bounds"]["x"] += 70
                if label == "partial" and row["text"] == "助手 AI":
                    row["text"] = "其他助手 AI"
            self.assertEqual(session.wechat_result(value, "助手"), (None, None))

    def test_wechat_clawbot_subtitle_never_overrides_network_category_or_requested_person(self):
        fake = WeChatFake()
        fake.promoted_bot, fake.search = True, "助手"
        session = ChatSession({"app": WECHAT, "action": "locate", "chat": "助手", "chat_kind": "person"}, fake)
        session.frame = fake.frame
        self.assertEqual(session.wechat_result(fake.visual({}), "助手"), (None, None))
        session.request["chat_kind"] = "any"
        value = fake.visual({})
        value["ocr"].append({"text": "网络结果", "bounds": bounds(fake.frame["x"] + 85, fake.frame["y"] + 70, 80, 18)})
        self.assertEqual(session.wechat_result(value, "助手"), (None, None))

    def test_wechat_promoted_and_contact_same_exact_name_remain_ambiguous(self):
        fake = WeChatFake()
        fake.promoted_bot = fake.ambiguous = True
        result = self.run_chat(fake, "locate", chat="助手")
        self.assertEqual(result["error"]["code"], "ambiguous_target")
        self.assertFalse(any(c["command"] == "visual_click" and c["control_kind"] == "navigation" for c in fake.calls))

    def test_wechat_network_and_message_history_are_not_chat_results(self):
        fake = WeChatFake()
        fake.search = "助手"
        session = ChatSession({"app": WECHAT, "action": "locate", "chat": "助手"}, fake)
        session.frame = fake.frame
        value = fake.visual({})
        heading = next(r for r in value["ocr"] if r["text"] == "联系人")
        for category in ["搜索网络结果", "聊天记录", "未知分类"]:
            heading["text"] = category
            self.assertEqual(session.wechat_result(value, "助手"), (None, None))



    def test_wechat_most_used_unknown_kind_never_permits_specific_kind_edits(self):
        fake = WeChatFake()
        fake.search = "精确目标"
        fake.search_category = "最常使用"
        for action in ("draft", "clear"):
            session = ChatSession({"app": WECHAT, "action": action, "chat_kind": "person"}, fake)
            session.frame = fake.frame
            self.assertEqual(session.wechat_result(fake.visual({}), "精确目标"), (None, None))
            current = WeChatFake()
            current.draft = "已授权草稿" if action == "clear" else ""
            fields = {"expected_draft": current.draft} if action == "clear" else {"text": "新草稿"}
            result = self.run_chat(current, action, chat_kind="person", **fields)
            self.assertEqual(result["error"]["code"], "chat_kind_unverified")
            self.assertFalse(any(c["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for c in current.calls))
            self.assertEqual(current.draft, "已授权草稿" if action == "clear" else "")

    def test_wechat_most_used_group_header_rejects_requested_person_after_navigation(self):
        fake = WeChatFake()
        fake.search_category = "最常使用"
        def callback(request):
            envelope = fake(request)
            if request["command"] == "visual_click" and request["control_kind"] == "navigation":
                fake.title = "目标群(12)"
            return envelope
        result = execute_chat({"app": WECHAT, "action": "locate", "chat": "目标群", "chat_kind": "person"}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "chat_kind_mismatch")
        self.assertEqual(result["error"]["details"], {"requested_kind": "person", "observed_kind": "group"})
        self.assertFalse(any(c["command"] == "visual_click" and c["control_kind"] == "chat_composer" for c in fake.calls))

    def test_wechat_current_group_header_kind_proof_permits_requested_group_draft(self):
        fake = WeChatFake()
        fake.title = "当前群(12)"
        result = self.assert_ok(self.run_chat(fake, "draft", text="群草稿", chat_kind="group"))
        self.assertTrue(result["chat_kind_verified"])
        self.assertEqual(result["chat_kind_evidence"]["member_count"], 12)
        self.assertEqual(fake.draft, "群草稿")

    def test_wechat_requested_group_rejects_contact_category(self):
        fake = WeChatFake()
        fake.search = "同名"
        session = ChatSession({"app": WECHAT, "action": "locate", "chat": "同名", "chat_kind": "group"}, fake)
        session.frame = fake.frame
        self.assertEqual(session.wechat_result(fake.visual({}), "同名"), (None, None))

    def test_wechat_history_overlap_and_bounded_position(self):
        fake = WeChatFake()
        fake.pages = [["新消息", "最后回复", "最新尾行"], ["较早消息", "新消息", "最后回复"], ["最早可见", "较早消息", "新消息"]]
        result = self.assert_ok(self.run_chat(fake, "history", pages=3))
        self.assertEqual(result["visible_text"], "最早可见\n较早消息\n新消息\n最后回复\n最新尾行")
        self.assertEqual(result["pages_read"], 3)
        self.assertEqual(result["overlap_rows_removed"], 4)
        self.assertEqual(result["page_overlap_rows"], [2, 2])
        self.assertTrue(result["coverage_contiguous"])
        self.assertFalse(result["gaps_possible"])
        self.assertTrue(result["truncated"])
        self.assertFalse(result["viewport_restored"])
        scrolls = [c for c in fake.calls if c["command"] == "visual_scroll"]
        self.assertEqual(len(scrolls), 2)
        self.assertTrue(all(c.get("target_text") for c in scrolls))
        self.assertTrue(all(c["delta_y"] == 12 for c in scrolls))

    def test_history_normalized_common_block_preserves_nonexact_edge_fragments(self):
        fake = WeChatFake()
        fake.pages = [["前缘残片", "B C", "DE", "较新"], ["更早", "AB", "BC", "D E", "后缘残片"]]
        result = self.assert_ok(self.run_chat(fake, "history", pages=3))
        self.assertEqual(result["visible_text"], "更早\n前缘残片\nAB\nB C\nDE\n较新\n后缘残片")
        self.assertEqual(result["page_overlap_rows"], [2])
        self.assertTrue(result["coverage_contiguous"])
        self.assertTrue(result["gaps_possible"])
        self.assertEqual(result["page_alignments"][0]["older_tail_unaligned"], 1)
        self.assertEqual(result["page_alignments"][0]["newer_head_unaligned"], 1)
        self.assertIn("前缘残片", [r["text"] for r in result["pages"][0]["rows"]])
        self.assertIn("后缘残片", [r["text"] for r in result["pages"][1]["rows"]])
        self.assertFalse(result["pages"][-1]["changed_viewport"])

    def test_history_preserves_real_repeated_messages_inside_a_page(self):
        fake = WeChatFake()
        fake.pages = [["重复", "锚点A", "锚点B", "较新"], ["更早", "重复", "重复", "锚点A", "锚点B"]]
        result = self.assert_ok(self.run_chat(fake, "history", pages=3))
        self.assertEqual(result["visible_text"], "更早\n重复\n重复\n锚点A\n锚点B\n较新")
        self.assertEqual(result["page_overlap_rows"], [3])
        self.assertTrue(result["coverage_contiguous"])

    def test_history_ambiguous_repeated_common_blocks_are_not_deduplicated(self):
        fake = WeChatFake()
        fake.pages = [["锚点A", "锚点B", "较新"], ["更早", "锚点A", "锚点B", "其他", "锚点A", "锚点B"]]
        result = self.assert_ok(self.run_chat(fake, "history", pages=3))
        self.assertEqual(result["visible_text"].count("锚点A"), 3)
        self.assertEqual(result["page_overlap_rows"], [0])
        self.assertEqual(result["page_alignments"][0]["reason"], "ambiguous_common_block")
        self.assertFalse(result["coverage_contiguous"])
        self.assertTrue(result["gaps_possible"])

    def test_history_actual_body_edge_clipping_is_excluded_but_retained_as_page_evidence(self):
        fake = WeChatFake()
        fake.pages = [["A", "B", "C"], ["更早", "A", "B"]]
        session = ChatSession({"app": WECHAT, "action": "history"}, fake)
        session.frame = fake.frame
        body = session.wechat_regions()["body"]
        def callback(request):
            envelope = fake(request)
            if request["command"] == "visual_read" and "regions" in request:
                envelope["result"]["ocr"] += [
                    {"text": "顶部裁切残片", "bounds": bounds(body["x"] + 30, body["y"] - 5, 100, 20)},
                    {"text": "底部裁切残片", "bounds": bounds(body["x"] + 30, body["y"] + body["height"] - 10, 100, 20)},
                ]
            return envelope
        result = self.assert_ok(execute_chat({"app": WECHAT, "action": "history", "pages": 3}, callback, recipe_store=False))
        self.assertEqual(result["visible_text"], "更早\nA\nB\nC")
        self.assertTrue(result["coverage_contiguous"])
        self.assertEqual(len(result["pages"][0]["clipped_row_indices"]), 2)
        self.assertIn("顶部裁切残片", [r["text"] for r in result["pages"][0]["rows"]])

    def test_history_same_text_with_inconsistent_scroll_geometry_is_not_proof(self):
        fake = WeChatFake()
        fake.pages = [["A", "B", "C"], ["更早", "A", "B"]]
        def callback(request):
            envelope = fake(request)
            if request["command"] == "visual_read" and fake.page:
                for row in envelope["result"]["ocr"]:
                    if row["text"] == "B":
                        row["bounds"]["y"] += 80
            return envelope
        result = self.assert_ok(execute_chat({"app": WECHAT, "action": "history", "pages": 3}, callback, recipe_store=False))
        self.assertEqual(result["page_overlap_rows"], [0])
        self.assertEqual(result["page_alignments"][0]["reason"], "row_geometry_not_aligned")
        self.assertFalse(result["coverage_contiguous"])



    def test_wechat_history_repeated_view_does_not_claim_eof(self):
        fake = WeChatFake()
        fake.pages = [["重复", "重复"]]
        result = self.assert_ok(self.run_chat(fake, "history", pages=10))
        self.assertEqual(result["stop_reason"], "viewport_unchanged")
        self.assertEqual(result["visible_text"], "重复\n重复")
        self.assertFalse(result["complete_history"])

    def test_wechat_changed_chat_stops_history(self):
        fake = WeChatFake()
        fake.switch_chat_on_scroll = True
        self.assertFalse(self.run_chat(fake, "history")["ok"])

    def test_wechat_history_changed_draft_returns_raw_composer_diagnostic_without_ignoring_it(self):
        fake = WeChatFake()
        indicator = {"text": "拚", "bounds": bounds(fake.frame["x"] + fake.frame["width"] * .92,
                                                    fake.frame["y"] + fake.frame["height"] * .90, 18, 18)}
        def callback(request):
            envelope = fake(request)
            if request["command"] == "visual_read" and fake.page:
                envelope["result"]["ocr"].append(copy.deepcopy(indicator))
            return envelope
        result = execute_chat({"app": WECHAT, "action": "history", "pages": 3}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertEqual(result["error"]["details"], {"original_draft": "", "current_draft": "拚", "current_composer_ocr": [indicator]})
        self.assertEqual(len([c for c in fake.calls if c["command"] == "visual_scroll"]), 1)
        self.assertFalse(any(c["command"] in {"visual_type_text", "visual_key"} for c in fake.calls))
        self.assertEqual(fake.draft, "")

    def test_mutation_failure_is_not_replayed(self):
        fake = WeChatFake()
        fake.fail_on_type = True
        result = self.run_chat(fake, "draft", text="测试")
        self.assertEqual(result["error"]["code"], "user_interrupted")
        self.assertFalse(result["automatic_replay_allowed"])
        self.assertEqual(len([c for c in fake.calls if c["command"] == "visual_type_text"]), 1)

    def test_post_focus_takeover_stops_after_one_focus_claim(self):
        fake = WeChatFake()
        fake.interrupted = "sustained_mouse_movement"
        result = self.run_chat(fake, "read")
        self.assertEqual(result["error"]["code"], "user_interrupted")
        self.assertEqual([c["command"] for c in fake.calls], ["status", "inspect", "focus", "status"])

    def test_dynamic_negative_geometry_without_pixel_scale(self):
        fake = WeChatFake()
        fake.frame["x"] = -1200
        fake.frame["y"] = -900
        self.assert_ok(self.run_chat(fake, "draft", text="测试"))
        click = next(c for c in fake.calls if c["command"] == "visual_click")
        self.assertLess(click["x"], 0)
        self.assertEqual(click["control_rect"]["x"], -1200 + 330)

    def test_feishu_draft_and_clear_use_exact_rich_serialization(self):
        fake = FeishuFake()
        self.assert_ok(self.run_chat(fake, "draft", text="命令 草稿"))
        typed = next(c for c in fake.calls if c["command"] == "type_text")
        self.assertEqual(typed["expected_value"], "命令 草稿" + STRUCTURE)
        self.assert_ok(self.run_chat(fake, "clear", expected_draft="命令 草稿"))
        cleared = next(c for c in fake.calls if c["command"] == "clear_text")
        self.assertEqual(cleared["expected_value"], "命令 草稿" + STRUCTURE)
        self.assertEqual(cleared["expected_empty_value"], "发送给 测试个人\n" + STRUCTURE)

    def test_feishu_changed_draft_stops_at_exact_value_read(self):
        fake = FeishuFake()
        fake.change_on_wait = True
        result = self.run_chat(fake, "draft", text="测试")
        self.assertEqual(result["error"]["code"], "wait_text_timeout")
        self.assertFalse(any(c["command"] == "type_text" for c in fake.calls))

    def test_feishu_native_empty_expected_does_not_match(self):
        fake = FeishuFake()
        result = fake({"command": "wait_text", "text": "", "element_id": "composer", "timeout_ms": 0})
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "wait_text_timeout")

    def test_feishu_simple_read_reuses_current_single_window_tree(self):
        fake = FeishuFake()
        self.assert_ok(self.run_chat(fake, "read"))
        self.assertEqual([c["command"] for c in fake.calls], ["status", "inspect", "focus", "status", "focus"])
        self.assertTrue(fake.calls[-1].get("restore_previous"))

    def test_feishu_edit_avoids_repeat_tree_and_requires_exact_wait_value(self):
        fake = FeishuFake()
        self.assert_ok(self.run_chat(fake, "draft", text="草稿"))
        self.assertEqual(len([c for c in fake.calls if c["command"] == "inspect"]), 1)
        waits = [c for c in fake.calls if c["command"] == "wait_text"]
        self.assertEqual(waits[0]["text"], "发送给 测试个人\n" + STRUCTURE)
        self.assertEqual(waits[-1]["text"], "草稿" + STRUCTURE)
        other = FeishuFake()
        other.extra_postcondition_text = True
        result = self.run_chat(other, "draft", text="草稿")
        self.assertEqual(result["error"]["code"], "draft_unverified")
        self.assertEqual(len([c for c in other.calls if c["command"] == "type_text"]), 1)

    def test_feishu_full_serialization_readback_limit_precedes_input(self):
        fake = FeishuFake()
        result = self.run_chat(fake, "draft", text="字" * 4000)
        self.assertEqual(result["error"]["code"], "text_readback_limit")
        self.assertFalse(any(c["command"] == "type_text" for c in fake.calls))

    def test_feishu_history_uses_2000_nodes_and_deduplicates(self):
        fake = FeishuFake()
        fake.pages = [["新消息", "最后回复", "最新尾行"], ["较早消息", "新消息", "最后回复"], ["最早可见", "较早消息", "新消息"]]
        result = self.assert_ok(self.run_chat(fake, "history", pages=3))
        self.assertEqual(result["visible_text"], "最早可见\n较早消息\n新消息\n最后回复\n最新尾行")
        self.assertTrue(all(c["max_nodes"] == 2000 for c in fake.calls if c["command"] == "inspect"))
        self.assertEqual(fake.draft, "")

    def test_feishu_exact_voice_hint_empty_variant_is_consistent_for_read_locate_and_draft(self):
        fake = FeishuFake()
        fake.title = "公司·主管工作群"
        fake.empty_prefix = VOICE_HINT
        read = self.assert_ok(self.run_chat(fake, "read", chat=fake.title))
        self.assertEqual(read["chat_title"], fake.title)
        self.assert_ok(self.run_chat(fake, "locate", chat=fake.title))
        self.assertFalse(any(c["command"] in {"press", "type_text", "clear_text"} for c in fake.calls))
        cleared = self.assert_ok(self.run_chat(fake, "clear", expected_draft=""))
        self.assertEqual(cleared["empty_value"], VOICE_HINT + "发送给 公司·主管工作群\n" + STRUCTURE)
        self.assert_ok(self.run_chat(fake, "draft", text="正常未发送草稿"))
        self.assertEqual(fake.draft, "正常未发送草稿")

    def test_feishu_voice_hint_text_without_complete_empty_placeholder_is_a_real_draft(self):
        fake = FeishuFake()
        session = ChatSession({"app": FEISHU, "action": "read"}, fake)
        session.frame = fake.frame
        for value in ["按住 fn 说话", VOICE_HINT, VOICE_HINT + "发送给 测试个人\n普通草稿"]:
            fake.draft = value
            self.assertEqual(session.feishu_draft(fake.tree()), value)
            result = self.run_chat(fake, "draft", text="不要覆盖")
            self.assertEqual(result["error"]["code"], "draft_present")
        self.assertFalse(any(c["command"] in {"type_text", "clear_text"} for c in fake.calls))

    def test_feishu_posted_clear_rechecks_exact_voice_hint_variant_without_replaying(self):
        class AfterClear(FeishuFake):
            def __call__(self, request):
                envelope = super().__call__(request)
                if request["command"] == "clear_text" and envelope["ok"]:
                    self.empty_prefix = VOICE_HINT
                    return {"ok": False, "error": {"code": "postcondition_failed", "message": "Clear events posted but expected empty differs",
                                                     "details": {"events_posted": 4, "clear_state_uncertain": True,
                                                                 "completed_steps": ["select_all_events_posted", "backspace_events_posted"]}}}
                return envelope
        fake = AfterClear()
        fake.title, fake.draft = "公司·主管工作群", "仅此草稿"
        result = self.assert_ok(self.run_chat(fake, "clear", expected_draft="仅此草稿"))
        self.assertEqual(result["verification_source"], "fresh_AX_exact_known_empty_serialization")
        self.assertEqual(result["empty_value"], VOICE_HINT + "发送给 公司·主管工作群\n" + STRUCTURE)
        self.assertEqual(len([c for c in fake.calls if c["command"] == "clear_text"]), 1)
        self.assertEqual(len([c for c in fake.calls if c["command"] == "inspect"]), 2)
        self.assertFalse(any(c["command"] in {"key", "type_text"} for c in fake.calls))
        self.assertEqual(fake.draft, "")

    def test_feishu_unknown_postclear_prefix_remains_unverified(self):
        class UnknownHint(FeishuFake):
            def __call__(self, request):
                envelope = super().__call__(request)
                if request["command"] == "clear_text" and envelope["ok"]:
                    self.empty_prefix = "按住 \nFN \n说话\n"
                return envelope
        fake = UnknownHint()
        fake.draft = "仅此草稿"
        result = self.run_chat(fake, "clear", expected_draft="仅此草稿")
        self.assertEqual(result["error"]["code"], "clear_unverified")
        self.assertEqual(len([c for c in fake.calls if c["command"] == "clear_text"]), 1)

    def test_feishu_webarea_history_covers_full_body_and_scrolls_without_click(self):
        fake = FeishuFake()
        fake.history_web_area = True
        fake.composer_width = 250
        read = self.assert_ok(self.run_chat(fake, "read"))
        self.assertIn("右侧可见文本", read["visible_text"])
        self.assertNotIn("已裁剪", read["visible_text"])
        fake.calls.clear()
        result = self.assert_ok(self.run_chat(fake, "history", pages=3))
        self.assertEqual(result["pages_read"], 3)
        scrolls = [c for c in fake.calls if c["command"] == "scroll"]
        self.assertEqual(len(scrolls), 2)
        self.assertFalse(any(c["command"] in {"click", "key"} for c in fake.calls))
        for scroll in scrolls:
            self.assertTrue(620 < scroll["x"] < 1180)
            self.assertLess(scroll["y"], 788)
            self.assertEqual(scroll["delta_y"], 4)

    def test_changed_history_pages_without_overlap_report_possible_gaps(self):
        for fake in [WeChatFake(), FeishuFake()]:
            fake.pages = [["当前页面"], ["更早页面"], ["之前页面"]]
            result = self.assert_ok(self.run_chat(fake, "history", pages=3))
            self.assertEqual(result["pages_read"], 3)
            self.assertEqual(result["page_overlap_rows"], [0, 0])
            self.assertFalse(result["coverage_contiguous"])
            self.assertTrue(result["gaps_possible"])
            self.assertFalse(result["complete_history"])

    def test_feishu_nonempty_draft_header_uses_chat_top_left_band(self):
        fake = FeishuFake()
        fake.history_web_area = True
        fake.draft = "已有草稿"
        read = self.assert_ok(self.run_chat(fake, "read"))
        self.assertEqual(read["chat_title"], "测试个人")
        self.assertNotIn("智能体", read["visible_text"])
        self.assertNotIn("已裁剪", read["visible_text"])
        self.assert_ok(self.run_chat(fake, "clear", expected_draft="已有草稿"))
        self.assertEqual(fake.draft, "")

    def test_feishu_header_counts_do_not_hide_group_or_numeric_nickname(self):
        for title in ["公司·主管工作群", "12345"]:
            fake = FeishuFake()
            fake.history_web_area = fake.header_counts = True
            fake.title = title
            fake.draft = "已有草稿"
            result = self.assert_ok(self.run_chat(fake, "read"))
            self.assertEqual(result["chat_title"], title)
            self.assert_ok(self.run_chat(fake, "clear", expected_draft="已有草稿"))

    def test_feishu_nested_counter_buttons_are_not_header_names(self):
        fake = FeishuFake()
        fake.history_web_area = fake.header_counts = True
        fake.title = "公司·主管工作群"
        fake.draft = "已有草稿"
        def native_shape(request):
            envelope = fake(request)
            if request["command"] == "inspect":
                rows = envelope["result"]["elements"]
                for row in list(rows):
                    if row.get("element_id") in {"member-count", "robot-count"}:
                        parent = row["element_id"] + "-button"
                        row["parent_id"] = parent
                        rows.append(ax(parent, "AXButton", row["position"]["x"] - 10, 180, 30, 24, actions=["AXPress"]))
            return envelope
        result = execute_chat({"app": FEISHU, "action": "clear", "expected_draft": "已有草稿"}, native_shape, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["result"]["chat_title"], "公司·主管工作群")

    def test_wechat_scroll_sender_is_body_text_not_a_second_header(self):
        fake = WeChatFake()
        fake.scrolled_header_sender = True
        result = self.assert_ok(self.run_chat(fake, "history", pages=3))
        self.assertEqual(result["pages_read"], 3)
        self.assertEqual(result["chat_title"], "测试群")
        self.assertIn("上卷后的消息发送者", result["visible_text"])

    def test_feishu_same_name_group_kind_uses_actual_result_subtitle(self):
        fake = FeishuFake()
        fake.ambiguous = True
        fake.group_result_index = 2
        result = self.assert_ok(self.run_chat(fake, "locate", chat="同名会话", chat_kind="group"))
        self.assertTrue(result["chat_kind_verified"])
        self.assertEqual(result["chat_kind_evidence"]["source"], "AX_search_result_subtitle")
        selected = next(c for c in fake.calls if c["command"] == "click" and c.get("element_id", "").startswith("result-"))
        self.assertEqual(selected["element_id"], "result-2")

    def test_feishu_truncated_tree_and_link_coverage_scroll_without_click(self):
        fake = FeishuFake()
        fake.history_web_area = True
        fake.history_blocked = True
        fake.ax_truncated = True
        result = self.assert_ok(self.run_chat(fake, "history", pages=3))
        self.assertEqual(result["pages_read"], 3)
        self.assertTrue(result["source_truncated"])
        self.assertFalse(any(c["command"] in {"click", "key"} for c in fake.calls))

    def test_feishu_history_dialog_stops_before_scroll(self):
        fake = FeishuFake()
        fake.history_web_area = True
        fake.history_dialog = True
        result = self.run_chat(fake, "history", pages=3)
        self.assertEqual(result["error"]["code"], "pending_dialog")
        self.assertFalse(any(c["command"] in {"scroll", "click", "key"} for c in fake.calls))

    def test_history_recipe_requires_a_changed_visible_page(self):
        with tempfile.TemporaryDirectory() as directory:
            store = RecipeStore(Path(directory) / "recipes.json")
            fake = FeishuFake()
            fake.pages = [["同一页面"]]
            result = execute_chat({"app": FEISHU, "action": "history", "pages": 3}, fake, recipe_store=store)
            self.assertTrue(result["ok"], result)
            row = store.list()["recipes"][0]
            self.assertEqual(row["successes"], 1)
            self.assertEqual(row["verified_successes"], 0)
            self.assertFalse(row["reusable"])
            fake.pages = [["当前页"], ["之前页"]]
            fake.page = 0
            result = execute_chat({"app": FEISHU, "action": "history", "pages": 3}, fake, recipe_store=store)
            self.assertTrue(result["ok"], result)
            self.assertGreater(result["result"]["pages_read"], 1)
            row = store.list()["recipes"][0]
            self.assertEqual(row["verified_successes"], 1)
            self.assertTrue(row["reusable"])

    def test_feishu_exact_search_result_and_ambiguity_rejection(self):
        fake = FeishuFake()
        self.assert_ok(self.run_chat(fake, "locate", chat="目标个人"))
        self.assertEqual(fake.title, "目标个人")
        other = FeishuFake()
        other.ambiguous = True
        result = self.run_chat(other, "locate", chat="目标个人")
        self.assertEqual(result["error"]["code"], "ambiguous_target")
        self.assertFalse(any(c.get("element_id", "").startswith("result-") and c["command"] == "click" for c in other.calls))

    def test_feishu_structured_search_uses_result_title_and_excludes_description_and_message_references(self):
        session = ChatSession({"app": FEISHU, "action": "locate", "chat": "指定助理"}, lambda _: None)
        session.frame = bounds(271, 112, 1316, 750)
        press = ["AXPress", "AXShowMenu", "AXScrollToVisible"]
        rows = [ax("list", "AXGroup", 410, 279, 1018, 500),
                ax("direct", "AXGroup", 436, 301, 986, 64, parent_id="list", actions=press),
                ax("name-group", "AXGroup", 494, 309, 104, 24, parent_id="direct", actions=press),
                ax("name", "AXStaticText", 494, 313, 104, 16, parent_id="name-group", value="指定助理"),
                ax("description-group", "AXGroup", 494, 335, 916, 18, parent_id="direct", actions=press),
                ax("description", "AXStaticText", 494, 336, 590, 16, parent_id="description-group", value="助理的实际描述"),
                ax("alternate", "AXGroup", 436, 365, 986, 64, parent_id="list", actions=press),
                ax("alternate-name-group", "AXGroup", 494, 373, 131, 24, parent_id="alternate", actions=press),
                ax("alternate-name", "AXStaticText", 494, 377, 131, 16, parent_id="alternate-name-group", value="另一个入口"),
                ax("alternate-description-group", "AXGroup", 494, 399, 916, 18, parent_id="alternate", actions=press),
                ax("description-prefix", "AXStaticText", 494, 400, 393, 16, parent_id="alternate-description-group", value="描述内部引用"),
                ax("inline-reference", "AXStaticText", 887, 400, 103, 16, parent_id="alternate-description-group", value="指定助理"),
                ax("message-section", "AXGroup", 430, 451, 998, 22, parent_id="list"),
                ax("message-heading", "AXStaticText", 430, 454, 28, 16, parent_id="message-section", value="消息"),
                ax("message-result", "AXGroup", 430, 481, 998, 66, parent_id="list", actions=press),
                ax("message-name-group", "AXGroup", 486, 491, 97, 20, parent_id="message-result", actions=press),
                ax("message-name", "AXStaticText", 486, 494, 89, 14, parent_id="message-name-group", value="指定助理"),
                ax("message-preview", "AXGroup", 486, 515, 930, 22, parent_id="message-result"),
                ax("preview-name", "AXStaticText", 634, 518, 104, 16, parent_id="message-preview", value="指定助理"),
                {"element_id": "hidden-name", "role": "AXStaticText", "parent_id": "message-preview", "value": "指定助理"}]
        tree = {"elements": rows}
        selected = session.feishu_search_names(tree, "指定助理")
        self.assertEqual([r["element_id"] for r in selected], ["name"])
        self.assertIsNone(session.feishu_result_kind(tree, selected[0]))
        # Two actual result titles still stay ambiguous, even when one is a bot.
        next(r for r in rows if r["element_id"] == "alternate-name")["value"] = "指定助理"
        self.assertEqual([r["element_id"] for r in session.feishu_search_names(tree, "指定助理")], ["name", "alternate-name"])

    def test_feishu_contacts_tab_restores_messages_by_current_ax_id(self):
        fake = FeishuFake()
        fake.tab = "contacts"
        fake.message_radio_id = "fresh-generation-42"
        result = self.assert_ok(self.run_chat(fake, "read"))
        self.assertEqual(result["visible_text"], "新消息\n最后回复")
        self.assertEqual(fake.tab, "messages")
        pressed = [c for c in fake.calls if c["command"] == "press"]
        self.assertEqual([c["element_id"] for c in pressed], ["fresh-generation-42"])
        self.assertFalse(any(c["command"] in {"type_text", "clear_text", "key"} for c in fake.calls))

    def test_feishu_message_navigation_ambiguity_stops_without_press(self):
        fake = FeishuFake()
        fake.tab = "contacts"
        fake.duplicate_message_radio = True
        result = self.run_chat(fake, "read")
        self.assertEqual(result["error"]["code"], "ambiguous_target")
        self.assertFalse(any(c["command"] == "press" for c in fake.calls))

    def test_feishu_fullwidth_shortcut_search_button_is_native_press(self):
        fake = FeishuFake()
        fake.search_button_description = "搜索（⌘＋K）"
        self.assert_ok(self.run_chat(fake, "locate", chat="目标个人"))
        self.assertTrue(any(c["command"] == "press" and c["element_id"] == "search-button" for c in fake.calls))

    def test_feishu_async_search_window_waits_without_press_replay(self):
        fake = FeishuFake()
        fake.modal_delay_reads = 2
        fake.search_input_role = "AXTextArea"
        self.assert_ok(self.run_chat(fake, "locate", chat="公司·主管工作群"))
        self.assertEqual(len([c for c in fake.calls if c["command"] == "press" and c["element_id"] == "search-button"]), 1)


    def test_feishu_missing_or_out_of_scope_modal_input_stops_at_three_seconds(self):
        for outside in (False, True):
            with self.subTest(outside=outside):
                fake = FeishuFake()
                fake.modal = True
                clock = [0.0]
                def callback(request):
                    envelope = fake(request)
                    if request["command"] == "inspect":
                        tree = envelope["result"]
                        if outside:
                            for row in tree["elements"]:
                                if row.get("element_id") == "search-field":
                                    row["position"]["y"] = 620
                        else:
                            tree["elements"] = [r for r in tree["elements"] if r.get("element_id") != "search-field"]
                    return envelope
                with patch("chat_workflows.time.monotonic", side_effect=lambda: clock[0]), patch("chat_workflows.time.sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
                    result = execute_chat({"app": FEISHU, "action": "locate", "chat": "指定员工"}, callback, recipe_store=False)
                self.assertEqual(result["error"]["code"], "target_not_found")
                self.assertEqual(result["error"]["details"]["matching_count"], 0)
                self.assertAlmostEqual(clock[0], 3.0)
                self.assertLessEqual(len([c for c in fake.calls if c["command"] == "inspect"]), 28)
                self.assertFalse(any(c["command"] in {"batch", "click", "press", "type_text", "clear_text", "key", "submit_text"} for c in fake.calls))

    def test_feishu_ambiguous_modal_inputs_stop_without_settle_or_mutation(self):
        fake = FeishuFake()
        fake.modal = True
        def callback(request):
            envelope = fake(request)
            if request["command"] == "inspect":
                field = next(r for r in envelope["result"]["elements"] if r.get("element_id") == "search-field")
                other = copy.deepcopy(field)
                other["element_id"] = "other-focused-field"
                envelope["result"]["elements"].append(other)
            return envelope
        with patch("chat_workflows.time.sleep") as sleep:
            result = execute_chat({"app": FEISHU, "action": "locate", "chat": "指定员工"}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "ambiguous_target")
        sleep.assert_not_called()
        self.assertFalse(any(c["command"] in {"batch", "click", "press", "type_text", "clear_text", "key", "submit_text"} for c in fake.calls))

    def test_feishu_input_settle_checks_focus_and_geometry_before_typing(self):
        for changed in ("focus", "geometry"):
            with self.subTest(changed=changed):
                fake = FeishuFake()
                fake.modal = True
                waiting = False
                def callback(request):
                    nonlocal waiting
                    envelope = fake(request)
                    if request["command"] == "inspect" and request.get("window_title") == SEARCH_MODAL:
                        if waiting and changed == "geometry":
                            envelope["result"]["windows"][0]["position"]["x"] += 1
                        envelope["result"]["elements"] = [r for r in envelope["result"]["elements"] if r.get("element_id") != "search-field"]
                        waiting = True
                    elif waiting and changed == "focus" and request["command"] == "status":
                        envelope["result"]["frontmost_app_bundle_id"] = "com.example.other"
                    return envelope
                result = execute_chat({"app": FEISHU, "action": "locate", "chat": "指定员工"}, callback, recipe_store=False)
                self.assertEqual(result["error"]["code"], "foreground_mismatch" if changed == "focus" else "target_geometry_changed")
                self.assertFalse(any(c["command"] in {"batch", "click", "type_text", "clear_text", "key", "submit_text"} for c in fake.calls))

    def test_feishu_exact_focused_search_replaces_query_once_with_final_serialization(self):
        fake = FeishuFake()
        fake.modal, fake.query, fake.search_input_role = True, "旧员工名", "AXTextArea"
        self.assert_ok(self.run_chat(fake, "locate", chat="指定员工"))
        typed = [c for c in fake.calls if c["command"] == "type_text"]
        self.assertEqual(len(typed), 1)
        self.assertTrue(typed[0]["replace_search"])
        self.assertEqual(typed[0]["expected_before"], "旧员工名\u200b\n")
        self.assertEqual(typed[0]["expected_value"], "指定员工\u200b\n")
        self.assertEqual(typed[0]["element_id"], "search-field")
        self.assertFalse(any(c["command"] in {"batch", "clear_text", "key", "submit_text"} for c in fake.calls))
        self.assertEqual([c["element_id"] for c in fake.calls if c["command"] == "click"], ["result-1"])

    def test_feishu_search_replacement_partial_failure_never_replays_selection_or_type(self):
        fake = FeishuFake()
        fake.modal, fake.query, fake.search_input_role, fake.fail_on_type = True, "旧员工名", "AXTextArea", True
        result = self.run_chat(fake, "locate", chat="指定员工")
        self.assertEqual(result["error"]["code"], "postcondition_failed")
        self.assertFalse(any(c["command"] in {"batch", "key", "clear_text"} for c in fake.calls))
        self.assertEqual(len([c for c in fake.calls if c["command"] == "type_text"]), 1)
        self.assertFalse(result["automatic_replay_allowed"])
        self.assertFalse(any(c.get("element_id", "").startswith("result-") for c in fake.calls))

    def test_feishu_query_whitespace_is_replaced_as_full_serialized_content(self):
        fake = FeishuFake()
        fake.modal, fake.query, fake.search_input_role = True, "  ", "AXTextArea"
        self.assert_ok(self.run_chat(fake, "locate", chat="指定员工"))
        typed = next(c for c in fake.calls if c["command"] == "type_text")
        self.assertTrue(typed["replace_search"])
        self.assertEqual(typed["expected_before"], "  \u200b\n")
        self.assertEqual(typed["expected_value"], "指定员工\u200b\n")
        self.assertFalse(any(c["command"] in {"batch", "key", "clear_text"} for c in fake.calls))

    def test_feishu_unproven_focus_keeps_legacy_guard_and_unknown_serialization_stops(self):
        for unknown_serialization in (False, True):
            with self.subTest(unknown_serialization=unknown_serialization):
                fake = FeishuFake()
                fake.modal, fake.query, fake.search_input_role = True, "旧员工名", "AXTextArea"
                raw = "旧员工名\u200b\n\u200b\n" if unknown_serialization else "旧员工名\u200b\n"
                def callback(request):
                    envelope = fake(request)
                    if request["command"] == "inspect":
                        for row in envelope["result"]["elements"]:
                            if row.get("element_id") == "search-field":
                                row["focused"] = unknown_serialization
                                if fake.query == "旧员工名":
                                    row["value"] = raw
                    return envelope
                result = execute_chat({"app": FEISHU, "action": "locate", "chat": "指定员工"}, callback, recipe_store=False)
                self.assertFalse(any(c.get("replace_search") for c in fake.calls))
                if unknown_serialization:
                    self.assertEqual(result["error"]["code"], "search_serialization_unverified")
                    self.assertFalse(any(c["command"] in {"batch", "click", "type_text", "clear_text", "key"} for c in fake.calls))
                else:
                    batch = next(c for c in fake.calls if c["command"] == "batch")
                    cleared = next(a for a in batch["actions"] if a["command"] == "clear_text")
                    self.assertEqual(cleared["expected_value"], raw)
                    self.assert_ok(result)


    def test_feishu_hint_arrives_before_readonly_preflight_binds_latest_complete_value(self):
        fake = FeishuFake()
        fake.modal, fake.query, fake.search_input_role = True, "旧员工名", "AXTextArea"
        first_modal_read = True
        def callback(request):
            nonlocal first_modal_read
            envelope = fake(request)
            if request["command"] == "inspect" and request.get("window_title") == SEARCH_MODAL and first_modal_read:
                first_modal_read = False
                fake.search_hint = True
            return envelope
        result = self.assert_ok(execute_chat({"app": FEISHU, "action": "locate", "chat": "指定员工"}, callback, recipe_store=False))
        self.assertEqual(result["chat_title"], "指定员工")
        typed = [c for c in fake.calls if c["command"] == "type_text"]
        self.assertEqual(len(typed), 1)
        self.assertEqual(typed[0]["expected_before"], "旧员工名\u200b\n\n回车查看答案")
        self.assertEqual(typed[0]["expected_value"], "指定员工\u200b\n")
        self.assertFalse(any(c["command"] in {"batch", "key", "clear_text"} for c in fake.calls))

    def test_feishu_hint_arrives_after_empty_query_input_and_full_query_remains_ready(self):
        fake = FeishuFake()
        fake.modal, fake.search_input_role = True, "AXTextArea"
        def callback(request):
            envelope = fake(request)
            if request["command"] == "type_text":
                fake.search_hint = True
            return envelope
        self.assert_ok(execute_chat({"app": FEISHU, "action": "locate", "chat": "指定员工"}, callback, recipe_store=False))
        typed = next(c for c in fake.calls if c["command"] == "type_text")
        self.assertTrue(typed["replace_search"])
        self.assertEqual(typed["expected_before"], "\u200b\n")
        self.assertEqual(typed["expected_value"], "指定员工\u200b\n")
        self.assertFalse(any(c["command"] in {"batch", "key", "clear_text"} for c in fake.calls))

    def test_feishu_known_hint_query_equal_wanted_is_not_retyped_and_literal_hint_name_is_retained(self):
        for query in ("指定员工", "回车查看答案"):
            with self.subTest(query=query):
                fake = FeishuFake()
                fake.modal, fake.query, fake.search_input_role, fake.search_hint = True, query, "AXTextArea", True
                result = self.assert_ok(self.run_chat(fake, "locate", chat=query))
                self.assertEqual(result["chat_title"], query)
                self.assertFalse(any(c["command"] in {"batch", "type_text", "clear_text", "key"} for c in fake.calls))

    def test_feishu_result_readiness_rejects_query_hint_collision_or_ambiguous_input(self):
        fake = FeishuFake()
        fake.modal, fake.query, fake.search_input_role, fake.search_hint = True, "指定员工回车查看答案", "AXTextArea", True
        session = ChatSession({"app": FEISHU, "action": "locate"}, fake)
        session.frame = bounds(400, 100, 600, 600)
        tree = fake.tree()
        self.assertFalse(session.feishu_search_results_ready(tree, "指定员工\u200b\n"))
        fake.query = "指定员工"
        tree = fake.tree()
        self.assertTrue(session.feishu_search_results_ready(tree, "指定员工\u200b\n"))
        duplicate = copy.deepcopy(next(r for r in tree["elements"] if r.get("element_id") == "search-field"))
        duplicate["element_id"] = "second-focused-input"
        tree["elements"].append(duplicate)
        with self.assertRaises(Stopped) as caught:
            session.feishu_search_results_ready(tree, "指定员工\u200b\n")
        self.assertEqual(caught.exception.code, "ambiguous_target")

    def test_feishu_hint_change_after_preflight_stops_with_zero_events_without_input_replay(self):
        fake = FeishuFake()
        fake.modal, fake.query, fake.search_input_role = True, "旧员工名", "AXTextArea"
        modal_reads = 0
        def callback(request):
            nonlocal modal_reads
            envelope = fake(request)
            if request["command"] == "inspect" and request.get("window_title") == SEARCH_MODAL:
                modal_reads += 1
                if modal_reads == 2:
                    fake.search_hint = True
            return envelope
        result = execute_chat({"app": FEISHU, "action": "locate", "chat": "指定员工"}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "precondition_failed")
        self.assertEqual(result["error"]["details"]["events_posted"], 0)
        self.assertEqual(fake.query, "旧员工名")
        self.assertEqual(len([c for c in fake.calls if c["command"] == "type_text"]), 1)
        self.assertFalse(any(c["command"] in {"batch", "click", "key", "clear_text"} for c in fake.calls))
        self.assertFalse(result["automatic_replay_allowed"])

    def test_feishu_malformed_enter_hint_stops_before_any_query_mutation(self):
        fake = FeishuFake()
        fake.modal, fake.query, fake.search_input_role = True, "旧员工名", "AXTextArea"
        def callback(request):
            envelope = fake(request)
            if request["command"] == "inspect":
                for row in envelope["result"]["elements"]:
                    if row.get("element_id") == "search-field":
                        row["value"] += "\n回车查看答案\n额外行"
            return envelope
        result = execute_chat({"app": FEISHU, "action": "locate", "chat": "指定员工"}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "search_serialization_unverified")
        self.assertFalse(any(c["command"] in {"batch", "click", "type_text", "clear_text", "key"} for c in fake.calls))

    def test_feishu_open_search_preserves_existing_main_chat_draft(self):
        fake = FeishuFake()
        fake.modal, fake.draft = True, "保留原草稿"
        result = self.run_chat(fake, "locate", chat="指定员工")
        self.assertEqual(result["error"]["code"], "draft_present")
        self.assertEqual(fake.draft, "保留原草稿")
        self.assertFalse(any(c["command"] in {"batch", "focus", "click", "type_text", "clear_text", "key", "submit_text"} for c in fake.calls))

    def test_feishu_search_waits_for_results_not_old_history_and_header(self):
        fake = FeishuFake()
        fake.results_delay_reads = 2
        fake.header_delay_reads = 2
        self.assert_ok(self.run_chat(fake, "locate", chat="公司·主管工作群"))
        self.assertEqual(len([c for c in fake.calls if c["command"] == "type_text"]), 1)
        clicks = [c for c in fake.calls if c["command"] == "click" and c.get("element_id", "").startswith("result-")]
        self.assertEqual(len(clicks), 1)
        self.assertEqual(clicks[0]["element_id"], "result-1")
        self.assertEqual(fake.title, "公司·主管工作群")

    def test_feishu_existing_known_search_modal_is_reused_for_locate(self):
        fake = FeishuFake()
        fake.modal = True
        fake.search_input_role = "AXTextArea"
        self.assert_ok(self.run_chat(fake, "locate", chat="公司·主管工作群"))
        self.assertFalse(any(c["command"] == "press" for c in fake.calls))
        self.assertEqual(next(c for c in fake.calls if c["command"] == "focus")["window_title"], SEARCH_MODAL)

    def test_feishu_existing_exact_search_query_is_not_retyped(self):
        fake = FeishuFake()
        fake.modal = True
        fake.query = "公司·主管工作群"
        self.assert_ok(self.run_chat(fake, "locate", chat="公司·主管工作群"))
        self.assertFalse(any(c["command"] in {"press", "type_text", "clear_text"} for c in fake.calls))

    def test_feishu_read_closes_only_known_search_modal_and_restores_main(self):
        fake = FeishuFake()
        fake.modal = True
        result = self.assert_ok(self.run_chat(fake, "read"))
        self.assertEqual(result["visible_text"], "新消息\n最后回复")
        self.assertEqual([c["key"] for c in fake.calls if c["command"] == "key"], ["escape"])
        self.assertEqual([c["window_title"] for c in fake.calls if c["command"] == "focus" and not c.get("restore_previous")], [SEARCH_MODAL])
        self.assertTrue(fake.calls[-1].get("restore_previous"))
        self.assertTrue(fake.calls[-1].get("restore_previous"))

    def test_recipe_autorecord_has_no_chat_or_native_content(self):
        with tempfile.TemporaryDirectory() as directory:
            store = RecipeStore(Path(directory) / "recipes.json")
            fake = WeChatFake()
            fake.title = "隐私群名"
            fake.pages = [["私密回复内容"]]
            result = execute_chat({"app": WECHAT, "action": "read", "chat": "隐私群名", "reply_contains": "私密回复内容"}, fake, recipe_store=store)
            self.assertTrue(result["ok"], result)
            content = store.path.read_text()
            self.assertNotIn("隐私群名", content)
            self.assertNotIn("私密回复内容", content)
            self.assertNotIn("snapshot-", content)
            row = store.list()["recipes"][0]
            self.assertEqual(row["verified_successes"], 1)
            self.assertTrue(row["reusable"])

    def test_script_registration_never_executes_or_promotes(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "model-script.py"
            source.write_text("raise RuntimeError('must never execute')")
            store = RecipeStore(Path(directory) / "recipes.json")
            result = execute_recipe({"action": "register", "source_path": str(source), "app": WECHAT, "parameter_names": ["chat", "text"]}, store)
            self.assertTrue(result["ok"], result)
            row = result["result"]
            self.assertFalse(row["executable"])
            self.assertFalse(row["reusable"])
            self.assertEqual(row["status"], "candidate")
            self.assertNotIn("must never execute", store.path.read_text())
            self.assertTrue(execute_recipe({"action": "list"}, store)["ok"])

    def test_failed_builtin_records_only_aggregate_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            store = RecipeStore(Path(directory) / "recipes.json")
            fake = WeChatFake()
            fake.draft = "秘密草稿"
            result = execute_chat({"app": WECHAT, "action": "draft", "text": "秘密命令"}, fake, recipe_store=store)
            self.assertFalse(result["ok"])
            row = store.list()["recipes"][0]
            self.assertEqual(row["failures"], 1)
            self.assertFalse(row["reusable"])
            self.assertNotIn("秘密", store.path.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
