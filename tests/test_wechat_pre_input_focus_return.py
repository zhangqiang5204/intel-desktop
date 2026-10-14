"""Known pre-input OCR failure returns once through native takeover guards."""
import copy
import unittest

from chat_workflows import ChatSession, Stopped, WECHAT, execute_chat
from test_chat_workflows import bounds
from test_wechat_focus_restore import RestoreFake


class PreInputFocusReturnTests(unittest.TestCase):
    def request(self, fake, action="send"):
        request = {"app": WECHAT, "action": action, "chat": fake.title}
        if action in {"send", "draft"}:
            request["text"] = "离线新消息"
        if action == "send":
            request["send_authorization"] = {"source": "current_user", "app": WECHAT,
                                             "chat": fake.title, "text": request["text"]}
        if action == "clear":
            request["expected_draft"] = fake.draft
        return request

    def restores(self, fake):
        return [c for c in fake.calls if c["command"] == "focus" and c.get("restore_previous")]

    def assert_no_text_delete_or_submit(self, fake):
        self.assertFalse(any(c["command"] in {"visual_type_text", "visual_key", "type_text", "submit_text", "key"}
                             for c in fake.calls))
        self.assertEqual(sum(c["command"] == "visual_click" for c in fake.calls), 1)

    def test_post_click_unknown_glyph_stops_send_and_returns_without_changing_draft(self):
        fake = RestoreFake()
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_click" and request.get("control_kind") == "chat_composer":
                # A simulated OCR-only caret, not text we may strip or overwrite.
                f = fake.frame
                response["result"]["ocr"].append({"text": "I", "bounds": bounds(f["x"] + 340, f["y"] + f["height"] * .88, 8, 16)})
            return response
        result = execute_chat(self.request(fake), callback, recipe_store=False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertFalse(result["sent"])
        self.assertTrue(result["focus_restored"])
        self.assertEqual(fake.front_app, "com.example.original")
        self.assertEqual(fake.draft, "")
        self.assertEqual(len(self.restores(fake)), 1)
        self.assert_no_text_delete_or_submit(fake)

    def test_actual_changed_draft_is_preserved_for_draft_and_clear(self):
        for action in ("draft", "clear"):
            with self.subTest(action=action):
                fake = RestoreFake()
                fake.draft = "原有待清草稿" if action == "clear" else ""
                fake.change_on_click = "原生回读的新草稿"
                result = execute_chat(self.request(fake, action), fake, recipe_store=False)
                self.assertEqual(result["error"]["code"], "draft_changed")
                self.assertTrue(result["focus_restored"])
                self.assertEqual(fake.draft, fake.change_on_click)
                self.assertEqual(len(self.restores(fake)), 1)
                self.assert_no_text_delete_or_submit(fake)

    def test_real_activity_before_return_yields_without_activating_origin(self):
        fake = RestoreFake(); fake.change_on_click = "保留用户草稿"
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_click":
                fake.interrupted = "manual_after_click"
            return response
        result = execute_chat(self.request(fake), callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertFalse(result["focus_restored"])
        self.assertFalse(result["focus_restore_attempted"])
        self.assertEqual(result["restore_reason"], "new_user_activity")
        self.assertEqual(fake.front_app, fake.app)
        self.assertEqual(len(self.restores(fake)), 1)
        self.assert_no_text_delete_or_submit(fake)

    def test_user_changed_application_is_not_pulled_back(self):
        fake = RestoreFake(); fake.change_on_click = "保留变化"
        def callback(request):
            response = fake(request)
            if request["command"] == "visual_click":
                fake.front_app = "com.example.user-selected"
            return response
        result = execute_chat(self.request(fake), callback, recipe_store=False)
        self.assertFalse(result["focus_restored"])
        self.assertEqual(result["restore_reason"], "focus_changed")
        self.assertEqual(fake.front_app, "com.example.user-selected")
        self.assertEqual(len(self.restores(fake)), 1)

    def test_lost_or_malformed_click_response_does_not_enter_known_boundary(self):
        for malformed in (False, True):
            with self.subTest(malformed=malformed):
                fake = RestoreFake()
                def callback(request):
                    if request["command"] == "visual_click":
                        fake.calls.append(copy.deepcopy(request))
                        if malformed:
                            return {"ok": True, "result": []}
                        raise OSError("Unknown click completion")
                    return fake(request)
                result = execute_chat(self.request(fake), callback, recipe_store=False)
                self.assertIn(result["error"]["code"], {"native_transport_error", "native_protocol_error"})
                self.assertFalse(result["focus_restored"])
                self.assertEqual(self.restores(fake), [])
                self.assert_no_text_delete_or_submit(fake)

    def test_native_draft_changed_cannot_supply_the_local_success_boundary(self):
        fake = RestoreFake()
        def callback(request):
            if request["command"] == "visual_click":
                fake.calls.append(copy.deepcopy(request))
                return {"ok": False, "error": {"code": "draft_changed", "message": "Native refusal",
                    "details": {"events_posted": 0, "safe_origin_restore": True, "navigation_only": True}}}
            return fake(request)
        result = execute_chat(self.request(fake), callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertFalse(result["focus_restored"])
        self.assertEqual(self.restores(fake), [])
        self.assert_no_text_delete_or_submit(fake)

    def test_known_boundary_is_consumed_once_even_if_native_return_fails(self):
        for failed in (False, True):
            with self.subTest(failed=failed):
                fake = RestoreFake(); fake.change_on_click = "新草稿"; fake.restore_error = failed
                session = ChatSession(self.request(fake, "draft"), fake)
                value = session.start(); session.title = fake.title
                with self.assertRaises(Stopped) as caught:
                    session.wechat_edit(value)
                first = session.finish_focus(caught.exception)
                self.assertEqual(first["focus_restored"], not failed)
                session.finish_focus(caught.exception)
                self.assertEqual(len(self.restores(fake)), 1)

    def test_completed_input_then_changed_final_draft_retains_existing_unknown_policy(self):
        fake = RestoreFake(); typed = False
        def callback(request):
            nonlocal typed
            if request["command"] == "visual_read" and typed:
                fake.draft = "输入后的不同草稿"
            response = fake(request)
            if request["command"] == "visual_type_text":
                typed = True
            return response
        result = execute_chat(self.request(fake, "draft"), callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertFalse(result["focus_restored"])
        self.assertEqual(self.restores(fake), [])
        self.assertEqual(sum(c["command"] == "visual_type_text" for c in fake.calls), 1)
        self.assertFalse(any(c["command"] == "visual_key" for c in fake.calls))


if __name__ == "__main__":
    unittest.main()
