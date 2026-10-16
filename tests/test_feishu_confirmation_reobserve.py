"""Posted-Send confirmation re-observes incomplete AX only; all HID is fake."""
import json
import unittest
from unittest.mock import patch

from chat_workflows import STRUCTURE
from test_feishu_post_submit_background import PostSubmitFake
import test_feishu_send_latency as latency


class ConfirmationFake(PostSubmitFake):
    def __init__(self, change="truncated", incomplete_reads=1, read_seconds=.8, guard=None):
        super().__init__()
        self.incomplete_change = change
        self.incomplete_reads = incomplete_reads
        self.read_seconds = read_seconds
        self.guard = guard
        self.read_starts = []
        self.submit_finished = None

    def __call__(self, request):
        started = self.now
        background = self.returned and request["command"] == "inspect"
        response = super().__call__(request)
        if request["command"] == "submit_text" and response["ok"]:
            self.submit_finished = self.now
        if not background:
            return response
        self.read_starts.append(started - self.submit_finished)
        self.now += self.read_seconds - .8
        if self.background_reads > self.incomplete_reads:
            return response
        tree = response["result"]
        composer = next(row for row in tree["elements"] if row["element_id"] == "composer")
        header = next(row for row in tree["elements"] if row["element_id"] == "header")
        if self.incomplete_change == "truncated":
            tree["truncated"] = True
        elif self.incomplete_change == "composer":
            composer.update(value_complete=False, value_truncated=True)
        elif self.incomplete_change == "header":
            header.update(value_complete=False, value_truncated=True)
        elif self.incomplete_change == "body":
            for row in tree["elements"]:
                if row.get("value") == self.text:
                    row.update(value_complete=False, value_truncated=True)
        if self.guard == "PID":
            tree["target_pid"] += 1
        elif self.guard == "window":
            tree["windows"][0]["title"] = "changed-window"
        elif self.guard == "frame":
            tree["windows"][0]["position"]["x"] += 1
        elif self.guard == "recipient":
            composer["value"] = composer["value"].replace(self.title, "其他收件人")
        elif self.guard == "secure_composer":
            composer["secure"] = True
        elif self.guard == "duplicate_identity":
            header["element_id"] = composer["element_id"]
        elif self.guard == "missing_parent":
            composer["parent_id"] = "unavailable-parent"
        elif self.guard == "body_geometry":
            for row in tree["elements"]:
                if row.get("value") == self.text:
                    row["size"]["height"] = 0
        elif self.guard == "missing_completeness":
            tree["truncated"] = False
            composer.pop("value_complete")
        elif self.guard == "malformed_completeness":
            composer["value_complete"] = False
            composer.pop("value_truncated")
        elif self.guard == "protocol":
            tree.pop("windows")
        elif self.guard in {"user_interrupted", "secure_input", "native_transport_error", "send_state_unknown"}:
            return {"ok": False, "error": {"code": self.guard, "message": "Synthetic native refusal",
                "details": {"confirmation_incomplete_reason": "ax_tree_truncated"}}}
        return response


