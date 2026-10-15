"""One-shot, read-only app observations for the current model. No focus or input.

The native helper owns capture masking and snapshot identity. This adapter adds
bounded chat semantics to that same observation, without retaining a baseline,
opening a chat, or turning a background snapshot into an input capability.
"""
from __future__ import annotations

import time
import re

WECHAT = "com.tencent.xinWeChat"
FEISHU = "com.bytedance.macos.feishu"
OBSERVE_TOOL = {
    "name": "desktop_observe",
    "description": "Observe a currently authorized native app without activating it or posting input. Known WeChat/Feishu states use chat semantics; other apps return actionable AX and optional masked-window pixels for the current model's visual/OCR reasoning. Generic results include continuation guidance: one observation or action is a stage, so assess the user's requested outcome and continue fresh observe/action/verify stages until that outcome is proved or a real dependency requires the user. Image failures preserve AX; new dialogs require fresh controls. This tool supplies no model service, completion claim or input authorization; chat is an assertion, never navigation.",
    "inputSchema": {"type": "object", "properties": {
        "app": {"type": "string", "minLength": 3, "maxLength": 256, "description": "Exact bundle ID of the application authorized by the current task."},
        "window_title": {"type": "string", "minLength": 1, "maxLength": 256},
        "chat": {"type": "string", "minLength": 1, "maxLength": 128, "description": "Optional expected currently selected chat. Reports a mismatch without navigating."},
        "background": {"type": "boolean", "const": True, "description": "This observation always runs in the background; default true."},
        "include_image": {"type": "boolean", "description": "Request a target-bound safely masked MCP PNG for model visual/OCR recognition. Generic apps require an exact window_title. Default false. Feishu's chat AX route reports image unavailable; desktop_inspect supports its exact-window image route."},
        "include_raw_state": {"type": "boolean", "description": "Include the full Feishu AX tree. Default false for a recognized chat: complete composer and visible-history semantics remain, with a bounded control projection. Unknown layouts retain the full native state."},
        "include_menus": {"type": "boolean", "description": "For generic apps, include the application's native menu commands alongside its AX window controls. Useful when a toolbar or custom UI has sparse AX. Does not activate or select a menu."},
        "max_nodes": {"type": "integer", "minimum": 1, "maximum": 2000, "description": "Feishu AX node budget, default 1000. Truncation is explicit."},
        "max_depth": {"type": "integer", "minimum": 1, "maximum": 40, "description": "Feishu AX depth budget, default 40."},
        "max_text_rows": {"type": "integer", "minimum": 1, "maximum": 100, "description": "WeChat OCR row budget, default 100."},
        "background_capture": {"type": "string", "enum": ["auto", "visible_screen", "exact_window"], "description": "WeChat read-only capture route, default auto. Snapshots never authorize input."},
        "since_observation_id": {"type": "string", "minLength": 1, "maxLength": 128, "description": "Optional native Feishu observation baseline. Python retains no history; missing/invalidated native baselines return a full state."},
    }, "required": ["app"], "additionalProperties": False},
    "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False},
}


