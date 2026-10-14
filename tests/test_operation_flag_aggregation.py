"""Operation diagnostics retain actual stage effects; no native UI is invoked."""
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/task_runtime.py"
sys.path.insert(0, str(SOURCE.parent))
from task_runtime import TaskRuntime
from workflow_tools import classify_result

PROOF = {"proof_full_value": True, "proof_same_target": True, "focus_verified": True}
PRIVATE = "PRIVATE_CLIPBOARD_AX_VALUE_CREDENTIAL_SENTINEL_5941"
PASTE = {"temporary_clipboard_used": True, "clipboard_restored": True,
         "clipboard_external_change": False, "clipboard_isolated": False,
         "input_may_be_partial": False}
CLEAR = {"temporary_clipboard_used": False, "clipboard_restored": False,
         "clipboard_external_change": False, "clipboard_isolated": True,
         "input_may_be_partial": False}


def receipt(native_id, flags, *, error=False, events=3):
    metadata = {**flags, "events_posted": events, "ax_actions_attempted": 2,
                "ax_menu_actions_attempted": 1, "ax_composer_focus_actions_attempted": 1,
                "clipboard_data": PRIVATE, "AXValue": PRIVATE, "password": PRIVATE}
    value = {"id": native_id, "ok": not error, "elapsed_ms": 5.0}
    if error:
        value["error"] = {"code": "background_postcondition_unknown", "message": PRIVATE, "details": metadata}
    else:
        value["result"] = metadata
    return value


