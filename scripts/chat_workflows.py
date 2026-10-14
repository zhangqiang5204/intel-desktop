"""Bounded native WeChat/Feishu workflows; explicit send authorization, no replay.

The callback receives a native request dict (including ``command``) and returns
the native ``{ok, result/error}`` envelope. IDs, PIDs, frames and OCR anchors are
always obtained from this invocation. No script evaluation or private chat DB.
"""
from __future__ import annotations

import math
import re
import time
import unicodedata
from collections import Counter

from recipe_store import ACTIONS, APPS, RecipeStore

WECHAT = "com.tencent.xinWeChat"
FEISHU = "com.bytedance.macos.feishu"
STRUCTURE = "\u200b\n\u200b\n\u200b"
VOICE_HINT = "按住 \nfn \n说话\n"
SEARCH_MODAL = "ModalWebViewWidget - search:search-command-bar:default"
SEARCH_STRUCTURE = "\u200b\n"
SEARCH_ENTER_HINT = "\n回车查看答案"
RECENT_SECTION_NAMES = {"联系人", "好友", "群聊", "群组", "AI助手", "公众号", "服务号", "功能", "最常使用", "搜索网络结果", "大搜索网络结果", "网络结果", "聊天记录", "搜索聊天记录"}
WECHAT_SEARCH_LOCAL = {"联系人", "好友", "群聊", "群组", "AI助手", "公众号", "服务号", "最近聊天", "功能", "最常使用"}
WECHAT_SEARCH_EXCLUDED = {"搜索网络结果", "网络结果", "聊天记录", "搜索聊天记录"}
CHAT_TOOL = {
    "name": "desktop_chat",
    "description": "Use action=observe for read-only background state and optional masked MCP images without focus/navigation. Locate a unique personal/group chat, observe visible replies/history, draft or clear exact owned text, remove an exact authorized WeChat draft prefix while preserving its suffix, or send one exact message already authorized by the current human. send_authorization asserts existing current-human authorization for this exact app/recipient/content; the tool does not grant it. Stops on changed drafts, ambiguity, errors or takeover, never replays. History is bounded visible UI text, never database history.",
    "inputSchema": {"type": "object", "properties": {
        "app": {"type": "string", "enum": sorted(APPS)},
        "action": {"type": "string", "enum": sorted(ACTIONS | {"observe"})},
        "background": {"type": "boolean", "description": "True with observe, or draft/clear in the currently selected chat: process-directed input preserves system focus and never falls back to foreground input or sends. Optional chat asserts the exact current recipient. Recipient changes stop the operation."},
        "include_image": {"type": "boolean", "description": "Only action=observe: request the same verified masked native frame as an MCP image block for the current model. Default false; unsupported routes report image unavailable."},
        "max_nodes": {"type": "integer", "minimum": 1, "maximum": 2000, "description": "Only action=observe: bounded Feishu AX nodes."},
        "max_depth": {"type": "integer", "minimum": 1, "maximum": 40, "description": "Only action=observe: bounded Feishu AX depth."},
        "max_text_rows": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Only action=observe: bounded WeChat OCR rows."},
        "background_capture": {"type": "string", "enum": ["auto", "visible_screen", "exact_window"], "description": "Only action=observe: WeChat read-only capture route."},
        "since_observation_id": {"type": "string", "minLength": 1, "maxLength": 128, "description": "Only action=observe: optional native Feishu observation baseline; no Python history is retained."},
        "chat": {"type": "string", "minLength": 1, "maxLength": 128, "description": "Exact recipient/group name; omit to use the currently selected chat."},
        "chat_kind": {"type": "string", "enum": ["any", "person", "group"], "description": "Requested kind, reported honestly as unverified when the UI exposes no kind evidence."},
        "window_title": {"type": "string", "description": "Optional exact main window title when multiple native windows exist."},
        "text": {"type": "string", "minLength": 1, "maxLength": 4096, "description": "Exact single-line draft or human-authorized message. Existing different drafts are preserved."},
        "expected_draft": {"type": "string", "maxLength": 4096, "description": "Exact visible draft owned/authorized for clearing. Changed drafts are preserved."},
        "prefix": {"type": "string", "minLength": 1, "maxLength": 64, "description": "Exact human-authorized leading text for WeChat clear_prefix; requires an explicit chat. BMP letters/numbers/punctuation only, one scalar per grapheme; whitespace/symbols/combining/joiner/control characters are unsupported. Preserves the complete remaining draft; never rewrites it."},
        "pages": {"type": "integer", "minimum": 3, "maximum": 10, "description": "History page bound, default 3; leaves the viewport at the oldest inspected page."},
        "reply_contains": {"type": "string", "minLength": 1, "maxLength": 1024, "description": "Optional text to observe in the visible message area. Presence alone does not establish sender or a new reply."},
        "baseline_text": {"type": "string", "maxLength": 16000, "description": "Prior visible_text for this same chat. Observe normalized visible changes and their text; changed visibility alone does not establish a new message or sender."},
        "previous_visible_text": {"type": "string", "maxLength": 16000, "description": "Alias of baseline_text."},
        "wait_timeout_ms": {"type": "integer", "minimum": 0, "maximum": 60000, "description": "Bounded read-only reply/change observation (read default 0), or send UI confirmation (default 5000)."},
        "send_authorization": {"type": "object", "properties": {"source": {"type": "string", "enum": ["current_user"]}, "app": {"type": "string", "enum": sorted(APPS)}, "chat": {"type": "string", "minLength": 1, "maxLength": 128}, "text": {"type": "string", "minLength": 1, "maxLength": 4096}}, "required": ["source", "app", "chat", "text"], "additionalProperties": False,
                               "description": "Caller assertion of the current human's existing exact send authorization; must match app/chat/text byte-for-byte. Never supply this for draft tests or merely inferred authority."},
    }, "required": ["app", "action"], "additionalProperties": False},
    "annotations": {"readOnlyHint": False, "destructiveHint": False, "openWorldHint": False},
}


class Stopped(Exception):
    def __init__(self, code, message, details=None):
        super().__init__(message)
        self.code, self.details = code, details or {}


def _norm(value):
    return re.sub(r"\s+", "", str(value).replace("\u200b", "").replace("\ufeff", ""))


def _ocr_line_sequence(value):
    # OCR line boundaries can move when deleting a prefix reflows the editor.
    # Preserve every other character, including spaces, rather than rewriting.
    return "".join(value.splitlines())


def _input_event_times(value, kind):
    """Optional diagnostic receipt; it never establishes input/value authority."""
    if not isinstance(value, dict) or value.get("clock") != "system_uptime_ms" or value.get("kind") != kind:
        return None
    times = tuple(value.get(key) for key in ("dispatch_started_ms", "dispatch_finished_ms", "complete_observation_ms"))
    if (any(type(t) not in {int, float} or not 0 <= t <= 10**12 or not math.isfinite(t) for t in times)
            or not times[0] <= times[1] <= times[2] or times[2] - times[0] > 60_000):
        return None
    return times


def _label_matches(label, wanted):
    actual, expected = _norm(label), _norm(wanted)
    return actual == expected or actual == expected + "AI" or re.fullmatch(re.escape(expected) + r"[（(]\d+[)）]", actual) is not None


def _wechat_search_query(wanted):
    # The observed 210pt input cannot display a full long group name. Estimate
    # at most 12 wide characters (24 half-width units), keeping normal short
    # queries unchanged and retaining common combining/emoji clusters whole.
    clusters = []
    for character in wanted:
        point = ord(character)
        mark = unicodedata.category(character).startswith("M") or 0x1F3FB <= point <= 0x1F3FF
        regional_pair = (0x1F1E6 <= point <= 0x1F1FF and clusters and len(clusters[-1]) == 1
                         and 0x1F1E6 <= ord(clusters[-1]) <= 0x1F1FF)
        if clusters and (mark or character == "\u200d" or clusters[-1].endswith("\u200d") or regional_pair):
            clusters[-1] += character
        else:
            clusters.append(character)
    query, used = [], 0
    for cluster in clusters:
        if any(unicodedata.category(character) == "So" or character in {"\ufe0f", "\u20e3"} for character in cluster):
            width = 2
        else:
            width = sum(0 if unicodedata.category(character).startswith("M") or unicodedata.category(character) == "Cf"
                        else 2 if unicodedata.east_asian_width(character) in {"W", "F"} else 1 for character in cluster)
        if used + width > 24:
            break
        query.append(cluster)
        used += width
    return "".join(query)


def _wechat_truncated_prefix(label):
    # These are actual observed ellipsis forms. A generic bullet is not one.
    match = re.fullmatch(r"(.+?)(?:\.{3}|…+|⋯+\.?)\s*", label)
    return match.group(1).rstrip() if match else None


def _wechat_truncated_result_matches(label, wanted):
    # A terminal UI ellipsis can identify a navigation probe, never a verified
    # recipient. The visible prefix must agree with the complete name and the
    # actual bounded query; the post-click header still proves the full name.
    prefix = _wechat_truncated_prefix(label)
    if prefix is None:
        return False
    prefix, expected, query = _norm(prefix), _norm(wanted), _norm(_wechat_search_query(wanted))
    return (len(prefix) < len(expected) and expected.startswith(prefix)
            and bool(query) and (prefix.startswith(query) or query.startswith(prefix)))


def _wechat_search_category(row):
    label = _norm(_text(row))
    # These complete headings include the two actual observed search icons.
    return "搜索网络结果" if label in {"大搜索网络结果", "六搜索网络结果"} else label


def _feishu_empty_name(raw):
    # This exact hint is metadata only when the complete native placeholder and
    # zero-width empty serialization follow it. User text alone is never stripped.
    for prefix in ("", VOICE_HINT):
        if raw.startswith(prefix + "发送给 "):
            name, separator, tail = raw[len(prefix) + 4:].partition("\n")
            if separator and _norm(name) and tail == STRUCTURE:
                return name
    return None


def _feishu_search_query(raw):
    # Only complete, observed serializations of the known search editor.
    # A hint appearing as part of the actual query is ordinary query text.
    if not isinstance(raw, str):
        return None
    for suffix in (SEARCH_STRUCTURE + SEARCH_ENTER_HINT, SEARCH_STRUCTURE):
        if raw.endswith(suffix):
            query = raw[:-len(suffix)]
            if not any(ord(char) < 32 or char in "\u200b\u2028\u2029" for char in query):
                return query
    return None


def _rect(row):
    value = row.get("bounds") or row.get("window_frame")
    if value is None and isinstance(row.get("position"), dict) and isinstance(row.get("size"), dict):
        value = {**row["position"], **row["size"]}
    if not isinstance(value, dict) or any(type(value.get(k)) not in (int, float) or not math.isfinite(value[k]) for k in ("x", "y", "width", "height")):
        raise Stopped("geometry_unavailable", "Current target/control geometry is unavailable")
    if value["width"] <= 0 or value["height"] <= 0:
        raise Stopped("geometry_unavailable", "Current target/control geometry is empty")
    return {k: value[k] for k in ("x", "y", "width", "height")}


def _roi(frame, x, y, width, height):
    return {"x": frame["x"] + frame["width"] * x, "y": frame["y"] + frame["height"] * y,
            "width": frame["width"] * width, "height": frame["height"] * height}


def _center(rect):
    return rect["x"] + rect["width"] / 2, rect["y"] + rect["height"] / 2


def _inside(row, region):
    try:
        x, y = _center(_rect(row))
        return region["x"] <= x <= region["x"] + region["width"] and region["y"] <= y <= region["y"] + region["height"]
    except Stopped:
        return False


def _text(row):
    for key in ("text", "value", "title", "description"):
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return ""


def _unique(rows, message):
    if len(rows) != 1:
        raise Stopped("ambiguous_target" if rows else "target_not_found", message, {"matching_count": len(rows)})
    return rows[0]


