"""Real local runtime execution of offline fixtures; no GUI proof is claimed."""
from datetime import datetime
import json
from pathlib import Path
import sys
import tempfile
import unittest
from zoneinfo import ZoneInfo

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from daily_analysis import analyze
from learning_store import LearningStore
from task_runtime import TaskRuntime


class RuntimeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.runtime = TaskRuntime(self.directory, "fixture-session")
        self.store = LearningStore(self.directory, runtime=self.runtime)
        self.source = self.directory / "textedit.json"
        self.source.write_text(json.dumps({"format": "desktop_plan/v1", "app": "com.apple.TextEdit",
                                          "parameter_names": ["text"], "steps": [],
                                          "postconditions": [{"equals": {"$param": "text"}}]}))
        self.row = self.store.register("fixture-task", "com.apple.TextEdit", str(self.source), ["text"])

    def tearDown(self):
        self.runtime.close()
        self.temporary.cleanup()

    def execute_fixture(self, identifier, *, state, proofs=None):
        def executor(context):
            context.record_source(self.row["id"], self.row["source_sha256"], parameter_names=["text"])
            context.record_native({"id": 1, "ok": True, "elapsed_ms": 10,
                                   "result": {"events_posted": 2, "value": "PRIVATE_BODY",
                                              "native_stage_ms": {"ax_read": 2, "value_verify": 3.5, "PRIVATE BODY": 99}}})
            context.set_outcome(state, verified_flags=proofs, error_code="native_protocol_error" if state == "failed" else None)
            return {"ok": state != "failed", "result": {"value": "PRIVATE_BODY"}}
        return self.runtime.run("desktop_script", {"app": "com.apple.TextEdit", "text": "PRIVATE_BODY"}, executor,
                                task_id="fixture-task", operation_id=identifier)

    def test_runtime_lookup_promotes_only_complete_postcondition(self):
        response = self.execute_fixture("fixture-verified", state="verified",
                                        proofs={"proof_full_value": True, "proof_same_target": True, "focus_verified": True})
        self.assertTrue(response["executed"])
        evidence = self.runtime.script_execution_evidence("fixture-verified")
        self.assertEqual(evidence["verification"]["source"], "runtime_postcondition")
        recorded = self.store.record_verified_execution(self.row["id"], "fixture-verified")
        self.assertEqual(recorded["status"], "verified")
        self.assertEqual(recorded["verification_count"], 3)
        self.assertNotIn("PRIVATE_BODY", self.store.path.read_text())

    def test_runtime_posted_only_and_failure_are_complete_unverified(self):
        self.execute_fixture("fixture-posted", state="accepted_unverified")
        posted = self.store.record_verified_execution(self.row["id"], "fixture-posted")
        self.assertFalse(posted["verified"])
        self.assertEqual(posted["status"], "candidate")
        self.execute_fixture("fixture-failed", state="failed")
        failed = self.store.record_verified_execution(self.row["id"], "fixture-failed")
        self.assertFalse(failed["verified"])
        self.assertEqual(self.store.list()["scripts"][0]["failures"], 1)

    def test_actual_runtime_sqlite_drives_daily_safe_report(self):
        self.execute_fixture("fixture-failed", state="failed")
        day = datetime.now(ZoneInfo("Asia/Tokyo")).date().isoformat()
        report = analyze(self.directory, day, "Asia/Tokyo")
        self.assertEqual(report["source"]["kind"], "sqlite")
        self.assertEqual(report["totals"]["count"], 1)
        self.assertEqual(report["totals"]["failures"], 1)
        self.assertEqual(report["by_error_tool_app"][0]["error_code"], "native_protocol_error")
        self.assertEqual(report["totals"]["native_elapsed_ms"]["p50"], 10)
        self.assertEqual(report["native_stage_ms"]["stages"][0]["stage"], "value_verify")
        self.assertEqual(report["native_stage_ms"]["stages"][0]["p95"], 3.5)
        self.assertNotIn("PRIVATE_BODY", json.dumps(report))

    def test_actual_runtime_safe_interruption_reason_reaches_daily_group(self):
        def executor(context):
            context.record_native({"id": 1, "ok": False, "error": {"code": "user_interrupted", "details": {
                "last_interruption_event": {"reason": "pointer_context_unknown", "event_type": 5,
                    "source_unix_process_id": 222, "target_unix_process_id": 777,
                    "pointer_owner": {"state": "unavailable", "fresh": False, "title": "PRIVATE_BODY"},
                    "keyboard_focus": {"state": "cached", "pid": 333, "fresh": True}, "text": "PRIVATE_BODY"}}}})
            context.set_outcome("interrupted", error_code="user_interrupted")
            return {"ok": False}
        self.runtime.run("desktop_transaction", {"app": "com.apple.TextEdit"}, executor,
                         task_id="fixture-task", operation_id="fixture-interrupted")
        day = datetime.now(ZoneInfo("Asia/Tokyo")).date().isoformat()
        report = analyze(self.directory, day, "Asia/Tokyo", write=False)
        self.assertEqual(report["by_interruption_reason"][0]["interruption_reason"], "pointer_context_unknown")
        self.assertEqual(report["by_interruption_reason"][0]["error_code"], "user_interrupted")
        self.assertEqual(report["by_interruption_reason"][0]["count"], 1)
        self.assertNotIn("PRIVATE_BODY", json.dumps(report))


if __name__ == "__main__":
    unittest.main()
