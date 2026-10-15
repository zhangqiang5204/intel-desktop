"""Exercise opt-in Send and posted-only receipts; all app/HID calls are fake."""
import copy
import unittest

from chat_workflows import ChatSession, Stopped, WECHAT, _input_event_times, execute_chat
from test_chat_completion import send_request
from test_wechat_post_submit_background import PostSubmitWeChatFake


class AtomicSendFake(PostSubmitWeChatFake):
    def __init__(self, *, atomic=True, mismatch=None, broken_receipt=None, **kwargs):
        super().__init__(**kwargs)
        self.atomic = atomic
        self.mismatch = mismatch
        self.broken_receipt = broken_receipt

    def __call__(self, request):
        if request["command"] == "visual_type_text" and request.get("focus_before_type"):
            assert request["expected_draft"] == "" and request["chat_title"] == self.title
            assert not any(c["command"] == "visual_click" for c in self.calls)
            if self.mismatch:
                self.calls.append(copy.deepcopy(request))
                self.draft = self.mismatch
                regions = ChatSession({"app": WECHAT, "action": "send"}, self)
                regions.frame = self.frame
                rois = regions.wechat_regions()
                value = self.visual({**request, "regions": [rois["header"], rois["composer"]]})
                value.update(ocr_regions=[rois["header"], rois["composer"]],
                    ocr_scope="post_action_recipient_and_complete_composer", input_eligible=False,
                    edit_recipient_verified=True, edit_recipient=self.title,
                    edit_proof_snapshot_id=value["snapshot_id"], atomic_composer_precondition_failed=True,
                    events_posted=2, composer_focus_events_posted=2, text_events_posted=0, value_verified=False)
                if self.broken_receipt:
                    value.update(self.broken_receipt)
                return {"ok": True, "result": value}
        response = super().__call__(request)
        if request["command"] == "status":
            response["result"]["visual"] = {"atomic_composer_edit": 1 if self.atomic else 0}
        if request["command"] == "visual_type_text" and request.get("focus_before_type") and response["ok"]:
            response["result"].update(events_posted=4, composer_focus_events_posted=2,
                                      text_events_posted=2, atomic_composer_edit=True)
        if request.get("key") == "return" and response["ok"]:
            value = response["result"]
            # This is exactly the binding consumed by background confirmation;
            # no post-Return OCR, current draft or snapshot capability exists.
            response["result"] = {key: value[key] for key in (
                "target_pid", "window_id", "window_frame", "display_topology_signature",
                "submit_events_posted", "submit_preconditions_verified", "send_verified", "events_posted") if key in value}
            response["result"].update(input_eligible=False, post_submit_verification_required=True,
                                      automatic_replay_allowed=False)
        return response


