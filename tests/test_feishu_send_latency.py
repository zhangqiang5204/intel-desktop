"""Real Send entry and real metadata ledger; native/UI operations are fakes."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from chat_workflows import FEISHU, execute_chat
from task_runtime import TaskRuntime
from workflow_tools import classify_result
from test_chat_completion import send_request
from test_feishu_focus_restore import FocusFeishuFake


class SendLatencyFake(FocusFeishuFake):
    def __init__(self):
        super().__init__()
        self.now = 0.0
        self.submitted = False
        self.proof_change = None
        self.change_at_submit = None

    def __call__(self, request):
        command = request["command"]
        if command == "submit_text" and self.change_at_submit:
            if self.change_at_submit == "recipient": self.title = "另一个收件人"
            if self.change_at_submit == "draft": self.draft += "变化"
            if self.change_at_submit == "focus": self.focused_id = None
        response = super().__call__(request)
        self.now += {"status": .001, "inspect": .8, "focus": .05, "wait_text": .002,
                     "click": .01, "type_text": .05, "submit_text": .02}.get(command, 0)
        if command == "submit_text" and response["ok"]:
            self.submitted = True
        if command == "batch" and response["ok"] and self.proof_change:
            value = response["result"]
            typed = next(row["result"] for row in value["results"] if row["command"] == "type_text")
            if self.proof_change == "missing_verified": typed.pop("value_verified")
            if self.proof_change == "false_verified": typed["value_verified"] = False
            if self.proof_change == "missing_type_value": typed.pop("value")
            if self.proof_change == "missing_pid": value.pop("target_pid")
            if self.proof_change == "missing_count": value.pop("completed_count")
            if self.proof_change == "wrong_count": value["completed_count"] = 1
            if self.proof_change == "changed_readback": value["results"][-1]["result"]["value"] += "额外值"
        return response

    def sleep(self, duration):
        self.now += duration


class FeishuSendLatencyTests(unittest.TestCase):
    def send(self, fake, **kwargs):
        with patch("chat_workflows.time.perf_counter", side_effect=lambda: fake.now), \
             patch("chat_workflows.time.monotonic", side_effect=lambda: fake.now), \
             patch("chat_workflows.time.sleep", side_effect=fake.sleep):
            return execute_chat(send_request(fake, **kwargs), fake, recipe_store=False)

    def before_submit(self, fake):
        return fake.calls[:next(i for i, c in enumerate(fake.calls) if c["command"] == "submit_text")]

    def test_same_invocation_complete_draft_reuses_readback_without_second_full_tree(self):
        fake = SendLatencyFake()
        response = self.send(fake)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertTrue(response["scope_completed"])
        self.assertEqual(len([c for c in self.before_submit(fake) if c["command"] == "inspect"]), 1)
        self.assertEqual(len([c for c in fake.calls if c["command"] == "inspect"]), 2)
        self.assertEqual(len([c for c in fake.calls if c["command"] == "type_text"]), 1)
        self.assertEqual(len([c for c in fake.calls if c["command"] == "submit_text"]), 1)
        self.assertEqual(fake.restore_calls, 1)
        timing = response["send_call_timing"]
        self.assertTrue(timing["draft_verification_reused"])
        self.assertEqual(timing["duration_basis"], "same_invocation_call_boundaries")
        self.assertFalse(timing["hid_event_timestamps_available"])
        self.assertEqual(timing["complete_draft_to_submit_call_ms"], 11.0)
        self.assertEqual(timing["submit_call_ms"], 20.0)
        self.assertEqual(timing["submit_call_finished_to_confirmation_ms"], 850.0)
        self.assertEqual(timing["focus_return_after_submit_call_ms"], 50.0)
        self.assertEqual(timing["confirmation_read_count"], 1)
        self.assertTrue(timing["confirmation_verified"])

    def test_missing_or_incomplete_type_proof_keeps_fresh_full_scan_fallback(self):
        for corruption in ("missing_verified", "false_verified", "missing_type_value", "missing_pid", "missing_count", "wrong_count"):
            with self.subTest(corruption=corruption):
                fake = SendLatencyFake()
                fake.proof_change = corruption
                response = self.send(fake)
                self.assertTrue(response["ok"], response)
                self.assertFalse(response["send_call_timing"]["draft_verification_reused"])
                self.assertEqual(len([c for c in self.before_submit(fake) if c["command"] == "inspect"]), 2)
                self.assertEqual(len([c for c in fake.calls if c["command"] == "type_text"]), 1)
                self.assertEqual(len([c for c in fake.calls if c["command"] == "submit_text"]), 1)

    def test_native_commit_rechecks_changed_recipient_full_value_and_focus_after_reuse(self):
        for changed in ("recipient", "draft", "focus"):
            with self.subTest(changed=changed):
                fake = SendLatencyFake()
                fake.change_at_submit = changed
                response = self.send(fake)
                self.assertFalse(response["ok"])
                self.assertFalse(response["sent"])
                self.assertEqual(response["error"]["code"], "submit_precondition_failed")
                self.assertTrue(response["send_call_timing"]["draft_verification_reused"])
                self.assertFalse(response["send_call_timing"]["confirmation_verified"])
                self.assertEqual(len([c for c in fake.calls if c["command"] == "submit_text"]), 1)
                self.assertFalse(response["automatic_replay_allowed"])

    def test_mismatching_full_readback_stops_before_any_submit(self):
        fake = SendLatencyFake()
        fake.proof_change = "changed_readback"
        response = self.send(fake)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "draft_unverified")
        self.assertFalse(any(c["command"] == "submit_text" for c in fake.calls))
        self.assertNotIn("submit_call_ms", response["send_call_timing"])
        self.assertEqual(fake.restore_calls, 1)

    def test_existing_draft_has_current_full_scan_without_invented_typing_time(self):
        fake = SendLatencyFake()
        fake.draft = send_request(fake)["text"]
        response = self.send(fake)
        self.assertTrue(response["ok"], response)
        self.assertFalse(response["send_call_timing"]["draft_verification_reused"])
        self.assertFalse(response["send_call_timing"]["hid_event_timestamps_available"])
        self.assertFalse(any(c["command"] == "type_text" for c in fake.calls))
        self.assertNotIn("input_finished_to_submit_ms", response["send_call_timing"])

    def test_post_submit_confirmation_timeout_is_not_reported_as_pre_submit_wait(self):
        fake = SendLatencyFake()
        fake.no_echo = True
        response = self.send(fake)
        timing = response["send_call_timing"]
        self.assertIsNone(response["result"]["sent"])
        self.assertFalse(response["result"]["send_verified"])
        self.assertFalse(timing["confirmation_verified"])
        self.assertLess(timing["complete_draft_to_submit_call_ms"], 100)
        self.assertGreaterEqual(timing["submit_call_finished_to_confirmation_ms"], 5000)
        self.assertGreater(timing["confirmation_read_count"], 1)
        self.assertEqual(len([c for c in fake.calls if c["command"] == "submit_text"]), 1)
        self.assertEqual(fake.restore_calls, 1)

    def test_explicit_reply_wait_occurs_after_submit_and_confirmation(self):
        quick = SendLatencyFake()
        quick_response = self.send(quick)
        waiting = SendLatencyFake()
        waiting_response = self.send(waiting, wait_timeout_ms=5000)
        self.assertTrue(waiting_response["ok"], waiting_response)
        self.assertTrue(waiting_response["result"]["send_verified"])
        for field in ("invocation_to_submit_call_ms", "complete_draft_to_submit_call_ms",
                      "submit_call_ms", "submit_call_finished_to_confirmation_ms"):
            self.assertEqual(quick_response["send_call_timing"][field], waiting_response["send_call_timing"][field])
        self.assertGreater(waiting_response["elapsed_ms"] - quick_response["elapsed_ms"], 5000)
        self.assertEqual(len([c for c in waiting.calls if c["command"] == "submit_text"]), 1)
        self.assertEqual(waiting.restore_calls, 1)

    def test_metadata_failure_only_marks_coverage_without_replaying_send(self):
        class BrokenLog:
            def record_phase(self, *args, **kwargs):
                raise OSError("Metadata unavailable")
        fake = SendLatencyFake()
        with patch("task_runtime.current_context", return_value=BrokenLog()):
            response = self.send(fake)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertFalse(response["send_call_timing"]["runtime_phase_log_complete"])
        self.assertEqual(len([c for c in fake.calls if c["command"] == "submit_text"]), 1)
        self.assertEqual(fake.restore_calls, 1)

    def test_actual_existing_runtime_persists_fixed_phase_timestamps_without_content(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = TaskRuntime(Path(directory))
            fake = SendLatencyFake()
            request = send_request(fake, "只在内存中的离线测试正文")
            def execute(context):
                def native(payload):
                    response = fake(payload)
                    context.record_native(response, substage=payload["command"])
                    return response
                response = execute_chat(request, native, recipe_store=False)
                classify_result("chat", request, response, context)
                return response
            packet = runtime.run("desktop_chat", request, execute, task_id="feishu-latency-fixture", operation_id="send-fixture")
            self.assertTrue(packet["response"]["ok"], packet["response"])
            self.assertEqual(packet["summary"]["state"], "verified")
            self.assertTrue(packet["response"]["send_call_timing"]["runtime_phase_log_complete"])
            logs = runtime.logs(task_id="feishu-latency-fixture")
            phases = [e for e in logs["events"] if (e.get("substage") or "").startswith("feishu_")]
            self.assertEqual([e["substage"] for e in phases], ["feishu_complete_draft", "feishu_submit_call_started", "feishu_submit_call_finished",
                "feishu_focus_return_after_submit_started", "feishu_focus_return_after_submit_finished", "feishu_send_verified"])
            self.assertEqual([e["created"] for e in phases], sorted(e["created"] for e in phases))
            self.assertNotIn(request["text"], json.dumps(logs, ensure_ascii=False))
            self.assertNotIn(fake.title, json.dumps(phases, ensure_ascii=False))
            self.assertNotIn(request["text"], json.dumps(packet["response"]["send_call_timing"], ensure_ascii=False))
            self.assertEqual(packet["summary"]["duration_basis"], "queued_workflow_invocation")
            self.assertGreaterEqual(packet["summary"]["total_duration_ms"] + 1,
                                    packet["summary"]["duration_ms"] + packet["summary"]["queue_wait_ms"])
            runtime.close()


if __name__ == "__main__":
    unittest.main()
