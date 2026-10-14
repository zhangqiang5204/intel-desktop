"""Validated event clock metadata on the actual Send entry, using fake UI only."""
import copy
import itertools
import json
import unittest
from unittest.mock import patch

from test_chat_completion import send_request
from test_wechat_send_focus_reuse import RetainedSendFake
from chat_workflows import _input_event_times, execute_chat


TYPE = {"clock": "system_uptime_ms", "kind": "unicode", "dispatch_started_ms": 1000.0,
        "dispatch_finished_ms": 1010.0, "complete_observation_ms": 1100.0}
SUBMIT = {"clock": "system_uptime_ms", "kind": "submit_return", "dispatch_started_ms": 1150.0,
          "dispatch_finished_ms": 1152.0, "complete_observation_ms": 1200.0}


class EventTimingFake(RetainedSendFake):
    def __init__(self):
        super().__init__()
        self.submitted = False
        self.typed_emitted = False
        self.type_changes = {}
        self.submit_changes = {}
        self.final_changes = {}

    def visual(self, request, region_only=False):
        value = super().visual(request, region_only)
        regions = [request["control_rect"]] if region_only else request.get("regions", [request.get("region")])
        value["ocr_regions"] = [copy.deepcopy(r) for r in regions if r] or [copy.deepcopy(self.frame)]
        value["ocr_scope"] = "requested_regions" if "regions" in request else "full_window"
        value["observation_materialized_uptime_ms"] = 1250.0 if self.submitted else 1120.0 if self.typed_emitted else 1099.0
        if self.submitted:
            value.update(copy.deepcopy(self.final_changes))
        return value

    def __call__(self, request):
        response = super().__call__(request)
        if response.get("ok") and request["command"] == "visual_type_text" and request.get("control_kind") == "chat_composer":
            self.typed_emitted = True
            response["result"].update(input_event_timing=copy.deepcopy(TYPE), events_posted=2)
            response["result"].update(copy.deepcopy(self.type_changes))
        elif response.get("ok") and request.get("key") == "return":
            self.submitted = True
            response["result"].update(input_event_timing=copy.deepcopy(SUBMIT), observation_materialized_uptime_ms=1199.0)
            response["result"].update(copy.deepcopy(self.submit_changes))
        return response


