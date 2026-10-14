"""Stage-end origin restoration with no content reads or user-focus reclaim."""
import copy
import unittest

from test_chat_workflows import WeChatFake
from chat_workflows import WECHAT, execute_chat, _focus_receipt
from desktop_client import client_payload
from mcp_images import mcp_content


class RestoreFake(WeChatFake):
    def __init__(self):
        super().__init__()
        self.origin_saved = False
        self.original_window = "original-exact-window"
        self.front_app = "com.example.original"
        self.restore_error = False
        self.after_focus_interruption = None

    def __call__(self, request):
        if request["command"] == "focus" and request.get("restore_previous"):
            self.calls.append(copy.deepcopy(request))
            self.assert_no_caller_origin(request)
            self.origin_saved = False
            if self.restore_error:
                return {"ok": False, "error": {"code": "origin_window_unavailable", "message": "Saved window vanished", "details": {"events_posted": 0}}}
            if self.interrupted or self.front_app != self.app:
                return {"ok": True, "result": {"focus_restored": False, "focus_restore_attempted": False,
                                               "restore_reason": "new_user_activity" if self.interrupted else "focus_changed", "events_posted": 0}}
            self.front_app = "com.example.original"
            return {"ok": True, "result": {"focus_restored": True, "focus_restore_attempted": True, "restore_reason": "restored",
                                           "target_pid": 999, "restored_window": self.original_window, "events_posted": 0}}
        response = super().__call__(request)
        if request["command"] == "focus":
            self.origin_saved = True
            self.front_app = self.app
            self.interrupted = self.after_focus_interruption
        return response

    @staticmethod
    def assert_no_caller_origin(request):
        if any(key.startswith("origin") or key.startswith("previous_") for key in request):
            raise AssertionError("Caller must not supply arbitrary restore origins")


