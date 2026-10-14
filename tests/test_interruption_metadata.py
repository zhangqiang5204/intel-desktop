"""Fixed-path interruption metadata fixtures; synthetic responses, no native UI."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/task_runtime.py"
sys.path.insert(0, str(SOURCE.parent))
from task_runtime import TaskRuntime, _native_interruption, _native_timing


SECRET = "PRIVATE_BODY_AXVALUE_TITLE_CREDENTIAL_SENTINEL_9817"


def response(event):
    return {"id": 77, "ok": False, "elapsed_ms": 12.5,
            "result": {"native_stage_ms": {"event_guard": 2.25}, "text": SECRET},
            "error": {"code": "user_interrupted", "message": SECRET,
                      "details": {"last_interruption_event": event, "request": {"text": SECRET}, "events_posted": 2}}}


def observed():
    return {"reason": "pointer_owner_conflict", "event_type": 22,
            "source_unix_process_id": 19, "target_unix_process_id": 123,
            "pointer_owner": {"state": "hit", "pid": 456, "window_id": 987,
                              "window_frame": {"x": -1920, "y": 33, "width": 1792, "height": 1120},
                              "sample_age_ms": 245.5, "fresh": True},
            "keyboard_focus": {"state": "cached", "pid": 123, "window_id": 765,
                               "sample_age_ms": 120.75, "fresh": False}}


class Fixtures(unittest.TestCase):
    def test_real_producer_structure_survives(self):
        self.assertEqual(_native_interruption(response(observed())), observed())

    def test_private_fields_are_discarded_at_every_level(self):
        event = observed()
        event.update(title=SECRET, AXValue=SECRET, body=SECRET, request={"text": SECRET},
                     screenshot=SECRET, keycode=42, point={"x": 12, "y": 44}, mode=SECRET,
                     event_timestamp_ns=999, exception_message=SECRET)
        for section in ("pointer_owner", "keyboard_focus"):
            event[section].update(title=SECRET, AXValue=SECRET, value=SECRET, credentials={"password": SECRET})
        event["pointer_owner"]["window_frame"]["title"] = SECRET
        event["keyboard_focus"]["window_frame"] = {"x": 1, "y": 2, "width": 3, "height": 4}
        self.assertEqual(_native_interruption(response(event)), observed())
        self.assertNotIn(SECRET, json.dumps(_native_interruption(response(event))))

    def test_reason_must_be_native_enum_not_arbitrary_ascii_text(self):
        for value in (SECRET, "unknown_future_reason", "pointer_owner_conflict\n" + SECRET, True, ["escape"], "x" * 100000):
            with self.subTest(value_type=type(value).__name__):
                event = observed(); event["reason"] = value
                self.assertNotIn("reason", _native_interruption(response(event)))

    def test_manual_reason_has_bounded_uint32_suffix(self):
        for value in ("manual_6", "manual_4294967295"):
            self.assertEqual(_native_interruption(response({"reason": value})), {"reason": value})
        for value in ("manual_-1", "manual_4294967296", "manual_1" + SECRET, "manual_999999999999999999999"):
            self.assertEqual(_native_interruption(response({"reason": value})), {})

    def test_only_exact_error_details_path_is_used(self):
        event = observed()
        for value in ({"result": {"last_interruption_event": event}},
                      {"error": {"last_interruption_event": event}},
                      {"error": {"details": {"nested": {"last_interruption_event": event}}}},
                      {"last_interruption_event": event},
                      {"error": {"details": [event]}},
                      {"error": {"details": {"last_interruption_event": SECRET}}}, None):
            self.assertEqual(_native_interruption(value), {})

    def test_pid_and_event_ids_are_strict_nonnegative_integers(self):
        limits = {"event_type": 4294967295, "source_unix_process_id": 2147483647, "target_unix_process_id": 2147483647}
        for key, limit in limits.items():
            for value in (True, False, 1.0, "123", -1, limit + 1, 10 ** 1000, float("nan"), {}, [123]):
                self.assertEqual(_native_interruption(response({key: value})), {})
            for value in (0, limit):
                self.assertEqual(_native_interruption(response({key: value})), {key: value})

    def test_nested_owner_ids_use_the_same_bounds(self):
        for section in ("pointer_owner", "keyboard_focus"):
            for key, maximum in (("pid", 2147483647), ("window_id", 4294967295)):
                for bad in (True, 4.0, -1, maximum + 1, SECRET):
                    self.assertEqual(_native_interruption(response({section: {key: bad}})), {})
                self.assertEqual(_native_interruption(response({section: {key: maximum}})), {section: {key: maximum}})

    def test_states_are_small_native_enums(self):
        for section, states in (("pointer_owner", ["hit", "unavailable", "no_application_window"]),
                                ("keyboard_focus", ["cached", "unknown"])):
            for state in states:
                self.assertEqual(_native_interruption(response({section: {"state": state}})), {section: {"state": state}})
            for bad in (SECRET, "hit" if section == "keyboard_focus" else "cached", {}, True):
                self.assertEqual(_native_interruption(response({section: {"state": bad}})), {})

    def test_age_is_finite_bounded_number_and_fresh_is_boolean(self):
        for section in ("pointer_owner", "keyboard_focus"):
            for bad in (True, -0.1, 86400000.1, float("inf"), float("nan"), 10 ** 1000, SECRET):
                self.assertEqual(_native_interruption(response({section: {"sample_age_ms": bad}})), {})
            self.assertEqual(_native_interruption(response({section: {"sample_age_ms": 86400000, "fresh": False}})),
                             {section: {"sample_age_ms": 86400000.0, "fresh": False}})
            self.assertEqual(_native_interruption(response({section: {"fresh": 1}})), {})

    def test_frame_requires_all_four_finite_bounded_components(self):
        frame = {"x": -1920, "y": 0, "width": 1920, "height": 1200}
        self.assertEqual(_native_interruption(response({"pointer_owner": {"window_frame": frame}})), {"pointer_owner": {"window_frame": frame}})
        for key in frame:
            bad_values = (True, SECRET, float("nan"), 10 ** 1000, 1000001, -1000001)
            if key in ("width", "height"): bad_values += (0, -1)
            for bad in bad_values:
                value = {**frame, key: bad}
                self.assertEqual(_native_interruption(response({"pointer_owner": {"window_frame": value}})), {})
        partial = {key: value for key, value in frame.items() if key != "height"}
        self.assertEqual(_native_interruption(response({"pointer_owner": {"window_frame": partial}})), {})

    def test_huge_timing_integers_are_discarded_without_overflow(self):
        self.assertEqual(_native_timing({"elapsed_ms": 10 ** 1000, "result": {"native_stage_ms": {"bad": 10 ** 1000, "good": 1.25}}}),
                         {"native_stage_ms": {"good": 1.25}})

    def test_existing_SQLite_schema_timing_and_runtime_chain_remain_compatible(self):
        with tempfile.TemporaryDirectory(prefix="runtime-interruption-") as directory:
            runtime = TaskRuntime(directory, session_id="fixture-session")
            db = runtime._persistent_db()
            before = {table: list(db.execute("PRAGMA table_info(" + table + ")")) for table in ("operations", "events")}
            dirty = observed(); dirty["title"] = SECRET
            raw = response(dirty)
            def execute(context):
                context.record_native(raw, substage="type_guard")
                return raw
            result = runtime.run("desktop_type_text", {"app": "test.authorized", "text": SECRET}, execute, operation_id="interruption-fixture")
            summary = result["summary"]
            self.assertEqual(summary["state"], "interrupted")
            self.assertEqual(summary["event_count"], 2)
            self.assertEqual(summary["timing"], {"native_elapsed_ms": 12.5, "native_stage_ms": {"event_guard": 2.25},
                                                "last_interruption_event": observed()})
            records = runtime.logs(operation_id="interruption-fixture")["events"]
            native = next(row for row in records if row["substage"] == "type_guard")
            self.assertEqual(native["timing"]["last_interruption_event"], observed())
            self.assertNotIn(SECRET, "\n".join(db.iterdump()))
            self.assertEqual(before, {table: list(db.execute("PRAGMA table_info(" + table + ")")) for table in before})
            self.assertLess(len(json.dumps(native["timing"]["last_interruption_event"])), 2048)
            runtime.close()


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Fixtures)
    outcome = unittest.TextTestRunner(verbosity=1).run(suite)
    result = {"passed": outcome.wasSuccessful(), "test_count": outcome.testsRun, "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
              "GUI_operations": 0, "HID_events": 0, "schema_extended": False,
              "diagnostic_storage": "operations/events.timing_json.last_interruption_event"}
    Path(__file__).with_name("interruption-results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    raise SystemExit(0 if outcome.wasSuccessful() else 1)