def validate_observation(request):
    if not isinstance(request, dict) or set(request) - set(OBSERVE_TOOL["inputSchema"]["properties"]):
        raise ValueError("Unknown observation argument")
    app = request.get("app")
    if not isinstance(app, str) or len(app) > 256 or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", app):
        raise ValueError("Observation requires an exact app bundle ID")
    if "background" in request and request["background"] is not True:
        raise ValueError("Observation is background read-only; background must be true")
    if "include_image" in request and type(request["include_image"]) is not bool:
        raise ValueError("include_image must be a boolean")
    if "include_raw_state" in request and type(request["include_raw_state"]) is not bool:
        raise ValueError("include_raw_state must be a boolean")
    if "include_menus" in request and (type(request["include_menus"]) is not bool or app in {WECHAT, FEISHU}):
        raise ValueError("include_menus is a generic-app boolean; known chats use their existing adapters")
    for name, maximum in (("window_title", 256), ("chat", 128), ("since_observation_id", 128)):
        if name in request and (not isinstance(request[name], str) or not request[name].strip()
                                or len(request[name]) > maximum or any(c in request[name] for c in "\r\n\t\x00")):
            raise ValueError(name + " must be an exact bounded single-line string")
    for name, maximum in (("max_nodes", 2000), ("max_depth", 40), ("max_text_rows", 100)):
        if name in request and (type(request[name]) is not int or not 1 <= request[name] <= maximum):
            raise ValueError(name + " is out of range")
    if "background_capture" in request and (request["app"] != WECHAT or request["background_capture"] not in {"auto", "visible_screen", "exact_window"}):
        raise ValueError("background_capture requires a supported WeChat read-only route")
    if "since_observation_id" in request and request["app"] != FEISHU:
        raise ValueError("since_observation_id requires the native Feishu AX observation route")
    if app not in {WECHAT, FEISHU}:
        if "chat" in request or "max_text_rows" in request:
            raise ValueError("Chat-specific arguments require a chat adapter")
        if request.get("include_image") and "window_title" not in request:
            raise ValueError("Generic model images require an exact window_title")


def _generic_observation(request, call, before):
    target = {key: request[key] for key in ("app", "window_title") if key in request}
    response = call("inspect", **target, max_depth=request.get("max_depth", 8),
                    max_nodes=request.get("max_nodes", 500),
                    include_image=request.get("include_image", False),
                    **({"include_menus": request["include_menus"]} if "include_menus" in request else {}))
    if not response["ok"]:
        return {**response, "automatic_replay_allowed": False}
    state = response.get("result")
    if (not isinstance(state, dict) or state.get("app") != request["app"]
            or type(state.get("target_pid")) is not int or state["target_pid"] <= 0
            or not isinstance(state.get("elements"), list)):
        raise ValueError("Generic inspection lacks current app/PID/AX binding")
    if "window_title" in target:
        windows = state.get("windows")
        if (not isinstance(windows, list) or len(windows) != 1
                or windows[0].get("title") != target["window_title"]):
            raise ValueError("Generic inspection exact window binding mismatch")
    after = call("status")
    result = {**target, "action": "observe", "route": "model_driven", "background": True,
              "read_only": True, "target_pid": state["target_pid"], "state": state,
              "focus_context_before": _focus_context(before.get("result", {})),
              "focus_context_after": _focus_context(after.get("result", {})) if after["ok"] else None,
              "focus_attempted": False, "events_posted": 0,
              "snapshot_authorizes_input": False, "automatic_replay_allowed": False,
              "image_requested": request.get("include_image", False),
              "image_available": state.get("image_available") is True and isinstance(state.get("image"), dict),
              "model_observation": "Use this current AX state and available masked image for local control/visual text recognition; choose a bounded action, then inspect the resulting window or dialog again. Keep script arguments parameterized and register demonstrated scripts; only verified current-digest desktop_plan/v1 plans may run."}
    if not result["image_available"]:
        result["image_unavailable_reason"] = state.get("image_unavailable_reason", "not_requested" if not request.get("include_image") else "native_image_not_returned")
    if not after["ok"]:
        result["focus_context_error"] = after.get("error", {})
    current_window = state.get("current_window", {})
    if (current_window.get("available") is True and current_window.get("app_frontmost") is True
            and current_window.get("authorized_owner_pid") == state["target_pid"]
            and current_window.get("title_complete") is True and current_window.get("title")
            and current_window.get("is_selected_window") is False):
        result["window_transition"] = {"new_inspection_required": True,
            "next_observation": {"app": request["app"], "window_title": current_window["title"]},
            "source": "current_authorized_app_window", "input_authorization": False,
            "previous_element_ids_reusable": False}
    # This is guidance for the current model, not a goal owner or an action loop.
    # A successful read proves only this observation; it cannot assess an
    # arbitrary user instruction or turn pixels into input authority.
    next_target = result.get("window_transition", {}).get("next_observation", target)
    next_arguments = dict(next_target)
    windows = state.get("windows", [])
    if "window_title" not in next_arguments and len(windows) == 1:
        title = windows[0].get("title")
        if isinstance(title, str) and title.strip() and len(title) <= 256 and not any(c in title for c in "\r\n\t\x00"):
            next_arguments["window_title"] = title
    containers = {"AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXMenuBar", "AXMenuBarItem", "AXMenu"}
    sparse = not any(element.get("actions") and element.get("role") not in containers or element.get("role") in {
        "AXButton", "AXTextArea", "AXTextField", "AXSearchField", "AXMenuItem",
        "AXCheckBox", "AXPopUpButton", "AXComboBox", "AXLink", "AXRow"
    } for element in state["elements"] if isinstance(element, dict))
    context_gaps = []
    if state.get("truncated") is True:
        context_gaps.append("ax_truncated")
        next_arguments.update(max_nodes=2000, max_depth=40)
    if sparse:
        context_gaps.append("sparse_ax_controls")
        next_arguments["include_menus"] = True
    if request.get("include_menus") is True:
        next_arguments["include_menus"] = True
    if result["image_requested"] and not result["image_available"]:
        context_gaps.append("requested_image_unavailable")
    # Request missing visual context once; do not prescribe an unchanged capture
    # retry after a failed image. AX and its exact menu controls remain usable.
    privacy_budget_expanded = (state.get("truncated") is True and result["image_requested"]
        and result.get("image_unavailable_reason") == "inspection_image_privacy_truncated"
        and (request.get("max_nodes", 500) < 2000 or request.get("max_depth", 8) < 40))
    if "window_title" in next_arguments and (result["image_available"] or sparse and not result["image_requested"] or privacy_budget_expanded):
        next_arguments["include_image"] = True
    result["continuation"] = {
        "task_completion": "not_assessed", "completion_scope": "observation_only",
        "next_step": "inspect_new_window" if "window_transition" in result else "assess_goal_then_continue",
        "refresh_after_action": True, "previous_element_ids_reusable_after_action": False,
        "context_gaps": context_gaps,
        "available_context": ["ax"] + (["masked_image"] if result["image_available"] else []),
        "next_observation": {"tool": "desktop_observe", "arguments": next_arguments},
        "input_authorization": False, "automatic_replay_allowed": False,
    }
    return {"ok": True, "result": result}


