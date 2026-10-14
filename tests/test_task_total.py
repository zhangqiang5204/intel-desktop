"""Runtime SQLite and daily-analysis fixtures. No native helper or GUI runs."""
from contextlib import closing
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from daily_analysis import analyze, safe_metadata
from task_runtime import TaskRuntime, operation_duration, WORKFLOW_DURATION_BASIS, TASK_DURATION_BASIS
from workflow_tools import task_action


TASK = "task-total-fixture"
PRIVATE = "PRIVATE BODY PARAMETER CREDENTIAL MUST NOT BE LOGGED"
BASE = datetime(2026, 10, 14, 1, tzinfo=timezone.utc).timestamp()


class Clock:
    def __init__(self):
        self.now = BASE

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class TaskTotalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.runtime = TaskRuntime(self.directory)
        self.clock = Clock()

    def tearDown(self):
        self.runtime.close()
        self.temp.cleanup()

    def operation(self, identifier, *, state="verified", tool="desktop_chat", task=TASK, seconds=1, native=None, action=None):
        def executor(context):
            if native is not None:
                context.record_native(native, substage="batch")
                context.record_native(native, substage="same_response_no_replay")
            self.clock.advance(seconds)
            context.set_outcome(state, verified_flags={"proof_full_value": state == "verified", "proof_same_target": state == "verified", "focus_verified": state == "verified"},
                                error_code=None if state == "verified" else "fixture_failed")
            return {"ok": state == "verified", "result": {"text": PRIVATE, "verified": state == "verified"}}

        with patch("task_runtime.time.time", side_effect=self.clock), patch("task_runtime.time.monotonic", side_effect=self.clock):
            args = {"app": "com.apple.TextEdit", "text": PRIVATE, "parameters": {"value": PRIVATE}}
            if action is not None:
                args["action"] = action
            return self.runtime.run(tool, args, executor,
                                    task_id=task, operation_id=identifier)

    def completion(self, references, final, *, unit="unit-fixture"):
        return self.runtime.record_task_completion(TASK, unit, "send_selection_acceptance", references, final)

    def sql(self, statement, values=()):
        with closing(sqlite3.connect(self.runtime.database)) as database, database:
            return database.execute(statement, values).fetchall()

    def test_workflow_total_is_real_created_to_finish_including_verification_and_focus_return(self):
        def executor(context):
            self.clock.advance(.5)
            context.record_phase("postcondition", "verify_complete_value")
            self.clock.advance(.25)
            context.record_phase("executing", "guarded_focus_return")
            self.clock.advance(.75)
            context.set_outcome("verified", verified_flags={"proof_full_value": True, "focus_verified": True})
            return {"ok": True}

        with patch("task_runtime.time.time", side_effect=self.clock), patch("task_runtime.time.monotonic", side_effect=self.clock):
            packet = self.runtime.run("desktop_transaction", {"app": "com.apple.TextEdit"}, executor, task_id=TASK, operation_id="full-workflow")
        summary = packet["summary"]
        self.assertEqual(summary["created"], BASE)
        self.assertEqual(summary["finished"], BASE + 1.5)
        self.assertEqual(summary["total_duration_ms"], 1500)
        self.assertEqual(summary["duration_basis"], WORKFLOW_DURATION_BASIS)
        self.assertTrue(summary["timing_complete"])
        terminal = self.runtime.logs(task_id=TASK)["events"][-1]
        self.assertEqual(terminal["timing"]["invocation_total"]["total_duration_ms"], 1500)
        self.assertEqual(json.loads(self.sql("SELECT summary_json FROM operations WHERE operation_id='full-workflow'")[0][0])["total_duration_ms"], 1500)

    def test_real_queue_wait_is_in_total_separately_from_executor_duration(self):
        claimed, release, waiter_ready = threading.Event(), threading.Event(), threading.Event()
        result = {}

        def first(context):
            claimed.set()
            self.assertTrue(release.wait(2))
            context.set_outcome("verified", verified_flags={"proof_full_value": True})
            return {"ok": True}

        def second(context):
            time.sleep(.02)  # Simulated work/verification, never native input.
            time.sleep(.015)  # Simulated guarded focus return.
            context.set_outcome("verified", verified_flags={"focus_verified": True})
            return {"ok": True}

        def run_second():
            waiter_ready.set()
            result["second"] = self.runtime.run("desktop_script", {"action": "run"}, second, task_id=TASK, operation_id="queued-workflow")

        first_thread = threading.Thread(target=lambda: self.runtime.run("desktop_chat", {}, first, task_id=TASK, operation_id="blocking-workflow"))
        second_thread = threading.Thread(target=run_second)
        first_thread.start()
        self.assertTrue(claimed.wait(2))
        second_thread.start()
        self.assertTrue(waiter_ready.wait(2))
        deadline = time.monotonic() + 2
        while self.runtime.get_operation("queued-workflow") is None and time.monotonic() < deadline:
            time.sleep(.001)
        self.assertIsNotNone(self.runtime.get_operation("queued-workflow"))
        time.sleep(.03)
        release.set()
        first_thread.join(2)
        second_thread.join(2)
        self.assertFalse(first_thread.is_alive())
        self.assertFalse(second_thread.is_alive())
        summary = result["second"]["summary"]
        self.assertGreater(summary["queue_wait_ms"], 20)
        self.assertGreater(summary["duration_ms"], 30)
        self.assertAlmostEqual(summary["total_duration_ms"], (summary["finished"] - summary["created"]) * 1000, places=2)
        self.assertGreaterEqual(summary["total_duration_ms"] + 1, summary["queue_wait_ms"] + summary["duration_ms"])
        self.assertEqual(summary["duration_basis"], WORKFLOW_DURATION_BASIS)

    def test_script_management_does_not_pollute_business_total_distribution(self):
        for action in ("register", "list", "analyze"):
            summary = self.operation("script-" + action, tool="desktop_script", action=action,
                                     state="accepted_unverified", seconds=.001)["summary"]
            self.assertFalse(summary["workflow_invocation"])
            self.assertTrue(summary["workflow_classification_complete"])
            self.assertEqual(summary["duration_basis"], "queued_tool_invocation")
            self.assertEqual(summary["invocation_action"], action)
            self.assertEqual(summary["timing"], {"invocation_action": action})
        self.operation("script-run", tool="desktop_script", action="run", seconds=2)
        self.operation("chat", seconds=3)
        self.operation("transaction", tool="desktop_transaction", seconds=4)
        report = analyze(self.directory, "2026-10-14", "UTC", write=False)
        workflows = report["task_totals"]["workflow_invocations"]
        self.assertEqual(report["totals"]["count"], 6)
        self.assertEqual(workflows["count"], 3)
        self.assertEqual(workflows["samples"], 3)
        self.assertEqual(workflows["p50"], 3000)
        self.assertEqual(workflows["unclassified_invocations"], 0)
        self.assertTrue(workflows["classification_coverage_complete"])
        self.assertNotIn(PRIVATE, json.dumps(report))

    def test_script_action_metadata_survives_restart_and_event_log_fallback(self):
        self.operation("script-register", tool="desktop_script", action="register", seconds=.001)
        self.operation("script-run", tool="desktop_script", action="run", seconds=2)
        events = self.runtime.logs(task_id=TASK)["events"]
        for event in events:
            expected = "register" if event["operation_id"] == "script-register" else "run"
            self.assertEqual(event["timing"]["invocation_action"], expected)
        path = self.directory / "script-actions.jsonl"
        path.write_text("".join(json.dumps(event) + "\n" for event in events))
        self.runtime.close()
        self.runtime = TaskRuntime(self.directory)
        self.assertEqual(self.runtime.get_operation("script-run")["invocation_action"], "run")
        self.assertFalse(self.runtime.get_operation("script-register")["workflow_invocation"])
        report = analyze(self.directory, "2026-10-14", "UTC", log_paths=[path], write=False)
        workflows = report["task_totals"]["workflow_invocations"]
        self.assertEqual(workflows["count"], 1)
        self.assertEqual(workflows["p50"], 2000)
        self.assertEqual(workflows["unclassified_invocations"], 0)
        self.assertNotIn(PRIVATE, path.read_text())

    def test_legacy_script_without_action_is_unclassified_even_if_old_summary_claimed_workflow(self):
        self.operation("legacy-script", tool="desktop_script", action="run", seconds=.001)
        self.sql("UPDATE operations SET timing_json='{}',summary_json=? WHERE operation_id='legacy-script'",
                 (json.dumps({"workflow_invocation": True, "duration_basis": WORKFLOW_DURATION_BASIS,
                              "action": "register", "parameters": {"value": PRIVATE}}),))
        self.operation("real-chat", seconds=2)
        report = analyze(self.directory, "2026-10-14", "UTC", write=True)
        workflows = report["task_totals"]["workflow_invocations"]
        self.assertEqual(workflows["count"], 1)
        self.assertEqual(workflows["p50"], 2000)
        self.assertEqual(workflows["unclassified_invocations"], 1)
        self.assertFalse(workflows["classification_coverage_complete"])
        self.assertFalse(workflows["coverage_complete"])
        self.assertIn("unclassified=1", (self.directory / "reports/current.txt").read_text())
        self.assertNotIn(PRIVATE, (self.directory / "reports/current.json").read_text())
        summary = self.runtime.get_operation("legacy-script")
        self.assertEqual(summary["duration_basis"], "queued_unclassified_invocation")
        self.assertEqual(summary["total_duration_ms"], 1)
        self.assertFalse(summary["workflow_classification_complete"])

    def test_unknown_or_non_scalar_script_action_is_never_persisted_or_guessed(self):
        for index, action in enumerate((PRIVATE, {"action": PRIVATE}, ["run"])):
            with self.subTest(action=action):
                summary = self.operation("invalid-action-" + str(index), tool="desktop_script", action=action)["summary"]
                self.assertFalse(summary["workflow_classification_complete"])
                self.assertFalse(summary["workflow_invocation"])
                self.assertIsNone(summary["invocation_action"])
                self.assertEqual(summary["timing"], {})
                self.assertNotIn(PRIVATE, json.dumps(summary))
        report = analyze(self.directory, "2026-10-14", "UTC", write=False)
        workflows = report["task_totals"]["workflow_invocations"]
        self.assertEqual(workflows["samples"], 0)
        self.assertIsNone(workflows["p50"])
        self.assertEqual(workflows["unclassified_invocations"], 3)
        self.assertNotIn(PRIVATE, json.dumps(report))

    def test_pending_script_event_retains_classification_without_claiming_complete_timing(self):
        captured = []
        def executor(context):
            event = self.runtime.logs(task_id=TASK)["events"][-1]
            captured.append(safe_metadata(event))
            context.set_outcome("verified", verified_flags={"proof_full_value": True})
            return {"ok": True}
        self.runtime.run("desktop_script", {"action": "run"}, executor, task_id=TASK, operation_id="pending-script")
        self.assertTrue(captured[0]["workflow_invocation"])
        self.assertTrue(captured[0]["workflow_classification_complete"])
        self.assertIsNone(captured[0]["total_duration_ms"])

    def test_explicit_task_span_still_includes_named_management_time(self):
        self.operation("script-preparation", tool="desktop_script", action="register", state="accepted_unverified", seconds=.2)
        self.operation("final-send", seconds=2)
        unit = self.completion(["script-preparation", "final-send"], "final-send")
        self.assertEqual(unit["total_duration_ms"], 2200)
        report = analyze(self.directory, "2026-10-14", "UTC", write=False)
        self.assertEqual(report["task_totals"]["workflow_invocations"]["count"], 1)
        self.assertEqual(report["task_totals"]["completed_task_units"]["p50"], 2200)

    def test_low_level_keys_are_not_presented_as_whole_workflow_tasks(self):
        summary = self.operation("key-one", tool="desktop_key")["summary"]
        self.assertFalse(summary["workflow_invocation"])
        self.assertEqual(summary["duration_basis"], "queued_tool_invocation")
        report = analyze(self.directory, "2026-10-14", "UTC", write=False)
        self.assertEqual(report["totals"]["count"], 1)
        self.assertEqual(report["task_totals"]["workflow_invocations"]["count"], 0)

    def test_explicit_unit_keeps_failed_search_kind_and_unknown_attempts_and_verified_end(self):
        self.operation("preflight", tool="desktop_status", state="completed", seconds=.2)
        self.clock.advance(.3)
        self.operation("failed-search", state="failed", seconds=.5)
        self.clock.advance(.5)
        self.operation("failed-kind", state="failed", seconds=.7)
        self.operation("unknown-attempt", state="unknown", seconds=.3)
        self.operation("final-send", seconds=.5)
        finished = self.runtime.get_operation("final-send")["finished"]
        unit = self.completion(["preflight", "failed-search", "failed-kind", "unknown-attempt", "final-send"], "final-send")
        self.assertEqual(unit["created"], BASE)
        self.assertEqual(unit["finished"], finished)
        self.assertEqual(unit["total_duration_ms"], round((finished - BASE) * 1000, 3))
        self.assertEqual(unit["duration_basis"], TASK_DURATION_BASIS)
        self.assertEqual(unit["failed_attempts"], 3)
        self.assertEqual(unit["unknown_attempts"], 1)
        self.assertEqual(unit["attempt_outcomes"]["failed"], 2)
        self.assertEqual(unit["verified_operation_id"], "final-send")
        self.assertFalse(unit["normality_assessed"])

    def test_completion_record_time_is_not_added_to_the_real_end_time(self):
        self.operation("begin", state="completed", tool="desktop_status")
        self.operation("end", seconds=2)
        self.clock.advance(3600)
        with patch("task_runtime.time.time", side_effect=self.clock):
            unit = self.completion(["begin", "end"], "end")
        self.assertEqual(unit["total_duration_ms"], 3000)
        self.assertEqual(unit["finished"], BASE + 3)
        event = self.runtime.logs(task_id=TASK)["events"][-1]
        self.assertEqual(event["created"], BASE + 3603)
        self.assertEqual(event["timing"]["task_completion"]["finished"], BASE + 3)

    def test_stable_task_id_history_is_not_accumulated_without_explicit_references(self):
        self.clock.now = BASE - 7 * 86400
        self.operation("old-task-history", seconds=600)
        self.clock.now = BASE
        self.operation("current-preflight", tool="desktop_status", state="completed")
        self.operation("current-end", seconds=2)
        unit = self.completion(["current-preflight", "current-end"], "current-end")
        self.assertEqual(unit["total_duration_ms"], 3000)
        self.assertNotIn("old-task-history", unit["operation_ids"])

    def test_cross_task_missing_duplicate_and_unverified_end_references_are_rejected(self):
        self.operation("owned-end")
        self.operation("other-task", task="another-task")
        self.operation("not-verified", state="accepted_unverified")
        for references, final in ((["owned-end", "other-task"], "owned-end"), (["absent", "owned-end"], "owned-end"),
                                  (["owned-end", "owned-end"], "owned-end"), (["not-verified"], "not-verified")):
            with self.subTest(references=references), self.assertRaises(ValueError):
                self.completion(references, final)
        self.assertFalse(any(event["substage"] == "task_completion_total" for event in self.runtime.logs(task_id=TASK)["events"]))

    def test_nonterminal_native_pending_or_missing_finished_cannot_be_recorded_as_complete(self):
        self.operation("end")
        for update in ("state='executing'", "native_pending=1", "finished=NULL"):
            with self.subTest(update=update):
                old = self.runtime.get_operation("end", include_summary=False)
                self.sql("UPDATE operations SET " + update + " WHERE operation_id='end'")
                with self.assertRaises(ValueError):
                    self.completion(["end"], "end")
                self.sql("UPDATE operations SET state=?,native_pending=?,finished=? WHERE operation_id='end'", (old["state"], old["native_pending"], old["finished"]))

    def test_unverified_later_attempt_cannot_extend_a_verified_completion_endpoint(self):
        self.operation("verified-end")
        self.operation("later-failed", state="failed")
        with self.assertRaises(ValueError):
            self.completion(["verified-end", "later-failed"], "verified-end")

    def test_complete_API_accepts_only_metadata_and_fixed_purpose(self):
        self.operation("end")
        request = {"action": "complete", "unit_id": "user-unit", "purpose": "maintenance_acceptance",
                   "operation_ids": ["end"], "verified_operation_id": "end"}
        result = task_action(request, {"task_id": TASK}, self.runtime)
        self.assertTrue(result["ok"])
        for change in ({"message": PRIVATE}, {"purpose": PRIVATE}, {"operation_ids": [PRIVATE]}, {"unit_id": PRIVATE}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                task_action({**request, **change}, {"task_id": TASK}, self.runtime)
        self.assertNotIn(PRIVATE, json.dumps(result))

    def test_completion_is_idempotent_and_restart_reads_same_boundaries_from_SQLite(self):
        self.operation("end", seconds=1.5)
        first = self.completion(["end"], "end")
        self.assertTrue(first["recorded"])
        second = self.completion(["end"], "end")
        self.assertFalse(second["recorded"])
        self.runtime.close()
        self.runtime = TaskRuntime(self.directory)
        saved = self.runtime.get_operation("end")
        self.assertEqual(saved["total_duration_ms"], 1500)
        self.assertEqual(saved["timing"]["task_completions"][0]["unit_id"], "unit-fixture")
        self.assertEqual(sum(event["substage"] == "task_completion_total" for event in self.runtime.logs(task_id=TASK)["events"]), 1)

    def test_unit_cannot_mutate_already_recorded_explicit_references(self):
        self.operation("start", state="completed", tool="desktop_status")
        self.operation("end")
        self.completion(["start", "end"], "end")
        with self.assertRaises(ValueError):
            self.completion(["end"], "end")

    def test_daily_distributions_include_workflow_totals_and_semantic_unit_spans(self):
        self.operation("pref", tool="desktop_status", state="completed", seconds=.1)
        self.operation("fail", state="failed", seconds=.5)
        self.operation("done", seconds=1.5)
        self.completion(["pref", "fail", "done"], "done")
        report = analyze(self.directory, "2026-10-14", "UTC")
        total = report["task_totals"]
        self.assertEqual(total["workflow_invocations"]["count"], 2)
        self.assertEqual(total["workflow_invocations"]["samples"], 2)
        self.assertEqual(total["workflow_invocations"]["p50"], 1000)
        self.assertEqual(total["completed_task_units"]["count"], 1)
        self.assertEqual(total["completed_task_units"]["p50"], 2100)
        self.assertEqual(total["completed_task_units"]["units"][0]["failed_attempts"], 1)
        self.assertFalse(total["normality_assessed"])
        self.assertFalse(total["automatic_optimization"])
        text = (self.directory / "reports/current.txt").read_text()
        self.assertIn(WORKFLOW_DURATION_BASIS, text)
        self.assertIn(TASK_DURATION_BASIS, text)
        self.assertNotIn(PRIVATE, (self.directory / "reports/current.json").read_text())

    def test_missing_timestamps_in_progress_and_unknown_do_not_have_normal_coverage(self):
        self.operation("unknown", state="unknown")
        self.operation("missing")
        self.sql("UPDATE operations SET started=NULL WHERE operation_id='missing'")
        self.operation("running")
        self.sql("UPDATE operations SET state='executing',finished=NULL WHERE operation_id='running'")
        report = analyze(self.directory, "2026-10-14", "UTC", write=False)
        coverage = report["task_totals"]["workflow_invocations"]
        self.assertEqual(coverage["unknown_outcomes"], 1)
        self.assertEqual(coverage["in_progress"], 1)
        self.assertEqual(coverage["missing_or_incomplete_timing"], 2)
        self.assertFalse(coverage["coverage_complete"])
        self.assertFalse(report["task_totals"]["normality_assessed"])

    def test_terminal_event_logs_preserve_task_and_invocation_totals_without_double_counting(self):
        self.operation("done", seconds=2)
        self.completion(["done"], "done")
        events = self.runtime.logs(task_id=TASK)["events"]
        path = self.directory / "fixture-events.jsonl"
        path.write_text("".join(json.dumps(event) + "\n" for event in events))
        report = analyze(self.directory, "2026-10-14", "UTC", log_paths=[path], write=False)
        self.assertEqual(report["totals"]["count"], 1)
        self.assertEqual(report["task_totals"]["workflow_invocations"]["p50"], 2000)
        self.assertEqual(report["task_totals"]["completed_task_units"]["p50"], 2000)

    def test_batch_aggregate_native_result_is_counted_once_not_once_per_child_or_echo(self):
        for ok in (True, False):
            with self.subTest(ok=ok):
                native = {"id": 1, "ok": ok, "elapsed_ms": 20, "result": {"events_posted": 6,
                          "results": [{"result": {"events_posted": 2}}, {"result": {"events_posted": 4}}]}}
                if not ok:
                    native["error"] = {"code": "fixture_failed", "details": {"events_posted": 6}}
                summary = self.operation("batch-" + str(ok), state="verified" if ok else "failed", native=native)["summary"]
                self.assertEqual(summary["event_count"], 6)
                self.assertEqual(summary["timing"]["native_elapsed_ms"], 20)
                self.assertEqual(summary["total_duration_ms"], 1000)

    def test_older_runtime_schema_without_timing_json_migrates_and_daily_does_not_guess_missing_times(self):
        self.operation("legacy")
        self.operation("legacy-script", tool="desktop_script", action="run")
        self.runtime.close()
        self.sql("ALTER TABLE operations DROP COLUMN timing_json")
        self.sql("ALTER TABLE events DROP COLUMN timing_json")
        self.runtime = TaskRuntime(self.directory)
        self.assertEqual(self.runtime.get_operation("legacy")["total_duration_ms"], 1000)
        self.assertFalse(self.runtime.get_operation("legacy-script")["workflow_classification_complete"])
        self.assertEqual(self.runtime.get_operation("legacy-script")["total_duration_ms"], 1000)
        self.sql("UPDATE operations SET started=NULL WHERE operation_id='legacy'")
        report = analyze(self.directory, "2026-10-14", "UTC", write=False)
        self.assertEqual(report["task_totals"]["workflow_invocations"]["samples"], 0)
        self.assertEqual(report["task_totals"]["workflow_invocations"]["unclassified_invocations"], 1)
        self.assertEqual(report["totals"]["execution_ms"]["samples"], 2)

    def test_time_reversal_and_pending_unknown_are_not_clamped_to_a_fake_zero_total(self):
        base = {"tool": "desktop_chat", "created": BASE, "started": BASE, "finished": BASE - 1, "state": "verified"}
        self.assertIsNone(operation_duration(base)["total_duration_ms"])
        self.assertFalse(operation_duration(base)["timing_complete"])
        base.update(finished=BASE + 10, state="unknown", native_pending=True)
        self.assertIsNone(operation_duration(base)["total_duration_ms"])

    def test_safe_daily_projection_discards_arbitrary_payload_inside_completion_metadata(self):
        self.operation("done")
        unit = self.completion(["done"], "done")
        unit["body"] = PRIVATE
        row = self.runtime.get_operation("done")
        row["timing"]["task_completions"] = [unit]
        projected = safe_metadata(row)
        self.assertNotIn(PRIVATE, json.dumps(projected, default=str))

    def test_invalid_completion_metadata_is_reported_as_incomplete_instead_of_normal(self):
        self.operation("done")
        unit = self.completion(["done"], "done")
        unit["purpose"] = {"body": PRIVATE}
        timing = {"task_completions": [unit]}
        self.sql("UPDATE operations SET timing_json=? WHERE operation_id='done'", (json.dumps(timing),))
        report = analyze(self.directory, "2026-10-14", "UTC", write=False)
        units = report["task_totals"]["completed_task_units"]
        self.assertEqual(units["invalid_or_incomplete_records"], 1)
        self.assertFalse(units["coverage_complete"])
        self.assertNotIn(PRIVATE, json.dumps(report))

    def test_event_fallback_reads_all_completion_units_linked_to_one_verified_source(self):
        self.operation("done")
        self.completion(["done"], "done", unit="send-unit")
        self.completion(["done"], "done", unit="root-unit")
        path = self.directory / "all-units.jsonl"
        path.write_text("".join(json.dumps(event) + "\n" for event in self.runtime.logs(task_id=TASK)["events"]))
        report = analyze(self.directory, "2026-10-14", "UTC", log_paths=[path], write=False)
        self.assertEqual(report["task_totals"]["completed_task_units"]["count"], 2)
        self.assertEqual(report["task_totals"]["workflow_invocations"]["samples"], 1)


if __name__ == "__main__":
    unittest.main()
