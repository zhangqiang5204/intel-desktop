#!/usr/bin/env python3
"""Local stdio MCP bridge. Persistent native AX and authorized local visual fallback."""
import atexit
import json
import math
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
from chat_workflows import CHAT_TOOL, execute_chat
from recipe_store import RECIPE_TOOL, execute_recipe
from desktop_observation import OBSERVE_TOOL, execute_observation
from mcp_images import MAX_RESPONSE_BYTES, mcp_content
from task_runtime import TaskRuntime,current_context
from workflow_tools import (TRANSACTION_TOOL,TASK_TOOL,SCRIPT_TOOL,add_runtime_schema,runtime_arguments,
                            classify_result,task_action,script_action,after_script_result)
from desktop_transactions import execute_transaction

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'bin' / 'IntelDesktopHelper'
COMMANDS = {'status', 'inspect', 'focus', 'press', 'click', 'set_text', 'select_text', 'type_text', 'clear_text', 'submit_text', 'key', 'scroll', 'wait_text', 'batch', 'background_type_text', 'background_visual_read'}
READ_ONLY = {'status', 'inspect', 'wait_text'}
VISUAL_COMMANDS = {'visual_read', 'visual_click', 'visual_type_text', 'visual_key', 'visual_scroll'}
COMMANDS |= VISUAL_COMMANDS
READ_ONLY.add('visual_read')
READ_ONLY.add('background_visual_read')
INTERNAL_COMMANDS = {'background_observe','background_chat_edit'}
COMMON = {
    'app': {'type': 'string', 'description': 'Exact bundle ID authorized by the current user task, e.g. com.apple.TextEdit'},
    'window_title': {'type': 'string', 'description': 'Exact target window title. Use when multiple windows exist.'},
}
PROPS = {
    'status': {},
    'inspect': {**COMMON, 'include_image': {'type': 'boolean', 'description': 'Optional target-only masked PNG for the current model alongside this call’s actionable AX IDs. Requires an explicit exact window_title; defaults false. No app allowlist, focus, pointer movement, input, desktop screenshot or file. Truncated/unknown privacy, unsupported capture or changed identity returns image_available=false with a reason while preserving AX. AX and pixels are not an atomic value snapshot; each later action still freshly validates its target.'}, 'include_menus': {'type': 'boolean', 'description': 'Include this application’s own menu commands as cached AX elements, sharing the same node budget. Excludes Apple, Services and recent-item subtrees. Use for native navigation when the window exposes only a shell.'}, 'enable_accessibility': {'type': 'boolean', 'description': 'Explicitly request supported per-app AX accessibility exposure before inspection. Returns raw unsupported/failure results; never changes macOS permissions.'}, 'max_depth': {'type': 'integer', 'minimum': 1, 'maximum': 40}, 'max_nodes': {'type': 'integer', 'minimum': 1, 'maximum': 2000}, 'compact': {'type': 'boolean', 'description': 'Return control identity, text and geometry without repeated AX diagnostic metadata. Default true.'}},
    'focus': {**COMMON, 'restore_previous': {'type': 'boolean', 'description': 'Return focus to the actual application/window saved by this helper at first stage takeover. Skip if the user has taken over; never post keys or replay business actions.'}},
    'press': {**COMMON, 'element_id': {'type': 'string'}},
    'click': {**COMMON, 'element_id': {'type': 'string'}, 'x': {'type': 'number'}, 'y': {'type': 'number'}},
    'set_text': {**COMMON, 'element_id': {'type': 'string'}, 'text': {'type': 'string', 'maxLength': 65536}},
    'select_text': {**COMMON, 'element_id': {'type': 'string', 'minLength': 1}, 'expected_value': {'type': 'string', 'maxLength': 65536, 'description': 'Exact full current AXValue. Changed text is preserved.'}, 'text': {'type': 'string', 'minLength': 1, 'maxLength': 65536, 'description': 'Exact text to select; repeated text requires explicit one-based occurrence.'}, 'occurrence': {'type': 'integer', 'minimum': 1, 'maximum': 65536}, 'range': {'type': 'object', 'properties': {'location': {'type': 'integer', 'minimum': 0, 'maximum': 131072}, 'length': {'type': 'integer', 'minimum': 0, 'maximum': 131072}}, 'required': ['location', 'length'], 'additionalProperties': False, 'description': 'Alternative explicit UTF-16 range, including restoring an owned previous selection.'}, 'expected_selection': {'type': 'object', 'properties': {'location': {'type': 'integer', 'minimum': 0, 'maximum': 131072}, 'length': {'type': 'integer', 'minimum': 0, 'maximum': 131072}}, 'required': ['location', 'length'], 'additionalProperties': False, 'description': 'Optional exact current selection required before changing it; useful for safe restoration.'}, 'background': {'type': 'boolean', 'description': 'Set selection through AX while target is outside the user\u2019s foreground; requires unchanged complete foreign focus proof. No focus, typing or mouse events.'}},
    'clear_text': {**COMMON, 'element_id': {'type': 'string'}, 'expected_value': {'type': 'string', 'maxLength': 65536, 'description': 'Exact full current AXValue authorized for clearing. The helper refuses changed content before sending events.'}, 'expected_empty_value': {'type': 'string', 'maxLength': 65536, 'description': 'Exact full AXValue of the cleared editor, including any known placeholder or structural characters.'}},
    'submit_text': {**COMMON, 'element_id': {'type': 'string', 'minLength': 1}, 'recipient_element_id': {'type': 'string', 'minLength': 1}, 'expected_recipient': {'type': 'string', 'minLength': 1, 'maxLength': 1024}, 'expected_value': {'type': 'string', 'minLength': 1, 'maxLength': 65536}, 'expected_empty_value': {'type': 'string', 'maxLength': 65536}, 'allow_submit': {'type': 'boolean', 'description': 'Assert the current human already authorized this exact recipient and message. Never set for unsent-draft tests. Native rechecks exact Feishu composer/header and posts one Return pair; delivery still requires fresh UI evidence.'}},
    'type_text': {**COMMON, 'element_id': {'type': 'string'}, 'text': {'type': 'string', 'maxLength': 65536}, 'replace_search': {'type': 'boolean', 'description': 'Replace only the currently focused Feishu known search-modal TextArea using Select-All and Unicode input, then verify the complete final AX value. Requires exact complete expected_before including the known UI hint if present; expected_value is the canonical query plus structural suffix. Verifies one of the two exact known full after serializations, with or without the appended 回车查看答案 hint. No Backspace or intermediate empty-state wait.'}, 'expected_before': {'type': 'string', 'maxLength': 65536}, 'expected_value': {'type': 'string', 'maxLength': 65536, 'description': 'Optional exact full AXValue after insertion, for rich-text UI that removes placeholders or adds structural characters. Must contain nonempty requested text. Otherwise selection-derived exact comparison is used.'}},
    'key': {**COMMON, 'key': {'type': 'string'}, 'modifiers': {'type': 'array', 'items': {'type': 'string', 'enum': ['cmd', 'shift', 'alt', 'ctrl']}, 'maxItems': 4}},
    'scroll': {**COMMON, 'element_id': {'type': 'string'}, 'x': {'type': 'number'}, 'y': {'type': 'number'}, 'delta_y': {'type': 'integer', 'minimum': -100, 'maximum': 100}},
    'wait_text': {**COMMON, 'element_id': {'type': 'string'}, 'text': {'type': 'string', 'maxLength': 65536}, 'timeout_ms': {'type': 'integer', 'minimum': 0, 'maximum': 5000}},
}
DESCRIPTIONS = {
    'status': 'Read native helper permissions, architecture, PID and active display geometry. Never requests permissions.',
    'inspect': 'Read a bounded AX tree for any authorized app/window, retaining actionable element IDs and Quartz global point geometry. Optional include_image:true adds a PID/title/frame/topology-bound target-only masked MCP PNG from the same call, with exact window_title required. Public window capture preserves focus and pointer; default false retains AX-only speed. Image failures preserve AX and report a reason. Pixels are model observation, not input authorization or an atomic AX-value snapshot; subsequent actions still freshly validate the target.',
    'focus': 'Explicitly focus the authorized running app/window. After a reported user takeover, wait for the user to hand control back before calling this again.',
    'press': 'Press an AX control by its current element ID.',
    'click': 'Click an AX control, or Quartz global point coordinates inside both an attached display and the verified target window. Negative coordinates are valid on left/upper displays. Focus first.',
    'set_text': 'Set a writable AX text value and read it back. This replaces existing text.',
    'select_text': 'Select exact Unicode text or an explicit UTF-16 range in a current identified native text control. Requires exact full text and window identity; rejects ambiguous occurrences, changed values/selections, protected controls and target/focus changes. Posts no keyboard/mouse events and never changes text. Optional background:true preserves the actual foreign-app focus; unsupported AX selection stops without fallback or replay.',
    'clear_text': 'Clear an identified text editor with native select-all and Backspace after matching its exact current value. Verify the exact expected empty value; preserves changed drafts by refusing the action. No Return or Send.',
    'submit_text': 'Submit a currently human-authorized Feishu message with one native Return pair after checking the exact cached composer and actual recipient header in the same chat window. Reject changed values, focus, geometry, security or takeover; never replay. Posted events alone do not prove delivery.',
    'type_text': 'Insert Unicode text, including Chinese, using native keyboard events. No clipboard access. Focus first.',
    'key': 'Send a shortcut/key to the verified foreground target app/window. Focus first.',
    'scroll': 'Scroll at a current AX control or verified Quartz window point. Sends no click; read the actual viewport afterward to verify movement.',
    'wait_text': 'Wait locally for target text instead of repeated model calls or screenshots.',
    'batch': 'Execute up to 32 actions in one native call with one fixed target. Stop on failure/user takeover. Prefer this for known sequences; report partial completion accurately.',
}
RECT = {'type': 'object', 'properties': {k: {'type': 'number', **({'exclusiveMinimum': 0} if k in {'width', 'height'} else {})} for k in ['x', 'y', 'width', 'height']}, 'required': ['x', 'y', 'width', 'height'], 'additionalProperties': False}
VISUAL_COMMON = {**COMMON, 'snapshot_id': {'type': 'string', 'minLength': 1, 'description': 'Fresh opaque snapshot ID. Inside a batch, latest refers only to a snapshot produced earlier in that same batch.'}, 'max_age_ms': {'type': 'integer', 'minimum': 1, 'maximum': 5000}, 'control_kind': {'type': 'string', 'enum': ['search', 'chat_composer', 'navigation']}, 'control_rect': RECT, 'confirm_control': {'type': 'boolean', 'description': 'Confirm this rectangle is the authorized identified control in the bound latest target snapshot; never use a password or login input.'}}
PROPS.update({
    'visual_read': {**COMMON, 'anchor_wait_timeout_ms': {'type': 'integer', 'minimum': 0, 'maximum': 3000, 'description': 'Read-only anchor wait. Zero returns actual fresh OCR immediately, with unconfirmed targets still denied for input.'}, 'region': RECT, 'regions': {'type': 'array', 'minItems': 1, 'maxItems': 8, 'items': RECT, 'description': 'Read bounded regions from one fresh target frame; mutually exclusive with region. Include actual target anchors when confirming.'}, 'anchor_texts': {'type': 'array', 'items': {'type': 'string', 'maxLength': 128}, 'maxItems': 8}, 'confirm_target': {'type': 'boolean'}, 'debug_image_path': {'type': 'string', 'description': 'Optional new absolute local PNG path for one diagnostic frame. Default stores no screenshot file.'}, 'max_text_rows': {'type': 'integer', 'minimum': 1, 'maximum': 100}},
    'visual_click': {**VISUAL_COMMON, 'x': {'type': 'number'}, 'y': {'type': 'number'}, 'navigation_target_kind': {'type': 'string', 'enum': ['text', 'icon'], 'description': 'Defaults to text with target_text OCR binding. Icon requires model-confirmed control_rect and explicit x/y, omits target_text, and retains all fresh target and point-ownership guards.'}, 'target_text': {'type': 'string', 'maxLength': 128}, 'wait_timeout_ms': {'type': 'integer', 'minimum': 0, 'maximum': 3000}},
    'visual_type_text': {**VISUAL_COMMON, 'replace_search': {'type': 'boolean', 'description': 'Replace an already clicked authorized search query using one guarded Select-All/Backspace/Unicode sequence and one final exact readback. Denied for chat composers.'}, 'text': {'type': 'string', 'minLength': 1, 'maxLength': 4096}, 'expected_text': {'type': 'string', 'maxLength': 4096}},
    'visual_key': {**VISUAL_COMMON, 'key': {'type': 'string'}, 'prefix': {'type': 'string', 'minLength': 1, 'maxLength': 64, 'description': 'Exact authorized owned prefix for clear_prefix; only ordinary BMP single-line characters.'}, 'expected_draft': {'type': 'string', 'maxLength': 4096, 'description': 'Complete current composer OCR required before clear_prefix or clear_draft. clear_draft also requires full chat_title and deletes the exact owned draft in one guarded Select-All/Backspace action; clear_prefix preserves the suffix.'}, 'modifiers': {'type': 'array', 'items': {'type': 'string', 'enum': ['cmd', 'shift', 'alt', 'ctrl']}, 'maxItems': 4}, 'allow_submit': {'type': 'boolean', 'description': 'Set only when the current human task explicitly authorizes sending this exact message to this recipient. False by default; never enable for unsent-draft tests.'}, 'expected_message': {'type': 'string', 'maxLength': 4096}, 'chat_title': {'type': 'string', 'maxLength': 128}},
    'visual_scroll': {**VISUAL_COMMON, 'x': {'type': 'number'}, 'y': {'type': 'number'}, 'target_text': {'type': 'string', 'maxLength': 128}, 'delta_y': {'type': 'integer', 'minimum': -100, 'maximum': 100}},
})
DESCRIPTIONS.update({
    'visual_read': 'Read the authorized foreground WeChat main window through bounded public ScreenCaptureKit target-window capture, target visibility checks and local Vision OCR when AX is unavailable. Supports windows spanning displays with mixed scales and negative origins. Returns Quartz text bounds, captured_regions, display_fragment_count and a bound snapshot. Input must fall within actually captured regions; display gaps are denied. Confirm at least two observed target anchors before visual input. No clipboard or cloud inference.',
    'visual_click': 'Click an identified authorized WeChat search, composer or navigation control in a fresh confirmed snapshot. Reject target, geometry, focus or takeover mismatch.',
    'visual_type_text': 'Insert single-line Chinese/Unicode into a confirmed WeChat input and verify expected text using a fresh local region OCR frame. No Return, Send, clipboard or automatic replay.',
    'visual_key': 'Post a safe navigation/editing key to a confirmed WeChat control. Return is denied by default and requires current-user authorization plus explicit allow_submit, exact fresh composer message and chat-header checks. Posted events alone never establish clear, navigation or send success.',
    'visual_scroll': 'Scroll inside a confirmed WeChat window region using a fresh target-bound snapshot. Read again to verify the visible result.',
})
VISUAL_REQUIRED = {cmd: ['snapshot_id', 'control_kind', 'control_rect', 'confirm_control'] for cmd in VISUAL_COMMANDS - {'visual_read'}}
VISUAL_REQUIRED['visual_read'] = ['window_title']
PROPS['visual_read']['include_image'] = {'type': 'boolean', 'description': 'Return the same native verified masked PNG as an MCP image block for the current model, bound to this snapshot/app/PID/window/display topology. Default false. No raw diagnostic image is published.'}
PROPS['background_visual_read'] = dict(PROPS['visual_read'])
PROPS['background_visual_read']['background_capture'] = {'type': 'string', 'enum': ['auto', 'visible_screen', 'exact_window'], 'description': 'Read-only capture route. Auto prefers the verified exact main window when supported; visible_screen uses current unoccluded target regions. Never authorizes background input.'}
PROPS['background_observe'] = {**COMMON, 'max_depth': {'type': 'integer', 'minimum': 1, 'maximum': 40}, 'max_nodes': {'type': 'integer', 'minimum': 1, 'maximum': 2000}, 'include_image': {'type': 'boolean'}, 'since_observation_id': {'type': 'string', 'minLength': 1, 'maxLength': 128}}
PROPS['background_type_text'] = {**COMMON, 'element_id': {'type': 'string', 'minLength': 1},
    'operation': {'type': 'string', 'enum': ['type', 'clear'], 'description': 'Process-directed edit; clear requires the exact complete owned draft. Neither operation sends.'},
    'recipient_element_id': {'type': 'string', 'minLength': 1},
    'expected_recipient': {'type': 'string', 'minLength': 1, 'maxLength': 128},
    'chat_title': {'type': 'string', 'minLength': 1, 'maxLength': 128},
    'snapshot_id': {'type': 'string', 'minLength': 1},
    'control_kind': {'type': 'string', 'enum': ['chat_composer']},
    'control_rect': RECT, 'confirm_control': {'type': 'boolean'},
    'text': {'type': 'string', 'minLength': 1, 'maxLength': 4096},
    'expected_before': {'type': 'string', 'maxLength': 65536},
    'expected_after': {'type': 'string', 'maxLength': 65536}}