def _model_state(app, state, semantics, include_raw_state):
    if (app != FEISHU or include_raw_state or semantics.get("recipient_verified") is not True
            or semantics.get("composer", {}).get("value_complete") is not True):
        return state
    elements = state.get("elements")
    if not isinstance(elements, list):
        return state
    composer_id = semantics["composer"].get("element_id")
    required = [e for e in elements if isinstance(e, dict) and (
        e.get("depth") == 0 or e.get("element_id") == composer_id)]
    controls = required + [e for e in elements if isinstance(e, dict) and e not in required and
        e.get("role") in {"AXButton", "AXTextField", "AXSearchField", "AXCheckBox", "AXPopUpButton"}]
    return {**state, "elements": controls[:80], "model_state_projection": {
        "kind": "recognized_chat_controls", "raw_node_count": len(elements),
        "projected_node_count": min(80, len(controls)), "controls_truncated": len(controls) > 80,
        "full_ax_tree_included": False, "complete_composer_retained": True,
        "visible_history_retained": True, "full_ax_tree_option": "include_raw_state:true"}}


def _focus_context(status):
    # System focus is not the target application's internal focused AX element.
    fields = {"frontmost_app_bundle_id", "frontmost_pid", "frontmost_source", "frontmost_window_id",
              "frontmost_window_frame", "frontmost_display_ids", "focused_window_id", "focused_window_frame",
              "focused_window_display_ids", "displays", "display_topology_generation", "coordinate_system", "interrupted"}
    return {key: value for key, value in status.items() if key in fields}


