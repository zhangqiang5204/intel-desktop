"""Pure fake native receipts for search-only stage cleanup; no GUI or HID."""
import copy
import unittest

from test_wechat_focus_restore import RestoreFake
from chat_workflows import ChatSession, Stopped, WECHAT, execute_chat


SEARCH_ACTIONS = [
    {"command": "visual_click", "control_kind": "search"},
    {"command": "visual_type_text", "control_kind": "search", "replace_search": True,
     "text": "文件传输助手", "expected_text": "文件传输助手"},
]


def failure(code="visual_target_changed", **details):
    return {"ok": False, "error": {"code": code, "message": "Search post-frame stopped",
        "details": {"failed_index": 1, "completed_count": 1, "events_posted": 8,
                    "completed_results": [{"index": 0, "command": "visual_click", "result": {"events_posted": 2}}],
                    "input_may_be_partial": True, "automatic_replay_allowed": False, **details}}}


class SearchOriginRestoreTests(unittest.TestCase):
    def stopped_session(self, actions=None, envelope=None, *, transport=False, command="batch", **arguments):
        fake = RestoreFake()
        session = ChatSession({"app": WECHAT, "action": "read"}, fake)
        session.start()
        original = session.invoke
        def callback(request):
            if request["command"] == command and not request.get("restore_previous"):
                fake.calls.append(copy.deepcopy(request))
                if transport:
                    raise OSError("Completion unavailable")
                return copy.deepcopy(failure() if envelope is None else envelope)
            return original(request)
        session.invoke = callback
        with self.assertRaises(Stopped) as caught:
            if command == "batch":
                session.call(command, actions=copy.deepcopy(SEARCH_ACTIONS if actions is None else actions))
            else:
                session.call(command, **arguments)
        return session, fake, caught.exception

    def assert_no_restore(self, session, fake, error):
        self.assertNotIn("safe_origin_restore", error.details)
        result = session.finish_focus(error)
        self.assertFalse(result["focus_restore_attempted"], result)
        self.assertFalse(any(c["command"] == "focus" and c.get("restore_previous") for c in fake.calls))

    def test_actual_search_replacement_prefix_8_balanced_events_attempts_guarded_restore_once(self):
        session, fake, error = self.stopped_session()
        self.assertTrue(error.details["safe_origin_restore"])
        self.assertNotIn("navigation_only", error.details)  # Search text changed.
        self.assertEqual(error.details["events_posted"], 8)
        self.assertTrue(session.finish_focus(error)["focus_restored"])
        self.assertEqual(session.pid, fake.pid)
        self.assertEqual(len([c for c in fake.calls if c["command"] == "batch"]), 1)
        restores = [c for c in fake.calls if c["command"] == "focus" and c.get("restore_previous")]
        self.assertEqual(len(restores), 1)
        self.assertEqual(restores[0], {"app": WECHAT, "window_title": "微信", "restore_previous": True, "command": "focus"})
        self.assertFalse(any(c["command"] in {"visual_type_text", "visual_key", "key", "submit_text"} for c in fake.calls))
        self.assertEqual(fake.draft, "")

    def test_high_level_send_search_failure_is_unsent_and_restores_without_replay(self):
        fake = RestoreFake()
        def callback(request):
            if request["command"] == "batch":
                fake.calls.append(copy.deepcopy(request))
                self.assertEqual([a["command"] for a in request["actions"]], ["visual_click", "visual_type_text"])
                self.assertTrue(request["actions"][1]["replace_search"])
                fake.search = "文件传输助手"  # Simulated search effect, never a chat draft.
                return failure()
            return fake(request)
        answer = execute_chat({"app": WECHAT, "action": "send", "chat": "文件传输助手",
                               "text": "合成验收消息", "send_authorization": {"source": "current_user", "app": WECHAT,
                                   "chat": "文件传输助手", "text": "合成验收消息"}}, callback, recipe_store=False)
        self.assertEqual(answer["error"]["code"], "visual_target_changed", answer)
        self.assertFalse(answer["sent"])
        self.assertTrue(answer["focus_restored"])
        self.assertTrue(answer["error"]["details"]["safe_origin_restore"])
        self.assertEqual(len([c for c in fake.calls if c["command"] == "batch"]), 1)
        self.assertEqual(fake.draft, "")
        self.assertFalse(any(c["command"] in {"visual_type_text", "visual_key", "key", "submit_text"} for c in fake.calls))

    def test_future_composer_or_return_actions_are_not_mistaken_for_executed_prefix(self):
        future = {"command": "visual_key", "key": "return", "allow_submit": True, "control_kind": "chat_composer"}
        session, _, error = self.stopped_session(SEARCH_ACTIONS + [future])
        self.assertTrue(error.details["safe_origin_restore"])

    def test_reads_and_search_navigation_clicks_allow_restore(self):
        for kind in ("search", "navigation"):
            with self.subTest(kind=kind):
                actions = [{"command": "visual_read"}, {"command": "visual_click", "control_kind": kind}]
                session, fake, error = self.stopped_session(actions)
                self.assertTrue(error.details["navigation_only"])
                self.assertTrue(session.finish_focus(error)["focus_restored"])

    def test_composer_typing_and_clicking_never_use_supplied_cleanup_flags(self):
        for action in ({"command": "visual_type_text", "control_kind": "chat_composer", "replace_search": True},
                       {"command": "visual_click", "control_kind": "chat_composer"},
                       {"command": "visual_click"}, {"command": "visual_click", "control_kind": []}):
            with self.subTest(action=action):
                session, fake, error = self.stopped_session([SEARCH_ACTIONS[0], action], failure(navigation_only=True, safe_origin_restore=True))
                self.assertNotIn("navigation_only", error.details)
                self.assert_no_restore(session, fake, error)

    def test_search_append_or_non_boolean_replacement_is_not_safe_replacement(self):
        for replacement in (None, False, 1, "true"):
            with self.subTest(replacement=replacement):
                action = {"command": "visual_type_text", "control_kind": "search", "replace_search": replacement}
                session, fake, error = self.stopped_session([SEARCH_ACTIONS[0], action])
                self.assert_no_restore(session, fake, error)

    def test_executed_return_delete_and_other_mutations_refuse_restore(self):
        for action in ({"command": "visual_key", "key": "return", "allow_submit": True},
                       {"command": "visual_key", "key": "backspace", "control_kind": "search"},
                       {"command": "key", "key": "return"}, {"command": "type_text"},
                       {"command": "visual_scroll"}, {"command": "submit_text"}):
            with self.subTest(action=action):
                session, fake, error = self.stopped_session(SEARCH_ACTIONS + [action], failure(failed_index=2))
                self.assert_no_restore(session, fake, error)

    def test_missing_invalid_or_out_of_range_failure_index_cannot_authorize_restore(self):
        for index in (None, True, -1, 2, 1.0, "1"):
            with self.subTest(index=index):
                session, fake, error = self.stopped_session(envelope=failure(failed_index=index))
                self.assert_no_restore(session, fake, error)

    def test_malformed_native_error_envelopes_are_unknown_protocol_completion(self):
        for envelope in ({"ok": False}, {"ok": False, "error": []},
                         {"ok": False, "error": {"code": "visual_target_changed", "message": "stopped", "details": []}},
                         {"ok": False, "error": {"code": "", "message": "stopped", "details": {}}},
                         {"ok": False, "error": {"code": "visual_target_changed", "message": 1, "details": {}}},
                         {"ok": "false", "error": failure()["error"]}):
            with self.subTest(envelope=envelope):
                session, fake, error = self.stopped_session(envelope=envelope)
                self.assertEqual(error.code, "native_protocol_error")
                self.assert_no_restore(session, fake, error)

    def test_valid_empty_native_details_are_omitted_without_granting_search_restore(self):
        session, fake, error = self.stopped_session(envelope={"ok": False, "error": {"code": "visual_target_changed", "message": "Stopped before prefix"}})
        self.assertEqual(error.code, "visual_target_changed")
        self.assert_no_restore(session, fake, error)

    def test_transport_loss_never_restores_even_for_search_actions(self):
        session, fake, error = self.stopped_session(transport=True)
        self.assertEqual(error.code, "native_transport_error")
        self.assert_no_restore(session, fake, error)

    def test_takeover_foreground_identity_and_unknown_completion_codes_refuse_restore(self):
        for code in ("user_interrupted", "foreground_mismatch", "foreground_unverified", "target_changed",
                     "target_geometry_changed", "draft_changed", "native_transport_error", "native_protocol_error", "operation_completion_unknown"):
            with self.subTest(code=code):
                session, fake, error = self.stopped_session(envelope=failure(code))
                self.assert_no_restore(session, fake, error)

    def test_native_late_user_activity_still_declines_restore(self):
        session, fake, error = self.stopped_session()
        fake.interrupted = "new_user_input"
        result = session.finish_focus(error)
        self.assertFalse(result["focus_restored"])
        self.assertEqual(result["restore_reason"], "new_user_activity")
        self.assertEqual(fake.front_app, fake.app)

    def test_unsafe_direct_composer_click_cannot_inherit_native_navigation_flag(self):
        session, fake, error = self.stopped_session(command="visual_click", control_kind="chat_composer",
            envelope=failure(navigation_only=True, safe_origin_restore=True))
        self.assert_no_restore(session, fake, error)


if __name__ == "__main__":
    unittest.main()
