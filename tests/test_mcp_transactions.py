"""Consumer integration fixtures. No native helper, AX, GUI, or schedule starts."""
import copy
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import server
from task_runtime import current_context

APP = "com.apple.TextEdit"
WINDOW = "FixtureDocument"
MARKER = "OFFLINE_PRIVATE_TEXT_7B4E"
PASSWORD = "OFFLINE_PASSWORD_8A2F"


def element(step="before"):
    return {"$element": {"step": step, "role": "AXTextArea"}}


def transaction():
    return {"app": APP, "window_title": WINDOW, "parameters": {"text": MARKER},
            "steps": [{"id": "before", "tool": "inspect", "arguments": {}},
                      {"id": "focus", "tool": "focus", "arguments": {}},
                      {"id": "write", "tool": "type_text", "arguments": {"element_id": element(), "text": {"$param": "text"}}},
                      {"id": "after", "tool": "inspect", "arguments": {}}],
            "postconditions": [{"step": "after", "element": {"role": "AXTextArea"}, "attribute": "value", "equals": {"$param": "text"}}]}


class FakeBridge:
    """Real schema validation plus deterministic fake native responses."""
    def __init__(self):
        self.calls = []
        self.mutations = []
        self.text = ""
        self.focused = False
        self.sequence = 0
        self.read_count = 0
        self.fail_read_number = None
        self.truncated_read_number = None
        self.foreign_read_number = None
        self.missing_window_number = None
        self.secure = False
        self.after_call = None

    def call(self, command, arguments):
        server.validate(command, arguments)
        self.sequence += 1
        self.calls.append((command, copy.deepcopy(arguments)))
        result = {"app": APP, "window_title": WINDOW, "pid": 777, "window_id": 12}
        error = None
        if command == "inspect":
            self.read_count += 1
            if self.read_count == self.fail_read_number:
                error = {"code": "ax_read_failed", "message": "Offline fixture read failure"}
            else:
                if self.read_count == self.foreign_read_number:
                    result["app"] = "com.apple.Notes"
                if self.read_count == self.missing_window_number:
                    result.pop("window_title")
                result.update(truncated=False, snapshot_id="fixture-" + str(self.read_count),
                              elements=[{"element_id": "fixture-element-" + str(self.read_count), "role": "AXTextArea",
                                         "secure": self.secure, "value": self.text,
                                         "value_truncated": self.read_count == self.truncated_read_number}])
        elif command == "focus":
            self.focused = True
            result.update(focus_verified=True, window_verified=True)
        elif command in {"type_text", "set_text"}:
            if not self.focused:
                error = {"code": "foreground_mismatch", "message": "Fixture target is not focused"}
            else:
                self.text = arguments["text"]
                self.mutations.append((command, copy.deepcopy(arguments)))
                result.update(value_verified=True, events_posted=2)
        elif command == "clear_text":
            if arguments["expected_value"] != self.text:
                error = {"code": "value_changed", "message": "Fixture owned value changed"}
            else:
                self.text = arguments["expected_empty_value"]
                self.mutations.append((command, copy.deepcopy(arguments)))
                result.update(value_verified=True, events_posted=2)
        elif command in {"key", "batch"}:
            self.mutations.append((command, copy.deepcopy(arguments)))
            result["events_posted"] = 1
        elif command == "visual_read":
            result.update(snapshot_id="fixture-visual", composer={"value": self.text, "value_complete": True})
        elif command == "status":
            result["native_ready"] = True
        else:
            error = {"code": "unsupported_fixture_action", "message": "Extend this fixture deliberately"}
        response = {"id": self.sequence, "ok": error is None, "elapsed_ms": 1.5, "result": result}
        if error:
            response["error"] = error
        context = current_context()
        if context:
            context.record_native(response, substage=command)
        if self.after_call:
            self.after_call(command, arguments)
        return response


class MCPTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.fake = FakeBridge()
        self.previous_bridge, self.previous_runtime = server.BRIDGE, server._RUNTIME
        server.BRIDGE = self.fake
        server._RUNTIME = None
        self.environment = patch.dict(os.environ, {"INTEL_DESKTOP_RUNTIME_DIR": str(self.directory)})
        self.environment.start()
        self.task_id = "fixture-task"
        self.call_number = 0
        # Any accidental native start is an immediate test failure.
        self.native_guard = patch.object(server.NativeBridge, "start", side_effect=AssertionError("Native start is forbidden in these fixtures"))
        self.native_guard.start()

    def tearDown(self):
        self.native_guard.stop()
        self.environment.stop()
        if server._RUNTIME is not None and server._RUNTIME is not self.previous_runtime:
            server._RUNTIME.close()
        server.BRIDGE, server._RUNTIME = self.previous_bridge, self.previous_runtime
        self.temporary.cleanup()

    def call(self, name, arguments, *, operation_id=None, task_id=None):
        self.call_number += 1
        result = server.handle({"jsonrpc": "2.0", "id": self.call_number, "method": "tools/call",
                                "params": {"name": "desktop_" + name, "arguments": {**arguments,
                                           "task_id": task_id or self.task_id,
                                           "operation_id": operation_id or "fixture-op-" + str(self.call_number)}}})
        self.assertEqual(result["content"][0]["type"], "text")
        return json.loads(result["content"][0]["text"])

    def metadata(self):
        database = self.directory / "runtime.sqlite3"
        with closing(sqlite3.connect(database)) as db:
            operations = db.execute("SELECT * FROM operations").fetchall()
            events = db.execute("SELECT * FROM events").fetchall()
        return json.dumps({"operations": operations, "events": events})

    def assert_no_execution(self, plan):
        response = self.call("transaction", plan)
        self.assertFalse(response["ok"])
        self.assertEqual(self.fake.calls, [], "Known invalid plan must be rejected before the first native action")
        self.assertEqual(self.fake.mutations, [])
        return response

    def register_plan(self):
        plan = transaction()
        plan.pop("parameters")
        plan.update(format="desktop_plan/v1", parameter_names=["text"])
        source = self.directory / "registered.json"
        source.write_text(json.dumps(plan))
        response = self.call("script", {"action": "register", "app": APP, "source_path": str(source),
                                         "parameter_names": ["text"], "purpose": "fixture_edit"})
        self.assertTrue(response["ok"])
        return source, response["result"]

    def test_real_mcp_schema_and_task_correlation(self):
        listed = server.handle({"method": "tools/list"})
        tools = {tool["name"]: tool for tool in listed["tools"]}
        for name in ("desktop_transaction", "desktop_script", "desktop_task"):
            self.assertIn("task_id", tools[name]["inputSchema"]["properties"])
        response = self.call("transaction", transaction(), operation_id="stable-operation")
        self.assertTrue(response["ok"])
        self.assertEqual(response["task_id"], self.task_id)
        self.assertEqual(response["operation_id"], "stable-operation")
        self.assertEqual(response["execution"]["state"], "verified")
        self.assertEqual(response["execution"]["event_count"], 2)
        self.assertEqual(len(self.fake.mutations), 1)

    def test_duplicate_operation_never_performs_second_action(self):
        first = self.call("transaction", transaction(), operation_id="dedupe-op")
        calls = len(self.fake.calls)
        second_plan = transaction()
        second_plan["parameters"]["text"] = "MUST_NOT_EXECUTE"
        second = self.call("transaction", second_plan, operation_id="dedupe-op")
        self.assertTrue(first["ok"])
        self.assertTrue(second["duplicate"])
        self.assertFalse(second["execution"]["executed"])
        self.assertEqual(len(self.fake.calls), calls)
        self.assertEqual(self.fake.text, MARKER)

    def test_parameter_element_and_result_reference_bind_to_current_read(self):
        plan = transaction()
        plan["window_title"] = {"$param": "window_title"}
        plan["parameters"]["window_title"] = WINDOW
        plan["steps"][2]["arguments"]["element_id"] = {"$ref": "before/result/elements/0/element_id"}
        response = self.call("transaction", plan)
        self.assertTrue(response["ok"])
        self.assertEqual(self.fake.mutations[0][1]["element_id"], "fixture-element-1")
        self.assertEqual(self.fake.mutations[0][1]["text"], MARKER)
        self.assertEqual(self.fake.mutations[0][1]["window_title"], WINDOW)

    def test_old_read_cannot_commit_after_mutation(self):
        plan = transaction()
        plan["steps"].pop()
        plan["postconditions"][0]["step"] = "before"
        plan["postconditions"][0]["equals"] = ""
        self.assert_no_execution(plan)

    def test_full_value_truncation_prevents_commit(self):
        self.fake.truncated_read_number = 2
        response = self.call("transaction", transaction())
        self.assertFalse(response["ok"])
        self.assertNotEqual(response["execution"]["state"], "verified")
        self.assertEqual(len(self.fake.mutations), 1)
        evidence = server.runtime().get_operation(response["operation_id"])
        self.assertFalse(evidence["verified_flags"].get("proof_full_value", False))

    def test_read_failure_after_mutation_is_partial_unknown_without_replay(self):
        self.fake.fail_read_number = 2
        response = self.call("transaction", transaction(), operation_id="partial-read-failure")
        self.assertFalse(response["ok"])
        self.assertEqual(response["execution"]["state"], "unknown")
        self.assertEqual(len(self.fake.mutations), 1)
        second = self.call("transaction", transaction(), operation_id="partial-read-failure")
        self.assertFalse(second["execution"]["executed"])
        self.assertEqual(len(self.fake.mutations), 1)

    def test_registered_plan_current_digest_app_and_runtime_evidence(self):
        _, row = self.register_plan()
        response = self.call("script", {"action": "run", "app": APP, "script_id": row["id"], "parameters": {"text": MARKER}})
        self.assertTrue(response["ok"])
        self.assertEqual(response["learning"]["status"], "verified")
        evidence = server.runtime().script_execution_evidence(response["operation_id"])
        self.assertEqual(evidence["script_id"], row["id"])
        self.assertEqual(evidence["source_sha256"], row["source_sha256"])
        self.assertTrue(evidence["verification"]["passed"])
        self.assertNotIn(MARKER, self.metadata())
        self.assertNotIn(MARKER, (self.directory / "learning.json").read_text())

    def test_script_source_change_resets_maturity_before_new_execution(self):
        source, row = self.register_plan()
        run = self.call("script", {"action": "run", "app": APP, "script_id": row["id"], "parameters": {"text": MARKER}})
        self.assertTrue(run["ok"])
        source.write_text(json.dumps(json.loads(source.read_text()), indent=2))
        listed = self.call("script", {"action": "list"})
        current = listed["result"]["scripts"][0]
        self.assertEqual(current["status"], "candidate")
        self.assertEqual(current["verified_successes"], 0)
        self.assertNotEqual(current["source_sha256"], row["source_sha256"])
        self.assertFalse(current["last_execution_verified"])

    def test_registered_app_mismatch_rejected_before_execution(self):
        _, row = self.register_plan()
        response = self.call("script", {"action": "run", "app": "com.apple.Notes", "script_id": row["id"], "parameters": {"text": MARKER}})
        self.assertFalse(response["ok"])
        self.assertEqual(self.fake.calls, [])

    def test_registered_plan_cannot_retain_prior_native_element_identity(self):
        source, _ = self.register_plan()
        plan = json.loads(source.read_text())
        plan["steps"][2]["arguments"]["element_id"] = "fixture-element-1"
        source.write_text(json.dumps(plan))
        registered = self.call("script", {"action": "register", "app": APP, "source_path": str(source), "parameter_names": ["text"]})
        response = self.call("script", {"action": "run", "app": APP, "script_id": registered["result"]["id"], "parameters": {"text": MARKER}})
        self.assertFalse(response["ok"])
        self.assertEqual(self.fake.calls, [], "Registered plans bind native IDs to this invocation, rather than retaining them")

    def test_old_python_candidate_is_not_executed(self):
        path = self.directory / "legacy.py"
        sentinel = self.directory / "never_created"
        path.write_text(f"from pathlib import Path\nPath({str(sentinel)!r}).touch()\npassword={PASSWORD!r}\n")
        registered = self.call("script", {"action": "register", "app": APP, "source_path": str(path), "parameter_names": []})
        self.assertTrue(registered["ok"])
        response = self.call("script", {"action": "run", "app": APP, "script_id": registered["result"]["id"], "parameters": {}})
        self.assertFalse(response["ok"])
        self.assertEqual(self.fake.calls, [])
        self.assertFalse(sentinel.exists())
        self.assertNotIn(PASSWORD, self.metadata())
        self.assertNotIn(PASSWORD, (self.directory / "learning.json").read_text())

    def test_cross_app_step_rejected_before_execution(self):
        plan = transaction()
        plan["steps"][2]["arguments"]["app"] = "com.apple.Notes"
        self.assert_no_execution(plan)

    def test_bounded_steps_and_postconditions_rejected_before_execution(self):
        for field in ("steps", "postconditions"):
            with self.subTest(field=field):
                plan = transaction()
                template = plan[field][0]
                plan[field] = [copy.deepcopy(template) for _ in range(17)]
                self.assert_no_execution(plan)

    def test_nested_batch_cross_app_rejected_before_execution(self):
        plan = transaction()
        plan["steps"][2] = {"id": "write", "tool": "batch", "arguments": {
            "actions": [{"command": "type_text", "app": "com.apple.Notes", "element_id": "invalid", "text": {"$param": "text"}}]}}
        self.assert_no_execution(plan)

    def test_invalid_native_argument_later_in_plan_rejected_before_execution(self):
        plan = transaction()
        plan["steps"][3]["arguments"]["unknown_key"] = PASSWORD
        self.assert_no_execution(plan)

    def test_invalid_forward_reference_rejected_before_execution(self):
        plan = transaction()
        plan["steps"][2]["arguments"]["element_id"] = {"$ref": "after/result/elements/0/element_id"}
        self.assert_no_execution(plan)

    def test_missing_postcondition_parameter_rejected_before_execution(self):
        plan = transaction()
        plan["postconditions"][0]["equals"] = {"$param": "missing"}
        self.assert_no_execution(plan)

    def test_nonscalar_parameter_rejected_before_execution(self):
        plan = transaction()
        plan["parameters"]["text"] = {"raw": PASSWORD}
        self.assert_no_execution(plan)

    def test_secure_result_reference_cannot_bypass_element_privacy(self):
        self.fake.secure = True
        plan = transaction()
        plan["steps"][2]["arguments"]["element_id"] = {"$ref": "before/result/elements/0/element_id"}
        response = self.call("transaction", plan)
        self.assertFalse(response["ok"])
        self.assertEqual(self.fake.mutations, [], "A secure element cannot be selected through $ref")

    def test_retained_send_authorization_rejected_before_execution(self):
        plan = transaction()
        plan["steps"][2]["arguments"]["send_authorization"] = True
        self.assert_no_execution(plan)

    def test_parameterized_return_cannot_bypass_registered_send_guard(self):
        plan = transaction()
        plan["steps"][2] = {"id": "write", "tool": "key", "arguments": {"key": {"$param": "key"}}}
        plan["parameters"] = {"key": "return"}
        plan["postconditions"][0]["equals"] = ""
        self.assert_no_execution(plan)

    def test_nested_batch_return_cannot_bypass_registered_send_guard(self):
        plan = transaction()
        plan["steps"][2] = {"id": "write", "tool": "batch", "arguments": {"actions": [{"command": "key", "key": "return"}]}}
        plan["postconditions"][0]["equals"] = ""
        self.assert_no_execution(plan)

    def test_read_privacy_raw_image_path_rejected_before_execution(self):
        plan = {"app": APP, "window_title": WINDOW,
                "steps": [{"id": "raw", "tool": "visual_read", "arguments": {"debug_image_path": str(self.directory / "private.png")}},
                          {"id": "after", "tool": "inspect", "arguments": {}}],
                "postconditions": [{"step": "after", "element": {"role": "AXTextArea"}, "attribute": "value", "equals": ""}]}
        self.assert_no_execution(plan)

    def test_missing_real_window_identity_cannot_claim_same_target(self):
        self.fake.missing_window_number = 2
        response = self.call("transaction", transaction())
        self.assertFalse(response["ok"])
        self.assertNotEqual(response["execution"]["state"], "verified")

    def test_cancel_current_task_at_boundary_stops_remaining_steps(self):
        operation = "cancel-operation"
        def cancel_after_write(command, arguments):
            if command == "type_text":
                cancelled = self.call("task", {"action": "cancel", "target_operation_id": operation})
                self.assertTrue(cancelled["ok"])
                self.assertEqual(cancelled["result"]["processes_terminated"], 0)
        self.fake.after_call = cancel_after_write
        response = self.call("transaction", transaction(), operation_id=operation)
        self.assertFalse(response["ok"])
        self.assertEqual(response["execution"]["state"], "interrupted")
        self.assertEqual(self.fake.read_count, 1)
        self.assertEqual(len(self.fake.mutations), 1)
        self.assertFalse(response["automatic_replay_allowed"])
        self.assertTrue(response["execution"]["executed"])
        self.assertNotIn("No new action was executed", response.get("error", {}).get("message", ""))
        calls = len(self.fake.calls)
        duplicate = self.call("transaction", transaction(), operation_id=operation)
        self.assertFalse(duplicate["execution"]["executed"])
        self.assertEqual(len(self.fake.calls), calls)

    def test_metadata_has_no_input_value_password_or_raw_error(self):
        plan = transaction()
        plan["parameters"]["unused_password"] = PASSWORD
        response = self.call("transaction", plan)
        self.assertTrue(response["ok"])
        operation = self.call("task", {"action": "operation", "target_operation_id": response["operation_id"]})
        logs = self.call("task", {"action": "logs", "target_operation_id": response["operation_id"]})
        for data in (self.metadata(), json.dumps(operation), json.dumps(logs)):
            self.assertNotIn(MARKER, data)
            self.assertNotIn(PASSWORD, data)


if __name__ == "__main__":
    unittest.main()