def _native_focus_context(value, nested=True):
    """Bound public native focus metadata; never retain foreign title/content."""
    if not isinstance(value, dict):
        return {}
    if nested and ("before" in value or "after" in value):
        result = {key: _native_focus_context(value[key], nested=False) for key in ("before", "after") if key in value}
        if isinstance(value.get("scope"), str) and len(value["scope"]) <= 128:
            result["scope"] = value["scope"]
        return result
    result = {}
    if type(value.get("available")) is bool:
        result["available"] = value["available"]
    for key in ("pid", "window_id"):
        if value.get(key) is None and key in value:
            result[key] = None
        elif type(value.get(key)) is int and 0 <= value[key] < 2**32:
            result[key] = value[key]
    for key in ("bundle_id", "source"):
        if value.get(key) is None and key in value:
            result[key] = None
        elif isinstance(value.get(key), str) and len(value[key]) <= 256:
            result[key] = value[key]
    if value.get("window_frame") is None and "window_frame" in value:
        result["window_frame"] = None
    elif isinstance(value.get("window_frame"), dict):
        from chat_workflows import _rect, Stopped
        try:
            result["window_frame"] = _rect({"bounds": value["window_frame"]})
        except Stopped:
            pass
    ids = value.get("display_ids")
    if isinstance(ids, list) and len(ids) <= 16 and all(type(item) is int and 0 < item < 2**32 for item in ids):
        result["display_ids"] = ids
    return result


def _covered(region, rectangles):
    """Require every point of an ROI to be in the native rectangle union."""
    from chat_workflows import _rect, Stopped
    if not isinstance(rectangles, list):
        return False
    clipped = []
    for raw in rectangles:
        try:
            rect = _rect({"bounds": raw})
        except Stopped:
            return False
        left, top = max(region['x'], rect['x']), max(region['y'], rect['y'])
        right = min(region['x'] + region['width'], rect['x'] + rect['width'])
        bottom = min(region['y'] + region['height'], rect['y'] + rect['height'])
        if right > left and bottom > top:
            clipped.append((left, right, top, bottom))
    edges = sorted({region['x'], region['x'] + region['width'], *(x for rect in clipped for x in rect[:2])})
    for left, right in zip(edges, edges[1:]):
        if right - left <= 1e-6:
            continue
        intervals = sorted((top, bottom) for x1, x2, top, bottom in clipped if x1 <= left + 1e-6 and x2 >= right - 1e-6)
        reached = region['y']
        for top, bottom in intervals:
            if top > reached + 1e-6:
                return False
            reached = max(reached, bottom)
        if reached < region['y'] + region['height'] - 1e-6:
            return False
    return True