PROPS['background_chat_edit']={**COMMON,'operation':{'type':'string','enum':['type','clear']},
    'chat_title':{'type':'string','minLength':1,'maxLength':128},
    'text':{'type':'string','minLength':1,'maxLength':4096},
    'expected_draft':{'type':'string','maxLength':4096},
    'expected_before':{'type':'string','maxLength':65536}}
PROPS['visual_type_text']['chat_title'] = {'type': 'string', 'minLength': 1, 'maxLength': 128, 'description': 'Exact whole recipient header for same-frame post-edit verification; enables reuse of the complete post-action composer/header evidence.'}
PROPS['visual_type_text']['focus_before_type'] = {'type': 'boolean', 'description': 'Opt-in atomic WeChat composer focus and type. Requires the complete empty expected_draft and exact chat_title; freshly rechecks after clicking before typing.'}
PROPS['visual_type_text']['expected_draft'] = {'type': 'string', 'const': '', 'description': 'The exact complete empty composer required by focus_before_type; absence of an editor never proves this value.'}
DESCRIPTIONS['background_visual_read'] = 'Read the authorized WeChat window without activating it or moving the pointer. Uses target-only capture and actual visible-region checks. Unrelated keyboard input does not block this read-only route. Result snapshots are read-only and cannot authorize input.'
DESCRIPTIONS['visual_read'] += ' include_image returns the same verified masked frame as a native MCP PNG block for the current model; metadata retains snapshot/app/PID/window/display binding.'
DESCRIPTIONS['background_visual_read'] += ' include_image returns the same verified masked frame as an MCP PNG block; it never upgrades the read-only snapshot into an input capability.'
DESCRIPTIONS['background_type_text'] = 'Type single-line Unicode or clear an exact owned draft in the bound WeChat/Feishu composer while preserving actual system focus. Requires full expected_before/expected_after and current recipient/control bindings: Feishu AX IDs plus PID/window-bound responder setup, explicit composer AXFocused and exact Edit menu actions (one paste, or select-all/delete; temporary clipboard for paste, restored if unchanged); WeChat snapshot/composer rectangle plus window-bound mouse events without moving the pointer, type 13 and PID Unicode. Known foreign-app activity may continue on the same or another display; target-app contention or unknown ownership stops further input. TextEdit retains append-only support. No Send, activation or global-event fallback; never replay partial/unknown results. Use desktop_chat with background:true for current-chat draft/clear; source support does not establish real-app acceptance.'
CHAT_TOOL['description'] += ' For WeChat/Feishu action=draft or clear, background:true preserves system focus and edits only the current chat. Omit chat to bind its freshly observed complete recipient, or supply the exact name as an assertion. Verify the exact draft/empty value and focus; no Send, navigation, foreground fallback or replay.'
for fields in VISUAL_REQUIRED.values():
    if 'window_title' not in fields: fields.append('window_title')