class ConfirmationReobservationTests(unittest.TestCase):
    def send(self, fake, **kwargs):
        return latency.FeishuSendLatencyTests().send(fake, **kwargs)

    def assert_only_reads_after_one_submit_and_return(self, fake):
        self.assertEqual(sum(call["command"] == "submit_text" for call in fake.calls), 1)
        self.assertEqual(fake.restore_calls, 1)
        submitted = next(index for index, call in enumerate(fake.calls) if call["command"] == "submit_text")
        self.assertTrue(fake.calls[submitted + 1].get("restore_previous"))
        self.assertTrue(all(call["command"] == "inspect" for call in fake.calls[submitted + 2:]))
        self.assertTrue(all(call["max_nodes"] == 2000 and call["include_menus"] is False
                            for call in fake.calls[submitted + 2:]))
        self.assertEqual(fake.front, fake.origin)

    def test_transient_incomplete_AX_then_strict_complete_proof_verifies_once(self):
        for change, reason in (("truncated", "ax_tree_truncated"), ("composer", "ax_composer_value_incomplete"),
                               ("header", "ax_header_value_incomplete"), ("body", "ax_body_value_incomplete")):
            with self.subTest(change=change):
                phases = []
                class Context:
                    def record_phase(self, *args, **kwargs):
                        phases.append(args)
                fake = ConfirmationFake(change)
                with patch("task_runtime.current_context", return_value=Context()):
                    response = self.send(fake)
                self.assertTrue(response["ok"], response)
                self.assertTrue(response["result"]["send_verified"])
                self.assertTrue(response["result"]["draft_empty"])
                self.assertEqual(response["result"]["full_AX_body_proof"]["exact_text_node_occurrences"], 1)
                timing = response["send_call_timing"]
                self.assertEqual((timing["confirmation_read_count"], timing["confirmation_incomplete_read_count"],
                                  timing["confirmation_reobservation_count"]), (2, 1, 1))
                self.assertEqual(timing["confirmation_incomplete_reasons"], {reason: 1})
                self.assertIn(("postcondition", "feishu_confirmation_ax_incomplete"), phases)
                self.assertIn(("postcondition", "feishu_confirmation_ax_reobserve"), phases)
                self.assertIn(("postcondition", "feishu_send_verified"), phases)
                self.assertNotIn(fake.text, json.dumps(timing, ensure_ascii=False) + str(phases))
                self.assertNotIn(fake.title, json.dumps(timing, ensure_ascii=False) + str(phases))
                self.assert_only_reads_after_one_submit_and_return(fake)

    def test_persistent_incomplete_AX_exhausts_original_budget_without_new_loop(self):
        fake = ConfirmationFake(incomplete_reads=100)
        response = self.send(fake, wait_timeout_ms=60000)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "send_state_unknown")
        self.assertIsNone(response["sent"])
        self.assertTrue(response["completion_unknown"])
        self.assertTrue(response["focus_restored"])
        details = response["error"]["details"]
        self.assertTrue(details["confirmation_budget_exhausted"])
        self.assertEqual(details["confirmation_incomplete_read_count"], fake.background_reads)
        self.assertEqual(details["confirmation_reobservation_count"], fake.background_reads - 1)
        self.assertTrue(all(start < 5 for start in fake.read_starts))
        self.assertLess(fake.now - fake.submit_finished, 6)
        self.assertGreaterEqual(fake.now - fake.submit_finished, 5)
        self.assert_only_reads_after_one_submit_and_return(fake)

    def test_remaining_budget_includes_early_focus_return_and_bounded_sleep(self):
        fake = ConfirmationFake(read_seconds=4.9, incomplete_reads=100)
        response = self.send(fake)
        self.assertEqual(response["error"]["code"], "send_state_unknown")
        self.assertEqual(fake.background_reads, 1)
        self.assertEqual(response["send_call_timing"]["confirmation_reobservation_count"], 0)
        self.assertAlmostEqual(fake.now - fake.submit_finished, 5)
        self.assert_only_reads_after_one_submit_and_return(fake)

    def test_identity_recipient_geometry_secure_protocol_and_native_refusals_never_retry(self):
        for guard in ("PID", "window", "frame", "recipient", "secure_composer", "duplicate_identity", "missing_parent",
                      "body_geometry", "missing_completeness", "malformed_completeness", "protocol", "user_interrupted", "secure_input",
                      "native_transport_error", "send_state_unknown"):
            with self.subTest(guard=guard):
                fake = ConfirmationFake("body" if guard == "body_geometry" else "truncated", guard=guard)
                response = self.send(fake)
                self.assertFalse(response["ok"], response)
                self.assertEqual(fake.background_reads, 1)
                self.assertEqual(response["send_call_timing"]["confirmation_reobservation_count"], 0)
                self.assertEqual(response["send_call_timing"]["confirmation_incomplete_read_count"], 0)
                self.assert_only_reads_after_one_submit_and_return(fake)

    def test_verified_send_reply_incompleteness_does_not_enter_confirmation_retry(self):
        class ReplyIncompleteFake(ConfirmationFake):
            def __call__(self, request):
                response = super().__call__(request)
                if self.returned and request["command"] == "inspect" and self.background_reads > 1:
                    response["result"]["truncated"] = True
                return response
        fake = ReplyIncompleteFake(incomplete_reads=0)
        response = self.send(fake, wait_timeout_ms=3000)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "send_state_unknown")
        self.assertTrue(response["sent"])
        self.assertTrue(response["send_call_timing"]["confirmation_verified"])
        self.assertEqual(fake.background_reads, 2)
        self.assertEqual(response["send_call_timing"]["confirmation_reobservation_count"], 0)
        self.assert_only_reads_after_one_submit_and_return(fake)

    def test_incomplete_baseline_stops_before_input_without_confirmation_retry(self):
        class BaselineIncompleteFake(ConfirmationFake):
            def __call__(self, request):
                response = super().__call__(request)
                if request["command"] == "inspect" and not self.returned:
                    response["result"]["truncated"] = True
                return response
        fake = BaselineIncompleteFake()
        response = self.send(fake)
        self.assertEqual(response["error"]["code"], "send_state_unknown")
        self.assertFalse(response["sent"])
        self.assertFalse(any(call["command"] in {"batch", "type_text", "click", "submit_text"} for call in fake.calls))
        self.assertEqual(response["send_call_timing"]["confirmation_read_count"], 0)
        self.assertEqual(response["send_call_timing"]["confirmation_reobservation_count"], 0)

    def test_reobservation_still_requires_exact_body_increase_and_empty_composer(self):
        for change in ("no_echo", "nonempty_composer", "nonexact_body"):
            with self.subTest(change=change):
                class UnprovenOutcomeFake(ConfirmationFake):
                    def __call__(self, request):
                        response = super().__call__(request)
                        if self.returned and request["command"] == "inspect" and self.background_reads > 1:
                            for row in response["result"]["elements"]:
                                if change == "nonempty_composer" and row["element_id"] == "composer":
                                    row["value"] = self.text + STRUCTURE
                                elif change == "nonexact_body" and row.get("value") == self.text:
                                    row["value"] += "extra"
                        return response
                fake = UnprovenOutcomeFake()
                fake.no_echo = change == "no_echo"
                response = self.send(fake)
                self.assertIsNone(response["result"]["sent"])
                self.assertFalse(response["result"]["send_verified"])
                self.assertFalse(response["business_completed"])
                self.assertEqual(response["send_call_timing"]["confirmation_reobservation_count"], 1)
                self.assertTrue(all(start < 5 for start in fake.read_starts))
                self.assert_only_reads_after_one_submit_and_return(fake)


if __name__ == "__main__":
    unittest.main()