def _chat_semantics(app, request, value):
    # Reuse only the pure interpretation methods from the known fast path. This
    # session never calls start/focus, and cannot execute native actions.
    from chat_workflows import ChatSession, Stopped, _rect, _label_matches
    session = ChatSession({"app": app, "action": "read"}, lambda _: (_ for _ in ()).throw(AssertionError("Observation attempted input")))
    if app == WECHAT:
        session.frame = _rect(value)
    else:
        windows = [row for row in value.get("windows", []) if row.get("title") == request["window_title"]]
        if not windows and value.get("window_title") == request["window_title"] and "window_frame" in value:
            # Native background_observe binds the exact selected window without
            # needing the legacy inspect windows[] representation.
            session.frame = _rect(value)
        elif len(windows) != 1:
            raise Stopped("target_not_found", "Expected one exact observed window")
        else:
            session.frame = _rect(windows[0])
    session.target["window_title"] = request["window_title"]
    result = {"chat_title": None, "recipient_verified": False,
              "composer": {"available": False, "value_complete": False},
              "visible_text": "", "rows": [], "complete_history": False,
              "position": "current_visible_viewport", "semantic_gaps": [],
              "message_semantics": "visible UI text; sender, message boundaries and newness are unverified"}
    try:
        title = session.wechat_header(value) if app == WECHAT else session.feishu_header(value)
        result.update(chat_title=title, recipient_verified=True)
        if "chat" in request:
            result["requested_chat_matches"] = _label_matches(title, request["chat"])
    except Stopped as error:
        result["semantic_gaps"].append({"field": "chat_title", "reason": error.code})
        if "chat" in request:
            result["requested_chat_matches"] = None
    try:
        if app == WECHAT:
            region = session.wechat_regions()["composer"]
            captured = _covered(region, value.get("captured_regions"))
            ocr_regions = value.get("ocr_regions")
            if ocr_regions is None and value.get("ocr_scope") in {"full_window", "full_window_and_top_footer_anchor_bands"}:
                ocr_regions = [session.frame]
            scanned = _covered(region, ocr_regions)
            draft = session.wechat_draft(value)
            complete = captured and scanned and value.get("ocr_truncated") is False
            reason = "composer_region_occluded" if not captured else "composer_region_not_scanned" if not scanned else "OCR_rows_truncated" if not complete else "fully_captured_and_scanned_composer"
            result["composer"] = {"available": complete, "value_complete": complete, "source": "local_OCR",
                                  "completeness_reason": reason, "region_captured": captured, "region_scanned": scanned}
            if complete:
                result["composer"].update(value=draft, draft=draft)
            else:
                result["composer"]["visible_text_fragment"] = draft
        else:
            row = session.feishu_composer(value)
            raw = row["value"]
            cap = value.get("values_max_characters", 4000)
            complete = row.get("value_complete")
            if type(complete) is not bool:
                complete = row.get("value_truncated") is False if "value_truncated" in row else type(cap) is int and len(raw) < cap
            result["composer"] = {"available": True, "element_id": row.get("element_id"), "value": raw,
                                  "draft": session.feishu_draft(value), "value_complete": complete,
                                  "source": "AX", "completeness_reason": "native_complete_value" if complete else "native_value_limit_or_truncation"}
    except Stopped as error:
        result["semantic_gaps"].append({"field": "composer", "reason": error.code})
    if not result["recipient_verified"]:
        # A geometric lane or AX text area is not sufficient evidence of a
        # chat composer. Unknown panes can put file lists or notes in that lane.
        composer = result["composer"]
        fragment = composer.pop("draft", composer.get("value", composer.get("visible_text_fragment", "")))
        composer.pop("value", None)
        composer.update(available=False, value_complete=False,
                        completeness_reason="chat_header_unverified", visible_text_fragment=fragment)
        result["semantic_gaps"].append({"field": "composer", "reason": "chat_header_unverified"})
    try:
        rows = session.visible_rows(value)
        result.update(rows=rows, visible_text="\n".join(row["text"] for row in rows), visible_rows_returned=len(rows))
    except Stopped as error:
        result["semantic_gaps"].append({"field": "visible_text", "reason": error.code})
    result["truncated"] = bool(value.get("truncated") or value.get("ocr_truncated"))
    return result