VISUAL_REQUIRED['visual_type_text'] += ['text', 'expected_text']
VISUAL_REQUIRED['visual_key'] += ['key']
VISUAL_REQUIRED['visual_scroll'] += ['x', 'y', 'delta_y']
# Child commands share the parent target. Target overrides and nested batches are forbidden.
action_variants = []
for cmd in ['press', 'click', 'set_text', 'type_text', 'clear_text', 'submit_text', 'key', 'scroll', 'wait_text', 'visual_read', 'visual_click', 'visual_type_text', 'visual_key', 'visual_scroll']:
    p = {k: v for k, v in PROPS[cmd].items() if k not in COMMON}
    p['command'] = {'const': cmd, 'type': 'string'}
    req = ['command'] + (['text'] if cmd in {'set_text', 'type_text', 'wait_text'} else []) + (['element_id'] if cmd in {'press', 'set_text', 'clear_text'} else []) + (['expected_value', 'expected_empty_value'] if cmd == 'clear_text' else []) + (['key'] if cmd == 'key' else []) + (['delta_y'] if cmd == 'scroll' else [])
    req += [k for k in VISUAL_REQUIRED.get(cmd, []) if k not in COMMON]
    if cmd == 'submit_text': req.extend(['element_id', 'recipient_element_id', 'expected_recipient', 'expected_value', 'expected_empty_value', 'allow_submit'])
    action_variants.append({'type': 'object', 'properties': p, 'required': req, 'additionalProperties': False})
