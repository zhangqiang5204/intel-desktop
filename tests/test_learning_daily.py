"""Offline fixtures. These are not desktop execution or real GUI acceptance."""
import json
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from learning_store import LearningStore
from daily_analysis import analyze, local_timezone, safe_metadata


class PersistedEvidenceFixture:
    """A read-only offline evidence adapter, never an execution authorization."""
    def __init__(self, path):
        self.path = path
        with closing(sqlite3.connect(path)) as db, db:
            db.execute("CREATE TABLE evidence(operation_id TEXT PRIMARY KEY, metadata TEXT)")

    def add(self, evidence):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("INSERT INTO evidence VALUES (?,?)", (evidence["operation_id"], json.dumps(evidence)))

    def script_execution_evidence(self, operation_id):
        with closing(sqlite3.connect(self.path)) as db:
            row = db.execute("SELECT metadata FROM evidence WHERE operation_id=?", (operation_id,)).fetchone()
        return json.loads(row[0]) if row else None


def plan():
    return {"format": "desktop_plan/v1", "app": "com.apple.TextEdit", "parameter_names": ["text"],
            "steps": [{"id": "type", "tool": "type_text", "arguments": {"text": {"$param": "text"}}}],
            "postconditions": [{"step": "after", "attribute": "value", "equals": {"$param": "text"}}]}


class LearningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "textedit.json"
        self.source.write_text(json.dumps(plan()))
        self.runtime = PersistedEvidenceFixture(self.directory / "fixture.sqlite3")
        self.store = LearningStore(self.directory, runtime=self.runtime)
        self.row = self.store.register("task-one", "com.apple.TextEdit", str(self.source), ["text"], "edit_text")

    def tearDown(self):
        self.temporary.cleanup()

    def evidence(self, operation_id, task_id="task-one", **override):
        result = {"operation_id": operation_id, "task_id": task_id, "app": self.row["app"], "script_id": self.row["id"],
                  "source_sha256": self.row["source_sha256"], "executed": True, "complete": True, "ok": True,
                  "verification": {"source": "runtime_postcondition", "complete": True, "passed": True, "checks": 2},
                  "duration_ms": 12.5, "event_count": 2}
        result.update(override)
        self.runtime.add(result)
        return operation_id

    def test_general_app_registers_metadata_only(self):
        self.assertEqual(self.row["status"], "candidate")
        self.assertEqual(self.row["language"], "json")
        self.assertTrue(self.row["parameterization_candidate"])
        self.assertEqual(self.row["size_bytes"], self.source.stat().st_size)
        self.assertEqual(len(self.row["source_sha256"]), 64)
        self.assertFalse(self.row["executable"])
        payload = self.store.path.read_text()
        self.assertNotIn('"steps"', payload)
        self.assertNotIn('"postconditions"', payload)
        self.assertEqual(os.stat(self.store.path).st_mode & 0o777, 0o600)

    def test_complete_evidence_promotes_and_deduplicates(self):
        first = self.evidence("op-one")
        result = self.store.record_verified_execution(self.row["id"], first)
        self.assertTrue(result["verified"])
        self.assertEqual(result["status"], "verified")
        self.assertFalse(self.store.record_verified_execution(self.row["id"], first)["recorded"])
        for identifier, task in [("op-two", "task-one"), ("op-three", "task-two")]:
            self.store.record_verified_execution(self.row["id"], self.evidence(identifier, task))
        current = self.store.list()["scripts"][0]
        self.assertEqual(current["status"], "reusable")
        self.assertEqual(current["verified_successes"], 3)
        self.assertEqual(current["verification_count"], 6)
        self.assertFalse(current["executable"])

    def test_posted_events_and_caller_flag_do_not_verify(self):
        op = self.evidence("posted-only", verification={"source": "caller_flag", "passed": True, "complete": True, "checks": 1}, verified=True)
        result = self.store.record_verified_execution(self.row["id"], op)
        self.assertFalse(result["verified"])
        self.assertEqual(result["status"], "candidate")
        incomplete = self.evidence("incomplete", complete=False)
        with self.assertRaises(ValueError):
            self.store.record_verified_execution(self.row["id"], incomplete)
        with self.assertRaises(TypeError):
            self.store.record_verified_execution(self.row["id"], "op", verified=True)

    def test_source_change_resets_to_candidate_before_reuse(self):
        self.store.record_verified_execution(self.row["id"], self.evidence("before-change"))
        value = plan()
        value["steps"].append({"id": "read", "tool": "inspect", "arguments": {}})
        self.source.write_text(json.dumps(value))
        current = self.store.list()["scripts"][0]
        self.assertEqual(current["status"], "candidate")
        self.assertEqual(current["verified_successes"], 0)
        self.assertEqual(current["total_successes"], 1)
        self.assertNotEqual(current["source_sha256"], self.row["source_sha256"])
        with self.assertRaises(ValueError):
            self.store.record_verified_execution(self.row["id"], self.evidence("stale-proof"))

    def test_rejected_stale_proof_persists_candidate_reset(self):
        self.store.record_verified_execution(self.row["id"], self.evidence("first-proof"))
        self.source.write_text(json.dumps(plan(), indent=2))
        with self.assertRaises(ValueError):
            self.store.record_verified_execution(self.row["id"], self.evidence("stale-after-write"))
        persisted = json.loads(self.store.path.read_text())["scripts"][self.row["id"]]
        self.assertEqual(persisted["status"], "candidate")
        self.assertEqual(persisted["verified_successes"], 0)

    def test_failure_is_counted_without_false_verification(self):
        self.store.record_verified_execution(self.row["id"], self.evidence("failure", ok=False, error_code="transport_failed", verification={}))
        current = self.store.list()["scripts"][0]
        self.assertEqual(current["failures"], 1)
        self.assertEqual(current["verification_count"], 0)
        self.assertEqual(current["last_error_code"], "transport_failed")
        self.assertEqual(self.store.analyze()["candidates"][0]["recommendation"], "repair_execution_failure")

    def test_sensitive_source_is_never_copied_or_promoted(self):
        marker = "PRIVATE_CHAT_BODY_DO_NOT_STORE"
        value = plan()
        value["steps"][0]["arguments"]["text"] = marker
        value["token"] = "SUPER_SECRET_CREDENTIAL"
        self.source.write_text(json.dumps(value))
        row = self.store.register("task-one", "com.apple.TextEdit", str(self.source), ["text"])
        self.row = row
        self.assertFalse(row["parameterization_candidate"])
        self.assertIn("hardcoded_input_value", row["safety_findings"])
        result = self.store.record_verified_execution(row["id"], self.evidence("sensitive-proof"))
        self.assertFalse(result["verified"])
        self.assertEqual(result["status"], "candidate")
        self.assertNotIn(marker, self.store.path.read_text())
        self.assertNotIn("SUPER_SECRET_CREDENTIAL", json.dumps(self.store.analyze()))

    def test_old_python_stays_candidate_and_is_not_imported(self):
        source = self.directory / "old_script.py"
        sentinel = self.directory / "should_not_exist"
        source.write_text(f"from pathlib import Path\nPath({str(sentinel)!r}).touch()\ntoken='SECRET_LITERAL'\n")
        row = self.store.register("task-one", "com.apple.TextEdit", str(source), ["text"])
        self.assertFalse(sentinel.exists())
        self.assertEqual(row["language"], "python")
        self.assertIn("conversion_to_desktop_plan_required", row["safety_findings"])
        self.assertIn("hardcoded_sensitive_value", row["safety_findings"])
        self.assertNotIn("SECRET_LITERAL", self.store.path.read_text())

    def test_only_registered_source_is_read(self):
        unregistered = self.directory / "private.json"
        unregistered.write_text("not valid json and should never be read")
        summary = self.store.analyze()
        self.assertEqual(summary["registered_count"], 1)
        self.assertNotIn(str(unregistered), json.dumps(summary))

    def test_missing_source_invalidates_proof(self):
        self.store.record_verified_execution(self.row["id"], self.evidence("before-missing"))
        self.source.unlink()
        current = self.store.list()["scripts"][0]
        self.assertFalse(current["source_available"])
        self.assertEqual(current["status"], "candidate")

    def test_string_placeholder_is_literal(self):
        value = plan()
        value["steps"][0]["arguments"]["text"] = "${text}"
        self.source.write_text(json.dumps(value))
        current = self.store.list()["scripts"][0]
        self.assertIn("hardcoded_input_value", current["safety_findings"])

    def test_invalid_plan_parameters_stay_metadata_candidate(self):
        value = plan()
        value["parameter_names"] = [{"raw": "NEVER_STORE"}]
        self.source.write_text(json.dumps(value))
        current = self.store.list()["scripts"][0]
        self.assertIn("parameter_names_mismatch", current["safety_findings"])
        self.assertEqual(current["status"], "candidate")
        self.assertNotIn("NEVER_STORE", self.store.path.read_text())


class DailyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def logs(self, rows):
        path = self.directory / "metadata.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        return path

    def event(self, operation_id, stamp="2026-10-12T16:00:00+00:00", **values):
        row = {"operation_id": operation_id, "task_id": "task-one", "chain_id": "chain-one",
               "timestamp": stamp, "tool": "desktop_inspect", "app": "com.apple.TextEdit", "state": "verified",
               "phase": "outcome", "duration_ms": 100, "queue_wait_ms": 10, "event_count": 0}
        row.update(values)
        return row

    def test_cross_day_local_timezone_filter(self):
        self.logs([self.event("yesterday", "2026-10-12T14:59:59+00:00"),
                   self.event("start", "2026-10-12T15:00:00+00:00"),
                   self.event("end", "2026-10-13T14:59:59+00:00"),
                   self.event("tomorrow", "2026-10-13T15:00:00+00:00")])
        report = analyze(self.directory, "2026-10-13", "Asia/Tokyo")
        self.assertEqual(report["totals"]["count"], 2)
        self.assertEqual(report["timezone"], "Asia/Tokyo")
        self.assertTrue((self.directory / "reports" / "current.txt").is_file())
        self.assertEqual(os.stat(self.directory / "reports" / "current.json").st_mode & 0o777, 0o600)

    def test_percentiles_queue_execution_and_priority(self):
        self.logs([self.event("one", duration_ms=10, queue_wait_ms=1000),
                   self.event("two", duration_ms=20, queue_wait_ms=2000, state="failed", error_code="native_protocol_error", event_count=2),
                   self.event("three", duration_ms=100, queue_wait_ms=3000, state="failed", error_code="native_protocol_error")])
        report = analyze(self.directory, "2026-10-13", "Asia/Tokyo", write=False)
        self.assertEqual(report["totals"]["execution_ms"]["p50"], 20)
        self.assertEqual(report["totals"]["execution_ms"]["p95"], 92)
        self.assertEqual(report["totals"]["queue_wait_ms"]["p95"], 2900)
        self.assertEqual(report["totals"]["failures"], 2)
        self.assertEqual(report["by_error_tool_app"][0]["count"], 2)
        self.assertTrue(any(x["kind"] == "queue_latency" for x in report["repair_candidates"]))
        self.assertTrue(any(x.get("safe_local_repair_candidate") and x.get("error_code") == "native_protocol_error" for x in report["repair_candidates"]))

    def test_payload_exception_credentials_and_screenshot_are_discarded(self):
        marker = "PRIVATE BODY SECRET PASSWORD"
        self.logs([self.event("one", state="failed", error_code=marker, body=marker, text=marker,
                             screenshot=marker, credential=marker, error={"message": marker}),
                   {"timestamp": "no valid timestamp", "message": marker},
                   self.event("two", tool=marker, app=marker, task_id=marker, state={"raw": marker})])
        report = analyze(self.directory, "2026-10-13", "Asia/Tokyo")
        encoded = json.dumps(report)
        self.assertNotIn(marker, encoded)
        self.assertEqual(report["invalid_records"], 1)
        self.assertEqual(report["by_error_tool_app"][0]["error_code"], "operation_failed")
        self.assertNotIn(marker, (self.directory / "reports" / "current.txt").read_text())

    def test_duplicate_phases_count_one_operation_and_event_total(self):
        self.logs([self.event("one", state="running", phase="native", event_count=2),
                   self.event("one", stamp="2026-10-12T16:00:01+00:00", state="verified", phase="outcome", event_count=2)])
        report = analyze(self.directory, "2026-10-13", "Asia/Tokyo", write=False)
        self.assertEqual(report["totals"]["count"], 1)
        self.assertEqual(report["totals"]["events_posted"], 2)
        self.assertEqual(report["deduplicated_records"], 1)

    def test_reason_groups_reuse_runtime_sanitizer_not_free_text(self):
        marker = "PRIVATE_REASON_DO_NOT_STORE"
        self.logs([self.event("one", state="interrupted", error_code="user_interrupted",
                             timing={"last_interruption_event": {"reason": "pointer_owner_conflict", "text": marker}}),
                   self.event("two", state="interrupted", error_code="user_interrupted",
                             timing={"last_interruption_event": {"reason": marker, "pointer_owner": {"title": marker}}}),
                   self.event("three", state="interrupted", error_code="user_interrupted",
                             timing={"last_interruption_event": {"reason": "manual_4294967295"}}),
                   self.event("four", state="interrupted", error_code="user_interrupted",
                             timing={"last_interruption_event": {"reason": "manual_4294967296"}})])
        report = analyze(self.directory, "2026-10-13", "Asia/Tokyo", write=False)
        reasons = {row["interruption_reason"] for row in report["by_interruption_reason"]}
        self.assertEqual(reasons, {"pointer_owner_conflict", "manual_4294967295"})
        self.assertNotIn(marker, json.dumps(report))
        self.assertEqual(report["interruption_reason_basis"], "last_native_event_per_operation")

    def test_sqlite_owner_takes_priority_over_duplicate_log(self):
        stamp = datetime(2026, 10, 13, 1, tzinfo=ZoneInfo("Asia/Tokyo")).timestamp()
        with closing(sqlite3.connect(self.directory / "runtime.sqlite3")) as db, db:
            db.execute("CREATE TABLE operations(operation_id TEXT, task_id TEXT, chain_id TEXT, tool TEXT, app TEXT, state TEXT, created REAL, finished REAL, queue_wait_ms REAL, duration_ms REAL, event_count INTEGER, flags_json TEXT, source_json TEXT, summary_json TEXT)")
            db.execute("INSERT INTO operations VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       ("sqlite-one", "task-one", "chain-one", "desktop_inspect", "com.apple.TextEdit", "failed", stamp - 60, stamp, 2000, 20, 2, "{}", "{}", json.dumps({"error_code": "native_protocol_error", "raw_exception": "SECRET"})))
        self.logs([self.event("duplicate-log")])
        report = analyze(self.directory, "2026-10-13", "Asia/Tokyo", write=False)
        self.assertEqual(report["source"]["kind"], "sqlite")
        self.assertEqual(report["totals"]["count"], 1)
        self.assertEqual(report["by_error_tool_app"][0]["error_code"], "native_protocol_error")
        self.assertNotIn("SECRET", json.dumps(report))

    def test_default_date_is_yesterday_and_cli_is_runnable(self):
        yesterday = datetime.now(ZoneInfo("Asia/Tokyo")).date().toordinal() - 1
        result = analyze(self.directory, timezone="Asia/Tokyo", write=False)
        self.assertEqual(datetime.fromisoformat(result["date"]).date().toordinal(), yesterday)
        completed = subprocess.run([sys.executable, str(SCRIPTS / "daily_analysis.py"), "analyze", "--runtime-dir", str(self.directory),
                                    "--date", "2026-10-13", "--timezone", "Asia/Tokyo"], text=True, capture_output=True, check=True)
        self.assertIn("2026-10-13 (Asia/Tokyo)", completed.stdout)
        self.assertTrue((self.directory / "reports" / "2026-10-13.json").exists())


if __name__ == "__main__":
    unittest.main()