def execute_observation(request, invoke_native):
    started, commands = time.monotonic(), []
    def call(command, **arguments):
        commands.append(command)
        response = invoke_native({"command": command, **arguments})
        if not isinstance(response, dict) or type(response.get("ok")) is not bool:
            raise ValueError("Native observation envelope is invalid")
        return response
    try:
        validate_observation(request)
        app = request["app"]
        target = {"app": app, "window_title": request.get("window_title", "微信" if app == WECHAT else "飞书")}
        before = call("status")
        if not before["ok"]:
            return {**before, "automatic_replay_allowed": False, "commands": commands}
        if app not in {WECHAT, FEISHU}:
            generic = _generic_observation(request, call, before)
            return {**generic, "commands": commands, "native_calls": len(commands),
                    "elapsed_ms": round((time.monotonic() - started) * 1000, 3)}
        if app == WECHAT:
            response = call("background_visual_read", **target, max_text_rows=request.get("max_text_rows", 100),
                            **{k: request[k] for k in ("include_image", "background_capture") if k in request})
        else:
            response = call("background_observe", **target, max_depth=request.get("max_depth", 40),
                            max_nodes=request.get("max_nodes", 1000),
                            **{k: request[k] for k in ("include_image", "since_observation_id") if k in request})
        if not response["ok"]:
            return {**response, "automatic_replay_allowed": False, "commands": commands}
        state = response.get("result")
        if not isinstance(state, dict) or type(state.get("target_pid")) is not int or state["target_pid"] <= 0:
            raise ValueError("Native observation lacks target PID binding")
        if state.get("app", app) != app or state.get("window_title", target["window_title"]) != target["window_title"]:
            raise ValueError("Native observation target binding mismatch")
        if app == WECHAT and (not isinstance(state.get("snapshot_id"), str) or not state["snapshot_id"] or not isinstance(state.get("ocr"), list)):
            raise ValueError("Native background observation lacks snapshot/OCR")
        after = call("status")
        native_focus = _native_focus_context(state.get("focus_context"))
        if "focus_context" in state:
            state = {**state, "focus_context": native_focus}
        current_focus = native_focus.get("after", native_focus)
        window_verified = (current_focus.get("available") is True and type(current_focus.get("pid")) is int
                           and current_focus["pid"] > 0 and type(current_focus.get("window_id")) is int
                           and current_focus["window_id"] > 0 and isinstance(current_focus.get("window_frame"), dict)
                           and bool(current_focus.get("display_ids")))
        from chat_workflows import Stopped
        try:
            semantics = _chat_semantics(app, target | {k: request[k] for k in ("chat",) if k in request}, state)
        except Stopped as error:
            semantics = {"chat_title": None, "recipient_verified": False, "composer": {"available": False, "value_complete": False},
                         "visible_text": "", "rows": [], "complete_history": False,
                         "semantic_gaps": [{"field": "layout", "reason": error.code}]}
        image_requested = request.get("include_image", False)
        result = {**target, "action": "observe", "background": True, "read_only": True,
                  "target_pid": state["target_pid"], "state": _model_state(app, state, semantics, request.get("include_raw_state", False)), **semantics,
                  "focus_context_before": _focus_context(before.get("result", {})),
                  "focus_context_after": _focus_context(after.get("result", {})) if after["ok"] else None,
                  "focus_context_scope": "application_and_display_topology",
                  "native_current_focus_context": native_focus,
                  "focus_context_complete": after["ok"] and window_verified,
                  "focused_window_verified": window_verified,
                  "keyboard_focus_display_ids": current_focus.get("display_ids", []) if window_verified else [],
                  "focus_attempted": False,
                  "events_posted": 0, "sent": False, "draft_preserved": True,
                  "automatic_replay_allowed": False, "snapshot_authorizes_input": False,
                  "image_requested": image_requested, "image_available": isinstance(state.get("image"), dict),
                  "model_observation": "Current model consumes this target-bound state and optional masked image, then chooses a bounded action batch; no model service is invoked."}
        if image_requested and not result["image_available"]:
            result["image_unavailable_reason"] = "unsupported_app_AX_only" if app == FEISHU else "native_image_not_returned"
        if not after["ok"]:
            result["focus_context_error"] = after.get("error", {})
        return {"ok": True, "result": result, "commands": commands, "native_calls": len(commands),
                "elapsed_ms": round((time.monotonic() - started) * 1000, 3)}
    except (ValueError, KeyError, TypeError) as error:
        return {"ok": False, "error": {"code": "invalid_request" if not commands else "native_protocol_error", "message": str(error)},
                "automatic_replay_allowed": False, "events_posted": 0, "commands": commands}
    except Exception as error:
        return {"ok": False, "error": {"code": "native_transport_error", "message": "Read-only observation failed", "exception_type": type(error).__name__},
                "automatic_replay_allowed": False, "events_posted": 0, "commands": commands}