class FocusRestoreTests(unittest.TestCase):
    def restores(self, fake):
        return [call for call in fake.calls if call["command"] == "focus" and call.get("restore_previous")]

    def scoped_restore(self, receipt, business_failure=False):
        fake = RestoreFake()
        if business_failure:
            fake.draft = "保留已有草稿"
        def callback(request):
            response = fake(request)
            if request['command'] == 'focus' and request.get('restore_previous'):
                response['result'].update(copy.deepcopy(receipt))
            return response
        request = {"app": WECHAT, "action": "draft", "text": "新草稿"} if business_failure else {"app": WECHAT, "action": "read"}
        return execute_chat(request, callback, recipe_store=False)

    def test_actual_native_app_only_receipt_survives_success_failure_and_metadata_client(self):
        receipt = {"focus_restored_app": True, "window_verified": False, "window_unknown": True,
                   "original_window_reference_unavailable": True, "restore_scope": "app_only", "previous_focus_scope": "exact_window",
                   "restore_raise_attempted": False, "restore_raise_result": None, "restore_verify_limit_ms": 400,
                   "restore_reason": "previous_window_unavailable_app_restored"}
        for business_failure in (False, True):
            result = self.scoped_restore(receipt, business_failure)
            self.assertEqual(result['ok'], not business_failure)
            self.assertTrue(result['focus_restored'])
            for key, value in receipt.items():
                self.assertEqual(result[key], value)
            payload = client_payload(mcp_content(result))
            if business_failure:
                self.assertTrue(payload.pop('mcp_is_error'))
            self.assertEqual(payload, result)

    def test_actual_native_exact_window_receipt_keeps_window_verification_and_AX_code(self):
        receipt = {"focus_restored_app": True, "window_verified": True, "window_unknown": False,
                   "original_window_reference_unavailable": False, "restore_scope": "exact_window", "previous_focus_scope": "exact_window",
                   "restore_raise_attempted": True, "restore_raise_result": {"code": -25208, "name": "not_implemented"},
                   "restore_verify_limit_ms": 400, "restore_reason": "previous_window_verified"}
        result = self.scoped_restore(receipt)
        self.assertTrue(result['ok'], result)
        for key, value in receipt.items():
            self.assertEqual(result[key], value)
        self.assertEqual(client_payload(mcp_content(result)), result)

    def test_native_restore_error_details_keep_typed_scope_without_invalidating_business(self):
        fake = RestoreFake()
        fake.restore_error = True
        receipt = {"focus_restored_app": False, "window_verified": False, "window_unknown": True,
                   "restore_scope": "app_only", "previous_focus_scope": "exact_window", "original_window_reference_unavailable": True}
        def callback(request):
            response = fake(request)
            if request['command'] == 'focus' and request.get('restore_previous'):
                response['error']['details'].update(receipt)
            return response
        result = execute_chat({"app": WECHAT, "action": "read"}, callback, recipe_store=False)
        self.assertTrue(result['ok'], result)
        self.assertFalse(result['focus_restored'])
        for key, value in receipt.items():
            self.assertEqual(result[key], value)
        self.assertEqual(len(self.restores(fake)), 1)

    def test_receipts_are_typed_bounded_metadata_without_origin_content(self):
        receipt = _focus_receipt({"focus_restored_app": "true", "window_verified": 1, "window_unknown": False,
                                  "restore_scope": "app_only", "previous_focus_scope": "arbitrary_window",
                                  "restore_raise_result": {"code": -25208, "name": "not_implemented", "title": "private"},
                                  "restore_verify_limit_ms": 6000, "origin_title": "private"})
        self.assertEqual(receipt, {"window_unknown": False, "restore_scope": "app_only", "restore_raise_result": {"code": -25208, "name": "not_implemented"}})

    def test_native_owned_navigation_diagnostic_survives_success_failure_and_client(self):
        # Actual producer keys/enums; numeric identities are synthetic public
        # metadata, not a claim that this fake backend captured a real window.
        diagnostic = {"candidate_reason": "bound", "candidate_available": True, "target_pid": 456,
                      "action_accepted": True, "claim_available": True, "claim_complete": True, "monitor_available": True,
                      "interrupted": False, "claimed_window_matches_selected": True, "claimed_PID_matches_selected": True,
                      "claimed_topology_matches": True, "claim_bound_to_modal": True, "main_AX_match_count": 1,
                      "main_frame": {"x": 2200, "y": 110, "width": 1316, "height": 750},
                      "modal_frame": {"x": 100, "y": 100, "width": 1316, "height": 750},
                      "main_matches_AXMainWindow": True, "modal_matches_AXFocusedWindow": True, "same_frame_CG_count": 1,
                      "same_frame_CG_rows": [{"window_id": 25001, "layer": 0, "onscreen": True, "alpha": 1}],
                      "same_frame_CG_rows_truncated": False, "main_CG_window_id": 25001,
                      "AX_main_identity_unchanged": True, "CG_main_identity_unchanged": True, "current_main_CG_window_id": 25001,
                      "modal_absent": True, "target_frontmost": True, "actual_AXMainWindow_matches": True,
                      "actual_AXFocusedWindow_matches": True, "topology_matches": True, "adoption_reason": "verified_owned_modal_to_main"}
        receipt = {"owned_navigation_focus_updated": True, "owned_navigation_diagnostic": diagnostic}
        for business_failure in (False, True):
            result = self.scoped_restore(receipt, business_failure)
            self.assertEqual(result['ok'], not business_failure)
            self.assertTrue(result['owned_navigation_focus_updated'])
            self.assertEqual(result['owned_navigation_diagnostic'], diagnostic)
            payload = client_payload(mcp_content(result))
            payload.pop('mcp_is_error', None)
            self.assertEqual(payload['owned_navigation_diagnostic'], diagnostic)

    def test_owned_navigation_diagnostic_is_bounded_and_excludes_content(self):
        rows = [{"window_id": 200 + index, "layer": 0, "onscreen": True, "alpha": .5, "title": "private", "body": "private"} for index in range(12)]
        diagnostic = {"candidate_reason": "main_CG_identity_ambiguous_or_unavailable", "adoption_reason": "x" * 10000,
                      "candidate_available": False, "claim_complete": 1, "target_pid": True, "main_AX_match_count": -1,
                      "same_frame_CG_count": 12, "main_CG_window_id": 2**32, "current_main_CG_window_id": None,
                      "main_frame": {"x": 10, "y": -20, "width": 900, "height": 700, "title": "private"},
                      "modal_frame": {"x": float('nan'), "y": 0, "width": 900, "height": 700},
                      "same_frame_CG_rows": rows, "same_frame_CG_rows_truncated": False, "window_title": "private", "text": "private"}
        receipt = _focus_receipt({"owned_navigation_focus_updated": "true", "owned_navigation_diagnostic": diagnostic})
        self.assertNotIn('owned_navigation_focus_updated', receipt)
        clean = receipt['owned_navigation_diagnostic']
        self.assertEqual(clean['candidate_reason'], diagnostic['candidate_reason'])
        self.assertFalse(clean['candidate_available'])
        self.assertEqual(len(clean['same_frame_CG_rows']), 8)
        self.assertTrue(clean['same_frame_CG_rows_truncated'])
        self.assertEqual(clean['main_frame'], {"x": 10, "y": -20, "width": 900, "height": 700})
        self.assertIsNone(clean['current_main_CG_window_id'])
        for key in ('adoption_reason', 'claim_complete', 'target_pid', 'main_AX_match_count', 'main_CG_window_id', 'modal_frame', 'window_title', 'text'):
            self.assertNotIn(key, clean)
        self.assertFalse(any('title' in row or 'body' in row for row in clean['same_frame_CG_rows']))

    def test_owned_navigation_diagnostic_rejects_malformed_numbers_and_keeps_explicit_absence(self):
        self.assertEqual(_focus_receipt({"owned_navigation_focus_updated": False, "owned_navigation_diagnostic": None}),
                         {"owned_navigation_focus_updated": False, "owned_navigation_diagnostic": None})
        receipt = _focus_receipt({"owned_navigation_diagnostic": {"main_frame": {"x": 10**400, "y": 0, "width": 1, "height": 1},
                                  "modal_frame": {"x": 0, "y": 0, "width": 0, "height": 1},
                                  "same_frame_CG_rows": [None, {"window_id": True, "layer": "0", "onscreen": 1, "alpha": 10**400},
                                                         {"window_id": 123, "alpha": float('inf')}], "candidate_reason": ["bound"]}})
        self.assertEqual(receipt, {"owned_navigation_diagnostic": {"same_frame_CG_rows": [{"window_id": 123}]}})

    def test_unavailable_target_content_stops_before_bootstrap_or_input_and_restores(self):
        fake = RestoreFake()
        def callback(request):
            response = fake(request)
            if request['command'] == 'visual_read':
                response['result'].update(content_available=False, captured_regions=[], ocr=[], anchor_matches=[],
                                          target_visible_verified=False, content_reason='no_readable_target_RGBA', capture_method='m' * 400)
            return response
        result = execute_chat({'app': WECHAT, 'action': 'locate', 'chat': fake.title}, callback, recipe_store=False)
        self.assertFalse(result['ok'])
        self.assertEqual(result['error']['code'], 'wechat_content_unavailable')
        self.assertEqual(result['error']['details']['content_reason'], 'no_readable_target_RGBA')
        self.assertEqual(len(result['error']['details']['capture_method']), 256)
        self.assertTrue(result['error']['details']['navigation_only'])
        self.assertTrue(result['focus_restored'])
        self.assertEqual(len([call for call in fake.calls if call['command'] == 'visual_read']), 1)
        self.assertEqual(len(self.restores(fake)), 1)
        self.assertFalse(any(call['command'] in {'visual_click', 'visual_key', 'visual_type_text', 'batch', 'key', 'type_text', 'submit_text'} for call in fake.calls))
        self.assertFalse(result['automatic_replay_allowed'])

    def test_legacy_missing_content_available_keeps_successful_read(self):
        fake = RestoreFake()
        result = execute_chat({'app': WECHAT, 'action': 'read'}, fake, recipe_store=False)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['result']['visible_text'], '新消息\n最后回复')
        self.assertTrue(result['focus_restored'])
        self.assertEqual(len([call for call in fake.calls if call['command'] == 'visual_read']), 1)

    def test_complete_available_capture_keeps_existing_read_flow(self):
        fake = RestoreFake()
        def callback(request):
            response = fake(request)
            if request['command'] == 'visual_read':
                response['result'].update(content_available=True, captured_regions=[dict(fake.frame)])
            return response
        result = execute_chat({'app': WECHAT, 'action': 'read'}, callback, recipe_store=False)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['result']['visible_text'], '新消息\n最后回复')
        self.assertTrue(result['focus_restored'])
        self.assertEqual(len([call for call in fake.calls if call['command'] == 'visual_read']), 1)

    def test_same_title_notification_uses_native_verified_main_never_largest_frame(self):
        fake = RestoreFake()
        def callback(request):
            response = fake(request)
            if request['command'] == 'inspect':
                main = response['result']['windows'][0]
                main.update(is_actual_main_window=True, actual_main_window_id=33789)
                notification = copy.deepcopy(main)
                notification.update(element_id='notification', is_actual_main_window=False)
                notification['position'] = {'x': 0, 'y': 0}
                notification['size'] = {'width': 2000, 'height': 1900}
                response['result']['windows'] = [notification, main]
            return response
        result = execute_chat({'app': WECHAT, 'action': 'read'}, callback, recipe_store=False)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['result']['visible_text'], '新消息\n最后回复')
        self.assertEqual(len([call for call in fake.calls if call['command'] == 'focus' and not call.get('restore_previous')]), 1)

    def test_same_title_windows_without_native_main_proof_stay_ambiguous_before_focus(self):
        for evidence in ({}, {'is_actual_main_window': True}, {'is_actual_main_window': True, 'actual_main_window_id': True}):
            fake = RestoreFake()
            def callback(request):
                response = fake(request)
                if request['command'] == 'inspect':
                    main = response['result']['windows'][0]
                    main.update(evidence)
                    notification = copy.deepcopy(main)
                    notification.update(element_id='notification', is_actual_main_window=False)
                    response['result']['windows'] = [main, notification]
                return response
            result = execute_chat({'app': WECHAT, 'action': 'read'}, callback, recipe_store=False)
            self.assertFalse(result['ok'])
            self.assertEqual(result['error']['code'], 'ambiguous_target')
            self.assertEqual([call['command'] for call in fake.calls], ['status', 'inspect'])

    def test_success_restores_saved_exact_origin_without_changing_business_pid(self):
        fake = RestoreFake()
        result = execute_chat({"app": WECHAT, "action": "draft", "text": "阶段测试"}, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["focus_restored"])
        self.assertEqual(result["restore_reason"], "restored")
        self.assertEqual(result["result"]["target_pid"], fake.pid)
        self.assertEqual(fake.front_app, "com.example.original")
        self.assertEqual(fake.calls[-1]["command"], "focus")
        self.assertTrue(fake.calls[-1]["restore_previous"])
        self.assertEqual(len(self.restores(fake)), 1)
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_type_text"]), 1)

    def test_safe_business_failure_restores_without_replay_or_overwrite(self):
        fake = RestoreFake()
        fake.draft = "已有用户草稿"
        result = execute_chat({"app": WECHAT, "action": "draft", "text": "新草稿"}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_present")
        self.assertTrue(result["focus_restored"])
        self.assertEqual(fake.draft, "已有用户草稿")
        self.assertEqual(len(self.restores(fake)), 1)
        self.assertFalse(any(call["command"] in {"visual_type_text", "visual_key", "visual_click"} for call in fake.calls))

    def test_post_claim_user_activity_skips_restore_and_never_reclaims(self):
        fake = RestoreFake()
        fake.after_focus_interruption = "manual_after_claim"
        result = execute_chat({"app": WECHAT, "action": "read"}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "user_interrupted")
        self.assertFalse(result["focus_restored"])
        self.assertEqual(result["restore_reason"], "user_interrupted")
        self.assertEqual(self.restores(fake), [])
        self.assertEqual(len([call for call in fake.calls if call["command"] == "focus"]), 1)

    def test_native_late_activity_skip_preserves_verified_business_result(self):
        fake = RestoreFake()
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_read":
                fake.interrupted = "manual_after_capture"
            return response
        result = execute_chat({"app": WECHAT, "action": "read"}, callback, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["focus_restored"])
        self.assertEqual(result["restore_reason"], "new_user_activity")
        self.assertEqual(fake.front_app, fake.app)
        self.assertFalse(fake.origin_saved)

    def test_native_focus_changed_skip_leaves_user_selected_app_untouched(self):
        fake = RestoreFake()
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_read":
                fake.front_app = "com.example.userselected"
            return response
        result = execute_chat({"app": WECHAT, "action": "read"}, callback, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["focus_restored"])
        self.assertEqual(result["restore_reason"], "focus_changed")
        self.assertEqual(fake.front_app, "com.example.userselected")

    def test_restore_failure_does_not_invalidate_verified_input_or_retry_it(self):
        fake = RestoreFake()
        fake.restore_error = True
        result = execute_chat({"app": WECHAT, "action": "draft", "text": "只输入一次"}, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["result"]["draft_verified"])
        self.assertFalse(result["focus_restored"])
        self.assertEqual(result["restore_reason"], "origin_window_unavailable")
        self.assertEqual(len(self.restores(fake)), 1)
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_type_text"]), 1)

    def test_unknown_input_completion_does_not_attempt_focus_restoration(self):
        fake = RestoreFake()
        def callback(request):
            if request["command"] == "visual_type_text":
                fake.calls.append(copy.deepcopy(request))
                fake.draft = "未知部分输入"
                raise OSError("Fake lost completion")
            return fake(request)
        result = execute_chat({"app": WECHAT, "action": "draft", "text": "完整请求"}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "native_transport_error")
        self.assertEqual(result["restore_reason"], "unknown_input_outcome")
        self.assertEqual(self.restores(fake), [])
        self.assertEqual(len([call for call in fake.calls if call["command"] == "visual_type_text"]), 1)

    def test_pre_schema_failure_has_zero_calls_and_no_restore(self):
        fake = RestoreFake()
        result = execute_chat({"app": WECHAT, "action": "clear_prefix", "prefix": "缺少聊天"}, fake, recipe_store=False)
        self.assertFalse(result["ok"])
        self.assertEqual(fake.calls, [])
        self.assertNotIn("focus_restored", result)

    def test_popup_navigation_failure_returns_focus_without_replaying_click(self):
        from chat_workflows import ChatSession, Stopped
        fake = RestoreFake()
        session = ChatSession({"app": WECHAT, "action": "read"}, fake)
        session.start()
        original = session.invoke
        def fail(request):
            if request["command"] == "batch":
                fake.calls.append(copy.deepcopy(request))
                return {"ok": False, "error": {"code": "visual_target_changed", "message": "Popup appeared", "details": {"failed_index": 0, "events_posted": 2, "input_may_be_partial": True}}}
            return original(request)
        session.invoke = fail
        with self.assertRaises(Stopped) as caught:
            session.call("batch", actions=[{"command": "visual_click", "control_kind": "search"}, {"command": "visual_type_text", "control_kind": "chat_composer"}])
        self.assertTrue(caught.exception.details["navigation_only"])
        self.assertTrue(session.finish_focus(caught.exception)["focus_restored"])
        self.assertEqual(len([c for c in fake.calls if c["command"] == "batch"]), 1)

    def test_partial_composer_typing_failure_does_not_restore_or_replay(self):
        from chat_workflows import ChatSession, Stopped
        fake = RestoreFake()
        session = ChatSession({"app": WECHAT, "action": "read"}, fake)
        session.start()
        def fail(request):
            return {"ok": False, "error": {"code": "visual_target_changed", "message": "Partial type", "details": {"failed_index": 1, "events_posted": 4, "input_may_be_partial": True}}}
        session.invoke = fail
        with self.assertRaises(Stopped) as caught:
            session.call("batch", actions=[{"command": "visual_click", "control_kind": "search"}, {"command": "visual_type_text", "control_kind": "chat_composer"}])
        self.assertNotIn("navigation_only", caught.exception.details)
        self.assertFalse(session.finish_focus(caught.exception)["focus_restore_attempted"])


if __name__ == "__main__":
    unittest.main()