class AtomicSendTests(unittest.TestCase):
    def test_actual_mcp_schema_and_validator_accept_the_native_atomic_shape(self):
        import server
        arguments = {"app": WECHAT, "window_title": "微信", "snapshot_id": "current",
            "control_kind": "chat_composer", "control_rect": {"x": 600, "y": 800, "width": 400, "height": 100},
            "confirm_control": True, "focus_before_type": True, "expected_draft": "",
            "chat_title": "目标个人", "text": "离线消息", "expected_text": "离线消息"}
        self.assertIn("expected_draft", server.PROPS["visual_type_text"])
        server.validate("visual_type_text", arguments)
        for field in ("expected_draft", "chat_title"):
            changed = dict(arguments); changed.pop(field)
            with self.assertRaises(ValueError): server.validate("visual_type_text", changed)

    def test_new_empty_send_uses_atomic_edit_and_background_proof_after_origin_return(self):
        fake = AtomicSendFake()
        response = execute_chat(send_request(fake), fake, recipe_store=False)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertTrue(response["focus_restored"])
        self.assertEqual(sum(c["command"] == "visual_click" for c in fake.calls), 0)
        typed = [c for c in fake.calls if c["command"] == "visual_type_text"]
        self.assertEqual(len(typed), 1)
        self.assertTrue(typed[0]["focus_before_type"])
        self.assertEqual(sum(c.get("key") == "return" for c in fake.calls), 1)
        self.assertEqual(fake.background_reads, 1)
        self.assertEqual(fake.restore_calls, 1)

    def test_default_draft_and_old_helper_keep_separate_composer_click(self):
        for mode in ("draft", "old_helper", "existing_draft"):
            with self.subTest(mode=mode):
                fake = AtomicSendFake(atomic=mode != "old_helper")
                request = send_request(fake)
                if mode == "draft":
                    request["action"] = "draft"
                    request.pop("send_authorization")
                if mode == "existing_draft":
                    fake.draft = request["text"]
                result = execute_chat(request, fake, recipe_store=False)
                self.assertTrue(result["ok"], result)
                self.assertEqual(sum(c["command"] == "visual_click" for c in fake.calls), 1)
                self.assertFalse(any(c.get("focus_before_type") for c in fake.calls))

    def test_complete_post_click_changed_draft_preserves_value_and_returns_once(self):
        fake = AtomicSendFake(mismatch="保留新草稿")
        response = execute_chat(send_request(fake), fake, recipe_store=False)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "draft_changed")
        self.assertEqual(fake.draft, "保留新草稿")
        self.assertTrue(response["focus_restored"], response)
        self.assertEqual(fake.restore_calls, 1)
        self.assertFalse(any(c.get("key") == "return" for c in fake.calls))

    def test_incomplete_post_click_receipt_cannot_invent_safe_return_boundary(self):
        for corrupt in ({"text_events_posted": 1}, {"events_posted": True},
                        {"edit_recipient_verified": False}, {"ocr_regions": []},
                        {"input_eligible": True}, {"edit_proof_snapshot_id": "other"}):
            with self.subTest(corrupt=corrupt):
                fake = AtomicSendFake(mismatch="保留新草稿", broken_receipt=corrupt)
                response = execute_chat(send_request(fake), fake, recipe_store=False)
                self.assertFalse(response["ok"])
                self.assertEqual(response["error"]["code"], "draft_unverified")
                self.assertEqual(fake.restore_calls, 0)
                self.assertFalse(any(c.get("key") == "return" for c in fake.calls))

    def test_transport_unknown_after_atomic_edit_never_retypes_or_submits(self):
        fake = AtomicSendFake()
        def invoke(request):
            response = fake(request)
            if request.get("focus_before_type"):
                raise OSError("Lost native edit completion")
            return response
        response = execute_chat(send_request(fake), invoke, recipe_store=False)
        self.assertFalse(response["ok"])
        self.assertFalse(response["automatic_replay_allowed"])
        self.assertEqual(sum(c.get("focus_before_type") is True for c in fake.calls), 1)
        self.assertFalse(any(c.get("key") == "return" for c in fake.calls))

    def test_posted_receipt_clock_does_not_claim_complete_observation(self):
        timing = {"clock": "system_uptime_ms", "kind": "submit_return", "completion_kind": "posted_receipt",
                  "dispatch_started_ms": 1000.0, "dispatch_finished_ms": 1001.0, "receipt_materialized_ms": 1002.0}
        self.assertEqual(_input_event_times(timing, "submit_return"), (1000.0, 1001.0, 1002.0))
        self.assertIsNone(_input_event_times({**timing, "receipt_materialized_ms": 999}, "submit_return"))
        self.assertIsNone(_input_event_times({k: v for k, v in timing.items() if k != "receipt_materialized_ms"}, "submit_return"))
        self.assertIsNone(_input_event_times({**timing, "kind": "unicode"}, "unicode"))

    def test_native_boundary_records_only_safe_notice_visibility_and_fixed_stage(self):
        for ok in (True, False):
            with self.subTest(ok=ok):
                notice = {"visible": True, "stage": "verifying", "text": "must not retain", "window_id": 999}
                envelope = {"ok": ok, "result": {"interaction_notice": notice}}
                if not ok:
                    envelope["error"] = {"code": "fixture_stopped", "message": "Native refusal"}
                session = ChatSession({"app": WECHAT}, lambda _: envelope)
                if ok:
                    session.call("status")
                else:
                    with self.assertRaises(Stopped):
                        session.call("status")
                self.assertEqual(session.native_timings[0]["interaction_notice"], {"visible": True, "stage": "verifying"})

    def test_invalid_notice_values_and_transport_failure_do_not_fabricate_visibility(self):
        session = ChatSession({"app": WECHAT}, lambda _: {"ok": True,
            "result": {"interaction_notice": {"visible": 1, "stage": "private user text"}}})
        session.call("status")
        self.assertNotIn("interaction_notice", session.native_timings[0])
        def lost(_):
            raise OSError("transport failure")
        session.invoke = lost
        with self.assertRaises(Stopped):
            session.call("status")
        self.assertNotIn("interaction_notice", session.native_timings[1])


if __name__ == "__main__":
    unittest.main()