def _history_alignment(older, newer):
    """Prove one adjacent-page overlap, not global text uniqueness."""
    left, right = [_norm(_text(x)) for x in older], [_norm(_text(x)) for x in newer]
    pairs, anchors = {}, []
    for i, text in enumerate(left):
        for j, other in enumerate(right):
            if text and text == other:
                old_point, new_point = _center(_rect(older[i])), _center(_rect(newer[j]))
                if abs(old_point[0] - new_point[0]) <= 4:
                    pairs[i, j] = old_point[1] - new_point[1]
    previous, longest = [0] * (len(right) + 1), 0
    for i, text in enumerate(left):
        current = [0] * (len(right) + 1)
        for j, other in enumerate(right):
            if (i, j) in pairs:
                size = current[j + 1] = previous[j] + 1
                longest = max(longest, size)
                if size >= 2 and (i + 1, j + 1) not in pairs:
                    block = [(i - k, j - k) for k in range(size)]
                    shifts = sorted(pairs[pair] for pair in block)
                    shift = shifts[len(shifts) // 2]
                    if all(abs(delta - shift) <= 4 for delta in shifts):
                        anchors.append((shift, block))
        previous = current
    if not anchors:
        return {"verified": False, "reason": "row_geometry_not_aligned" if longest >= 2 else "no_two_row_common_block", "matching_rows": 0}
    alternatives = {}
    for shift, block in anchors:
        near = [pair for pair, delta in pairs.items() if abs(delta - shift) <= 4]
        old_counts, new_counts = {}, {}
        for i, j in near:
            old_counts[i] = old_counts.get(i, 0) + 1
            new_counts[j] = new_counts.get(j, 0) + 1
        unique = frozenset((i, j) for i, j in near if old_counts[i] == new_counts[j] == 1)
        if len(unique) >= 2 and any(pair in unique and (pair[0] + 1, pair[1] + 1) in unique for pair in block):
            alternatives[unique] = max(alternatives.get(unique, 0), len(near) - len(unique))
    if not alternatives:
        return {"verified": False, "reason": "ambiguous_row_geometry", "matching_rows": 0}
    score = max(map(len, alternatives))
    winners = [pairs for pairs in alternatives if len(pairs) == score]
    if len(winners) != 1:
        return {"verified": False, "reason": "ambiguous_common_block", "matching_rows": score}
    matched = sorted(winners[0])
    shifts = sorted(pairs[pair] for pair in matched)
    shift = shifts[len(shifts) // 2]
    if shift <= 1:
        return {"verified": False, "reason": "row_geometry_not_aligned", "matching_rows": score}
    # Several exact blocks may share this unique translation even when OCR
    # changes an intervening line or swaps near-horizontal line ordering.
    # Deduplicate only their one-to-one exact rows, retaining every unmatched row.
    old_ids, new_ids = {i for i, _ in matched}, {j for _, j in matched}
    interior = (sum(i not in old_ids for i in range(min(old_ids), max(old_ids) + 1))
                + sum(j not in new_ids for j in range(min(new_ids), max(new_ids) + 1)))
    return {"verified": True, "reason": "unique_exact_blocks_and_downward_row_translation",
            "matching_rows": score, "longest_common_block": longest,
            "row_shift_y": shift, "row_matches": [{"older_index": i, "newer_index": j} for i, j in matched],
            "older_tail_unaligned": len(left) - max(old_ids) - 1, "newer_head_unaligned": min(new_ids),
            "interior_rows_unaligned": interior, "ambiguous_row_pairs_preserved": alternatives[winners[0]]}


def _validate(request):
    allowed = set(CHAT_TOOL["inputSchema"]["properties"])
    if not isinstance(request, dict) or set(request) - allowed:
        raise Stopped("invalid_request", "Unknown chat argument")
    if request.get("app") not in APPS:
        raise Stopped("app_not_supported", "Chat adapters support only the exact WeChat and Feishu bundle IDs")
    if request.get("action") not in ACTIONS:
        raise Stopped("send_denied" if request.get("action") == "submit" else "invalid_request", "Unsupported chat action")
    if "background" in request:
        if type(request["background"]) is not bool or request["background"] is not True or request["action"] not in {"draft", "clear"}:
            raise Stopped("invalid_request", "Background edits require draft/clear in the currently selected chat")
    if set(request) & {"include_image", "max_nodes", "max_depth", "max_text_rows", "since_observation_id", "background_capture"}:
        raise Stopped("invalid_request", "Background/image observation arguments require action=observe")
    for key, limit in (("chat", 128), ("text", 4096), ("expected_draft", 4096), ("prefix", 64), ("reply_contains", 1024), ("window_title", 256), ("baseline_text", 16000), ("previous_visible_text", 16000)):
        if key in request and (not isinstance(request[key], str) or len(request[key]) > limit or (key != "expected_draft" and not request[key])):
            if key in {"baseline_text", "previous_visible_text"} and request[key] == "":
                continue
            raise Stopped("invalid_request", f"Invalid {key}")
    # expected_draft is comparison evidence for clearing existing content;
    # its line breaks are never posted as keyboard input.
    for key in ("chat", "text"):
        if key in request and any(c in request[key] for c in "\r\n\t\x00"):
            raise Stopped("send_denied", "Only single-line chat names and text are accepted")
    if request.get("chat_kind", "any") not in {"any", "person", "group"}:
        raise Stopped("invalid_request", "Invalid chat_kind")
    if "pages" in request and (type(request["pages"]) is not int or not 3 <= request["pages"] <= 10):
        raise Stopped("invalid_request", "pages must be between 3 and 10")
    if "wait_timeout_ms" in request and (type(request["wait_timeout_ms"]) is not int or not 0 <= request["wait_timeout_ms"] <= 60000):
        raise Stopped("invalid_request", "wait_timeout_ms must be between 0 and 60000")
    if request["action"] == "locate" and "chat" not in request:
        raise Stopped("invalid_request", "locate requires an exact chat name")
    if request["action"] == "draft" and "text" not in request:
        raise Stopped("invalid_request", "draft requires text")
    if request["action"] == "clear" and "expected_draft" not in request:
        raise Stopped("invalid_request", "clear requires the exact expected_draft")
    if request["action"] == "clear_prefix":
        if request["app"] != WECHAT:
            raise Stopped("app_not_supported", "clear_prefix currently supports only WeChat")
        if not request.get("chat") or not _norm(request["chat"]) or not request.get("prefix") or not _norm(request["prefix"]):
            raise Stopped("invalid_request", "clear_prefix requires an explicit exact chat and a nonempty authorized prefix")
        if any(ord(character) > 0xffff or unicodedata.category(character)[0] not in {"L", "N", "P"} for character in request["prefix"]):
            raise Stopped("invalid_request", "prefix must contain at most 64 BMP letters/numbers/punctuation without whitespace/symbols/combining/joiner/control characters")
    if request["action"] == "send":
        assertion = request.get("send_authorization")
        required = {"source": "current_user", "app": request["app"], "chat": request.get("chat"), "text": request.get("text")}
        if not request.get("chat") or not request.get("text") or not isinstance(assertion, dict) or assertion != required:
            raise Stopped("send_denied", "Sending requires existing current-human authorization matching this exact app, recipient and text")
        if not _norm(request["text"]):
            raise Stopped("send_denied", "Sending requires nonempty visible message content")
    elif "send_authorization" in request:
        raise Stopped("invalid_request", "send_authorization applies only to send")
    for key, actions in (("text", {"draft", "send"}), ("expected_draft", {"clear"}), ("prefix", {"clear_prefix"}), ("pages", {"history"})):
        if key in request and request["action"] not in actions:
            raise Stopped("invalid_request", f"{key} does not apply to this action")
    if "reply_contains" in request and request["action"] not in {"read", "send"}:
        raise Stopped("invalid_request", "reply_contains applies only to read/send")
    if any(k in request for k in ("baseline_text", "previous_visible_text")) and request["action"] != "read":
        raise Stopped("invalid_request", "Reply/baseline observation applies only to read")
    if "wait_timeout_ms" in request and request["action"] not in {"read", "send"}:
        raise Stopped("invalid_request", "wait_timeout_ms applies only to read/send")
    if "baseline_text" in request and "previous_visible_text" in request and request["baseline_text"] != request["previous_visible_text"]:
        raise Stopped("invalid_request", "The two baseline aliases differ")


def _focus_receipt(value):
    """Retain only bounded native restoration facts, never origin content."""
    result = {}
    for key in ("focus_restored_app", "window_verified", "window_unknown", "original_window_reference_unavailable", "restore_raise_attempted", "owned_navigation_focus_updated"):
        if type(value.get(key)) is bool:
            result[key] = value[key]
    for key in ("restore_scope", "previous_focus_scope"):
        if value.get(key) in ("app_only", "exact_window", "unavailable"):
            result[key] = value[key]
    raw = value.get("restore_raise_result")
    if "restore_raise_result" in value and raw is None:
        result["restore_raise_result"] = None
    elif isinstance(raw, dict) and type(raw.get("code")) is int and -(2**31) <= raw["code"] < 2**31:
        result["restore_raise_result"] = {"code": raw["code"]}
        if isinstance(raw.get("name"), str) and re.fullmatch(r"[a-z_]{1,64}", raw["name"]):
            result["restore_raise_result"]["name"] = raw["name"]
    if type(value.get("restore_verify_limit_ms")) is int and 0 <= value["restore_verify_limit_ms"] <= 5000:
        result["restore_verify_limit_ms"] = value["restore_verify_limit_ms"]
    diagnostic = value.get("owned_navigation_diagnostic")
    if "owned_navigation_diagnostic" in value and diagnostic is None:
        result["owned_navigation_diagnostic"] = None
    elif isinstance(diagnostic, dict):
        bounded = {}
        for key, allowed in {
            "candidate_reason": {"claim_unavailable", "main_AX_identity_unavailable", "main_PID_mismatch", "main_CG_identity_ambiguous_or_unavailable", "bound"},
            "adoption_reason": {"candidate_unavailable", "input_monitor_interrupted_or_unavailable", "task_identity_mismatch", "post_navigation_proof_incomplete", "verified_owned_modal_to_main"},
        }.items():
            if isinstance(diagnostic.get(key), str) and diagnostic[key] in allowed:
                bounded[key] = diagnostic[key]
        for key in ("candidate_available", "action_accepted", "claim_available", "claim_complete", "monitor_available", "interrupted",
                    "claimed_window_matches_selected", "claimed_PID_matches_selected", "claimed_topology_matches", "claim_bound_to_modal",
                    "main_matches_AXMainWindow", "modal_matches_AXFocusedWindow", "same_frame_CG_rows_truncated", "AX_main_identity_unchanged",
                    "CG_main_identity_unchanged", "modal_absent", "target_frontmost", "actual_AXMainWindow_matches", "actual_AXFocusedWindow_matches", "topology_matches"):
            if type(diagnostic.get(key)) is bool:
                bounded[key] = diagnostic[key]
        for key, low, high in (("target_pid", 1, 2**31 - 1), ("main_AX_match_count", 0, 10000), ("same_frame_CG_count", 0, 10000),
                               ("main_CG_window_id", 1, 2**32 - 1), ("current_main_CG_window_id", 1, 2**32 - 1)):
            if type(diagnostic.get(key)) is int and low <= diagnostic[key] <= high:
                bounded[key] = diagnostic[key]
        if "current_main_CG_window_id" in diagnostic and diagnostic["current_main_CG_window_id"] is None:
            bounded["current_main_CG_window_id"] = None
        for key in ("main_frame", "modal_frame"):
            frame = diagnostic.get(key)
            if key in diagnostic and frame is None:
                bounded[key] = None
            elif (isinstance(frame, dict) and all(type(frame.get(axis)) in {int, float} and abs(frame[axis]) <= 10**7 and math.isfinite(frame[axis]) for axis in ("x", "y", "width", "height"))
                  and frame["width"] > 0 and frame["height"] > 0):
                bounded[key] = {axis: frame[axis] for axis in ("x", "y", "width", "height")}
        cg_rows = diagnostic.get("same_frame_CG_rows")
        if isinstance(cg_rows, list):
            rows = []
            for row in cg_rows[:8]:
                if not isinstance(row, dict):
                    continue
                safe = {}
                for key, low, high in (("window_id", 1, 2**32 - 1), ("layer", -(2**31), 2**31 - 1)):
                    if type(row.get(key)) is int and low <= row[key] <= high:
                        safe[key] = row[key]
                if type(row.get("onscreen")) is bool:
                    safe["onscreen"] = row["onscreen"]
                if type(row.get("alpha")) in {int, float} and 0 <= row["alpha"] <= 1 and math.isfinite(row["alpha"]):
                    safe["alpha"] = row["alpha"]
                if safe:
                    rows.append(safe)
            bounded["same_frame_CG_rows"] = rows
            if len(cg_rows) > 8:
                bounded["same_frame_CG_rows_truncated"] = True
        result["owned_navigation_diagnostic"] = bounded
    return result


def _focus_claim_receipt(value):
    """Keep the first claim's bounded handoff facts, without origin identities."""
    result = {}
    for key in ("previous_focus_recorded", "handoff_notice_shown", "continuous_task_focus_claim"):
        if type(value.get(key)) is bool:
            result[key] = value[key]
    if value.get("previous_focus_scope") in {"app_only", "exact_window", "unavailable"}:
        result["previous_focus_scope"] = value["previous_focus_scope"]
    waited = value.get("handoff_wait_ms")
    if type(waited) in {int, float} and math.isfinite(waited) and 0 <= waited <= 5000:
        result["handoff_wait_ms"] = waited
    if value.get("takeover_baseline") == "before_target_activation":
        result["takeover_baseline"] = value["takeover_baseline"]
    return result


class ChatSession:
    def __init__(self, request, invoke):
        self.request, self.invoke = request, invoke
        self.app = request["app"]
        self.target = {"app": self.app}
        self.pid = None
        self.frame = None
        self.calls = []
        self.native_timings = []
        self.native_timings_count = 0
        self.mutation_attempted = False
        self.title = ""
        self.anchors = []
        self.search_anchors = []
        self.kind_evidence = None
        self.open_search_main = None
        self.submit_started = False
        self.submit_posted = False
        self.send_verified = False
        self.send_focus_reused = False
        self.edited_value = None
        self.edited_input_receipt = None
        self.focus_attempted = False
        self.focus_claim_verified = False
        self.focus_claim_receipt = {}
        self.focus_restore_requested = False
        self.details_close_attempted = False
        self.owned_feishu_search = None
        self.navigation_recovery = None
        self.clear_recovery = None

    def call(self, command, **arguments):
        restoring = command == "focus" and arguments.get("restore_previous") is True
        if command == "focus" and not restoring:
            self.focus_attempted = True
        mutating = command not in {"status", "inspect", "visual_read", "background_visual_read", "background_observe", "wait_text"}
        self.mutation_attempted |= mutating
        payload = {**({} if command == "status" else self.target), **arguments, "command": command}
        self.calls.append({"command": command})  # Never retain arguments/content.
        started = time.perf_counter()
        try:
            envelope = self.invoke(payload)
        except Exception as error:
            raise Stopped("native_transport_error", "Native completion is unknown; no automatic replay", {"exception_type": type(error).__name__, "mutation_attempted": self.mutation_attempted}) from error
        finally:
            self.native_timings_count += 1
            if len(self.native_timings) < 32:
                self.native_timings.append({"command": command, "elapsed_ms": round(max(0, (time.perf_counter() - started) * 1000), 3)})
        if not isinstance(envelope, dict) or not isinstance(envelope.get("ok"), bool):
            raise Stopped("native_protocol_error", "Native callback must return an ok/result envelope")
        if not envelope["ok"]:
            error = envelope.get("error")
            if (not isinstance(error, dict) or not isinstance(error.get("code"), str) or not error["code"]
                    or not isinstance(error.get("message"), str) or not isinstance(error.get("details", {}), dict)):
                raise Stopped("native_protocol_error", "Native error must contain a code, message and optional details object")
            details = dict(error.get("details", {}))
            # Derive cleanup eligibility from this invocation's executed
            # prefix, never from flags supplied by an error. Search replacement
            # may leave a partial query, but cannot edit or submit a composer.
            # Native still owns task/origin/focus/takeover restoration guards.
            details.pop("navigation_only", None)
            details.pop("safe_origin_restore", None)
            def safe_action(action):
                if not isinstance(action, dict):
                    return False
                name, kind = action.get("command"), action.get("control_kind")
                return (name == "visual_read" or name == "visual_click" and kind in ("search", "navigation")
                        or name == "visual_type_text" and kind == "search" and action.get("replace_search") is True)
            navigation_only = command == "visual_read" or command == "visual_click" and arguments.get("control_kind") in ("search", "navigation")
            safe_origin_restore = False
            if command == "batch":
                index = details.get("failed_index")
                actions = arguments.get("actions", [])
                safe_origin_restore = (isinstance(actions, list) and type(index) is int and 0 <= index < len(actions)
                                       and all(safe_action(a) for a in actions[:index + 1]))
                navigation_only = safe_origin_restore and all(a["command"] != "visual_type_text" for a in actions[:index + 1])
            if error["code"] in {"native_transport_error", "native_protocol_error", "operation_completion_unknown",
                                  "user_interrupted", "foreground_mismatch", "foreground_unverified", "target_changed",
                                  "target_geometry_changed", "draft_changed"}:
                navigation_only = safe_origin_restore = False
            if navigation_only:
                details["navigation_only"] = True
            if safe_origin_restore:
                details["safe_origin_restore"] = True
            raise Stopped(error["code"], error["message"], details)
        value = envelope.get("result")
        if not isinstance(value, dict):
            raise Stopped("native_protocol_error", "Native result must be an object")
        actual = value.get("target_pid")
        if actual is not None and not restoring:
            if self.pid is not None and actual != self.pid:
                raise Stopped("target_changed", "The running application's PID changed; no further actions")
            self.pid = actual
        if command == "focus" and not restoring and value.get("foreground_verified") is True:
            if not self.focus_claim_verified:
                self.focus_claim_receipt = _focus_claim_receipt(value)
            self.focus_claim_verified = True
        return value

    def finish_focus(self, error=None):
        if not self.focus_attempted:
            return {}
        # Uncertain business input never authorizes replay or cleanup. It also
        # need not strand a Feishu foreground claim (including a lost claim
        # receipt): the native owner alone decides whether the saved origin is
        # still safe to restore.
        guarded_feishu_return = self.app == FEISHU
        details = error.details if error and isinstance(error.details, dict) else {}
        clear_stop = self.clear_recovery.get("stop_code") if self.clear_recovery else None
        if error and clear_stop in {"user_interrupted", "foreground_mismatch", "foreground_unverified", "target_changed", "target_geometry_changed"}:
            return {"focus_restored": False, "focus_restore_attempted": False, "restore_reason": clear_stop}
        if error and self.clear_recovery is not None and self.clear_recovery.get("verified") is not True and not guarded_feishu_return:
            return {"focus_restored": False, "focus_restore_attempted": False,
                    "restore_reason": self.clear_recovery.get("stop_code", "clear_outcome_unverified")}
        recovery_stop = details.get("navigation_recovery_stop_code")
        if error and recovery_stop in {"user_interrupted", "foreground_mismatch", "foreground_unverified", "target_changed", "target_geometry_changed",
                                       "navigation_identity_unverified", "navigation_focus_unverified"}:
            return {"focus_restored": False, "focus_restore_attempted": False, "restore_reason": recovery_stop}
        if error and (error.code in {"user_interrupted", "foreground_mismatch", "foreground_unverified", "target_changed", "target_geometry_changed"}
                      or error.code == "draft_changed" and not guarded_feishu_return
                      or error.code == "visual_target_changed" and details.get("navigation_only") is not True and details.get("safe_origin_restore") is not True):
            return {"focus_restored": False, "focus_restore_attempted": False, "restore_reason": error.code}
        unknown = {"native_transport_error", "native_protocol_error", "operation_completion_unknown", "send_state_unknown", "draft_unverified", "clear_unverified", "prefix_clear_unverified"}
        safe_restore = details.get("navigation_only") is True or details.get("safe_origin_restore") is True or (details.get("delete_events_posted") == 0 and error and error.code in {"prefix_caret_unverified", "prefix_grapheme_boundary_unverified"})
        if error and not guarded_feishu_return and (error.code in unknown or details.get("input_may_be_partial") is True and not safe_restore):
            return {"focus_restored": False, "focus_restore_attempted": False, "restore_reason": "unknown_input_outcome"}
        cleanup = {}
        if error and error.code in {"target_not_found", "ambiguous_target"} and self.owned_feishu_search:
            cleanup = self.feishu_close_owned_search()
            if cleanup.get("owned_search_modal_closed") is not True:
                return {"focus_restored": False, "focus_restore_attempted": False,
                        "restore_reason": "owned_search_cleanup_unverified", **cleanup}
        try:
            self.focus_restore_requested = True
            restored = self.call("focus", restore_previous=True)
        except Stopped as failure:
            # A focus restoration cannot invalidate already verified business
            # evidence or justify replaying typing/deletion/submission.
            attempted = failure.details.get("focus_restore_attempted")
            if type(attempted) is not bool:
                attempted = None if self.app == FEISHU else True
            return {"focus_restored": False, "focus_restore_requested": True, "focus_restore_attempted": attempted,
                    "restore_reason": failure.code, **_focus_receipt(failure.details), **cleanup}
        verified = restored.get("focus_restored") is True
        reason = restored.get("restore_reason")
        return {"focus_restored": verified, "focus_restore_requested": True, "focus_restore_attempted": restored.get("focus_restore_attempted") is True,
                "restore_reason": reason[:256] if isinstance(reason, str) else "restored" if verified else "restore_unverified", **_focus_receipt(restored), **cleanup}

    def status(self, strict=False, ignore_prior_interruption=False):
        state = self.call("status")
        if state.get("interrupted") and not (ignore_prior_interruption and not strict):
            raise Stopped("user_interrupted", "External input/takeover was reported; no focus recovery or replay", {"reason": state["interrupted"]})
        if strict and (state.get("frontmost_app_bundle_id") != self.app or state.get("frontmost_pid") != self.pid):
            raise Stopped("foreground_mismatch", "The chat application lost foreground focus; no focus recovery or replay")
        return state

    def inspect(self, all_windows=False):
        args = {"max_depth": 40, "max_nodes": 2000, "include_menus": self.app == FEISHU}
        if all_windows:
            args["window_title"] = None
        # Omit None rather than invoking a wrapper with an invalid title.
        if all_windows:
            saved = self.target
            self.target = {"app": self.app}
            try:
                tree = self.call("inspect", **{k: v for k, v in args.items() if v is not None})
            finally:
                self.target = saved
        else:
            tree = self.call("inspect", **args)
        if not isinstance(tree.get("elements"), list) or not isinstance(tree.get("windows"), list):
            raise Stopped("native_protocol_error", "AX inspection lacks windows/elements")
        return tree

    def start(self):
        # The current user allows one active focus claim. A historical activity
        # report cannot block that claim; every post-focus status remains strict.
        self.status(ignore_prior_interruption=True)
        tree = self.inspect(all_windows=True)
        wanted = self.request.get("window_title", "微信" if self.app == WECHAT else "飞书")
        windows = [w for w in tree["windows"] if w.get("title") == wanted]
        if self.app == WECHAT and len(windows) > 1:
            # A same-title notification is not the chat main window. Trust only
            # native AXMainWindow identity plus its verified CG layer-0 binding;
            # this selects a target, never establishes actual keyboard focus.
            actual_main = [w for w in windows if w.get("is_actual_main_window") is True
                           and type(w.get("actual_main_window_id")) is int and w["actual_main_window_id"] > 0]
            if len(actual_main) == 1:
                windows = actual_main
        main = _unique(windows, "Expected one exact native main window")
        self.target["window_title"] = main["title"]
        self.frame = _rect(main)
        if self.app == WECHAT:
            self.wechat_regions()  # Reject out-of-window control ROIs before focus/input.
        if self.app == FEISHU:
            modals = [w for w in tree["windows"] if w.get("title") == SEARCH_MODAL]
            if modals:
                modal = _unique(modals, "The known Feishu search window is ambiguous")
                main_target, main_frame = dict(self.target), dict(self.frame)
                if self.request["action"] == "locate" and self.feishu_composer_candidates(tree) and self.feishu_draft(tree):
                    raise Stopped("draft_present", "The current chat has a draft; search navigation stopped to preserve it")
                self.target["window_title"], self.frame = modal["title"], _rect(modal)
                focused = self.call("focus")
                if focused.get("foreground_verified") is not True:
                    raise Stopped("foreground_unverified", "Known search-window focus was not verified")
                self.status(strict=True)
                if self.request["action"] == "locate":
                    self.open_search_main = (main_target, main_frame)
                    return self.inspect()
                self.call("key", key="escape")
                tree, _ = self.feishu_wait_search_modal(opened=False)
                self.target, self.frame = main_target, main_frame
                # Escape returned our modal to its verified main window. A new
                # focus claim here can overwrite the external origin with
                # Feishu itself. Continue this atomic stage via fresh reads;
                # native finalization adopts only its exact owned navigation.
                return self.feishu_message_pane(self.feishu_read())
        result = self.call("focus")
        if result.get("foreground_verified") is not True:
            raise Stopped("foreground_unverified", "Native focus was not verified")
        self.status(strict=True)
        if self.app == WECHAT:
            return self.wechat_read(allow_blank_bootstrap=bool(self.request.get("chat")))
        # Focus does not invalidate native AX IDs. For the observed simple main
        # window, reuse this invocation's initial tree after exact focus/PID
        # verification. Dialogs, tab recovery and search still inspect afresh.
        if len(tree["windows"]) == 1 and result.get("window_title") == main["title"] and self.feishu_composer_candidates(tree):
            return tree
        return self.feishu_message_pane(self.feishu_read())

    def wechat_regions(self, frame=None):
        f = frame or self.frame
        # Both observed 932pt and 855pt main windows retain a 321pt sidebar;
        # the chat title starts at +336pt in each. Horizontal window ratios
        # would admit the sidebar's + button on a narrower main window.
        def region(left, top, width, height):
            return {"x": f["x"] + left, "y": f["y"] + top, "width": width, "height": height}
        regions = {"header": region(326, 5, f["width"] - 342, min(45, f["height"] - 5)),
                   "search": region(70, f["height"] * .014, 210, f["height"] * .025),
                   "send": region(f["width"] - 120, f["height"] * .94, 110, f["height"] * .06),
                   "recent": region(56, 50, 261, f["height"] - 80),
                   # The actual search popup extends 71pt past the sidebar
                   # and nearly to the bottom, including 功能/ClawBot results.
                   "results": region(72, f["height"] * .042, 320, f["height"] * .928),
                   "body": region(326, 55, f["width"] - 342, f["height"] * .852 - 55),
                   # Include padding above the first ink: on the observed 1x
                   # screen, .862H cut through its top at y963. Keep the same
                   # .955H bottom, above the toolbar/Send, without pixel scaling.
                   "composer": region(330, f["height"] * .85, f["width"] - 360, f["height"] * .105)}
        regions["details"] = region(f["width"] - 250, 55, 250, f["height"] - 55)
        regions["details_toggle"] = region(f["width"] - 60, 8, 50, 38)
        for name, rect in regions.items():
            if (rect["width"] <= 0 or rect["height"] <= 0 or rect["x"] < f["x"] or rect["y"] < f["y"]
                    or rect["x"] + rect["width"] > f["x"] + f["width"] + 1e-6
                    or rect["y"] + rect["height"] > f["y"] + f["height"] + 1e-6):
                raise Stopped("unsupported_window_geometry", "The current WeChat window is too small for the observed native control layout", {"region": name, "window_frame": dict(f)})
        return regions

    def visual_identity(self, value):
        frame = _rect(value)
        if self.frame != frame:
            raise Stopped("target_geometry_changed", "Window geometry changed during this chat workflow")
        if not isinstance(value.get("snapshot_id"), str) or not isinstance(value.get("ocr"), list):
            raise Stopped("native_protocol_error", "Visual read lacks current snapshot/OCR")
        if value.get("content_available") is False:
            details = {"navigation_only": True}
            for key in ("content_reason", "capture_method"):
                if isinstance(value.get(key), str):
                    details[key] = value[key][:256]
            raise Stopped("wechat_content_unavailable", "Native capture returned no readable WeChat target content; no chat navigation or input is permitted", details)
        return value

    def wechat_header_rows(self, value):
        region = self.wechat_regions()["header"]
        # The title starts at +336pt in both observed window widths and the
        # 1x/2x long-group captures. Right toolbar icons start much farther
        # right (+726/+810pt); OCR text in that column is not a chat title.
        # Keep the entire left-aligned row, including every suffix character.
        return [row for row in self.wechat_control_evidence(value)
                if _inside(row, region) and self.frame["x"] + 326 <= _rect(row)["x"] <= self.frame["x"] + 360
                and _norm(_text(row)) not in {"", "AI", "搜索", "发送"}]

    def wechat_header(self, value, wanted=None):
        rows = self.wechat_header_rows(value)
        candidates = [r for r in rows if _label_matches(_text(r), wanted)] if wanted else rows
        try:
            return _text(_unique(candidates, "The exact chat title is not uniquely visible in the header" if wanted else "The current chat header is ambiguous or unavailable"))
        except Stopped as error:
            # Report this frame's header only. A sidebar name or older background
            # observation must never be substituted for the current recipient.
            # This literal status can replace the title while a reply is being
            # composed. It still fails recipient verification; only a read-only
            # wait after an independently verified send may defer this failure.
            if (wanted and error.code == "target_not_found" and len(rows) == 1
                    and _norm(_text(rows[0])) in {"对方正在输入", "对方正在输入…", "对方正在输入⋯", "对方正在输入..."}
                    and value.get("ocr_truncated") is False and self.wechat_has_send(value)):
                error.details["header_status"] = "typing"
            error.details.update(header_region=dict(self.wechat_regions()["header"]),
                header_candidates=[{"text": _text(row)[:128], "text_truncated": len(_text(row)) > 128,
                                    "bounds": dict(_rect(row))} for row in rows[:8]],
                header_candidates_truncated=len(rows)>8,
                header_present=bool(rows), snapshot_id=value.get("snapshot_id"),
                target_visible_verified=value.get("target_visible_verified") is True)
            raise

    def wechat_control_evidence(self, value):
        # Native anchor matches come from the same complete scoped OCR union,
        # even when its returned business rows are capped. Add only actual
        # identity/control observations, never omitted message-body rows.
        rows = list(value["ocr"])
        regions = self.wechat_regions()
        for match in value.get("anchor_matches", []):
            for row in match.get("matching_ocr", []):
                if any(_inside(row, regions[key]) for key in ("header", "search", "send")):
                    if not any(_text(old) == _text(row) and _rect(old) == _rect(row) for old in rows):
                        rows.append(row)
        return rows

    def wechat_read_regions(self, include_recent=False, include_details=False):
        regions = self.wechat_regions()
        # Multi-region native reads scan only these regions. Request both fresh
        # spatial anchors explicitly, ahead of potentially long message text.
        selected = [regions["header"], regions["search"], regions["send"], regions["composer"]]
        if include_details:
            selected.append(regions["details"])
            return selected  # Panel proof must not compete with body/recent rows.
        if include_recent:
            selected.append(regions["recent"])
        elif self.request["action"] in {"read", "history", "send"}:
            selected.append(regions["body"])
        return selected

    def wechat_has_send(self, value):
        region = self.wechat_regions()["send"]
        return any(_inside(row, region) and _norm(_text(row)).lower() in {"发送", "send"}
                   for row in self.wechat_control_evidence(value))

    def wechat_overlay_query(self, value):
        # Native33 identifies and composites the actual local popup, then proves
        # the complete search-text lane. Hidden background text is not evidence.
        if (type(value.get("search_overlay_window_id")) is int and value["search_overlay_window_id"] > 0
                and value.get("search_overlay_query_verified") is True
                and isinstance(value.get("search_lane_text"), str) and _norm(value["search_lane_text"])
                and _inside({"bounds": value.get("search_lane_frame")}, self.wechat_regions()["search"])):
            return value["search_lane_text"]
        return None

    def wechat_details_controls(self, value):
        panel = self.wechat_regions()["details"]
        labels = {"搜索群成员", "Q搜索群成员", "q搜索群成员", "群聊名称", "群公告", "群二维码",
                  "消息免打扰", "置顶聊天", "保存到通讯录", "查找聊天内容"}
        return [row for row in self.wechat_control_evidence(value) if _inside(row, panel)
                and panel["x"] + 8 <= _rect(row)["x"] <= panel["x"] + 45 and _norm(_text(row)) in labels]

    def wechat_details_panel(self, value):
        regions, rows = self.wechat_regions(), self.wechat_control_evidence(value)
        panel = regions["details"]
        header_rows = self.wechat_header_rows(value)
        if len(header_rows) != 1 or _rect(header_rows[0])["x"] + _rect(header_rows[0])["width"] >= panel["x"]:
            return None
        if any(_inside(row, regions["send"]) and _norm(_text(row)) in {"发送", "send"} for row in rows):
            return None
        # Actual group details have a right-side aligned control column, a
        # member-search field above its settings, and group-specific sections
        # in the middle. Body words or one composer line are insufficient.
        column = self.wechat_details_controls(value)
        settings = [row for row in column if _norm(_text(row)) in {"消息免打扰", "置顶聊天", "保存到通讯录", "查找聊天内容"}]
        group_sections = [row for row in column if _norm(_text(row)) in {"群聊名称", "群公告", "群二维码"}
                          and _rect(row)["y"] >= self.frame["y"] + 180]
        member_search = [row for row in column if _norm(_text(row)) in {"搜索群成员", "Q搜索群成员", "q搜索群成员"}
                         and self.frame["y"] + 55 <= _rect(row)["y"] <= self.frame["y"] + 180]
        verified_group = (len({_norm(_text(row)) for row in group_sections}) >= 2 and len(member_search) == 1
                          and re.fullmatch(r".+[（(]\d+[)）]", _norm(_text(header_rows[0]))) is not None)
        if len({_norm(_text(row)) for row in settings}) < 3 or max(_rect(row)["x"] for row in settings) - min(_rect(row)["x"] for row in settings) > 12:
            # A recognizable group panel with incomplete settings still hides
            # the editor, but cannot authorize the close icon.
            return {"kind": "unknown", "verified": False, "region": panel} if verified_group else None
        if verified_group:
            # Member count changes the height of the member grid. On the
            # observed 5/30/178-person panels the settings follow the actual
            # group metadata, rather than a fixed fraction of the main window.
            metadata_bottom = max(_rect(row)["y"] + _rect(row)["height"] for row in group_sections)
            following_settings = [row for row in settings if _rect(row)["y"] >= metadata_bottom]
            verified_group = len({_norm(_text(row)) for row in following_settings}) >= 3
        return {"kind": "group" if verified_group else "unknown", "verified": verified_group, "region": panel}

    def wechat_complete_composer_capture(self, value):
        # The same pure rectangle-union check used by background observations.
        from desktop_observation import _covered
        region = self.wechat_regions()["composer"]
        scanned = value.get("ocr_regions")
        if scanned is None and value.get("ocr_scope") in {"full_window", "full_window_and_top_footer_anchor_bands"}:
            scanned = [self.frame]
        return (_covered(region, value.get("captured_regions")) and _covered(region, scanned)
                and value.get("ocr_truncated") is False)

    def wechat_close_details(self, value, panel):
        if not panel["verified"]:
            raise Stopped("wechat_details_panel_unverified", "A details-like control column obscures the composer; no guessed icon input")
        if self.details_close_attempted:
            raise Stopped("wechat_details_panel_close_unverified", "The details panel remains after one close attempt; no input replay", {"navigation_only": True})
        selected_title = self.wechat_header(value)
        regions = self.wechat_regions()
        checks = [regions[key] for key in ("header", "search", "send", "composer", "details")]
        anchors = ["搜索", selected_title]
        self.status(strict=True)
        confirmed = self.visual_identity(self.call("visual_read", regions=checks, anchor_texts=anchors,
                                                  confirm_target=True, anchor_wait_timeout_ms=0, max_text_rows=100))
        self.wechat_header(confirmed, selected_title)
        current_panel = self.wechat_details_panel(confirmed)
        if confirmed.get("target_visible_verified") is not True:
            raise Stopped("visual_target_unconfirmed", "Two current spatial anchors are required before closing details")
        if current_panel is None:
            if self.wechat_details_controls(confirmed) or not self.wechat_complete_composer_capture(confirmed):
                raise Stopped("composer_read_incomplete", "Details disappeared, but the complete composer is not readable; no icon input")
            self.anchors = anchors
            return confirmed
        if not current_panel["verified"]:
            raise Stopped("wechat_details_panel_unverified", "The confirmed details layout changed before closing; no guessed icon input")
        self.details_close_attempted = True
        self.call("visual_click", **self.visual_args(confirmed, "navigation", regions["details_toggle"]),
                  navigation_target_kind="icon", x=self.frame["x"] + self.frame["width"] - 35, y=self.frame["y"] + 27)
        deadline = time.monotonic() + 3
        while True:
            self.status(strict=True)
            fresh = self.visual_identity(self.call("visual_read", regions=checks, anchor_texts=["搜索", "发送"],
                                                  confirm_target=True, anchor_wait_timeout_ms=0, max_text_rows=100))
            headers = self.wechat_header_rows(fresh)
            if headers and not any(_label_matches(_text(row), selected_title) for row in headers):
                raise Stopped("chat_selection_changed", "The selected chat changed while closing details; no input replay", {"navigation_only": True})
            if (not self.wechat_details_controls(fresh) and fresh.get("target_visible_verified") is True
                    and self.wechat_complete_composer_capture(fresh)):
                self.wechat_header(fresh, selected_title)
                self.anchors = ["搜索", "发送"]
                return fresh
            if time.monotonic() >= deadline:
                raise Stopped("wechat_details_panel_close_unverified", "Panel disappearance and the complete current composer were not verified after one icon click", {"navigation_only": True})
            time.sleep(.12)

    def wechat_read(self, expected_title=None, allow_blank_bootstrap=False, include_recent=False):
        self.status(strict=True)
        anchors = self.anchors or ["搜索", "发送"]
        read_regions = self.wechat_read_regions(include_recent)
        value = self.call("visual_read", regions=read_regions, anchor_texts=anchors, confirm_target=True,
                          anchor_wait_timeout_ms=0, max_text_rows=100)
        self.visual_identity(value)
        details_probed = False
        if not self.wechat_has_send(value) and self.wechat_header_rows(value):
            # A normal footer proves this broad right-hand details scan is
            # unnecessary. Read it only for a missing footer, retaining a fresh
            # complete frame rather than mixing its controls with earlier rows.
            previous_headers = self.wechat_header_rows(value)
            self.status(strict=True)
            value = self.visual_identity(self.call("visual_read", regions=self.wechat_read_regions(include_recent, include_details=True),
                                                  anchor_texts=anchors, confirm_target=True, anchor_wait_timeout_ms=0, max_text_rows=100))
            details_probed = True
            if value.get("ocr_truncated"):
                raise Stopped("wechat_details_read_truncated", "Complete current details controls are unavailable; no guessed icon or draft interpretation")
            if len(previous_headers) == 1:
                self.wechat_header(value, _text(previous_headers[0]))
        panel = self.wechat_details_panel(value)
        if panel is not None:
            value = self.wechat_close_details(value, panel)
            anchors = self.anchors
        if details_probed and (include_recent or self.request["action"] in {"read", "history", "send"}):
            # The isolated probe/close proof has no business rows. Read the
            # requested current body/recent scope independently after it.
            preserved_header = self.wechat_header(value)
            self.status(strict=True)
            value = self.visual_identity(self.call("visual_read", regions=read_regions, anchor_texts=anchors,
                                                  confirm_target=True, anchor_wait_timeout_ms=0, max_text_rows=100))
            self.wechat_header(value, preserved_header)
            if panel is not None and self.wechat_details_controls(value):
                raise Stopped("wechat_details_panel_close_unverified", "Details reappeared after one close attempt; no icon replay", {"navigation_only": True})
        try:
            header = self.wechat_header(value, expected_title)
        except Stopped as error:
            if (allow_blank_bootstrap and self.request.get("chat") and error.code == "target_not_found"
                    and error.details.get("matching_count") == 0):
                return self.wechat_bootstrap_recent(value, self.request["chat"])
            raise
        # Footer evidence is independent of the returned business-row cap.
        observed = self.wechat_control_evidence(value)
        regions = self.wechat_regions()
        header_rows = [r for r in self.wechat_header_rows(value) if _text(r) == header]
        send_rows = sorted([r for r in observed if "发送" in _norm(_text(r)) or _norm(_text(r)).lower() == "send"],
                           key=lambda r: _rect(r)["y"] if _inside(r, regions["send"]) else -float("inf"), reverse=True)
        send_rows = [r for r in send_rows if _inside(r, regions["send"])]
        search_rows = [r for r in observed if _norm(_text(r)) in {"搜索", "Q搜索", "q搜索"} and _inside(r, regions["search"])]
        if header_rows and send_rows:
            self.search_anchors = [_text(header_rows[0]), "发送" if "发送" in _text(send_rows[0]) else _text(send_rows[0])]
        if value.get("target_visible_verified") is not True:
            # A filled search field can hide 搜索. Confirm once using actual
            # fresh header/Send observations; no input uses an unconfirmed frame.
            fallback_rows = (header_rows[:1] + send_rows[:1] + search_rows[:1])[:2]
            if len(fallback_rows) < 2 or _rect(fallback_rows[0]) == _rect(fallback_rows[1]):
                raise Stopped("visual_target_unconfirmed", "Two spatially distinct actual OCR anchors are required")
            anchors = ["搜索" if r in search_rows else "发送" if r in send_rows and "发送" in _text(r) else _text(r) for r in fallback_rows]
            value = self.visual_identity(self.call("visual_read", regions=read_regions, anchor_texts=anchors, confirm_target=True, max_text_rows=100))
        if value.get("target_visible_verified") is not True:
            raise Stopped("visual_target_unconfirmed", "Native target visibility is unverified")
        self.anchors = anchors
        if include_recent and value.get("ocr_truncated"):
            # Body/panel text must never exhaust the sidebar's return budget.
            # Refetch all navigation controls, composer and recent rows together
            # on one current frame; never attach an old header to a newer crop.
            value = self.visual_identity(self.call("visual_read", regions=self.wechat_read_regions(include_recent=True),
                                                  anchor_texts=self.anchors, confirm_target=True,
                                                  anchor_wait_timeout_ms=0, max_text_rows=100))
            self.wechat_header(value, header)
            if value.get("ocr_truncated") is not False:
                raise Stopped("recent_read_truncated", "Complete current recent-chat OCR is unavailable; no no-match/search fallback or navigation input")
            if value.get("target_visible_verified") is not True or not self.wechat_has_send(value):
                raise Stopped("visual_target_unconfirmed", "Current title and composer controls changed during recent refetch; no navigation")
        elif value.get("ocr_truncated"):
            # A full-window row cap can hide the composer. Read its complete
            # current region rather than interpreting omitted draft rows as empty.
            region = self.wechat_regions()["composer"]
            composer = self.visual_identity(self.call("visual_read", anchor_texts=self.anchors, confirm_target=True,
                                                     region=region, max_text_rows=100))
            if composer.get("ocr_truncated") or composer.get("target_visible_verified") is not True:
                raise Stopped("composer_read_truncated", "Complete current composer OCR is unavailable; no input")
            value = {**value, "snapshot_id": composer["snapshot_id"],
                     "ocr": [r for r in value["ocr"] if not _inside(r, region)] + composer["ocr"]}
        self.title = self.wechat_header(value, expected_title)
        if include_recent and ("captured_regions" in value or "ocr_regions" in value):
            from desktop_observation import _covered
            regions = self.wechat_regions()
            if (not _covered(regions["recent"], value.get("captured_regions"))
                    or not _covered(regions["recent"], value.get("ocr_regions"))
                    or not self.wechat_complete_composer_capture(value)):
                raise Stopped("recent_read_incomplete", "The complete recent list and current composer are not covered by this same frame; no navigation")
        value["recent_scope_read"] = include_recent and value.get("ocr_truncated") is False
        return value

    def visual_args(self, value, kind, region):
        return {"snapshot_id": value["snapshot_id"], "max_age_ms": 5000, "control_kind": kind,
                "control_rect": region, "confirm_control": True}

    def wechat_navigation_click(self, value, expected_title, region, target_text, **coordinates):
        """One text-navigation click; a complete fresh proof can survive its failed capture."""
        try:
            self.call("visual_click", **self.visual_args(value, "navigation", region),
                      target_text=target_text, wait_timeout_ms=1000, **coordinates)
            return None
        except Stopped as failure:
            if (failure.code not in {"visual_target_changed", "visual_capture_unavailable", "visual_capture_failed", "visual_frame_timeout"}
                    or type(failure.details.get("events_posted")) is not int or failure.details["events_posted"] != 2):
                raise
            # In native visual_click this exact count is its balanced down/up
            # pair. It says nothing about the selected recipient or editor.
            receipt = {"attempted": True, "verified": False, "original_error_code": failure.code,
                       "events_posted": 2, "automatic_replay_allowed": False, "capture_attempts": 0}
            self.navigation_recovery = receipt
            try:
                regions = self.wechat_regions()
                deadline = time.monotonic() + 3
                while True:
                    self.status(strict=True)
                    if time.monotonic() >= deadline:
                        raise Stopped("navigation_recovery_timeout", "Read-only navigation proof exceeded its three-second readiness limit")
                    receipt["capture_attempts"] += 1
                    try:
                        fresh = self.visual_identity(self.call("visual_read", regions=[regions[k] for k in ("header", "search", "send", "composer")],
                                                              anchor_texts=[expected_title, "发送"], confirm_target=True,
                                                              anchor_wait_timeout_ms=0, max_text_rows=100))
                    except Stopped as capture_failure:
                        if capture_failure.code not in {"visual_target_changed", "visual_capture_unavailable", "visual_capture_failed", "visual_frame_timeout"}:
                            raise
                        evidence = capture_failure.details
                        if evidence.get("focused_AX_reference_equal") is False or evidence.get("focused_title_equal") is False:
                            raise Stopped("navigation_focus_unverified", "Actual focused-window identity changed during capture") from capture_failure
                        if "focused_window_pid" in evidence and evidence["focused_window_pid"] != self.pid:
                            raise Stopped("navigation_identity_unverified", "Actual focused-window PID changed during capture") from capture_failure
                        for key in ("focused_frame_before", "focused_frame_after"):
                            if key in evidence:
                                try:
                                    frame = _rect({"bounds": evidence[key]})
                                except Stopped:
                                    raise Stopped("navigation_focus_unverified", "Actual focused-window geometry is unavailable during capture") from capture_failure
                                if frame != self.frame:
                                    raise Stopped("navigation_focus_unverified", "Actual focused-window geometry changed during capture") from capture_failure
                        self.status(strict=True)
                        remaining = deadline - time.monotonic()
                        if remaining <= .15:
                            raise Stopped("navigation_recovery_timeout", "Read-only navigation capture did not settle within three seconds") from capture_failure
                        if receipt["capture_attempts"] >= 2:
                            raise
                        time.sleep(.15)
                        continue
                    if time.monotonic() > deadline:
                        raise Stopped("navigation_recovery_timeout", "Read-only navigation proof returned after its readiness limit")
                    break
                for key in ("target_pid", "window_id"):
                    if type(value.get(key)) is not int or value[key] <= 0 or type(fresh.get(key)) is not int or fresh[key] != value[key]:
                        raise Stopped("navigation_identity_unverified", "Current PID/window identity does not match the posted navigation")
                topology = value.get("display_topology_signature")
                if not isinstance(topology, str) or not topology or fresh.get("display_topology_signature") != topology:
                    raise Stopped("navigation_identity_unverified", "Display topology changed or is unavailable after navigation")
                if (_rect({"bounds": value.get("focused_window_frame")}) != self.frame
                        or _rect({"bounds": fresh.get("focused_window_frame")}) != self.frame):
                    raise Stopped("navigation_focus_unverified", "The actual focused window is not the bound chat main window")
                header = self.wechat_header(fresh, expected_title)
                if (fresh.get("target_visible_verified") is not True or fresh.get("input_eligible") is not True
                        or fresh.get("read_only_background") is not False or not self.wechat_has_send(fresh)
                        or not self.wechat_complete_composer_capture(fresh)):
                    raise Stopped("navigation_selection_unverified", "Complete current target anchors and composer are unavailable after navigation")
                self.wechat_draft(fresh)  # Preserve its complete actual value, including an existing draft.
                self.status(strict=True)
                self.anchors = self.search_anchors = [header, "发送"]
                self.title = header
                receipt.update(verified=True, verification_source="fresh_same_window_full_header_and_complete_composer",
                               proof_snapshot_id=fresh["snapshot_id"])
            except Stopped as proof_failure:
                receipt["stop_code"] = proof_failure.code[:128]
                details = {**failure.details, "navigation_recovery_stop_code": proof_failure.code[:128]}
                raise Stopped(failure.code, str(failure), details) from proof_failure
            # Read/history/send still require their separate current business
            # scope. This is a read, never a retry of the posted mouse pair.
            return self.wechat_read(expected_title=expected_title) if self.request["action"] in {"read", "history", "send"} else fresh

    def wechat_draft(self, value):
        panel = self.wechat_details_panel(value)
        if panel is not None:
            raise Stopped("wechat_details_panel_open", "The details panel obscures the complete chat composer",
                          {"panel_kind": panel["kind"], "panel_confirmed": panel["verified"]})
        rows = sorted(self.wechat_composer_rows(value), key=lambda r: (_rect(r)["y"], _rect(r)["x"]))
        return "\n".join(_text(r) for r in rows)

    def wechat_composer_rows(self, value):
        region = self.wechat_regions()["composer"]
        rows = [row for row in value["ocr"] if _inside(row, region)]
        hint = value.get("empty_composer_hint")
        if (not isinstance(hint, dict) or hint.get("verified") is not True
                or hint.get("kind") != "wechat_voice_placeholder"
                or hint.get("style") != "light_gray_on_light_background"
                or hint.get("verification_source") != "same_frame_OCR_geometry_and_gray_glyph_pixels"
                or not isinstance(value.get("snapshot_id"), str) or hint.get("snapshot_id") != value["snapshot_id"]
                or type(value.get("frame_complete_serial")) is not int or value["frame_complete_serial"] <= 0
                or type(hint.get("frame_complete_serial")) is not int or hint["frame_complete_serial"] != value["frame_complete_serial"]
                or not isinstance(hint.get("text"), str) or _norm(hint["text"]) != "按住鼠标语音输入文字"):
            return rows
        # This native proof marks one gray placeholder row from this exact
        # frame. Its wording alone never makes black user text or other hints
        # empty, and it makes no claim about any additional composer rows.
        from desktop_observation import _covered
        try:
            bounds = _rect({"bounds": hint.get("bounds")})
            composer = _rect({"bounds": hint.get("composer_region")})
        except Stopped:
            return rows
        if not _covered(bounds, [region]) or not _covered(bounds, [composer]):
            return rows
        matched = [index for index, row in enumerate(rows) if row.get("text") == hint["text"] and _rect(row) == bounds]
        return [row for index, row in enumerate(rows) if index != matched[0]] if len(matched) == 1 else rows

    def wechat_recent_row(self, name, rows):
        bounds = _rect(name)
        def timestamp(row):
            return re.fullmatch(r"(?:(?:昨天|今天|(?:星期|周)[一二三四五六日天])?(?:[01]?\d|2[0-3]):[0-5]\d|(?:星期|周)[一二三四五六日天]|(?:\d{4}/)?\d{1,2}/\d{1,2})", _norm(_text(row))) is not None
        times = [row for row in rows if timestamp(row) and _rect(row)["x"] >= bounds["x"] + bounds["width"] + 8
                 and abs(_center(_rect(row))[1] - _center(bounds)[1]) <= 6]
        previews = [row for row in rows if row is not name and _text(row) and not timestamp(row)
                    and abs(_rect(row)["x"] - bounds["x"]) <= 16
                    and 0 <= _rect(row)["y"] - bounds["y"] - bounds["height"] <= 24]
        return len(times) == len(previews) == 1

    def wechat_recent_rows(self, value):
        recent = [r for r in value["ocr"] if _inside(r, self.wechat_regions()["recent"])]
        if value.get("ocr_truncated") or any(_norm(_text(r)) in RECENT_SECTION_NAMES and not self.wechat_recent_row(r, recent) for r in recent):
            return []
        return recent

    def wechat_recent_matches(self, value, wanted):
        return [r for r in self.wechat_recent_rows(value) if _label_matches(_text(r), wanted)]

    def wechat_recent_prefix_probe(self, value, wanted):
        # Long sidebar names can split into a prefix and a clipped tail, with
        # Vision omitting the visible ellipsis. This is one local navigation
        # probe only; time/preview structure and the full new header are required.
        if _norm(_wechat_search_query(wanted)) == _norm(wanted):
            return None
        recent = self.wechat_recent_rows(value)
        candidates = [row for row in recent if _norm(_text(row)) not in RECENT_SECTION_NAMES
                      and (_wechat_truncated_result_matches(_text(row), wanted)
                           or _wechat_truncated_result_matches(_text(row) + "…", wanted))
                      and self.wechat_recent_row(row, recent)]
        if len(candidates) > 1:
            raise Stopped("ambiguous_target", "Multiple structured recent-chat prefixes; no provisional navigation click", {"matching_count": len(candidates)})
        return candidates[0] if candidates else None

    def wechat_bootstrap_recent(self, value, wanted):
        if not value.get("recent_scope_read"):
            value = self.visual_identity(self.call("visual_read", regions=self.wechat_read_regions(include_recent=True),
                                                    anchor_texts=["搜索", "发送"], confirm_target=True,
                                                    anchor_wait_timeout_ms=0, max_text_rows=100))
        def reliable_label(row):
            label, confidence = _text(row), row.get("confidence")
            # Emoji names and low-confidence glyph substitutions changed on
            # the observed fresh navigation crop. An intermediate chat needs
            # a complete stable label; legacy OCR without confidence remains
            # eligible, while the final recipient header is still mandatory.
            return (not any(unicodedata.category(char) == "So" or char in {"\ufe0f", "\u20e3", "\u200d"} for char in label)
                    and _wechat_truncated_prefix(label) is None
                    and (confidence is None or type(confidence) in {int, float}
                         and math.isfinite(confidence) and .5 <= confidence <= 1))
        def candidate(current, selected_label=None, require_structure=False):
            evidence = self.wechat_control_evidence(current)
            if self.wechat_header_rows(current):
                raise Stopped("chat_selection_changed", "A chat title appeared during blank startup confirmation; no repeated recent-row click")
            if any(_inside(row, self.wechat_regions()["send"]) for row in evidence):
                raise Stopped("chat_header_unverified", "Send is visible but the selected chat header is unavailable; no navigation")
            if any(_text(row) and _inside(row, self.wechat_regions()["composer"]) for row in current["ocr"]):
                raise Stopped("draft_unverified", "Composer text is visible without a selected chat header; preserve it")
            searches = [row for row in evidence if _norm(_text(row)) in {"搜索", "Q搜索", "q搜索"}
                        and _inside(row, self.wechat_regions()["search"])]
            _unique(searches, "Blank-chat bootstrap requires one actual visible Search marker")
            recent = self.wechat_recent_rows(current)
            if selected_label is not None:
                matches = [row for row in recent if _norm(_text(row)) == _norm(selected_label)
                           and (not require_structure or reliable_label(row) and self.wechat_recent_row(row, recent))]
                return _unique(matches, "The exact bootstrap recent row is no longer uniquely proven")
            matches = [row for row in recent if _label_matches(_text(row), wanted)]
            if matches:
                return _unique(matches, "Blank-chat bootstrap requires one exact current requested recent chat")
            # Establish a normal selected-chat header/Send without typing into
            # a blank pane. A unique current name plus its time and preview are
            # required; aggregate/category rows are not intermediate editors.
            intermediate = [row for row in recent if _norm(_text(row)) not in RECENT_SECTION_NAMES
                            and reliable_label(row) and self.wechat_recent_row(row, recent)
                            and sum(_norm(_text(other)) == _norm(_text(row)) for other in recent) == 1]
            if not intermediate:
                raise Stopped("target_not_found", "Blank startup has no uniquely proven recent chat for safe navigation")
            return min(intermediate, key=lambda row: (-(row.get("confidence") if row.get("confidence") is not None else .5),
                                                       _rect(row)["y"], _rect(row)["x"]))
        row = candidate(value)
        intermediate = not _label_matches(_text(row), wanted)
        bootstrap_title = re.sub(r"[（(]\d+[)）]$", "", re.sub(r"\s+AI$", "", _text(row))) if intermediate else wanted
        anchors = ["搜索", _text(row)]
        confirmed = self.visual_identity(self.call("visual_read", regions=self.wechat_read_regions(include_recent=True),
                                                  anchor_texts=anchors, confirm_target=True, max_text_rows=100))
        if confirmed.get("target_visible_verified") is not True:
            raise Stopped("visual_target_unconfirmed", "Search and the exact recent label were not confirmed as two current spatial anchors")
        row = candidate(confirmed, _text(row), require_structure=intermediate)
        recovered = self.wechat_navigation_click(confirmed, bootstrap_title, self.wechat_tight_region(row, padding=8), _text(row))
        if recovered is None:
            self.anchors, self.search_anchors = [], []
        # Bootstrap is allowed once at startup. A missing/changed header after
        # this posted click stops; it must never toggle the same row by replay.
        return recovered if recovered is not None else self.wechat_read(expected_title=bootstrap_title)

    def wechat_locate(self, value, wanted):
        self.wechat_header_group(value, wanted)
        kind = self.request.get("chat_kind", "any")
        kind_satisfied = kind == "any" or self.kind_evidence and self.kind_evidence["kind"] == kind
        if _label_matches(self.title, wanted) and kind_satisfied:
            self.wechat_header(value, wanted)
            return value
        if self.wechat_draft(value):
            raise Stopped("draft_present", "The current chat has a draft; navigation stopped to preserve it")
        # Current-title matches need no sidebar scan. A filled search overlay
        # cannot prove a recent row, so go directly to guarded query replacement.
        search_visible = any(_norm(_text(row)) in {"搜索", "Q搜索", "q搜索"}
                             and _inside(row, self.wechat_regions()["search"]) for row in self.wechat_control_evidence(value))
        if kind != "person" and not _label_matches(self.title, wanted) and search_visible and not value.get("recent_scope_read"):
            value = self.wechat_read(expected_title=self.title, include_recent=True)
            if self.wechat_draft(value):
                raise Stopped("draft_present", "The current chat has a draft; recent navigation stopped to preserve it")
        # Reuse an already displayed exact recent-chat label. Search overlays
        # have section headings, so never treat their network/history rows as a
        # recent conversation. Native semantic click still resolves fresh OCR.
        matches = self.wechat_recent_matches(value, wanted)
        prefix_probe = (self.wechat_recent_prefix_probe(value, wanted)
                        if kind != "person" and not matches and not _label_matches(self.title, wanted) else None)
        # 公众号 is also an actual recent-chat name. Its independent right-side
        # timestamp and aligned preview prove a conversation row, while category
        # headings retain the existing overlay guard.
        if not _label_matches(self.title, wanted) and (len(matches) == 1 or prefix_probe is not None):
            row = prefix_probe if prefix_probe is not None else matches[0]
            region = self.wechat_tight_region(row, padding=8 if prefix_probe is not None else 6)
            coordinates = {}
            if prefix_probe is not None:
                # Retain the complete observed name line, including split OCR
                # fragments/badge. Native must still see this literal prefix
                # at its actual center before posting the one click.
                recent_region = self.wechat_regions()["recent"]
                region["width"] = recent_region["x"] + recent_region["width"] - region["x"]
                coordinates = dict(zip(("x", "y"), _center(_rect(row))))
            recovered = self.wechat_navigation_click(value, wanted, region,
                                                     (_wechat_truncated_prefix(_text(row)) or _text(row)) if prefix_probe is not None else _text(row),
                                                     **coordinates)
            if recovered is None:
                self.anchors = []
            value = recovered if recovered is not None else self.wechat_read(expected_title=wanted if prefix_probe is not None else None)
            self.wechat_header(value, wanted)
            self.wechat_header_group(value, wanted)
            if kind == "any" or self.kind_evidence and self.kind_evidence["kind"] == kind:
                return value
            if self.wechat_draft(value):
                raise Stopped("draft_present", "The selected chat has a draft; classification search stopped to preserve it")
        if len(self.search_anchors) != 2:
            raise Stopped("visual_target_unconfirmed", "Fresh header and Send anchors are required before search input")
        self.anchors = list(self.search_anchors)
        region = self.wechat_regions()["search"]
        point = _center(region)
        controls = {"max_age_ms": 5000, "control_kind": "search", "control_rect": region, "confirm_control": True, "snapshot_id": "latest"}
        # A bounded search prefix is only a query. Recipient selection and the
        # final header still require the caller's complete exact wanted name.
        # An explicitly ellipsized local result is only a unique navigation
        # probe; it does not relax this final recipient proof.
        query = _wechat_search_query(wanted)
        observed_query = self.wechat_overlay_query(value)
        if observed_query and _norm(observed_query) == _norm(query):
            self.anchors = [observed_query, self.search_anchors[1]]
            return self.wechat_select_search(wanted)
        changed = self.call("batch", actions=[
            # The current confirmed snapshot already proves the empty composer,
            # title and Send. Native checks its age before this click and then
            # refreshes local controls/anchor regions on every continuation.
            # A stale first snapshot stops with zero events, never replays.
            {"command": "visual_click", **controls, "snapshot_id": value["snapshot_id"], "x": point[0], "y": point[1]},
            {"command": "visual_type_text", **controls, "replace_search": True, "text": query, "expected_text": query},
        ])
        completed = changed.get("results", [])
        if (isinstance(completed, list) and completed and isinstance(completed[-1], dict)
                and completed[-1].get("command") == "visual_type_text" and isinstance(completed[-1].get("result"), dict)):
            typed = self.visual_identity(completed[-1]["result"])
            rows = [row for row in typed["ocr"] if _inside(row, region) and _norm(_text(row)) == _norm(query)]
            actual_query = self.wechat_overlay_query(typed)
            if not actual_query or _norm(actual_query) != _norm(query):
                actual_query = _text(rows[0]) if len(rows) == 1 else None
            if typed.get("value_verified") is True and actual_query:
                # This text came from the complete current query readback. The
                # next fresh panel read independently confirms it and actual
                # Send; a popup-covered old header is no longer an anchor.
                self.anchors = [actual_query, self.search_anchors[1]]
                self.search_anchors = list(self.anchors)
        return self.wechat_select_search(wanted)

    def wechat_select_search(self, wanted):
        deadline = time.monotonic() + 3
        while True:
            results = self.wechat_search_read()
            result, category = self.wechat_result(results, wanted)
            if result is None:
                refined = self.wechat_refine_search_name(results, wanted)
                if refined is not None:
                    results, result, category = refined
                    break
            if result is not None or time.monotonic() >= deadline:
                break
            time.sleep(.12)
        if result is None:
            raise Stopped("target_not_found", "No exact local contact/group result appeared; network and message-history matches are excluded")
        prefix = _wechat_truncated_prefix(_text(result)) if _wechat_truncated_result_matches(_text(result), wanted) else None
        coordinates = dict(zip(("x", "y"), _center(_rect(result)))) if prefix is not None else {}
        recovered = self.wechat_navigation_click(results, wanted, self.wechat_tight_region(result, padding=8 if prefix is not None else 6),
                                                 prefix or _text(result), **coordinates)
        self.kind_evidence = ({"kind": "unknown", "source": "local_OCR_search_result_subtitle", "subtitle": "微信 ClawBot"}
                              if category == "微信 ClawBot" else
                              {"kind": self.wechat_category_kind(category), "source": "local_OCR_search_category", "category": category})
        if recovered is None:
            self.anchors = []
        result = recovered if recovered is not None else self.wechat_read()
        self.wechat_header(result, wanted)
        if wanted == "文件传输助手" and category == "功能":
            if (_norm(self.wechat_header(result)) != wanted or result.get("snapshot_id") == results.get("snapshot_id")
                    or any(result.get(key) != results.get(key) for key in ("target_pid", "window_id", "display_topology_signature"))
                    or result.get("target_visible_verified") is not True or result.get("input_eligible") is not True
                    or result.get("read_only_background") is not False
                    or _rect({"bounds": result.get("focused_window_frame")}) != self.frame
                    or not self.wechat_complete_composer_capture(result)):
                raise Stopped("navigation_selection_unverified", "The built-in file assistant requires a new complete exact recipient and composer in the same current window")
        return result

    def wechat_tight_region(self, row, padding=6):
        selected = _rect(row)
        vertical_padding = max(padding, (30 - selected["height"]) / 2) if padding > 6 else padding
        left, top = max(self.frame["x"], selected["x"] - padding), max(self.frame["y"], selected["y"] - vertical_padding)
        return {"x": left, "y": top, "width": min(selected["width"] + padding * 2, self.frame["x"] + self.frame["width"] - left),
                "height": min(selected["height"] + vertical_padding * 2, self.frame["y"] + self.frame["height"] - top)}

    def wechat_header_group(self, value, wanted):
        label = self.wechat_header(value)
        if _label_matches(label, wanted):
            members = re.fullmatch(re.escape(_norm(wanted)) + r"[（(](\d+)[)）]", _norm(label))
            if members:
                self.kind_evidence = {"kind": "group", "source": "current_chat_header_member_count", "member_count": int(members.group(1))}

    def wechat_search_read(self):
        self.status(strict=True)
        full = self.wechat_regions()["results"]
        top = {**full, "height": min(320, full["height"])}
        # In the observed built-in file-assistant layout a network heading
        # precedes 功能. Read the whole result scope once for this exact target;
        # that early heading cannot prove the later function row is unique.
        regions = (full,) if self.request.get("chat") == "文件传输助手" else (top, full)
        for region in regions:
            value = self.visual_identity(self.call("visual_read", region=region,
                                                   anchor_texts=self.anchors, confirm_target=True, max_text_rows=100))
            if value.get("target_visible_verified") is not True:
                raise Stopped("visual_target_unconfirmed", "Search panel target visibility is unverified")
            if value.get("ocr_truncated"):
                if region == top and top != full:
                    continue
                raise Stopped("search_results_truncated", "Search panel OCR is truncated; result uniqueness is unverified")
            # A complete history/network heading closes all eligible local
            # results. Without that observed boundary, a same-named group or
            # low 功能 result can still be below: expand before selecting.
            closed = any(_wechat_search_category(row) in WECHAT_SEARCH_EXCLUDED
                         and _inside(row, region) and _rect(row)["y"] + _rect(row)["height"] < region["y"] + region["height"] - 2
                         for row in value["ocr"])
            if region == full or closed:
                value["search_scope_complete"] = True
                value["search_panel_height_read"] = region["height"]
                return value

    def wechat_search_sections(self, value):
        rows = [row for row in value["ocr"] if _inside(row, self.wechat_regions()["results"])]
        headings = sorted([row for row in rows if _wechat_search_category(row) in WECHAT_SEARCH_LOCAL | WECHAT_SEARCH_EXCLUDED],
                          key=lambda row: _rect(row)["y"])
        stop_y = min((_rect(row)["y"] for row in headings if _wechat_search_category(row) in WECHAT_SEARCH_EXCLUDED), default=float("inf"))
        return rows, headings, stop_y

    def wechat_refine_search_name(self, value, wanted):
        # One observed popup layout merges the avatar and trailing icons into
        # the name row. It authorizes only a read of the actual name column.
        # No characters from that merged line become a recipient or click label.
        from desktop_observation import _covered
        query = _wechat_search_query(wanted)
        if (value.get("search_scope_complete") is not True or value.get("ocr_truncated") is not False
                or self.wechat_overlay_query(value) != query or not self.wechat_has_send(value)
                or value.get("input_eligible") is not True or value.get("read_only_background") is not False
                or type(value.get("target_pid")) is not int or value["target_pid"] != self.pid
                or type(value.get("window_id")) is not int or value["window_id"] <= 0
                or not isinstance(value.get("display_topology_signature"), str) or not value["display_topology_signature"]):
            return None
        popup = _rect({"bounds": value.get("search_overlay_frame")})
        if (abs(popup["x"] - self.frame["x"] - 48) > 2 or abs(popup["y"] - self.frame["y"] - 35) > 2
                or abs(popup["width"] - 368) > 2):
            return None
        rows, headings, stop_y = self.wechat_search_sections(value)
        def local_query_rows(source_rows, source_headings, cutoff):
            matches = []
            for row in source_rows:
                preceding = [h for h in source_headings if _rect(h)["y"] < _rect(row)["y"]]
                category = _wechat_search_category(preceding[-1]) if preceding else ""
                if (category in WECHAT_SEARCH_LOCAL and _rect(row)["y"] < cutoff
                        and (query in _text(row) or _label_matches(_text(row), wanted)
                             or _wechat_truncated_result_matches(_text(row), wanted))):
                    matches.append((row, category))
            return matches
        def merged(row):
            rect = _rect(row)
            # Actual48 includes the avatar; actual49/54 recognize it separately
            # and merge only the name-column text with the trailing icons.
            # Actual54's first glyph starts at popup+77, with Vision's tiny
            # normalized-coordinate rounding error; the crop stays at +80.
            observed_left = (popup["x"] + 28 <= rect["x"] <= popup["x"] + 48
                             or popup["x"] + 77 - 1e-5 <= rect["x"] <= popup["x"] + 82)
            return (query in _text(row) and observed_left
                    and popup["x"] + 268 < rect["x"] + rect["width"] <= popup["x"] + popup["width"]
                    and popup["y"] <= rect["y"] and rect["y"] + rect["height"] <= popup["y"] + popup["height"]
                    and 8 <= rect["height"] <= 28)
        matches = local_query_rows(rows, headings, stop_y)
        if not any(merged(row) for row, _ in matches):
            return None
        row, category = _unique(matches, "Multiple local query rows prevent a unique name-column reread")
        kind = self.wechat_category_kind(category)
        allow_unknown_locate = self.request["action"] == "locate" and category == "最常使用"
        if self.request.get("chat_kind", "any") not in {"any", kind} and not allow_unknown_locate:
            return None
        full = self.wechat_regions()["results"]
        scanned_scope = {**full, "height": value.get("search_panel_height_read", full["height"])}
        if (not _covered(scanned_scope, value.get("captured_regions")) or not _covered(scanned_scope, value.get("ocr_regions"))
                or _rect({"bounds": value.get("focused_window_frame")}) != self.frame):
            raise Stopped("search_name_refinement_unverified", "The original complete search scope is not covered by the current bound frame")
        band = {"x": popup["x"] + 80, "y": _rect(row)["y"] - 10, "width": 188, "height": 35}
        if not _covered(band, [popup]):
            raise Stopped("search_name_refinement_unverified", "The observed name column is not wholly inside the bound search popup")
        regions = self.wechat_regions()
        requested = [regions[key] for key in ("header", "search", "send")] + [full, band]
        self.status(strict=True)
        fresh = self.visual_identity(self.call("visual_read", regions=requested, anchor_texts=[query, "发送"],
                                               confirm_target=True, max_text_rows=100))
        for key in ("target_pid", "window_id", "display_topology_signature", "search_overlay_window_id", "search_overlay_frame"):
            if fresh.get(key) != value.get(key):
                raise Stopped("search_name_refinement_unverified", "Search window identity changed during the name-column reread")
        if (fresh["snapshot_id"] == value["snapshot_id"] or self.wechat_overlay_query(fresh) != query
                or fresh.get("target_visible_verified") is not True or fresh.get("input_eligible") is not True
                or fresh.get("read_only_background") is not False or not self.wechat_has_send(fresh)
                or _rect({"bounds": fresh.get("focused_window_frame")}) != self.frame):
            raise Stopped("search_name_refinement_unverified", "The fresh complete query, anchors or focused window are unavailable")
        if (fresh.get("ocr_truncated") is not False or fresh.get("ocr_scope") != "requested_regions"
                or any(not _covered(region, fresh.get("captured_regions")) or not _covered(region, fresh.get("ocr_regions")) for region in requested)):
            raise Stopped("search_name_refinement_unverified", "The fresh full search scope and name column must both be complete and covered")
        if not any(all(abs(_rect({"bounds": scanned})[key] - band[key]) <= 1e-6 for key in band)
                   for scanned in fresh["ocr_regions"]):
            raise Stopped("search_name_refinement_unverified", "The actual isolated name-column OCR region was not scanned")
        fresh_rows, fresh_headings, fresh_stop = self.wechat_search_sections(fresh)
        fresh_matches = local_query_rows(fresh_rows, fresh_headings, fresh_stop)
        clean = [(r, c) for r, c in fresh_matches if _covered(_rect(r), [band])
                 and (_label_matches(_text(r), wanted) or _wechat_truncated_result_matches(_text(r), wanted))]
        name, new_category = _unique(clean, "The fresh name column lacks one exact or explicitly ellipsized local result")
        if new_category != category or abs(_center(_rect(name))[1] - _center(_rect(row))[1]) > 6:
            raise Stopped("search_name_refinement_unverified", "The freshly read name does not correspond to the current local result row")
        # The two OCR crops can return the same physical row twice with different
        # text. Ignore only its current merged form; any other local query row
        # still prevents this provisional navigation, regardless of chat kind.
        duplicates = [r for r, c in fresh_matches if r is not name and merged(r) and c == category
                      and abs(_center(_rect(r))[1] - _center(_rect(name))[1]) <= 6]
        if len(duplicates) > 1 or any(r is not name and r not in duplicates for r, _ in fresh_matches):
            raise Stopped("ambiguous_target", "Multiple local query results remain after the name-column reread", {"matching_count": len(fresh_matches)})
        selected = {**fresh, "ocr": [r for r in fresh["ocr"] if r not in duplicates], "search_scope_complete": True,
                    "search_panel_height_read": full["height"]}
        result, category = self.wechat_result(selected, wanted)
        if result is None:
            raise Stopped("target_not_found", "The fresh local name does not match the complete requested recipient")
        return selected, result, category

    def wechat_result(self, value, wanted):
        rows, headings, stop_y = self.wechat_search_sections(value)
        if wanted == "文件传输助手":
            return self.wechat_file_transfer_result(value, rows, headings)
        local, category = WECHAT_SEARCH_LOCAL, _wechat_search_category
        # The lower part of the popup can expose the background recent list.
        # Local results end at the first history/network section; later visible
        # category-like background names cannot reopen eligible navigation.
        candidates, local_matches = [], []
        for row in rows:
            exact = _label_matches(_text(row), wanted)
            truncated = _wechat_truncated_result_matches(_text(row), wanted)
            if not (exact or truncated) or _rect(row)["y"] >= stop_y:
                continue
            preceding = [h for h in headings if _rect(h)["y"] < _rect(row)["y"]]
            section = category(preceding[-1]) if preceding else ""
            if exact and not section and headings and category(headings[0]) in local:
                # Actual promoted ClawBot search results precede 联系人 and
                # have no category heading. Require their exact adjacent native
                # subtitle, aligned below the exact name and before that heading.
                bounds = _rect(row)
                subtitles = [r for r in rows if _norm(_text(r)) == "微信ClawBot"
                             and abs(_rect(r)["x"] - bounds["x"]) <= 16
                             and 0 <= _rect(r)["y"] - bounds["y"] - bounds["height"] <= 24
                             and _rect(r)["y"] + _rect(r)["height"] < _rect(headings[0])["y"]]
                if len(subtitles) == 1:
                    section = "微信 ClawBot"
            if section not in local | {"微信 ClawBot"}:
                continue
            local_matches.append((row, section, truncated))
            kind = self.wechat_category_kind(section)
            allow_unknown_locate = self.request["action"] == "locate" and section == "最常使用"
            if self.request.get("chat_kind", "any") not in {"any", kind} and not allow_unknown_locate:
                continue
            candidates.append((row, section))
        # An abbreviated name does not prove which complete recipient it is.
        # Count every matching local prefix/exact row before narrowing by kind;
        # kind alone cannot resolve a truncation probe's ambiguity.
        if len(local_matches) > 1 and any(truncated for _, _, truncated in local_matches):
            raise Stopped("ambiguous_target", "Multiple exact local or explicitly truncated search results; no navigation click", {"matching_count": len(local_matches)})
        if len(candidates) > 1:
            raise Stopped("ambiguous_target", "Multiple exact local or explicitly truncated search results; no navigation click", {"matching_count": len(candidates)})
        return candidates[0] if candidates else (None, None)

    def wechat_file_transfer_result(self, value, rows, headings):
        # This is only a navigation probe for the observed built-in function,
        # not a generic reopening of local rows below a network/history cutoff.
        # A background model observation never supplies foreground input proof.
        from desktop_observation import _covered
        wanted, full = "文件传输助手", self.wechat_regions()["results"]
        if (self.request.get("chat") != wanted or self.request.get("chat_kind", "any") != "any"
                or self.wechat_overlay_query(value) != wanted
                or value.get("search_scope_complete") is not True or value.get("ocr_truncated") is not False
                or value.get("search_panel_height_read") != full["height"]
                or value.get("target_visible_verified") is not True or value.get("input_eligible") is not True
                or value.get("read_only_background") is not False
                or type(value.get("target_pid")) is not int or value["target_pid"] != self.pid
                or type(value.get("window_id")) is not int or value["window_id"] <= 0
                or not isinstance(value.get("display_topology_signature"), str) or not value["display_topology_signature"]
                or not isinstance(value.get("snapshot_id"), str) or not value["snapshot_id"]
                or not _covered(full, value.get("captured_regions")) or not _covered(full, value.get("ocr_regions"))):
            return None, None
        if _rect({"bounds": value.get("focused_window_frame")}) != self.frame:
            return None, None
        popup = _rect({"bounds": value.get("search_overlay_frame")})
        functions = [h for h in headings if _wechat_search_category(h) == "功能" and _inside(h, popup)]
        if len(functions) != 1:
            return None, None
        heading = functions[0]
        following = [h for h in headings if _rect(h)["y"] > _rect(heading)["y"] and _inside(h, popup)]
        # The observed complete history heading closes this function section.
        if not following or _wechat_search_category(following[0]) not in {"聊天记录", "搜索聊天记录"}:
            return None, None
        top = _rect(heading)["y"] + _rect(heading)["height"]
        bottom = _rect(following[0])["y"]
        matches = [r for r in rows if _inside(r, popup) and top <= _rect(r)["y"]
                   and _rect(r)["y"] + _rect(r)["height"] < bottom
                   and (_label_matches(_text(r), wanted) or _wechat_truncated_result_matches(_text(r), wanted))]
        if len(matches) > 1:
            raise Stopped("ambiguous_target", "Multiple file-assistant function rows; no navigation click", {"matching_count": len(matches)})
        if len(matches) != 1 or _text(matches[0]) != wanted:
            return None, None
        return matches[0], "功能"

    @staticmethod
    def wechat_category_kind(category):
        return "group" if category in {"群聊", "群组"} else "person" if category in {"联系人", "好友"} else "unknown"

    def wechat_clear_outcome(self, value, recipient, failure):
        # The one completed normal clear can outlast native OCR verification.
        # Prove its actual final UI once, without replaying deletion or using
        # the higher-level reader's panel/navigation helpers.
        from desktop_observation import _covered
        receipt = {"attempted": True, "verified": False, "original_error_code": failure.code,
                   "events_posted": 4, "native_draft_cleared": False, "automatic_replay_allowed": False,
                   "capture_attempts": 0}
        self.clear_recovery = receipt
        try:
            self.status(strict=True)
            regions = self.wechat_regions()
            requested = [regions[key] for key in ("header", "search", "send", "composer")]
            receipt["capture_attempts"] = 1
            fresh = self.visual_identity(self.call("visual_read", regions=requested,
                                                   anchor_texts=[recipient, "发送"], confirm_target=True,
                                                   anchor_wait_timeout_ms=0, max_text_rows=100))
            for key in ("target_pid", "window_id"):
                if type(value.get(key)) is not int or value[key] <= 0 or type(fresh.get(key)) is not int or fresh[key] != value[key]:
                    raise Stopped("clear_identity_unverified", "Current PID/window does not match the completed clear")
            topology = value.get("display_topology_signature")
            if not isinstance(topology, str) or not topology or fresh.get("display_topology_signature") != topology:
                raise Stopped("clear_identity_unverified", "The display topology changed or is unavailable after clear")
            if (_rect({"bounds": value.get("focused_window_frame")}) != self.frame
                    or _rect({"bounds": fresh.get("focused_window_frame")}) != self.frame):
                raise Stopped("clear_focus_unverified", "The actual focused window is not the original bound main window")
            if (fresh["snapshot_id"] == value["snapshot_id"] or fresh.get("target_visible_verified") is not True
                    or fresh.get("target_identity_verified") is not True or fresh.get("input_eligible") is not True
                    or fresh.get("read_only_background") is not False or fresh.get("ocr_scope") != "requested_regions"
                    or not self.wechat_has_send(fresh) or not self.wechat_complete_composer_capture(fresh)
                    or any(not _covered(region, fresh.get("captured_regions")) or not _covered(region, fresh.get("ocr_regions")) for region in requested)):
                raise Stopped("clear_outcome_unverified", "Complete fresh foreground anchors and composer are unavailable after clear")
            if _norm(self.wechat_header(fresh)) != _norm(recipient):
                raise Stopped("clear_recipient_changed", "The whole actual chat title changed after clear")
            if self.wechat_draft(fresh) != "" or self.wechat_composer_rows(fresh):
                raise Stopped("clear_outcome_unverified", "The complete current composer is not strictly empty after clear")
            self.status(strict=True)
            receipt.update(verified=True, proof_snapshot_id=fresh["snapshot_id"],
                           verification_source="fresh_same_window_whole_recipient_header_and_complete_empty_composer")
            return fresh
        except Stopped as proof_failure:
            receipt["stop_code"] = proof_failure.code[:128]
            raise Stopped(failure.code, str(failure), {**failure.details, "clear_recovery_stop_code": proof_failure.code[:128]}) from proof_failure

    def wechat_edit(self, value, action=None):
        before = self.wechat_draft(value)
        recipient = self.title
        action = action or self.request["action"]
        if action == "draft" and before:
            raise Stopped("draft_present", "Composer is not empty; the existing draft was preserved")
        if action == "clear" and before != self.request["expected_draft"]:
            raise Stopped("draft_changed", "Visible composer does not equal expected_draft; no clear events")
        if action == "clear" and not before:
            return {"draft_empty": True, "draft_verified": True, "sent": False}
        region = self.wechat_regions()["composer"]
        args = self.visual_args(value, "chat_composer", region)
        x, y = _center(region)
        clicked = self.visual_identity(self.call("visual_click", **args, x=x, y=y))
        # The click's fresh OCR is the last pre-input evidence. Reads would reset
        # native visual input focus, so consume this post-click snapshot directly.
        if self.wechat_draft(clicked) != before:
            raise Stopped("draft_changed", "The composer changed before editing; no text/delete events")
        args = self.visual_args(clicked, "chat_composer", region)
        if action == "draft":
            changed = self.visual_identity(self.call("visual_type_text", **args, text=self.request["text"], expected_text=self.request["text"], chat_title=recipient))
            if changed.get("value_verified") is not True:
                raise Stopped("draft_unverified", "Native input was not verified; no replay")
            # The action's first OCR can momentarily include the caret. Reuse
            # the final read already required below to prove the complete value;
            # never remove unknown glyphs or post the text a second time.
        else:
            try:
                changed = self.visual_identity(self.call("visual_key", **args, key="clear_draft",
                                                         expected_draft=before, chat_title=recipient))
            except Stopped as failure:
                if (failure.code != "postcondition_failed" or type(failure.details.get("events_posted")) is not int
                        or failure.details["events_posted"] != 4 or failure.details.get("draft_cleared") is not False):
                    raise
                final = self.wechat_clear_outcome(clicked, recipient, failure)
                self.edited_value = final
                return {"draft_empty": True, "draft_verified": True, "draft": "", "sent": False}
            if (changed.get("draft_cleared") is not True or changed.get("value_verified") is not True
                    or changed.get("events_posted") != 4 or self.wechat_draft(changed)):
                raise Stopped("clear_unverified", "Clear events posted, but visible composer is not empty; no replay")
        # Native action OCR is limited to the control. Obtain the complete
        # header/composer view again before reporting the business result.
        from desktop_observation import _covered
        same_frame_proof = (changed.get("edit_recipient_verified") is True
                            and changed.get("edit_recipient") == recipient
                            and changed.get("edit_proof_snapshot_id") == changed.get("snapshot_id")
                            and changed.get("ocr_scope") == "post_action_recipient_and_complete_composer"
                            and changed.get("target_identity_verified") is True
                            and changed.get("input_eligible") is True
                            and changed.get("read_only_background") is False
                            and changed.get("target_pid") == clicked.get("target_pid")
                            and type(changed.get("window_id")) is int and changed["window_id"] > 0
                            and changed.get("window_id") == clicked.get("window_id")
                            and bool(clicked.get("display_topology_signature"))
                            and changed.get("display_topology_signature") == clicked["display_topology_signature"]
                            and changed.get("focused_window_frame") == self.frame
                            and self.wechat_complete_composer_capture(changed)
                            and _covered(self.wechat_regions()["header"], changed.get("captured_regions"))
                            and _covered(self.wechat_regions()["header"], changed.get("ocr_regions")))
        final = changed if same_frame_proof else self.wechat_read(expected_title=recipient)
        self.wechat_header(final, recipient)
        expected = self.request["text"] if action == "draft" else ""
        if self.wechat_draft(final) != expected:
            raise Stopped("draft_changed", "Final composer differs from the verified edit; no replay")
        self.edited_value = final
        if action == "draft":
            self.edited_input_receipt = {key: changed.get(key) for key in
                ("input_event_timing", "events_posted", "value_verified", "target_pid", "window_id", "display_topology_signature")}
        return {"draft_empty": not expected, "draft_verified": True, "draft": expected, "sent": False}

    def wechat_clear_prefix(self, value):
        recipient = self.title
        self.wechat_header(value, self.request["chat"])
        before, prefix = self.wechat_draft(value), self.request["prefix"]
        if not before.startswith(prefix):
            raise Stopped("prefix_mismatch", "The complete current draft does not begin with the exact authorized prefix; no deletion")
        expected = before[len(prefix):]
        expected_sequence = _ocr_line_sequence(expected)
        region = self.wechat_regions()["composer"]
        x, y = _center(region)
        clicked = self.visual_identity(self.call("visual_click", **self.visual_args(value, "chat_composer", region), x=x, y=y))
        if self.wechat_draft(clicked) != before:
            raise Stopped("draft_changed", "The complete draft changed while focusing; no prefix deletion")
        changed = self.visual_identity(self.call("visual_key", **self.visual_args(clicked, "chat_composer", region),
                                                  key="clear_prefix", expected_draft=before, prefix=prefix, chat_title=recipient))
        if (changed.get("prefix_deleted") is not True or changed.get("value_verified") is not True
                or not isinstance(changed.get("expected_after"), str)
                or _ocr_line_sequence(changed["expected_after"]) != expected_sequence
                or _ocr_line_sequence(self.wechat_draft(changed)) != expected_sequence):
            raise Stopped("prefix_clear_unverified", "Prefix deletion/suffix preservation is unverified; no replay")
        final = self.wechat_read(expected_title=recipient)
        self.wechat_header(final, self.request["chat"])
        actual = self.wechat_draft(final)
        if _ocr_line_sequence(actual) != expected_sequence:
            raise Stopped("draft_changed", "Final complete suffix differs from the verified prefix deletion; no replay")
        self.edited_value = final
        return {"prefix_cleared": True, "suffix_preserved": True, "draft_empty": not actual,
                "draft_verified": True, "draft": actual, "sent": False,
                "verification_source": "complete_visible_suffix_with_layout_only_newline_normalization",
                "draft_value_semantics": "current visible OCR lines; physical newline boundaries are unverified"}

    def feishu_elements(self, tree):
        rows = list(tree["elements"])
        focused = tree.get("focused_element", {})
        if isinstance(focused, dict) and focused.get("element_id") and not any(r.get("element_id") == focused["element_id"] for r in rows):
            rows.append(focused)
        return [r for r in rows if not r.get("secure")]

    def feishu_read(self):
        self.status(strict=True)
        tree = self.inspect()
        window = _unique([w for w in tree["windows"] if w.get("title") == self.target["window_title"]], "Selected AX window is unavailable")
        if _rect(window) != self.frame:
            raise Stopped("target_geometry_changed", "Window geometry changed during this chat workflow")
        self.status(strict=True)
        return tree

    def feishu_composer(self, tree):
        rows = self.feishu_composer_candidates(tree)
        placeholders = [r for r in rows if _feishu_empty_name(r["value"]) is not None]
        return _unique(placeholders or rows, "Expected one identifiable message composer in the lower chat area")

    def feishu_composer_candidates(self, tree):
        return [r for r in self.feishu_elements(tree) if r.get("role") == "AXTextArea" and isinstance(r.get("value"), str)
                and _inside(r, _roi(self.frame, .22, .55, .78, .45))]

    def feishu_message_pane(self, tree):
        if self.feishu_composer_candidates(tree):
            return tree
        # The main window may be on 通讯录. Resolve its actual native navigation
        # control, then wait for the real message editor instead of requiring
        # the user/model to locate or switch the tab manually.
        controls = [r for r in self.feishu_elements(tree) if r.get("role") == "AXRadioButton"
                    and r.get("description") == "消息" and r.get("enabled", True) and "AXPress" in r.get("actions", [])]
        messages = _unique(controls, "Expected one current AX 消息 navigation control")
        self.call("press", element_id=messages["element_id"])
        deadline = time.monotonic() + 3
        while True:
            tree = self.feishu_read()
            if self.feishu_composer_candidates(tree):
                return tree
            if time.monotonic() >= deadline:
                raise Stopped("message_pane_unavailable", "消息 navigation completed, but no current message composer appeared; no replay")
            time.sleep(.12)

    def feishu_header(self, tree, wanted=None):
        composer = self.feishu_composer(tree)
        raw = composer["value"]
        name = _feishu_empty_name(raw)
        if name is not None:
            if wanted and not _label_matches(name, wanted):
                raise Stopped("recipient_mismatch", "Selected composer belongs to a different recipient")
            return name
        rect = _rect(composer)
        area = self.feishu_chat_area(tree)
        if area:
            bounds = _rect(area)
            region = {"x": bounds["x"], "y": bounds["y"], "width": bounds["width"] * .67, "height": min(56, bounds["height"])}
        else:
            region = {"x": rect["x"] - 8, "y": self.frame["y"], "width": min(rect["width"] + 16, self.frame["x"] + self.frame["width"] - rect["x"] + 8), "height": self.frame["height"] * .16}
        rows = [r for r in self.feishu_elements(tree) if r.get("role") in {"AXStaticText", "AXHeading"} and _inside(r, region)
                and _rect(r)["height"] > 2 and _rect(r)["width"] > 2 and _text(r) and _norm(_text(r)) not in {"智能体", "AI"}]
        if rows:
            name = min(rows, key=lambda r: _rect(r)["x"])
            name_rect = _rect(name)
            by_id = {r.get("element_id"): r for r in self.feishu_elements(tree)}
            def in_counter_button(row):
                for _ in range(4):
                    row = by_id.get(row.get("parent_id"), {})
                    if row.get("role") == "AXButton":
                        return True
                return False
            def header_counter(row):
                rect = _rect(row)
                siblings = not row.get("parent_id") or not name.get("parent_id") or row["parent_id"] == name["parent_id"] or in_counter_button(row)
                return row is not name and _norm(_text(row)).isdigit() and siblings and rect["x"] >= name_rect["x"] + name_rect["width"] - 2 \
                    and abs(_center(rect)[1] - _center(name_rect)[1]) <= max(rect["height"], name_rect["height"])
            def official_header_badge(row):
                # Match the observed grouped decoration, not arbitrary labels
                # or a recipient whose actual complete name is 官方.
                parent = by_id.get(row.get("parent_id"), {})
                if row is name or row.get("role") != "AXStaticText" or _text(row) != "官方" \
                        or parent.get("role") != "AXGroup" or in_counter_button(row):
                    return False
                try:
                    rect, group = _rect(row), _rect(parent)
                except Stopped:
                    return False
                right = name_rect["x"] + name_rect["width"]
                return 2 < rect["width"] <= 32 and 2 < rect["height"] <= 14 \
                    and rect["height"] <= name_rect["height"] * .8 \
                    and 0 < group["width"] <= 40 and 0 < group["height"] <= 20 \
                    and group["x"] <= rect["x"] and group["y"] <= rect["y"] \
                    and rect["x"] + rect["width"] <= group["x"] + group["width"] \
                    and rect["y"] + rect["height"] <= group["y"] + group["height"] \
                    and group["x"] >= right and right + 2 <= rect["x"] <= right + 128 \
                    and name_rect["y"] <= rect["y"] \
                    and rect["y"] + rect["height"] <= name_rect["y"] + name_rect["height"] \
                    and abs(_center(rect)[1] - _center(name_rect)[1]) <= 2
            rows = [row for row in rows if not header_counter(row)]
            official_badges = [row for row in rows if official_header_badge(row)]
            if len(official_badges) == 1:
                rows = [row for row in rows if row is not official_badges[0]]
        if wanted:
            rows = [r for r in rows if _label_matches(_text(r), wanted)]
        else:
            rows = [r for r in rows if _norm(_text(r)) not in {"聊天", "消息", "搜索", "发送"}]
        return _text(_unique(rows, "The current AX chat header cannot be identified uniquely"))

    def feishu_draft(self, tree):
        value = self.feishu_composer(tree)["value"]
        if _feishu_empty_name(value) is not None:
            return ""
        return value[:-len(STRUCTURE)] if value.endswith(STRUCTURE) else value.replace("\u200b", "").rstrip("\n")

    def feishu_locate(self, tree, wanted):
        if self.open_search_main:
            main_target, main_frame = self.open_search_main
            self.open_search_main = None
            return self.feishu_select_search(tree, wanted, main_target, main_frame)
        current = self.feishu_header(tree)
        kind = self.request.get("chat_kind", "any")
        if _label_matches(current, wanted) and (kind == "any" or self.kind_evidence and self.kind_evidence["kind"] == kind):
            self.title = current
            return tree
        if self.feishu_draft(tree):
            raise Stopped("draft_present", "The current chat has a draft; navigation stopped to preserve it")
        menu = [r for r in tree.get("menu_elements", []) if r.get("title") == "搜索" and r.get("enabled", True) and "AXPress" in r.get("actions", [])]
        buttons = [r for r in self.feishu_elements(tree) if r.get("role") == "AXButton"
                   and any(re.split(r"[（(]", r.get(k, ""), maxsplit=1)[0].strip() == "搜索" for k in ("title", "description"))
                   and r.get("enabled", True) and "AXPress" in r.get("actions", [])]
        search = _unique(menu or buttons, "A unique AX search control is required")
        self.call("press" if "AXPress" in search.get("actions", []) else "click", element_id=search["element_id"])
        _, modal = self.feishu_wait_search_modal(opened=True)
        main_target, main_frame = dict(self.target), dict(self.frame)
        self.target["window_title"], self.frame = modal["title"], _rect(modal)
        self.status(strict=True)
        search_tree = self.inspect()
        return self.feishu_select_search(search_tree, wanted, main_target, main_frame)

    def feishu_wait_search_modal(self, *, opened):
        deadline = time.monotonic() + 3
        while True:
            self.status(strict=True)
            tree = self.inspect(all_windows=True)
            matches = [w for w in tree["windows"] if w.get("title") == SEARCH_MODAL]
            if len(matches) > 1:
                raise Stopped("ambiguous_target", "The known Feishu search window is ambiguous")
            if bool(matches) == opened:
                return tree, matches[0] if matches else None
            if time.monotonic() >= deadline:
                raise Stopped("search_modal_timeout", "Known search-window visibility did not settle within the bounded read-only wait; no key/press replay")
            time.sleep(.12)

    def feishu_select_search(self, search_tree, wanted, main_target, main_frame):
        # The exact modal can be visible before its AX editor is rendered.
        # Wait only while no eligible input exists, retaining the same bound
        # PID/window/frame and strict foreground checks. Ambiguity or any
        # mutation failure still stops immediately without focus/input replay.
        deadline = time.monotonic() + 3
        while True:
            inputs = self.feishu_search_inputs(search_tree)
            if inputs or time.monotonic() >= deadline:
                break
            time.sleep(min(.12, max(0, deadline - time.monotonic())))
            search_tree = self.feishu_read()
        field = _unique(inputs, "The search modal input is ambiguous")
        raw = field["value"]
        query_value = _feishu_search_query(raw)
        suffix = SEARCH_STRUCTURE if query_value is not None or raw.endswith(SEARCH_STRUCTURE) else ""
        bound_search_editor = self.target.get("window_title") == SEARCH_MODAL and field.get("role") == "AXTextArea" and field.get("focused") is True
        if bound_search_editor and query_value is None:
            raise Stopped("search_serialization_unverified", "The complete focused search value has an unknown serialization; no input")
        current_query = query_value if query_value is not None else raw
        if current_query != wanted:
            if bound_search_editor:
                # One fresh, read-only preflight can observe the app's hint
                # arriving without accepting a different query or window.
                search_tree = self.feishu_read()
                field = _unique(self.feishu_search_inputs(search_tree), "The search modal input changed before typing")
                fresh_query = _feishu_search_query(field["value"])
                if fresh_query is None:
                    raise Stopped("search_serialization_unverified", "Fresh focused search value has an unknown serialization; no input")
                if field.get("role") != "AXTextArea" or field.get("focused") is not True or fresh_query != query_value:
                    raise Stopped("search_query_changed", "The actual focused editor or complete query changed before typing; no input")
                # Bind the full literal old value, including an observed hint.
                # Native skips Select-All for a genuinely empty query and
                # verifies one of the two complete final AX serializations.
                typed = self.call("type_text", element_id=field["element_id"], text=wanted, expected_value=wanted + SEARCH_STRUCTURE,
                                  replace_search=True, expected_before=field["value"])
                # Ownership requires this invocation's successful full-value
                # write. An already equal query, legacy editor or partial write
                # never authorizes failure cleanup.
                if typed.get("value_verified") is True and _feishu_search_query(typed.get("value")) == wanted:
                    self.owned_feishu_search = {"query": wanted, "pid": self.pid,
                        "modal_target": dict(self.target), "modal_frame": dict(self.frame),
                        "main_target": dict(main_target), "main_frame": dict(main_frame),
                        "field_frame": _rect(field),
                        "topology_generation": search_tree.get("display_topology_generation"),
                        "displays": search_tree.get("displays")}
            else:
                actions = [{"command": "click", "element_id": field["element_id"]}]
                if _norm(raw):
                    actions.append({"command": "clear_text", "element_id": field["element_id"], "expected_value": raw, "expected_empty_value": suffix})
                actions.append({"command": "type_text", "element_id": field["element_id"], "text": wanted, "expected_value": wanted + suffix})
                self.call("batch", actions=actions)
        # A few bounded read-only inspections accommodate result rendering. A
        # failed/ambiguous mutation is never retried.
        deadline = time.monotonic() + 3
        while True:
            results = self.feishu_read()
            ready = self.feishu_search_results_ready(results, wanted + suffix)
            matches = self.feishu_search_names(results, wanted) if ready else []
            kind = self.request.get("chat_kind", "any")
            if kind != "any":
                matches = [r for r in matches if (self.feishu_result_kind(results, r) or {}).get("kind") == kind]
            # Parent and child labels at the same geometry are one displayed
            # result; different result positions remain ambiguous.
            unique = {}
            for row in matches:
                unique.setdefault(tuple(_rect(row).values()), row)
            matches = list(unique.values())
            if matches or time.monotonic() >= deadline:
                break
            time.sleep(.12)
        selected = _unique(matches, "No unique exact Feishu search result")
        self.kind_evidence = self.feishu_result_kind(results, selected)
        self.call("click", element_id=selected["element_id"])
        self.owned_feishu_search = None
        self.target, self.frame = main_target, main_frame
        deadline = time.monotonic() + 3
        while True:
            tree = self.feishu_read()
            try:
                self.title = self.feishu_header(tree, wanted)
                return tree
            except Stopped as error:
                if error.code not in {"recipient_mismatch", "target_not_found", "ambiguous_target"} or time.monotonic() >= deadline:
                    raise
            time.sleep(.12)

    def feishu_close_owned_search(self):
        """Close one unchanged, verified own query; never repeat business input."""
        owned, self.owned_feishu_search = self.owned_feishu_search, None
        receipt = {"owned_search_cleanup_attempted": False, "owned_search_modal_closed": False,
                   "owned_search_cleanup_events_posted": 0}
        try:
            if (self.app != FEISHU or self.pid != owned["pid"] or self.target != owned["modal_target"]
                    or self.target.get("window_title") != SEARCH_MODAL or self.frame != owned["modal_frame"]):
                raise Stopped("search_cleanup_target_changed", "The owned search target changed; no cleanup")
            tree = self.feishu_read()
            if tree.get("truncated") is not False:
                raise Stopped("search_cleanup_ax_incomplete", "Complete search controls are unavailable; no cleanup")
            for key, expected in (("display_topology_generation", owned["topology_generation"]), ("displays", owned["displays"])):
                if expected is not None and tree.get(key) != expected:
                    raise Stopped("display_topology_changed", "Display topology changed; no cleanup")
            field = _unique(self.feishu_search_inputs(tree), "The owned search editor is not unique")
            focused = tree.get("focused_element", {})
            field_frame = _rect(field)
            if (field.get("role") != "AXTextArea" or field.get("focused") is not True
                    or field.get("enabled", True) is not True or field.get("secure") is True
                    or not isinstance(focused, dict) or focused.get("available") is not True
                    or focused.get("within_selected_window") is not True or focused.get("secure") is True
                    or focused.get("element_id") != field.get("element_id") or focused.get("role") != "AXTextArea"
                    or focused.get("value") != field.get("value") or _rect(focused) != field_frame
                    or any(field_frame[k] != owned["field_frame"][k] for k in ("x", "y", "height"))):
                raise Stopped("search_cleanup_focus_unverified", "The actual focused owned search editor changed; no cleanup")
            if _feishu_search_query(field["value"]) != owned["query"]:
                raise Stopped("search_cleanup_query_changed", "The complete owned query changed or has an unknown hint; no cleanup")
            self.status(strict=True)
            receipt["owned_search_cleanup_attempted"] = True
            receipt["owned_search_cleanup_events_posted"] = None
            closed = self.call("key", key="escape")
            count = closed.get("events_posted")
            if type(count) is int and 0 <= count <= 2:
                receipt["owned_search_cleanup_events_posted"] = count
            # The native Escape receipt proves event delivery only. Independently
            # verify the modal is absent and the original main frame survives;
            # native restoration still proves actual focus/origin identity.
            tree, _ = self.feishu_wait_search_modal(opened=False)
            main = _unique([w for w in tree["windows"] if w.get("title") == owned["main_target"]["window_title"]],
                           "The original Feishu main window is unavailable after cleanup")
            if _rect(main) != owned["main_frame"]:
                raise Stopped("target_geometry_changed", "The original main geometry changed; no focus recovery")
            self.target, self.frame = owned["main_target"], owned["main_frame"]
            self.status(strict=True)
            receipt.update(owned_search_modal_closed=True, owned_search_cleanup_reason="verified_owned_search_modal_closed")
        except Stopped as failure:
            count = failure.details.get("events_posted")
            if receipt["owned_search_cleanup_attempted"] and type(count) is int and 0 <= count <= 2:
                receipt["owned_search_cleanup_events_posted"] = count
            receipt["owned_search_cleanup_reason"] = failure.code[:128]
        return receipt

    def feishu_search_names(self, tree, wanted):
        rows = self.feishu_elements(tree)
        by_id = {row.get("element_id"): row for row in rows}
        def parents(item):
            chain = []
            for _ in range(16):
                item = by_id.get(item.get("parent_id"))
                if item is None:
                    break
                chain.append(item)
            return chain
        candidates = [r for r in rows if r.get("role") in {"AXStaticText", "AXRow", "AXButton"}
                      and _label_matches(_text(r), wanted) and _inside(r, _roi(self.frame, 0, .18, 1, .82)) and _rect(r)["height"] > 2]
        selected = []
        for row in candidates:
            if not row.get("parent_id"):
                # Older flat AX envelopes have no relationship evidence. Their
                # existing exact/visible uniqueness check remains authoritative.
                selected.append(row)
                continue
            chain = [row] + parents(row)
            owner = next((ancestor for ancestor in chain if ancestor.get("role") in {"AXGroup", "AXRow", "AXButton"}
                          and "AXPress" in ancestor.get("actions", []) and _inside(ancestor, self.frame) and _inside(row, _rect(ancestor))), None)
            if owner is None:
                continue
            # Actual result rows have a pressable title group inside a pressable
            # whole row. Inline descriptions share that whole row's ownership.
            while True:
                parent = by_id.get(owner.get("parent_id"), {})
                if (parent.get("role") not in {"AXGroup", "AXRow", "AXButton"} or "AXPress" not in parent.get("actions", [])
                        or not _inside(parent, self.frame)):
                    break
                owner = parent
            owner_id, container = owner.get("element_id"), owner.get("parent_id")
            texts = [text for text in rows if text.get("role") == "AXStaticText" and _text(text)
                     and _inside(text, _rect(owner)) and _rect(text)["height"] > 2
                     and any(parent.get("element_id") == owner_id for parent in parents(text))]
            title = min(texts, key=lambda text: (_rect(text)["y"], _rect(text)["x"])) if texts else row
            if _text(title) != _text(row) or _rect(title) != _rect(row):
                continue
            message_result = False
            for heading in rows:
                if heading.get("role") != "AXStaticText" or _norm(_text(heading)) != "消息" or not _inside(heading, self.frame):
                    continue
                branch = next((ancestor for ancestor in parents(heading) if ancestor.get("parent_id") == container), None)
                if (branch and "AXPress" not in branch.get("actions", [])
                        and _rect(heading)["y"] + _rect(heading)["height"] <= _rect(owner)["y"]):
                    message_result = True
                    break
            if not message_result:
                selected.append(row)
        return selected

    def feishu_result_kind(self, tree, row):
        name = _rect(row)
        rows = self.feishu_elements(tree)
        by_id = {r.get("element_id"): r for r in rows}
        def nearby_parents(item):
            ids = set()
            for _ in range(2):
                parent = item.get("parent_id")
                if not parent:
                    break
                ids.add(parent)
                item = by_id.get(parent, {})
            return ids
        for subtitle in rows:
            if subtitle.get("role") != "AXStaticText" or not _text(subtitle).startswith("群消息更新于"):
                continue
            if not _inside(subtitle, _roi(self.frame, 0, .18, 1, .82)):
                continue
            rect = _rect(subtitle)
            if rect["height"] <= 2 or abs(rect["x"] - name["x"]) > 16 or not name["y"] + name["height"] - 2 <= rect["y"] <= name["y"] + name["height"] + 56:
                continue
            if row.get("parent_id") and subtitle.get("parent_id") and not nearby_parents(row).intersection(nearby_parents(subtitle)):
                continue
            return {"kind": "group", "source": "AX_search_result_subtitle", "subtitle_prefix": "群消息更新于"}
        return None

    def feishu_search_results_ready(self, tree, expected_value):
        rows = self.feishu_elements(tree)
        inputs = self.feishu_search_inputs(tree)
        if len(inputs) > 1:
            raise Stopped("ambiguous_target", "The current search query input is ambiguous", {"matching_count": len(inputs)})
        result_region = _roi(self.frame, 0, .12, 1, .88)
        if not inputs:
            return False
        expected_query = _feishu_search_query(expected_value)
        actual = inputs[0]["value"]
        if (_feishu_search_query(actual) != expected_query if expected_query is not None else actual != expected_value):
            return False
        historical = {"历史", "搜索历史", "历史记录", "最近搜索", "猜你想搜", "常用"}
        if any(_norm(_text(r)) in historical and _inside(r, result_region) and _rect(r)["height"] > 2 for r in rows):
            return False
        # Observed query-result mode exposes native category buttons. A keyword
        # in the previous history/common list is not a chat result merely because
        # typing already updated the search field.
        categories = {_text(r) for r in rows if r.get("role") == "AXButton" and _text(r) in {"消息", "联系人", "群组"}
                      and "AXPress" in r.get("actions", []) and _inside(r, result_region)}
        return len(categories) >= 2

    def feishu_search_inputs(self, tree):
        inputs = [r for r in self.feishu_elements(tree) if r.get("role") in {"AXComboBox", "AXTextField", "AXTextArea", "AXSearchField"}
                  and isinstance(r.get("value"), str) and _inside(r, _roi(self.frame, 0, 0, 1, .50))]
        focused = [r for r in inputs if r.get("focused") is True]
        return focused or inputs

    def feishu_edit(self, tree, action=None):
        before = self.feishu_draft(tree)
        action = action or self.request["action"]
        if action == "draft" and before:
            raise Stopped("draft_present", "Composer is not empty; the existing draft was preserved")
        if action == "clear" and before != self.request["expected_draft"]:
            raise Stopped("draft_changed", "AX composer does not equal expected_draft; no clear events")
        if action == "clear" and not before:
            return {"draft_empty": True, "draft_verified": True, "sent": False,
                    "empty_value": self.feishu_composer(tree)["value"], "verification_source": "current_AX_exact_known_empty_serialization"}
        # This ID comes from a tree acquired in the current invocation (or the
        # fresh post-navigation tree). Read the exact current value cheaply;
        # native wait_text's substring matched flag alone is never sufficient.
        self.feishu_header(tree, self.title)
        composer = self.feishu_composer(tree)
        current = self.call("wait_text", element_id=composer["element_id"], text=composer["value"], timeout_ms=0)
        if current.get("value") != composer["value"]:
            raise Stopped("draft_changed", "The AX draft changed before editing")
        empty = "发送给 " + self.title + "\n" + STRUCTURE
        expected = self.request["text"] if action == "draft" else ""
        expected_value = expected + STRUCTURE if expected else empty
        if len(expected_value) > 4000:
            raise Stopped("text_readback_limit", "Complete Feishu AX serialization exceeds the native 4000-character readback bound; no input")
        if action == "draft":
            if _feishu_empty_name(composer["value"]) != self.title:
                raise Stopped("composer_serialization_unknown", "The composer does not match the verified Feishu empty serialization")
            actions = [{"command": "click", "element_id": composer["element_id"]},
                       {"command": "type_text", "element_id": composer["element_id"], "text": expected, "expected_value": expected_value}]
        else:
            actions = [{"command": "clear_text", "element_id": composer["element_id"],
                        "expected_value": composer["value"], "expected_empty_value": empty}]
        actions.append({"command": "wait_text", "element_id": composer["element_id"], "text": expected_value, "timeout_ms": 1000})
        try:
            completed = self.call("batch", actions=actions)
        except Stopped as error:
            if (action == "clear" and error.code == "postcondition_failed" and error.details.get("events_posted", 0) > 0
                    and error.details.get("clear_state_uncertain") is True
                    and "backspace_events_posted" in error.details.get("completed_steps", [])):
                return self.feishu_verify_cleared()
            raise
        results = completed.get("results", [])
        final = results[-1].get("result", {}) if results and results[-1].get("command") == "wait_text" else {}
        if final.get("value") != expected_value:
            if action == "clear":
                return self.feishu_verify_cleared()
            raise Stopped("draft_unverified", "Final AX composer differs from the exact expected serialization; no replay")
        self.status(strict=True)
        answer = {"draft_empty": not expected, "draft_verified": True, "draft": expected, "sent": False}
        if action == "clear":
            answer.update(empty_value=final["value"], verification_source="exact_full_AX_readback")
        return answer

    def feishu_verify_cleared(self):
        # A posted clear is never replayed. Independently acquire current AX,
        # checking PID, frame, foreground, exact recipient and the entire value.
        tree = self.feishu_read()
        self.feishu_header(tree, self.title)
        value = self.feishu_composer(tree)["value"]
        if _feishu_empty_name(value) != self.title:
            raise Stopped("clear_unverified", "Fresh AX does not equal a complete known empty serialization for the same recipient; no replay")
        return {"draft_empty": True, "draft_verified": True, "draft": "", "sent": False,
                "empty_value": value, "verification_source": "fresh_AX_exact_known_empty_serialization"}

    def send_once(self, value):
        text = self.request["text"]
        before = self.draft_value(value)
        if before not in {"", text}:
            raise Stopped("draft_present", "A different existing draft was preserved; no send or overwrite")
        before_occurrences = sum(_norm(row["text"]) == _norm(text) for row in self.visible_rows(value))
        written_here = False
        typed_receipt, draft_proof = None, None
        if not before:
            if self.app == WECHAT:
                self.wechat_edit(value, action="draft")
                written_here = True
                value = self.edited_value
                typed_receipt, draft_proof = self.edited_input_receipt, value
            else:
                self.feishu_edit(value, action="draft")
                value = self.refresh()
        if self.draft_value(value) != text:
            raise Stopped("draft_changed", "The exact authorized message is no longer the complete draft; no send")
        self.status(strict=True)
        if self.app == WECHAT:
            region = self.wechat_regions()["composer"]
            # Only this invocation's complete post-edit native proof can avoid
            # a duplicate focus click. Native Return independently revalidates
            # the retained control/revision, full draft and recipient.
            retained = (written_here and value.get("input_control_focus_retained") is True
                        and value.get("edit_recipient_verified") is True
                        and value.get("edit_recipient") == self.title
                        and value.get("edit_proof_snapshot_id") == value.get("snapshot_id")
                        and value.get("ocr_scope") == "post_action_recipient_and_complete_composer"
                        and value.get("read_only_background") is False
                        and value.get("target_identity_verified") is True
                        and value.get("input_eligible") is True
                        and self.wechat_complete_composer_capture(value))
            self.send_focus_reused = retained
            if retained:
                clicked = value
            else:
                x, y = _center(region)
                clicked = self.visual_identity(self.call("visual_click", **self.visual_args(value, "chat_composer", region), x=x, y=y))
            if self.wechat_draft(clicked) != text:
                raise Stopped("draft_changed", "Composer changed while focusing; no submit events")
            self.submit_started = True
            submitted = self.call("visual_key", **self.visual_args(clicked, "chat_composer", region), key="return",
                                  allow_submit=True, expected_message=text, chat_title=self.title)
        else:
            self.feishu_header(value, self.title)
            composer = self.feishu_composer(value)
            area = self.feishu_chat_area(value)
            if area is None:
                raise Stopped("recipient_unverified", "Sending requires the actual messenger-chat header and composer")
            bounds = _rect(area)
            band = {**bounds, "width": bounds["width"] * .67, "height": min(56, bounds["height"])}
            headers = [row for row in self.feishu_elements(value) if row.get("role") == "AXStaticText"
                       and _text(row) == self.title and _inside(row, band) and _rect(row)["height"] > 2]
            recipient = _unique(headers, "Exact current AX recipient header is ambiguous; no send")
            self.call("click", element_id=composer["element_id"])
            self.submit_started = True
            submitted = self.call("submit_text", element_id=composer["element_id"], recipient_element_id=recipient["element_id"],
                                  expected_recipient=self.title, expected_value=composer["value"],
                                  expected_empty_value="发送给 " + self.title + "\n" + STRUCTURE, allow_submit=True)
        if submitted.get("submit_events_posted") is not True or submitted.get("submit_preconditions_verified") is not True:
            raise Stopped("send_state_unknown", "Submission completion/preconditions are unknown; never replay")
        self.submit_posted = True
        event_timing = None
        # Posting Return is not a send result. Observe this same PID/title and
        # full composer plus increased exact message occurrence in the body.
        deadline = time.monotonic() + 5
        while True:
            value = self.refresh()
            draft = self.draft_value(value)
            rows = self.visible_rows(value)
            visible = "\n".join(row["text"] for row in rows)
            occurrences = sum(_norm(row["text"]) == _norm(text) for row in rows)
            if not draft and occurrences > before_occurrences:
                self.send_verified = True
                if written_here:
                    event_timing = self.wechat_verified_send_timing(typed_receipt, draft_proof, submitted, value)
                break
            if draft not in {"", text}:
                raise Stopped("draft_changed", "Composer changed after submission; send state is uncertain and no replay is allowed")
            if time.monotonic() >= deadline:
                return {"sent": None, "send_verified": False, "submission_state": "posted_unverified", "submit_events_posted": True,
                        "delivery_verified": False, "draft_preserved": True, "visible_text": visible, "rows": rows,
                        "reply_evidence": {"sender_verified": False, "new_since_request": None, "requested_text_visible": False}}
            time.sleep(.12)
        echo_baseline = visible
        observation = self.observe_reply(value, baseline=echo_baseline, timeout_ms=self.request.get("wait_timeout_ms", 0))
        result = {**observation, "sent": True, "send_verified": True, "submission_state": "observed_in_chat",
                "submit_events_posted": True, "delivery_verified": False,
                "draft_empty": None if observation.get("current_recipient_verified") is False else True,
                "send_verification_source": "fresh_same_chat_empty_composer_and_increased_complete_exact_text_row_occurrence",
                "reply_baseline_text": echo_baseline}
        if event_timing is not None:
            result["send_event_timing"] = event_timing
        return result

    def wechat_verified_send_timing(self, typed, draft_proof, submitted, observed):
        # Called only after the existing full empty-composer + increased exact
        # bubble occurrence check. Missing old-helper data only omits metadata.
        if (self.app != WECHAT or self.send_verified is not True or not isinstance(typed, dict)
                or typed.get("value_verified") is not True or type(typed.get("events_posted")) is not int
                or typed["events_posted"] <= 0 or submitted.get("submit_events_posted") is not True
                or submitted.get("submit_preconditions_verified") is not True
                or type(submitted.get("events_posted")) is not int or submitted["events_posted"] != 2):
            return None
        type_times = _input_event_times(typed.get("input_event_timing"), "unicode")
        submit_times = _input_event_times(submitted.get("input_event_timing"), "submit_return")
        if type_times is None or submit_times is None:
            return None
        for key in ("target_pid", "window_id", "display_topology_signature"):
            binding = typed.get(key)
            if (key == "display_topology_signature" and (not isinstance(binding, str) or not binding)
                    or key != "display_topology_signature" and (type(binding) is not int or binding <= 0)
                    or any(source.get(key) != binding for source in (draft_proof, submitted, observed))):
                return None
        if typed["target_pid"] != self.pid:
            return None
        try:
            if (not self.wechat_complete_composer_capture(draft_proof) or not self.wechat_complete_composer_capture(observed)
                    or _norm(self.wechat_header(observed)) != _norm(self.title)):
                return None
        except Stopped:
            return None
        draft_stamp = draft_proof.get("observation_materialized_uptime_ms")
        final_stamp = observed.get("observation_materialized_uptime_ms")
        if any(type(t) not in {int, float} or not 0 <= t <= 10**12 or not math.isfinite(t) for t in (draft_stamp, final_stamp)):
            return None
        complete_draft = max(type_times[2], draft_stamp)
        if (draft_stamp < type_times[1] or not type_times[2] <= complete_draft <= submit_times[0]
                or not submit_times[2] <= final_stamp or final_stamp - type_times[0] > 120_000):
            return None
        timing = {"clock": "system_uptime_ms",
                  "input_finished_to_submit_ms": round(submit_times[0] - type_times[1], 3),
                  "complete_draft_verified_to_submit_ms": round(submit_times[0] - complete_draft, 3),
                  "submit_dispatch_ms": round(submit_times[1] - submit_times[0], 3),
                  "submit_to_verified_observation_ms": round(final_stamp - submit_times[1], 3)}
        for source, name in ((typed, "continuous_submit_proof_prepared"), (submitted, "continuous_submit_proof_reused")):
            if type(source.get(name)) is bool:
                timing[name] = source[name]
        proof_age = submitted.get("continuous_submit_proof_frame_age_ms")
        if type(proof_age) in {int, float} and math.isfinite(proof_age) and 0 <= proof_age <= 1000:
            timing["continuous_submit_proof_frame_age_ms"] = round(proof_age, 3)
        return timing

    def observe_reply(self, value, *, baseline=None, timeout_ms=0):
        original_draft = self.draft_value(value)
        marker = self.request.get("reply_contains")
        started = time.monotonic()
        deadline = started + timeout_ms / 1000
        transient_headers = 0
        baseline_counts = Counter(_norm(line) for line in baseline.splitlines() if _norm(line)) if baseline is not None else Counter()
        while True:
            rows = self.visible_rows(value)
            visible = "\n".join(row["text"] for row in rows)
            changed = baseline is not None and _norm(visible) != _norm(baseline)
            remaining = baseline_counts.copy()
            new_rows = []
            if changed:
                for row in rows:
                    key = _norm(row["text"])
                    if remaining[key]:
                        remaining[key] -= 1
                    else:
                        new_rows.append(row)
            new_text = "\n".join(row["text"] for row in new_rows)
            evidence_text = new_text if baseline is not None else visible
            matched = bool(marker and _norm(marker) in _norm(evidence_text))
            ready = matched if marker else (bool(new_rows) if baseline is not None else True)
            if ready or time.monotonic() >= deadline:
                break
            time.sleep(min(.12, max(0, deadline - time.monotonic())))
            while True:
                try:
                    value = self.refresh()
                    break
                except Stopped as error:
                    if not (self.app == WECHAT and self.send_verified and error.code == "target_not_found"
                            and error.details.get("header_status") == "typing"):
                        raise
                    # Do not read reply text under an unverified recipient or
                    # replay input. Keep the original wait deadline and require
                    # the complete actual title to return before using any rows.
                    transient_headers += 1
                    if time.monotonic() >= deadline:
                        return {"reply_observation_state": "pending_typing", "reply_header_status": "typing",
                                "recipient_verified": False, "current_recipient_verified": False,
                                "draft_preserved": None, "observation_timed_out": True,
                                "observation_waited_ms": round((time.monotonic() - started) * 1000, 3),
                                "observation_transient_header_count": transient_headers,
                                "reply_evidence": {"requested_text_visible": None,
                                                   "requested_text_visible_in_current_view": None,
                                                   "newly_visible_since_baseline": None, "sender_verified": False,
                                                   "new_since_request": None, "new_reply_verified": False,
                                                   "source": "recipient_header_temporarily_unavailable"}}
                    time.sleep(min(.12, max(0, deadline - time.monotonic())))
            if self.draft_value(value) != original_draft:
                raise Stopped("draft_changed", "Draft changed during response observation; no further input or replay")
        result = {"visible_text": visible, "rows": rows, "visible_rows_returned": len(rows),
                  "truncated": bool(value.get("truncated") or value.get("ocr_truncated")), "complete_history": False,
                  "position": "current_visible_viewport", "draft_preserved": True,
                  "baseline_provided": baseline is not None, "visible_text_changed": changed,
                  "new_visible_text": new_text, "new_visible_lines": [row["text"] for row in new_rows],
                  "observation_waited_ms": round((time.monotonic() - started) * 1000, 3),
                  "observation_transient_header_count": transient_headers,
                  "observation_timed_out": not ready,
                  "message_semantics": "visible text differences; message boundaries, sender, direction and actual message newness are unverified"}
        if marker or baseline is not None:
            result["reply_evidence"] = {"requested_text_visible": matched if marker else bool(new_rows),
                                        "requested_text_visible_in_current_view": bool(marker and _norm(marker) in _norm(visible)),
                                        "newly_visible_since_baseline": bool(new_rows), "sender_verified": False,
                                        "new_since_request": None, "new_reply_verified": False,
                                        "source": "normalized_visible_text_difference" if baseline is not None else "current_visible_message_area"}
        return result

    def visible_rows(self, value):
        if self.app == WECHAT:
            panel = self.wechat_details_panel(value)
            rows = [{"text": _text(r), "bounds": _rect(r), "source": "local_OCR"} for r in value["ocr"] if _text(r) and _inside(r, self.wechat_regions()["body"])
                    and (panel is None or _center(_rect(r))[0] < panel["region"]["x"])]
        else:
            body = self.feishu_body_region(value)
            rows = [{"text": _text(r), "bounds": _rect(r), "element_id": r["element_id"], "source": "AX"} for r in self.feishu_elements(value)
                    if r.get("role") == "AXStaticText" and _text(r) and _inside(r, body) and _rect(r)["height"] > 2 and _rect(r)["width"] > 2]
        seen, result = set(), []
        for row in sorted(rows, key=lambda r: (_rect(r)["y"], _rect(r)["x"])):
            key = (_text(row), tuple(_rect(row).values()))
            if key not in seen:
                seen.add(key)
                result.append(row)
        return result

    def feishu_chat_area(self, tree):
        areas = [r for r in self.feishu_elements(tree) if r.get("role") == "AXWebArea" and r.get("title") == "messenger-chat"]
        return _unique(areas, "The current messenger-chat WebArea is ambiguous") if areas else None

    def feishu_body_region(self, tree):
        composer = _rect(self.feishu_composer(tree))
        area = self.feishu_chat_area(tree)
        bounds = _rect(area) if area else {"x": composer["x"] - 8, "y": self.frame["y"],
                                          "width": composer["width"] + 16, "height": self.frame["height"]}
        left = max(bounds["x"], self.frame["x"])
        right = min(bounds["x"] + bounds["width"], self.frame["x"] + self.frame["width"])
        top = max(bounds["y"] + min(56, bounds["height"]), self.frame["y"]) if area else max(bounds["y"], self.frame["y"] + self.frame["height"] * .16)
        bottom = min(bounds["y"] + bounds["height"], composer["y"] - 12)
        if right <= left or bottom <= top:
            raise Stopped("geometry_unavailable", "Current message body geometry is empty")
        return {"x": left, "y": top, "width": right - left, "height": bottom - top}

    def feishu_history_scroll(self, tree, rows):
        if any(r.get("role") in {"AXSheet", "AXDialog", "AXPopover"} or r.get("subrole") == "AXDialog" for r in tree["elements"]):
            raise Stopped("pending_dialog", "A dialog/popover is present; history navigation stopped")
        area = self.feishu_chat_area(tree)
        if area is None:
            candidates = [r for r in self.feishu_elements(tree) if r.get("role") == "AXScrollArea" and any(_inside(row, _rect(r)) for row in rows)
                          and not _inside(self.feishu_composer(tree), _rect(r))]
            if not candidates:
                return None
            smallest = min(_rect(r)["width"] * _rect(r)["height"] for r in candidates)
            area = _unique([r for r in candidates if _rect(r)["width"] * _rect(r)["height"] == smallest], "AX history scroll area is ambiguous")
        body = self.feishu_body_region(tree)
        container = _rect(area)
        anchors = [row for row in rows if _inside(row, body) and _inside(row, container)]
        if not anchors:
            raise Stopped("history_safe_point_unavailable", "No currently displayed StaticText lies inside the actual chat body")
        point = _center(anchors[len(anchors) // 2]["bounds"])
        # Native scroll verifies current AX hit, PID/window/display, foreground
        # and CG occlusion. It posts a wheel at this point, never a click or key;
        # an incomplete tree therefore cannot trigger an unseen message link.
        return {"command": "scroll", "x": point[0], "y": point[1], "delta_y": 4}

    def refresh(self):
        expected_title = self.title
        value = self.wechat_read(expected_title=expected_title) if self.app == WECHAT else self.feishu_read()
        title = self.wechat_header(value, expected_title) if self.app == WECHAT else self.feishu_header(value, expected_title)
        if not _label_matches(title, expected_title):
            raise Stopped("recipient_mismatch", "Selected chat changed during reading")
        return value

    def draft_value(self, value):
        return self.wechat_draft(value) if self.app == WECHAT else self.feishu_draft(value)

    def history_page(self, value, index):
        body = self.wechat_regions()["body"] if self.app == WECHAT else self.feishu_body_region(value)
        raw = self.visible_rows(value)
        kept, clipped = [], []
        for i, row in enumerate(raw):
            rect = _rect(row)
            if (rect["x"] < body["x"] - 1 or rect["x"] + rect["width"] > body["x"] + body["width"] + 1
                    or rect["y"] <= body["y"] + 1 or rect["y"] + rect["height"] >= body["y"] + body["height"] - 1
                    or rect["height"] <= 2):
                clipped.append(i)
            else:
                kept.append(row)
        return kept, {"page_index": index, "body_region": body, "rows": raw,
                      "clipped_row_indices": clipped, "rows_used": len(kept),
                      "source_truncated": bool(value.get("truncated") or value.get("ocr_truncated"))}

    def history(self, value):
        original_draft = self.draft_value(value)
        requested = self.request.get("pages", 3)
        rows, evidence = self.history_page(value, 0)
        evidence["changed_viewport"] = True
        pages = [evidence]
        def entries(items, page_index, offset):
            return [{"row": {**row, "page_index": page_index}, "y": _center(_rect(row))[1] + offset,
                     "x": _center(_rect(row))[0]} for row in items]
        previous_entries, previous_offset = entries(rows, 0, 0), 0
        groups, page_rows = [list(previous_entries)], [rows]
        overlaps, reason = 0, "page_limit"
        page_overlaps, alignments = [], []
        any_truncation = bool(value.get("truncated") or value.get("ocr_truncated"))
        for _ in range(1, requested):
            if not rows:
                reason = "no_visible_navigation_anchor"
                break
            if self.app == WECHAT:
                anchor = rows[len(rows) // 2]
                x, y = _center(anchor["bounds"])
                self.call("visual_scroll", **self.visual_args(value, "navigation", self.wechat_regions()["body"]),
                          x=x, y=y, delta_y=12, target_text=anchor["text"][:128])
            else:
                scroll = self.feishu_history_scroll(value, rows)
                if scroll is None:
                    reason = "scroll_control_unavailable"
                    break
                self.call("scroll", x=scroll["x"], y=scroll["y"], delta_y=scroll["delta_y"])
            value = self.refresh()
            current_draft = self.draft_value(value)
            if current_draft != original_draft:
                details = {"original_draft": original_draft, "current_draft": current_draft}
                if self.app == WECHAT:
                    details["current_composer_ocr"] = [{"text": _text(row), "bounds": _rect(row)} for row in value["ocr"]
                                                       if _inside(row, self.wechat_regions()["composer"])]
                raise Stopped("draft_changed", "Draft changed while reading history; pagination stopped", details)
            rows, evidence = self.history_page(value, len(pages))
            any_truncation |= bool(value.get("truncated") or value.get("ocr_truncated"))
            changed = [_norm(_text(r)) for r in rows] != [_norm(_text(r)) for r in page_rows[-1]]
            evidence["changed_viewport"] = changed
            pages.append(evidence)
            if not changed:
                reason = "viewport_unchanged"
                break
            alignment = _history_alignment(rows, page_rows[-1])
            page_rows.append(rows)
            if alignment["verified"]:
                offset = previous_offset - alignment["row_shift_y"]
                matched = {pair["older_index"]: previous_entries[pair["newer_index"]] for pair in alignment["row_matches"]}
                current_entries = []
                for i, row in enumerate(rows):
                    if i in matched:
                        current_entries.append(matched[i])
                    else:
                        item = entries([row], evidence["page_index"], offset)[0]
                        current_entries.append(item)
                        groups[0].append(item)
                groups[0].sort(key=lambda item: (item["y"], item["x"]))
                removed = len(matched)
            else:
                current_entries, offset = entries(rows, evidence["page_index"], 0), 0
                groups.insert(0, list(current_entries))
                removed = 0
            previous_entries, previous_offset = current_entries, offset
            alignments.append(alignment)
            overlaps += removed
            page_overlaps.append(removed)
        continuous = bool(alignments) and all(alignment["verified"] for alignment in alignments)
        uncertain_edges = any(alignment.get("older_tail_unaligned", 0) or alignment.get("newer_head_unaligned", 0)
                              or alignment.get("interior_rows_unaligned", 0) or alignment.get("ambiguous_row_pairs_preserved", 0) for alignment in alignments)
        combined = [item["row"] for group in groups for item in group]
        return {"visible_text": "\n".join(r["text"] for r in combined), "rows": combined, "pages_read": len(page_rows),
                "pages": pages, "viewports_observed": len(pages), "page_alignments": alignments,
                "visible_rows_returned": len(combined),
                "pages_requested": requested, "overlap_rows_removed": overlaps, "stop_reason": reason,
                "page_overlap_rows": page_overlaps, "coverage_contiguous": continuous,
                "gaps_possible": not continuous or any_truncation or uncertain_edges,
                "coverage_basis": "a unique downward row translation anchored by at least two contiguous exact normalized rows; only one-to-one exact rows are merged, source completeness is separate",
                "truncated": True, "source_truncated": any_truncation, "complete_history": False,
                "position": "oldest_inspected_visible_page", "viewport_restored": False, "draft_preserved": True,
                "message_semantics": "visible text rows; message boundaries, sender and direction are unverified"}

    def background_edit(self):
        # The native owner binds, edits and completely rereads in one command.
        # No outer full-tree/visual read and no compatibility input replay.
        if self.request.get('chat_kind','any')!='any':
            raise Stopped('background_chat_kind_unverified','Atomic background editing requires current kind evidence; no input')
        self.target['window_title']=self.request.get('window_title','微信' if self.app==WECHAT else '飞书')
        action=self.request['action'];expected=self.request['text'] if action=='draft' else ''
        args={'operation':'type' if action=='draft' else 'clear'}
        if action=='draft':args['text']=expected
        else:args['expected_draft']=self.request['expected_draft']
        if self.request.get('chat'):args['chat_title']=self.request['chat']
        result=self.call('background_chat_edit',**args)
        isolated=(result.get('foreground_preserved') is True or
                  result.get('focus_isolated') is True and result.get('activated_foreground') is False)
        if (result.get('atomic_chat_edit') is not True or result.get('value_verified') is not True
                or result.get('recipient_verified') is not True or result.get('composer_complete') is not True
                or not isinstance(result.get('chat_title'),str) or not result['chat_title']
                or result.get('draft_text')!=expected or not isinstance(result.get('draft_value'),str)
                or result.get('draft_empty')!=(expected=='') or not isolated):
            raise Stopped('background_postcondition_unknown','Complete actual draft, recipient and system-focus evidence are required; no replay')
        self.title=result['chat_title']
        return {'chat_title':self.title,'recipient_verified':True,'background':True,
                'draft_empty':not expected,'draft_verified':True,'draft':result['draft_text'],
                'draft_value':result['draft_value'],'sent':False,
                'focus_attempted':False,'foreground_preserved':result.get('foreground_preserved') is True,
                'focus_isolated':isolated,'activated_foreground':False,
                'external_focus_change_detected':result.get('external_focus_change_detected') is True,
                'events_posted':result.get('events_posted'),'input_route':result.get('input_route'),
                'ax_actions_attempted':result.get('ax_actions_attempted',0),
                'ax_menu_actions_attempted':result.get('ax_menu_actions_attempted',0),
                'ax_composer_focus_actions_attempted':result.get('ax_composer_focus_actions_attempted',0),
                'temporary_clipboard_used':result.get('temporary_clipboard_used',False),
                'clipboard_restored':result.get('clipboard_restored',False),
                'clipboard_external_change':result.get('clipboard_external_change',False),
                'clipboard_isolated':result.get('clipboard_isolated',False),
                'verification_source':result.get('verification_source'),'atomic_chat_edit':True,
                'native_stage_ms':result.get('native_stage_ms',{}),'pointer_preserved':result.get('pointer_preserved'),
                'foreign_pointer_events_allowed':result.get('foreign_pointer_events_allowed',0)}

    def run(self):
        if self.request.get("background") is True:
            return self.background_edit()
        value = self.start()
        desired = self.request.get("chat")
        if self.app == WECHAT:
            value = self.wechat_locate(value, desired) if desired else value
            self.title = self.wechat_header(value, desired)
            requested_kind = self.request.get("chat_kind", "any")
            # Search frequency proves a local destination but not person/group.
            # Fresh title member counts can add positive group evidence after
            # navigation; specific-kind edits require evidence before input.
            self.wechat_header_group(value, desired or re.sub(r"[（(]\d+[)）]$", "", self.title))
            actual_kind = self.kind_evidence["kind"] if self.kind_evidence else "unknown"
            if requested_kind != "any" and actual_kind not in {"unknown", requested_kind}:
                raise Stopped("chat_kind_mismatch", "The fresh chat kind evidence does not match the requested kind", {"requested_kind": requested_kind, "observed_kind": actual_kind})
            if self.request["action"] in {"draft", "clear", "clear_prefix", "send"} and requested_kind != "any" and actual_kind == "unknown":
                raise Stopped("chat_kind_unverified", "The requested chat kind is unverified; no draft/clear events")
        else:
            value = self.feishu_locate(value, desired) if desired else value
            self.title = self.feishu_header(value, desired)
        action = self.request["action"]
        common = {"app": self.app, "action": action, "chat_title": self.title, "target_pid": self.pid,
                  "window_title": self.target["window_title"], "recipient_verified": True,
                  "chat_kind_requested": self.request.get("chat_kind", "any"), "chat_kind_verified": False,
                  "sent": False, "automatic_replay_allowed": False}
        if self.kind_evidence:
            common.update(chat_kind_verified=self.kind_evidence["kind"] != "unknown", chat_kind_evidence=self.kind_evidence)
        if action in {"draft", "clear", "clear_prefix", "send"} and self.request.get("chat_kind", "any") != "any":
            if not self.kind_evidence or self.kind_evidence["kind"] != self.request["chat_kind"]:
                raise Stopped("chat_kind_unverified", "A specific chat kind requires positive evidence before draft/clear/send events")
        if action == "locate":
            return {**common, "located": True, "draft_preserved": True}
        if action == "send":
            return {**common, **self.send_once(value)}
        if action == "clear_prefix":
            return {**common, **self.wechat_clear_prefix(value)}
        if action in {"draft", "clear"}:
            return {**common, **(self.wechat_edit(value) if self.app == WECHAT else self.feishu_edit(value))}
        if action == "history":
            return {**common, **self.history(value)}
        baseline = self.request.get("baseline_text", self.request.get("previous_visible_text"))
        return {**common, **self.observe_reply(value, baseline=baseline, timeout_ms=self.request.get("wait_timeout_ms", 0))}


def execute_chat(request, invoke_native, *, recipe_store=None):
    if isinstance(request, dict) and request.get("action") == "observe":
        from desktop_observation import execute_observation
        return execute_observation({k: v for k, v in request.items() if k != "action"}, invoke_native)
    started = time.monotonic()
    session = None
    outcome_error = Stopped("operation_completion_unknown", "Business completion is unknown")
    restoration = {}
    try:
        _validate(request)
        session = ChatSession(request, invoke_native)
        result = session.run()
        answer = {"ok": True, "result": result}
        outcome_error = None
    except Exception as failure:
        error = failure if isinstance(failure, Stopped) else Stopped(
            "operation_completion_unknown", "Chat completion is unknown; no automatic replay",
            {"exception_type": type(failure).__name__})
        outcome_error = error
        sent = True if session and session.send_verified else None if session and session.submit_started else False
        if session and session.submit_started and not session.submit_posted and (error.details.get("submit_events_posted") is False or error.details.get("events_posted") == 0):
            sent = False
        answer = {"ok": False, "error": {"code": error.code, "message": str(error), "details": error.details},
                  "sent": sent, "automatic_replay_allowed": False}
        if session and session.submit_started:
            answer["submission_state"] = "observed_in_chat" if session.send_verified else "not_posted" if sent is False else "unknown"
    finally:
        if session:
            try:
                restoration = session.finish_focus(outcome_error)
            except Exception as failure:
                restoration = {"focus_restored": False, "focus_restore_attempted": None,
                               "restore_reason": "focus_finalization_unknown",
                               "focus_finalization_exception_type": type(failure).__name__}
    answer.update(restoration)
    if session and session.app == FEISHU and session.focus_attempted:
        business_completed = answer["ok"]
        restored = restoration.get("focus_restored") is True
        yielded = restoration.get("restore_reason") in {"user_interrupted", "user_takeover", "new_user_activity"}
        answer.update(focus_claim_verified=session.focus_claim_verified,
                      focus_claim_receipt=session.focus_claim_receipt,
                      focus_return_required=session.focus_claim_verified or session.focus_restore_requested,
                      focus_restore_requested=session.focus_restore_requested,
                      focus_lifecycle="restored" if restored else "yielded_to_user" if yielded else "unverified",
                      business_completed=business_completed, scope_completed=business_completed and restored)
        if isinstance(answer.get("result"), dict):
            answer["result"].update(restoration)
        if business_completed and not restored:
            # The business proof remains valid, but the full foreground scope
            # did not finish. Expose that failure instead of silently returning
            # ok from a native ok:true/restored:false receipt. Never replay.
            answer.update(ok=False, automatic_replay_allowed=False,
                          error={"code": "user_interrupted" if yielded else "focus_restore_unverified",
                                 "message": "Business completed; focus yielded to the user" if yielded else "Business completed; the saved focus return is unverified. Do not replay input or reclaim focus",
                                 "details": {"business_completed": True, "focus_return_required": True,
                                             "restore_reason": restoration.get("restore_reason", "restore_unverified")}})
            if session.submit_started:
                answer.update(sent=True if session.send_verified else answer["result"].get("sent"),
                              send_verified=session.send_verified,
                              submission_state=answer["result"].get("submission_state", "unknown"))
    elapsed = round((time.monotonic() - started) * 1000, 3)
    answer["elapsed_ms"] = elapsed
    if session:
        answer["native_calls"] = len(session.calls)
        if request.get("action") == "send" and session.app == WECHAT:
            answer["send_focus_reused"] = session.send_focus_reused
        answer["commands"] = [x["command"] for x in session.calls]
        answer["native_timings"] = session.native_timings
        answer["native_timings_count"] = session.native_timings_count
        answer["native_timings_truncated"] = session.native_timings_count > len(session.native_timings)
        if session.navigation_recovery is not None:
            answer["navigation_recovery"] = session.navigation_recovery
        if session.clear_recovery is not None:
            answer["clear_recovery"] = session.clear_recovery
    # Recording is best-effort metadata; a ledger failure cannot invalidate a
    # verified draft or justify replaying an action. False explicitly disables
    # recording for isolated tests, without changing the production default.
    if recipe_store is not False and isinstance(request, dict) and request.get("app") in APPS and request.get("action") in ACTIONS:
        try:
            store = recipe_store or RecipeStore()
            verified = answer["ok"] and (request["action"] != "history" or answer["result"].get("pages_read", 0) > 1)
            if request["action"] == "send":
                verified = answer["ok"] and answer["result"].get("sent") is True and answer["result"].get("send_verified") is True
            answer["recipe"] = store.record_builtin(request["app"], request["action"], ok=answer["ok"],
                                                     verified=verified, duration_ms=elapsed,
                                                     error_code="chat_stopped" if not answer["ok"] else "")
        except (ValueError, OSError) as error:
            answer["recipe_recorded"] = False
            answer["recipe_error"] = type(error).__name__
    return answer