class OperationFlagAggregation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="operation-flags-")
        self.addCleanup(self.temporary.cleanup)
        self.runtime = TaskRuntime(self.temporary.name, session_id="flags-session")
        self.addCleanup(self.runtime.close)

    def run_steps(self, responses, *, operation_id="flags-op", outcome="verified"):
        def execute(context):
            for index, response in enumerate(responses):
                context.boundary()
                context.record_native(response, substage="step_" + str(index))
            context.record_phase("postcondition", "full_actual_value", verified_flags=PROOF)
            context.set_outcome(outcome, verified_flags=PROOF)
            return responses[-1]
        return self.runtime.run("desktop_transaction", {"app": "com.bytedance.macos.feishu", "text": PRIVATE},
                                execute, task_id="flags-task", operation_id=operation_id)

    def flags(self, outcome):
        return outcome["summary"]["verified_flags"]

    def test_actual_paste_then_no_lease_clear_keeps_restoration_and_use(self):
        # Matches the two receipts in fe-background-queued58-left.json.
        outcome = self.run_steps([receipt(1, PASTE), receipt(2, CLEAR)])
        flags = self.flags(outcome)
        self.assertTrue(flags["temporary_clipboard_used"])
        self.assertTrue(flags["clipboard_restored"])
        self.assertFalse(flags["clipboard_isolated"])
        self.assertFalse(flags["clipboard_external_change"])
        self.assertEqual(outcome["summary"]["state"], "verified")
        self.assertEqual(outcome["summary"]["event_count"], 6)
        events = self.runtime.logs(operation_id="flags-op")["events"]
        native = [row for row in events if row["substage"] in {"step_0", "step_1"}]
        self.assertEqual(native[0]["verified_flags"], PASTE)
        self.assertEqual(native[1]["verified_flags"], CLEAR)
        saved = self.runtime._persistent_db().execute("SELECT summary_json FROM operations WHERE operation_id=?", ("flags-op",)).fetchone()
        for reader in (self.runtime.get_operation("flags-op"), json.loads(saved[0])):
            self.assertEqual(reader["verified_flags"], flags)

    def test_external_clipboard_change_and_partial_input_remain_after_clear(self):
        changed = {**PASTE, "clipboard_external_change": True, "clipboard_restored": False,
                   "input_may_be_partial": True}
        flags = self.flags(self.run_steps([receipt(1, changed), receipt(2, CLEAR)], outcome="unknown"))
        self.assertTrue(flags["clipboard_external_change"])
        self.assertTrue(flags["input_may_be_partial"])
        self.assertTrue(flags["temporary_clipboard_used"])
        self.assertFalse(flags["clipboard_isolated"])
        self.assertFalse(flags["clipboard_restored"])

    def test_every_actual_paste_restoration_must_succeed_in_either_order(self):
        for order in ((True, False, True), (False, True, True), (True, True, False)):
            with self.subTest(order=order):
                responses = [receipt(index + 1, {**PASTE, "clipboard_restored": restored})
                             for index, restored in enumerate(order)]
                responses.append(receipt(4, CLEAR))
                flags = self.flags(self.run_steps(responses, operation_id="restore-" + str(order.index(False))))
                self.assertFalse(flags["clipboard_restored"])
                self.assertTrue(flags["temporary_clipboard_used"])

    def test_clear_before_and_after_paste_is_not_a_restore_requirement(self):
        flags = self.flags(self.run_steps([receipt(1, CLEAR), receipt(2, PASTE), receipt(3, CLEAR)]))
        self.assertTrue(flags["clipboard_restored"])
        self.assertFalse(flags["clipboard_isolated"])

    def test_status_capability_without_actual_clipboard_stage_does_not_affect_summary(self):
        capability = {"id": 1, "ok": True, "result": {"clipboard_isolated": False, "clipboard_restored": False}}
        flags = self.flags(self.run_steps([capability, receipt(2, CLEAR)]))
        self.assertTrue(flags["clipboard_isolated"])
        self.assertFalse(flags["temporary_clipboard_used"])
        self.assertNotIn("clipboard_restored", flags)
        source_event = next(row for row in self.runtime.logs(operation_id="flags-op")["events"] if row["substage"] == "step_0")
        self.assertFalse(source_event["verified_flags"]["clipboard_isolated"])
        status_only = self.run_steps([capability], operation_id="status-only", outcome="completed")
        self.assertNotIn("clipboard_isolated", self.flags(status_only))
        self.assertNotIn("clipboard_restored", self.flags(status_only))

    def test_non_boolean_usage_does_not_turn_capability_into_clipboard_stage(self):
        for index, invalid in enumerate((1, "true", None)):
            dirty = {"temporary_clipboard_used": invalid, "clipboard_isolated": False, "clipboard_restored": False,
                     "clipboard_external_change": "false", "input_may_be_partial": "true"}
            flags = self.flags(self.run_steps([receipt(1, dirty), receipt(2, CLEAR)], operation_id="bad-bool-" + str(index)))
            self.assertTrue(flags["clipboard_isolated"])
            self.assertFalse(flags["input_may_be_partial"])
            self.assertFalse(flags["clipboard_external_change"])
            self.assertNotIn("clipboard_restored", flags)

    def test_final_proof_flags_keep_latest_value_semantics(self):
        responses = [receipt(1, {**PASTE, "value_verified": True, "foreground_preserved": True}),
                     receipt(2, {**CLEAR, "value_verified": False, "foreground_preserved": False})]
        flags = self.flags(self.run_steps(responses, outcome="completed"))
        self.assertFalse(flags["value_verified"])
        self.assertFalse(flags["foreground_preserved"])
        self.assertTrue(flags["proof_full_value"])
        self.assertTrue(flags["proof_same_target"])
        self.assertTrue(flags["focus_verified"])

    def test_later_phase_and_outcome_false_flags_do_not_erase_occurred_effects(self):
        def execute(context):
            context.record_native(receipt(1, {**PASTE, "input_may_be_partial": True, "clipboard_external_change": True}))
            context.record_phase("postcondition", "clear_check", verified_flags=CLEAR)
            context.set_outcome("unknown", verified_flags=CLEAR)
            return {"ok": True}
        flags = self.flags(self.runtime.run("desktop_transaction", {}, execute, operation_id="phase-finish"))
        self.assertTrue(flags["input_may_be_partial"])
        self.assertTrue(flags["clipboard_external_change"])
        self.assertTrue(flags["temporary_clipboard_used"])
        self.assertTrue(flags["clipboard_restored"])
        self.assertFalse(flags["clipboard_isolated"])

    def test_zero_CG_failure_then_read_preserves_exception_and_queue_can_continue(self):
        failed = receipt(1, {**PASTE, "input_may_be_partial": True, "clipboard_external_change": True}, error=True, events=0)
        failed["error"]["details"]["last_interruption_event"] = {
            "reason": "pointer_owner_conflict", "event_type": 22, "title": PRIVATE,
            "pointer_owner": {"state": "hit", "pid": 456, "window_id": 987, "AXValue": PRIVATE}}
        read = {"id": 2, "ok": True, "result": {**CLEAR, "body": PRIVATE, "events_posted": 0}}
        calls = []
        def execute(context):
            calls.append("paste")
            context.record_native(failed, substage="paste_failed")
            classify_result("chat", {"action": "draft"}, failed, context)
            context.boundary()
            context.record_native(read, substage="fresh_read")
            return read
        args = {"app": "com.bytedance.macos.feishu", "action": "draft", "text": PRIVATE}
        first = self.runtime.run("desktop_chat", args, execute, task_id="flags-task", operation_id="unknown-op")
        summary = first["summary"]
        self.assertEqual(summary["state"], "unknown")
        self.assertEqual(summary["error_code"], "background_postcondition_unknown")
        self.assertEqual(summary["event_count"], 0)
        self.assertFalse(summary["conflict_active"])
        self.assertTrue(summary["verified_flags"]["input_may_be_partial"])
        self.assertTrue(summary["verified_flags"]["clipboard_external_change"])
        self.assertTrue(summary["verified_flags"]["clipboard_restored"])
        self.assertFalse(summary["verified_flags"]["clipboard_isolated"])
        self.assertEqual(summary["timing"]["native_action_counts"],
                         {"ax_actions_attempted": 2, "ax_menu_actions_attempted": 1, "ax_composer_focus_actions_attempted": 1})
        self.assertEqual(summary["timing"]["last_interruption_event"]["reason"], "pointer_owner_conflict")
        log = self.runtime.logs(operation_id="unknown-op")
        count_before = len(log["events"])
        duplicate = self.runtime.run("desktop_chat", args, execute, task_id="flags-task", operation_id="unknown-op")
        self.assertFalse(duplicate["executed"])
        self.assertEqual(duplicate["summary"], summary)
        self.assertEqual(calls, ["paste"])
        self.assertEqual(len(self.runtime.logs(operation_id="unknown-op")["events"]), count_before)
        successor = self.runtime.run("desktop_status", {}, lambda _: {"ok": True},
                                     task_id="next-task", operation_id="after-unknown")
        self.assertTrue(successor["executed"])
        self.assertEqual(successor["summary"]["state"], "completed")
        self.assertNotIn(PRIVATE, json.dumps(log))
        # Read SQLite through its own connection; do not disturb POSIX locks by
        # opening/closing the active database as an ordinary file.
        with closing(sqlite3.connect(self.runtime.database)) as database:
            self.assertNotIn(PRIVATE, "\n".join(database.iterdump()))


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(OperationFlagAggregation)
    outcome = unittest.TextTestRunner(verbosity=1).run(suite)
    result = {"passed": outcome.wasSuccessful(), "test_count": outcome.testsRun,
              "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
              "GUI_operations": 0, "HID_events": 0, "schema_extended": False,
              "diagnostic_storage": "operations.flags_json; original per-stage events.flags_json retained"}
    Path(__file__).with_name("aggregation-results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    raise SystemExit(0 if outcome.wasSuccessful() else 1)