PROPS['batch'] = {**COMMON, 'actions': {'type': 'array', 'minItems': 1, 'maxItems': 32, 'items': {'oneOf': action_variants}}}
TOOLS = []
for cmd in sorted(COMMANDS):
    required = ([] if cmd == 'status' else ['app'])
    if cmd in {'set_text', 'type_text', 'wait_text'}: required.append('text')
    if cmd in {'press', 'set_text', 'clear_text'}: required.append('element_id')
    if cmd == 'clear_text': required.extend(['expected_value', 'expected_empty_value'])
    if cmd == 'select_text': required.extend(['window_title', 'element_id', 'expected_value'])
    if cmd == 'submit_text': required.extend(['window_title', 'element_id', 'recipient_element_id', 'expected_recipient', 'expected_value', 'expected_empty_value', 'allow_submit'])
    if cmd == 'key': required.append('key')
    if cmd == 'batch': required.append('actions')
    if cmd == 'background_type_text': required.extend(['window_title', 'expected_before', 'expected_after'])
    if cmd == 'background_visual_read': required.append('window_title')
    required.extend(VISUAL_REQUIRED.get(cmd, []))
    TOOLS.append({'name': 'desktop_' + cmd, 'description': DESCRIPTIONS[cmd],
                  'inputSchema': {'type': 'object', 'properties': PROPS[cmd], 'required': required, 'additionalProperties': False},
                  'annotations': {'readOnlyHint': cmd in READ_ONLY and cmd != 'inspect', 'destructiveHint': cmd not in READ_ONLY,
                                  'idempotentHint': cmd in {'status', 'inspect'}, 'openWorldHint': False}})