class SendEventTimingTests(unittest.TestCase):
    def run_send(self, fake):
        clock = itertools.count(0, 1)
        with patch("chat_workflows.time.monotonic", side_effect=lambda: next(clock)), patch("chat_workflows.time.sleep"):
            return execute_chat(send_request(fake), fake, recipe_store=False)

    def assert_sent_without_timing(self, fake):
        response = self.run_send(fake)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["sent"])
        self.assertNotIn("send_event_timing", response["result"])
        self.assertEqual(sum(c.get("key") == "return" for c in fake.calls), 1)

    def test_success_reports_four_actual_clock_differences_after_full_send_verification(self):
        fake = EventTimingFake()
        response = self.run_send(fake)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertFalse(response["result"]["delivery_verified"])
        self.assertEqual(response["result"]["send_event_timing"], {
            "clock": "system_uptime_ms", "input_finished_to_submit_ms": 140.0,
            "complete_draft_verified_to_submit_ms": 50.0, "submit_dispatch_ms": 2.0,
            "submit_to_verified_observation_ms": 98.0})
        self.assertEqual(sum(c.get("key") == "return" for c in fake.calls), 1)
        self.assertEqual(sum(c["command"] == "visual_click" and c.get("control_kind") == "chat_composer" for c in fake.calls), 1)
        serialized = json.dumps(response["result"]["send_event_timing"], ensure_ascii=False)
        self.assertNotIn(fake.title, serialized)
        self.assertNotIn(send_request(fake)["text"], serialized)
        self.assertNotIn("dispatch_started_ms", serialized)

    def test_old_helper_missing_any_timestamp_only_omits_metadata(self):
        for phase in ("type", "submit", "observation", "draft_observation"):
            with self.subTest(phase=phase):
                fake = EventTimingFake()
                if phase == "type":
                    fake.type_changes["input_event_timing"] = None
                elif phase == "submit":
                    fake.submit_changes["input_event_timing"] = None
                elif phase == "observation":
                    fake.final_changes["observation_materialized_uptime_ms"] = None
                else:
                    fake.type_changes["observation_materialized_uptime_ms"] = None
                self.assert_sent_without_timing(fake)
        self.assert_sent_without_timing(RetainedSendFake())

    def test_wrong_clock_kind_and_nonfinite_nonnumeric_or_negative_values_are_omitted(self):
        for phase in ("type", "submit"):
            original = TYPE if phase == "type" else SUBMIT
            for field, changed in (("clock", "wall_time_ms"), ("kind", "clear"),
                                   ("dispatch_started_ms", -1), ("dispatch_started_ms", True),
                                   ("dispatch_started_ms", "1000"), ("dispatch_started_ms", float("nan")),
                                   ("dispatch_finished_ms", float("inf")), ("complete_observation_ms", 10**1000)):
                with self.subTest(phase=phase, field=field, changed=str(changed)[:20]):
                    fake = EventTimingFake()
                    timing = {**original, field: changed}
                    (fake.type_changes if phase == "type" else fake.submit_changes)["input_event_timing"] = timing
                    self.assert_sent_without_timing(fake)

    def test_backward_interstage_and_unreasonable_intervals_are_omitted(self):
        for type_timing, submit_timing, stamp in (
            ({**TYPE, "dispatch_finished_ms": 999}, SUBMIT, 1250),
            ({**TYPE, "complete_observation_ms": 1005}, SUBMIT, 1250),
            (TYPE, {**SUBMIT, "dispatch_started_ms": 1090}, 1250),
            (TYPE, {**SUBMIT, "dispatch_finished_ms": 1149}, 1250),
            (TYPE, SUBMIT, 1190), (TYPE, SUBMIT, 130001),
            ({**TYPE, "dispatch_started_ms": 10**13}, SUBMIT, 1250),
        ):
            with self.subTest(type=type_timing, submit=submit_timing, stamp=stamp):
                fake = EventTimingFake()
                fake.type_changes["input_event_timing"] = type_timing
                fake.submit_changes["input_event_timing"] = submit_timing
                fake.final_changes["observation_materialized_uptime_ms"] = stamp
                self.assert_sent_without_timing(fake)

    def test_missing_or_zero_type_events_and_noninteger_submit_receipt_omit_metadata(self):
        for phase, events in (("type", None), ("type", 0), ("type", True), ("submit", 2.0), ("submit", 1)):
            with self.subTest(phase=phase, events=events):
                fake = EventTimingFake()
                (fake.type_changes if phase == "type" else fake.submit_changes)["events_posted"] = events
                self.assert_sent_without_timing(fake)

    def test_preexisting_draft_has_no_this_invocation_type_receipt(self):
        fake = EventTimingFake()
        fake.draft = send_request(fake)["text"]
        self.assert_sent_without_timing(fake)
        self.assertEqual(sum(c["command"] == "visual_type_text" for c in fake.calls), 0)

    def test_fallback_full_draft_read_uses_its_new_verified_time_without_retaining_focus(self):
        fake = EventTimingFake()
        fake.corrupt = ("edit_recipient_verified", False)
        response = self.run_send(fake)
        self.assertTrue(response["ok"], response)
        self.assertEqual(response["result"]["send_event_timing"]["complete_draft_verified_to_submit_ms"], 30.0)
        self.assertEqual(response["result"]["send_event_timing"]["input_finished_to_submit_ms"], 140.0)
        self.assertEqual(sum(c["command"] == "visual_click" and c.get("control_kind") == "chat_composer" for c in fake.calls), 2)
        self.assertEqual(sum(c.get("key") == "return" for c in fake.calls), 1)

    def test_no_echo_never_reports_verified_observation_timing(self):
        fake = EventTimingFake()
        fake.no_echo = True
        response = self.run_send(fake)
        self.assertTrue(response["ok"], response)
        self.assertIsNone(response["result"]["sent"])
        self.assertFalse(response["result"]["send_verified"])
        self.assertNotIn("send_event_timing", response["result"])
        self.assertEqual(sum(c.get("key") == "return" for c in fake.calls), 1)

    def test_changed_identity_or_incomplete_final_composer_cannot_acquire_timing_proof(self):
        for corruption in ({"window_id": 92}, {"display_topology_signature": "other"}, {"captured_regions": []}):
            with self.subTest(corruption=corruption):
                fake = EventTimingFake()
                fake.final_changes = corruption
                response = self.run_send(fake)
                # Existing business behavior remains authoritative. Optional
                # diagnostics never promote changed/incomplete identities.
                self.assertNotIn("send_event_timing", response.get("result", {}))
                self.assertEqual(sum(c.get("key") == "return" for c in fake.calls), 1)

    def test_incomplete_submit_or_native_focus_error_has_no_send_timing(self):
        for flag in ("submit_events_posted", "submit_preconditions_verified"):
            with self.subTest(flag=flag):
                fake = EventTimingFake()
                fake.submit_changes[flag] = False
                response = self.run_send(fake)
                self.assertFalse(response["ok"])
                self.assertNotIn("send_event_timing", response.get("result", {}))
        fake = EventTimingFake()
        fake.invalidate_before_submit = True
        response = self.run_send(fake)
        self.assertFalse(response["ok"])
        self.assertNotIn("send_event_timing", response.get("result", {}))

    def test_optional_receipt_validator_requires_all_three_ordered_values(self):
        self.assertEqual(_input_event_times(TYPE, "unicode"), (1000.0, 1010.0, 1100.0))
        for field in TYPE:
            missing = dict(TYPE)
            del missing[field]
            self.assertIsNone(_input_event_times(missing, "unicode"))


if __name__ == "__main__":
    unittest.main()