class NativeBridge:
    def __init__(self):
        self.process = None
        self.seq = 0
        self.buffer = b''

    def start(self):
        if self.process is not None:
            if self.process.poll() is not None:
                raise RuntimeError('Native helper exited. Start a new MCP session; actions are never automatically replayed.')
            if self.process.stdin.closed:
                raise RuntimeError('Native helper is draining capture cleanup after EOF; no new actions or replacement helper.')
            return
        if not NATIVE.is_file():
            raise RuntimeError('Native helper missing. Run native/build.sh first.')
        self.process = subprocess.Popen([str(NATIVE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, bufsize=0)

    def close(self):
        p = self.process
        if p is None: return True
        from process_shutdown import drain_process_after_eof
        closed = drain_process_after_eof(p)
        if closed:
            self.process = None
        return closed

    def call(self, cmd, args):
        context=current_context()
        if context:context.boundary(cmd)
        validate(cmd, args)
        if context is None:
            # Direct scripts use the same executor as MCP. A script that owns
            # several related steps must wrap its entire stage in TaskRuntime.run.
            engine = runtime()
            def queued(current):
                response = self.call(cmd, args)
                classify_result(cmd, args, response, current)
                return response
            envelope = engine.run('desktop_' + cmd, args, queued)
            response = envelope.get('response')
            if not isinstance(response, dict):
                response = {'ok': False, 'error': {
                    'code': envelope['summary'].get('error_code') or 'queue_not_executed',
                    'message': 'Queued native call did not execute; no automatic replay'},
                    'automatic_replay_allowed': False}
            response = dict(response)
            response['execution'] = envelope['summary']
            return response
        self.start()
        if cmd in {'focus', 'resume', 'press', 'click', 'set_text', 'select_text', 'type_text', 'clear_text', 'submit_text', 'key', 'scroll',
                   'visual_read', 'background_visual_read', 'visual_click', 'visual_key',
                   'visual_type_text', 'visual_scroll', 'background_type_text', 'background_chat_edit', 'batch'} or (
                       cmd == 'inspect' and args.get('include_image') is True):
            process = self.process
            context.on_finish(self, lambda: self._finish_capture_scope(context, process))
        return self._exchange(cmd, args, context)

    def _finish_capture_scope(self, context, process):
        if self.process is not process or process.poll() is not None:
            return
        row = context.runtime.get_operation(context.operation_id, include_summary=False)
        if row['native_pending']:
            # The prior action has no known completion boundary. Do not append
            # another native command; the existing runtime retains its lease.
            return
        try:
            response = self._exchange('_finish_operation', {}, context)
            if not response.get('ok') or response.get('result', {}).get('capture_scope_released') is not True:
                raise RuntimeError('Native capture scope did not finish')
        except Exception:
            if not self.close():
                # The failed stop response is a known command result, but the
                # capture remains pending. Keep this child's FIFO claim until
                # its EOF drain actually exits instead of starting another stream.
                context.register_native_pid(process.pid, process=process)
            raise

    def _exchange(self, cmd, args, context):
        self.seq += 1
        request = {**{k: v for k, v in args.items() if k != 'compact'}, 'command': cmd, 'id': self.seq}
        # Internal correlation also binds retained native focus to its task.
        # Public callers cannot inject this field through tool arguments.
        if context:
            request['_runtime_task_id'] = context.task_id
            operation_id = getattr(context, 'operation_id', None)
            if operation_id is not None:
                request['_runtime_operation_id'] = operation_id
        data = (json.dumps(request, ensure_ascii=False) + '\n').encode()
        if context:
            context.record_phase('precondition','native:'+cmd)
            context.register_native_pid(self.process.pid,process=self.process)
            context.record_phase('executing','native:'+cmd)
        self.process.stdin.write(data)
        deadline = time.monotonic() + (180 if cmd == 'batch' else 20)
        with selectors.DefaultSelector() as sel:
            sel.register(self.process.stdout, selectors.EVENT_READ)
            while b'\n' not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not sel.select(remaining):
                    self.close()
                    raise RuntimeError('Native request timed out. Completion is unknown; inspect before retrying any mutation.')
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('Native helper EOF. Completion is unknown; no automatic replay.')
                self.buffer += chunk
                if len(self.buffer) > MAX_RESPONSE_BYTES:
                    self.close()
                    raise RuntimeError('Native response exceeds 8 MiB.')
        line, self.buffer = self.buffer.split(b'\n', 1)
        response = json.loads(line)
        if response.get('id') != self.seq:
            self.close()
            raise RuntimeError('Native response ID mismatch; stopped without replay.')
        if context:context.record_native(response,substage=cmd)
        if cmd == 'inspect' and args.get('compact', True):
            response = compact_inspection(response)
        return response


def compact_inspection(response):
    result = response.get('result', {})
    for field in ['elements', 'windows', 'menu_elements']:
        for element in result.get(field, []):
            for key in list(element):
                if key in {'child_sources', 'display_intersections', 'coordinate_system'} or key.endswith('_result'):
                    element.pop(key, None)
    element = result.get('focused_element', {})
    for key in list(element):
        if key in {'child_sources', 'display_intersections', 'coordinate_system'} or key.endswith('_result'):
            element.pop(key, None)
    result['compact'] = True
    return response


def validate(cmd, args):
    if cmd not in COMMANDS | INTERNAL_COMMANDS or not isinstance(args, dict): raise ValueError('Unknown tool or invalid arguments.')
    if set(args) - set(PROPS[cmd]): raise ValueError('Unknown argument: ' + ', '.join(sorted(set(args) - set(PROPS[cmd]))))
    if cmd != 'status' and (not isinstance(args.get('app'), str) or not args['app'].strip()): raise ValueError('app bundle ID required')
    if 'window_title' in args and not isinstance(args['window_title'], str): raise ValueError('window_title must be a string')
    if cmd == 'select_text':
        if not all(isinstance(args.get(k), str) for k in ('window_title', 'element_id', 'expected_value')) or not args['window_title'] or not args['element_id'] or len(args['expected_value']) > 65536: raise ValueError('Exact selection target and complete value required')
        if ('text' in args) == ('range' in args): raise ValueError('Choose exact text or one UTF-16 range')
        if 'text' in args and (not isinstance(args['text'], str) or not 1 <= len(args['text']) <= 65536): raise ValueError('Nonempty bounded selection text required')
        if 'occurrence' in args and ('text' not in args or type(args['occurrence']) is not int or not 1 <= args['occurrence'] <= 65536): raise ValueError('Selection occurrence must be a one-based integer')
        if 'background' in args and type(args['background']) is not bool: raise ValueError('background must be boolean')
        units = args['expected_value'].encode('utf-16-le')
        for field in ('range', 'expected_selection'):
            if field not in args: continue
            r = args[field]
            if not isinstance(r, dict) or set(r) != {'location', 'length'} or any(type(r[k]) is not int or not 0 <= r[k] <= 131072 for k in r): raise ValueError('Bounded UTF-16 range required')
            if r['location'] + r['length'] > len(units) // 2: raise ValueError('Selection range exceeds complete value')
            try:
                units[:r['location'] * 2].decode('utf-16-le'); units[:(r['location'] + r['length']) * 2].decode('utf-16-le')
            except UnicodeDecodeError as error: raise ValueError('Selection cannot split a surrogate pair') from error
    if cmd=='background_chat_edit':
        if args.get('app') not in {'com.tencent.xinWeChat','com.bytedance.macos.feishu'}:raise ValueError('Atomic chat edit supports the two verified chat applications')
        operation=args.get('operation')
        if operation not in {'type','clear'}:raise ValueError('Atomic operation must be type or clear')
        if operation=='type':
            value=args.get('text')
            if not isinstance(value,str) or not value or len(value)>4096 or any(ord(c)<32 or ord(c)==127 or c in '\u2028\u2029' for c in value):raise ValueError('Atomic draft requires bounded single-line Unicode')
        elif 'text' in args or not any(isinstance(args.get(k),str) for k in ('expected_draft','expected_before')):raise ValueError('Atomic clear requires the complete exact owned draft')
        for key,limit in [('chat_title',128),('expected_draft',4096),('expected_before',65536)]:
            if key in args and (not isinstance(args[key],str) or len(args[key])>limit or key=='chat_title' and not args[key]):raise ValueError('Invalid atomic '+key)
    if cmd == 'focus' and 'restore_previous' in args and type(args['restore_previous']) is not bool: raise ValueError('restore_previous must be a boolean')
    if cmd == 'visual_type_text' and 'focus_before_type' in args and type(args['focus_before_type']) is not bool: raise ValueError('focus_before_type must be a boolean')
    if cmd == 'visual_type_text' and args.get('focus_before_type') is True:
        if (args.get('expected_draft') != '' or not isinstance(args.get('chat_title'), str) or not args['chat_title']
                or args.get('control_kind') != 'chat_composer' or args.get('replace_search') is True
                or args.get('text') != args.get('expected_text')):
            raise ValueError('Atomic composer editing requires an exact empty draft, recipient and equal final text')
    if cmd in {'background_type_text', 'background_visual_read'} and not args.get('window_title'): raise ValueError('Exact background window_title required')
    if cmd == 'background_visual_read':
        validate('visual_read', {k: v for k, v in args.items() if k != 'background_capture'})
        if not isinstance(args.get('background_capture', 'auto'), str) or args.get('background_capture', 'auto') not in {'auto', 'visible_screen', 'exact_window'}: raise ValueError('Unknown background capture route')
    if 'include_image' in args and type(args['include_image']) is not bool: raise ValueError('include_image must be a boolean')
    if cmd == 'inspect' and args.get('include_image') and 'window_title' not in args: raise ValueError('include_image requires an explicit exact window_title')
    if args.get('include_image') and 'debug_image_path' in args: raise ValueError('Model images cannot be combined with raw diagnostic image paths')
    if cmd == 'background_observe':
        if args.get('app') != 'com.bytedance.macos.feishu' or not args.get('window_title'): raise ValueError('background_observe requires the exact Feishu window')
        if 'since_observation_id' in args and (not isinstance(args['since_observation_id'], str) or not 1 <= len(args['since_observation_id']) <= 128): raise ValueError('since_observation_id must be a bounded nonempty string')
    if cmd == 'background_type_text':
        operation = args.get('operation', 'type')
        if operation not in {'type', 'clear'}: raise ValueError('Unknown background edit operation')
        value = args.get('text')
        if operation == 'type':
            if not isinstance(value, str) or not value or len(value) > 4096 or any(ord(c) < 32 or ord(c) == 127 or c in '\u2028\u2029' for c in value): raise ValueError('Background Unicode must be nonempty bounded single-line text without control characters')
        elif 'text' in args: raise ValueError('Background clear does not accept text')
        for field in ('expected_before', 'expected_after'):
            if not isinstance(args.get(field), str) or len(args[field]) > 65536: raise ValueError(field + ' must be a complete bounded AX value')
        if args['app'] == 'com.apple.TextEdit':
            if operation != 'type' or not args.get('element_id') or args['expected_after'] != args['expected_before'] + value: raise ValueError('TextEdit background append requires an exact element and complete expected_after')
        elif args['app'] == 'com.bytedance.macos.feishu':
            if not all(isinstance(args.get(k), str) and args[k] for k in ('element_id', 'recipient_element_id', 'expected_recipient')): raise ValueError('Feishu background edit requires exact composer and recipient elements')
            if operation == 'type' and value not in args['expected_after']: raise ValueError('Feishu after serialization must contain the requested text')
        elif args['app'] == 'com.tencent.xinWeChat':
            if (not all(isinstance(args.get(k), str) and args[k] for k in ('snapshot_id', 'chat_title'))
                    or args.get('control_kind') != 'chat_composer' or args.get('confirm_control') is not True
                    or not isinstance(args.get('control_rect'), dict)): raise ValueError('WeChat background edit requires the exact bound composer snapshot and whole recipient')
            if args['expected_after'] != (args['expected_before'] + value if operation == 'type' else ''): raise ValueError('WeChat background edit requires exact complete expected_after')
        else: raise ValueError('Unsupported background editor app')
    if cmd in {'press', 'set_text', 'clear_text'} and not isinstance(args.get('element_id'), str): raise ValueError('element_id required')
    if 'element_id' in args and not isinstance(args['element_id'], str): raise ValueError('element_id must be a string')
    if cmd in {'set_text', 'type_text', 'wait_text'} and (not isinstance(args.get('text'), str) or len(args['text']) > 65536): raise ValueError('text must be a string of at most 65536 characters')
    if 'expected_value' in args:
        if not isinstance(args['expected_value'], str) or len(args['expected_value']) > 65536: raise ValueError('expected_value must be a string of at most 65536 characters')
        if args.get('text') and args['text'] not in args['expected_value']: raise ValueError('expected_value must contain requested nonempty text')
    if cmd == 'type_text':
        if 'replace_search' in args and type(args['replace_search']) is not bool: raise ValueError('replace_search must be a boolean')
        if args.get('replace_search'):
            if args.get('app') != 'com.bytedance.macos.feishu' or args.get('window_title') != 'ModalWebViewWidget - search:search-command-bar:default': raise ValueError('Search replacement requires the exact Feishu search modal')
            if not args.get('element_id'): raise ValueError('Exact search element_id required')
            before, value = args.get('expected_before'), args.get('text')
            if not isinstance(before, str) or len(before) > 65536: raise ValueError('Search replacement requires the exact observed structural AX value')
            canonical_before = before[:-len('\n回车查看答案')] if before.endswith('\u200b\n\n回车查看答案') else before
            if not canonical_before.endswith('\u200b\n') or any(ord(c) < 32 or ord(c) == 127 or c in '\u200b\u2028\u2029' for c in canonical_before[:-2]): raise ValueError('Unknown complete search AX serialization')
            if not value or any(ord(c) < 32 or ord(c) == 127 or c in '\u200b\u2028\u2029' for c in value): raise ValueError('Search query must be bounded nonempty single-line text')
            if args.get('expected_value') != value + '\u200b\n': raise ValueError('Search replacement requires the exact complete final query serialization')
        elif 'expected_before' in args: raise ValueError('expected_before requires search replacement')
    if cmd == 'clear_text':
        if not isinstance(args.get('expected_value'), str): raise ValueError('expected_value required')
        if not isinstance(args.get('expected_empty_value'), str) or len(args['expected_empty_value']) > 65536: raise ValueError('expected_empty_value must be a string of at most 65536 characters')
    if cmd == 'submit_text':
        if args.get('app') != 'com.bytedance.macos.feishu' or args.get('window_title') != '飞书': raise ValueError('submit_text requires the exact Feishu main window')
        if args.get('allow_submit') is not True: raise ValueError('submit_text requires existing exact current-human authorization')
        for field, limit in [('element_id', 1024), ('recipient_element_id', 1024), ('expected_recipient', 1024), ('expected_value', 65536)]:
            if not isinstance(args.get(field), str) or not args[field] or len(args[field]) > limit: raise ValueError(field + ' must be a nonempty bounded string')
        if not isinstance(args.get('expected_empty_value'), str) or len(args['expected_empty_value']) > 65536: raise ValueError('expected_empty_value must be a bounded string')
        if args['element_id'] == args['recipient_element_id'] or args['expected_value'] == args['expected_empty_value']: raise ValueError('Distinct composer/header and nonempty message required')
    if 'enable_accessibility' in args and type(args['enable_accessibility']) is not bool: raise ValueError('enable_accessibility must be a boolean')
    if 'compact' in args and type(args['compact']) is not bool: raise ValueError('compact must be a boolean')
    if 'include_menus' in args and type(args['include_menus']) is not bool: raise ValueError('include_menus must be a boolean')
    if cmd in VISUAL_COMMANDS:
        for name in VISUAL_REQUIRED[cmd]:
            if name not in args: raise ValueError(name + ' required')
        if 'regions' in args:
            if 'region' in args: raise ValueError('region and regions are mutually exclusive')
            if not isinstance(args['regions'], list) or not 1 <= len(args['regions']) <= 8: raise ValueError('regions must contain 1..8 rectangles')
            for rect in args['regions']:
                if not isinstance(rect, dict) or set(rect) != {'x', 'y', 'width', 'height'}: raise ValueError('regions require x,y,width,height')
                if any(type(rect[k]) not in (int, float) or not math.isfinite(rect[k]) for k in rect): raise ValueError('regions coordinates must be finite')
                if rect['width'] <= 0 or rect['height'] <= 0: raise ValueError('regions sizes must be positive')
        for name in ['region', 'control_rect']:
            if name not in args: continue
            rect = args[name]
            if not isinstance(rect, dict) or set(rect) != {'x', 'y', 'width', 'height'}: raise ValueError(name + ' must contain x,y,width,height only')
            if any(type(rect[k]) not in (int, float) or not math.isfinite(rect[k]) for k in rect): raise ValueError(name + ' coordinates must be finite')
            if rect['width'] <= 0 or rect['height'] <= 0: raise ValueError(name + ' size must be positive')
        for name in ['confirm_target', 'confirm_control']:
            if name in args and type(args[name]) is not bool: raise ValueError(name + ' must be a boolean')
        anchors = args.get('anchor_texts', [])
        if not isinstance(anchors, list) or len(anchors) > 8 or any(not isinstance(x, str) or not x or len(x) > 128 for x in anchors): raise ValueError('anchor_texts must contain up to 8 nonempty strings')
        if args.get('confirm_target') and len(anchors) < 2: raise ValueError('Two observed target anchors are required before visual input')
        if 'debug_image_path' in args and (not isinstance(args['debug_image_path'], str) or not Path(args['debug_image_path']).is_absolute()): raise ValueError('debug_image_path must be an absolute local path')
        if 'anchor_wait_timeout_ms' in args and (type(args['anchor_wait_timeout_ms']) is not int or not 0 <= args['anchor_wait_timeout_ms'] <= 3000): raise ValueError('anchor_wait_timeout_ms out of range')
        if 'max_text_rows' in args and (type(args['max_text_rows']) is not int or not 1 <= args['max_text_rows'] <= 100): raise ValueError('max_text_rows out of range')
        if 'max_age_ms' in args and (type(args['max_age_ms']) is not int or not 1 <= args['max_age_ms'] <= 5000): raise ValueError('max_age_ms out of range')
        if cmd != 'visual_read':
            if not isinstance(args['snapshot_id'], str) or not args['snapshot_id']: raise ValueError('snapshot_id required')
            if args['control_kind'] not in ['search', 'chat_composer', 'navigation'] or args['confirm_control'] is not True: raise ValueError('An identified confirmed visual control is required')
        if cmd in {'visual_click', 'visual_scroll'}:
            has_point='x' in args or 'y' in args
            if has_point or cmd == 'visual_scroll' or args['control_kind'] != 'navigation':
                if any(type(args.get(k)) not in (int, float) or not math.isfinite(args[k]) for k in ['x', 'y']): raise ValueError('Finite click/scroll point required')
        if 'wait_timeout_ms' in args and (type(args['wait_timeout_ms']) is not int or not 0 <= args['wait_timeout_ms'] <= 3000): raise ValueError('wait_timeout_ms out of range')
        navigation_kind = args.get('navigation_target_kind', 'text')
        if 'navigation_target_kind' in args and (cmd != 'visual_click' or args['control_kind'] != 'navigation' or navigation_kind not in ('text', 'icon')): raise ValueError('navigation_target_kind is text or icon on navigation visual_click only')
        if cmd == 'visual_click' and args['control_kind'] == 'navigation':
            if navigation_kind == 'icon':
                if 'target_text' in args: raise ValueError('Icon navigation must omit target_text')
                if any(type(args.get(k)) not in (int, float) or not math.isfinite(args[k]) for k in ['x', 'y']): raise ValueError('Icon navigation requires explicit finite x and y')
                r = args['control_rect']
                if not (r['x'] <= args['x'] < r['x'] + r['width'] and r['y'] <= args['y'] < r['y'] + r['height']): raise ValueError('Icon point must lie inside control_rect')
            elif not isinstance(args.get('target_text'), str) or not args['target_text']: raise ValueError('Text navigation requires target_text')
        if cmd == 'visual_type_text':
            if 'replace_search' in args and type(args['replace_search']) is not bool: raise ValueError('replace_search must be a boolean')
            if args.get('replace_search') and args['control_kind'] != 'search': raise ValueError('replace_search is restricted to an authorized search control')
            text = args['text']; expected = args['expected_text']
            if args.get('replace_search') and text != expected: raise ValueError('Search replacement requires the complete desired query as expected_text')
            if not isinstance(text, str) or not text or len(text) > 4096 or any(c in text for c in '\n\r\t'): raise ValueError('Visual input must be nonempty single-line text up to 4096 characters')
            if not isinstance(expected, str) or len(expected) > 4096 or text not in expected or any(c in expected for c in '\n\r\t'): raise ValueError('expected_text must contain the complete requested single-line text')
        if cmd == 'visual_key':
            if not isinstance(args['key'], str): raise ValueError('visual key required')
            if 'allow_submit' in args and type(args['allow_submit']) is not bool: raise ValueError('allow_submit must be a boolean')
            if args['key'].lower() == 'clear_prefix':
                import unicodedata
                prefix=args.get('prefix'); draft=args.get('expected_draft'); title=args.get('chat_title')
                if args.get('control_kind') != 'chat_composer' or args.get('modifiers') or args.get('allow_submit'): raise ValueError('clear_prefix requires an unmodified confirmed composer without submit')
                if not isinstance(prefix, str) or not 1 <= len(prefix) <= 64 or any(ord(c) > 0xffff or unicodedata.category(c)[0] not in 'LNP' for c in prefix): raise ValueError('prefix must be ordinary BMP characters, without controls, separators or combining marks')
                if not isinstance(draft, str) or len(draft) > 4096 or not draft.startswith(prefix): raise ValueError('Complete expected_draft must start with exact prefix')
                if not isinstance(title, str) or not title or len(title)>128: raise ValueError('Exact chat_title required for prefix clearing')
            if args['key'].lower() in ['enter', 'return']:
                if args.get('allow_submit') is not True or args['control_kind'] != 'chat_composer': raise ValueError('Return requires an explicitly authorized composer submission')
                message=args.get('expected_message'); title=args.get('chat_title')
                if not isinstance(message, str) or not message or len(message)>4096: raise ValueError('expected_message required for submission')
                if not isinstance(title, str) or not title or len(title)>128: raise ValueError('chat_title required for submission')
            mods=args.get('modifiers', [])
            if not isinstance(mods, list) or len(mods)>4 or any(m not in ['cmd','shift','alt','ctrl'] for m in mods): raise ValueError('Invalid visual key modifiers')
            if args['key'].lower() in ['enter','return'] and mods: raise ValueError('Authorized visual submission requires unmodified Return')
        if cmd == 'visual_scroll' and (type(args['delta_y']) is not int or not -100 <= args['delta_y'] <= 100): raise ValueError('delta_y out of range')
    if cmd == 'key':
        if not isinstance(args.get('key'), str): raise ValueError('key required')
        mods = args.get('modifiers', [])
        if not isinstance(mods, list) or len(mods) > 4 or any(m not in ['cmd', 'shift', 'alt', 'ctrl'] for m in mods): raise ValueError('Invalid key modifiers')
    if cmd in {'click', 'scroll'}:
        if 'element_id' not in args and not all(isinstance(args.get(k), (int, float)) and not isinstance(args[k], bool) and math.isfinite(args[k]) for k in ['x', 'y']): raise ValueError('click requires element_id or numeric x/y')
        if 'element_id' in args and ('x' in args or 'y' in args): raise ValueError('choose element_id or coordinates')
    if cmd == 'scroll' and (type(args.get('delta_y')) is not int or not -100 <= args['delta_y'] <= 100 or args['delta_y'] == 0): raise ValueError('scroll delta_y must be a nonzero integer in -100..100')
    for k, low, high in [('max_depth', 1, 40), ('max_nodes', 1, 2000), ('timeout_ms', 0, 5000)]:
        if k in args and (type(args[k]) is not int or not low <= args[k] <= high): raise ValueError(k + ' out of range')
    if cmd == 'batch':
        actions = args.get('actions')
        if not isinstance(actions, list) or not 1 <= len(actions) <= 32: raise ValueError('batch requires 1..32 actions')
        if any(isinstance(action, dict) and action.get('include_image') for action in actions) and any(isinstance(action, dict) and 'debug_image_path' in action for action in actions):
            raise ValueError('Model-image batches cannot publish raw diagnostic image paths')
        for action in actions:
            if not isinstance(action, dict) or action.get('command') not in {'press', 'click', 'set_text', 'type_text', 'clear_text', 'submit_text', 'key', 'scroll', 'wait_text'} | VISUAL_COMMANDS: raise ValueError('invalid batch action')
            if 'app' in action or 'window_title' in action: raise ValueError('batch actions cannot change target')
            validate(action['command'], {**{k: args[k] for k in COMMON if k in args}, **{k: v for k, v in action.items() if k != 'command'}})

BRIDGE = NativeBridge()
atexit.register(BRIDGE.close)
TOOLS.extend([CHAT_TOOL, RECIPE_TOOL, OBSERVE_TOOL])
TOOLS.extend([TRANSACTION_TOOL,TASK_TOOL,SCRIPT_TOOL])
add_runtime_schema(TOOLS)
_RUNTIME=None

def runtime():
    global _RUNTIME
    if _RUNTIME is None:_RUNTIME=TaskRuntime(directory=os.environ.get('INTEL_DESKTOP_RUNTIME_DIR'))
    return _RUNTIME

def dispatch_plain(cmd,arguments):
    if cmd=='chat':return execute_chat(arguments,lambda request:BRIDGE.call(request['command'],{k:v for k,v in request.items() if k!='command'}))
    if cmd=='observe':return execute_observation(arguments,lambda request:BRIDGE.call(request['command'],{k:v for k,v in request.items() if k!='command'}))
    if cmd=='recipe':return execute_recipe(arguments)
    return BRIDGE.call(cmd,arguments)

def action_arguments(cmd):
    if cmd=='chat':return set(CHAT_TOOL['inputSchema']['properties'])
    if cmd=='observe':return set(OBSERVE_TOOL['inputSchema']['properties'])
    if cmd not in PROPS:raise ValueError('Unknown workflow action')
    return set(PROPS[cmd])
dispatch_plain.allowed_arguments=action_arguments

def managed_call(cmd,arguments):
    engine=runtime();args,meta=runtime_arguments(arguments,engine)
    if cmd=='task':return task_action(args,meta,engine)
    if cmd not in COMMANDS|{'chat','observe','recipe','transaction','script'}:raise ValueError('Unknown tool')
    def execute(context):
        try:
            if cmd=='transaction':response=execute_transaction(args,dispatch_plain,context)
            elif cmd=='script':response=script_action(args,dispatch_plain,context,engine)
            else:response=dispatch_plain(cmd,args)
        except ValueError as error:
            response={'ok':False,'error':{'code':'invalid_request','message':str(error)},'validation_failed':True,'automatic_replay_allowed':False}
        except RuntimeError as error:
            response={'ok':False,'error':{'code':'bridge_failure','message':str(error)},'completion_unknown':True,'automatic_replay_allowed':False}
        classify_result(cmd,args,response,context)
        return response
    packet=engine.run('desktop_'+cmd,args,execute,**meta)
    summary=packet['summary'];response=packet.get('response')
    if response is None:
        successful=summary['state'] in {'verified','completed','accepted_unverified'}
        executed=packet['executed']
        response={'ok':successful,'executed':executed,'duplicate':packet.get('duplicate',False),'events_posted':summary['event_count'] if executed else 0,
                  'result':{'original_execution':summary,'fresh_result_required':True},'automatic_replay_allowed':False}
        if not successful:response['error']={'code':summary.get('error_code') or 'operation_already_recorded','message':('Execution stopped at a safe boundary; earlier completed steps are recorded and no action was replayed' if executed else 'No new action was executed; inspect the recorded outcome before another invocation')}
        if cmd=='script' and summary.get('source',{}).get('script_id'):response['script_id']=summary['source']['script_id']
    response.update(task_id=summary['task_id'],operation_id=summary['operation_id'],transaction_id=summary['transaction_id'],chain_id=summary['chain_id'],
                    execution={'state':summary['state'],'executed':packet['executed'],'queue_wait_ms':summary['queue_wait_ms'],'duration_ms':summary['duration_ms'],'event_count':summary['event_count']})
    if cmd=='script':after_script_result(response,engine)
    return response

def handle(req):
    method = req.get('method')
    if method == 'initialize':
        return {'protocolVersion': req.get('params', {}).get('protocolVersion', '2024-11-05'),
                'capabilities': {'tools': {'listChanged': False}}, 'serverInfo': {'name': 'intel-desktop', 'version': '0.1.73'},
                'instructions': 'Native Intel Mac desktop control. Use only for apps authorized by the current user task. Prefer AX inspection and fixed-target batches for foreground work. desktop_observe reads a currently authorized native app without focus or input; known chats use their adapters and unfamiliar apps retain current-model AX plus masked-window visual recognition; historical HID interruption does not block read-only observation. desktop_chat background:true supports current-chat draft/clear with a freshly verified recipient; chat may be omitted. The process/window-bound editor preserves system focus, verifies exact before/after values, yields on target-app contention and never sends or falls back to global input. Known foreign-app activity may continue on the same or another display. For shared foreground input, claim once per authorized stage, monitor new post-claim activity and restore the saved origin only without takeover; never refocus or replay an interrupted stage. Optional MCP PNG blocks and semantic state are consumed by the current model, without a new model service. The WeChat route takes a fresh complete exact-filter PTS frame each time; bound warm streams and exact-pixel ROI OCR rows do not substitute old-frame input proof. Feishu paste temporarily leases and ownership-restores the general clipboard; clipboard isolation is not provided. All MCP calls and direct NativeBridge calls share one FIFO. Use a stable task_id and an atomic chat, batch or transaction for a foreground stage; separate model calls do not reserve the desktop while thinking. Actual response versions and execution metadata outrank a stale tool description. WeChat AX shells support navigation-only coordinate clicks in the verified sidebar; compositor/body typing still requires the visual route. Never claim success from posted events alone. Sending requires current-human authorization for the exact recipient and content; unsent-draft tests never send.'}
    if method == 'ping': return {}
    if method == 'tools/list': return {'tools': TOOLS}
    if method == 'tools/call':
        params = req.get('params', {})
        name = params.get('name', '')
        cmd = name.removeprefix('desktop_') if hasattr(name, 'removeprefix') else name[8:]
        if name != 'desktop_' + cmd: raise ValueError('Unknown tool')
        started = time.perf_counter()
        arguments = params.get('arguments', {})
        response=managed_call(cmd,arguments)
        if cmd == 'status' and response.get('ok'):
            response['result']['plugin_version'] = '0.1.73'
            response['result']['plugin_runtime_features'] = {'guarded_focus_return': 3, 'operation_scoped_capture': True, 'feishu_send_stages': 1, 'feishu_submit_focus_return': 1, 'all_window_menu_optional': 1, 'capture_lifecycle_shutdown': 2, 'background_chat_capture_finalizer': 1, 'feishu_complete_body_proof': 1, 'wechat_pre_input_focus_return': 1, 'wechat_submit_focus_return': 1, 'completion_purpose_proof': 1, 'persistent_interaction_notice': 1, 'wechat_atomic_composer_edit': 1, 'wechat_submit_posted_receipt': 1}
        response['bridge_elapsed_ms'] = round((time.perf_counter() - started) * 1000, 3)
        content = mcp_content(response)
        if any(block['type'] == 'image' for block in content['content']):
            # visual_read's native result binds PID/window/snapshot/topology;
            # retain the exact app/window request alongside the emitted image.
            metadata = json.loads(content['content'][0]['text'])
            target = {key: arguments[key] for key in ('app', 'window_title') if key in arguments}
            if 'window_title' not in target and isinstance(response.get('result'), dict):
                title = response['result'].get('window_title')
                if isinstance(title, str): target['window_title'] = title
            metadata['image_request_target'] = target
            content['content'][0]['text'] = json.dumps(metadata, ensure_ascii=False)
        return content
    raise LookupError('Method not found: ' + str(method))


def main():
    for line in sys.stdin.buffer:
        if len(line) > 2 * 1024 * 1024:
            continue
        try:
            req = json.loads(line)
            if not isinstance(req, dict): raise ValueError('Request must be an object')
        except (ValueError, UnicodeDecodeError):
            print(json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Invalid JSON request'}}), flush=True)
            continue
        if 'id' not in req: continue
        try:
            result = handle(req)
            out = {'jsonrpc': '2.0', 'id': req['id'], 'result': result}
        except LookupError as e:
            out = {'jsonrpc': '2.0', 'id': req['id'], 'error': {'code': -32601, 'message': str(e)}}
        except Exception as e:
            if req.get('method') == 'tools/call':
                invalid = isinstance(e, ValueError)
                failure = {'ok': False, 'error': {'code': 'invalid_request' if invalid else 'bridge_failure', 'message': str(e)}, 'automatic_replay_allowed': False}
                if invalid: failure.update(events_posted=0, validation_failed=True)
                else: failure['completion_unknown'] = True
                out = {'jsonrpc': '2.0', 'id': req['id'], 'result': {'content': [{'type': 'text', 'text': json.dumps(failure, ensure_ascii=False)}], 'isError': True}}
            else:
                out = {'jsonrpc': '2.0', 'id': req['id'], 'error': {'code': -32602, 'message': str(e)}}
        print(json.dumps(out, ensure_ascii=False), flush=True)

if __name__ == '__main__': main()
