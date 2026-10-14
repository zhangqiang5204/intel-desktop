"""Local FIFO desktop execution ledger. Transactions have no automatic rollback.

run() queues one synchronous executor(context). Multiple native steps belong in
that executor; nested run() is rejected. Only metadata is persisted. A returned
ok flag is not a verified postcondition: the executor must set_outcome() after
checking the actual result. Cancellation never terminates a process.
"""
from __future__ import annotations

import json
from contextlib import closing
import atexit
import math
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import threading
import time
import uuid


ACTIVE = {"claim", "precondition", "executing", "postcondition"}
TERMINAL = {"verified", "completed", "accepted_unverified", "failed", "interrupted", "unknown", "cancelled"}
PHASES = {"enqueue", *ACTIVE, *TERMINAL}
COMPLETION_PURPOSES = {"send_selection_acceptance", "maintenance_acceptance", "chat_send_acceptance", "text_selection_acceptance"}
WORKFLOW_DURATION_BASIS = "queued_workflow_invocation"
TASK_DURATION_BASIS = "first_recorded_preflight_to_verified_completion"
SCRIPT_ACTIONS = {"register", "list", "run", "analyze"}
FLAGS = {"proof_full_value", "proof_same_target", "focus_verified", "proof_focus_preserved",
         "foreground_preserved", "system_focus_preserved", "postcondition_verified",
         "precondition_verified", "recipient_verified", "draft_verified", "value_verified",
         "operation_verified", "response_verified", "target_verified", "empty_verified",
         "input_may_be_partial", "temporary_clipboard_used", "clipboard_restored",
         "clipboard_external_change", "clipboard_isolated"}
_LOCAL = threading.local()
_ID = re.compile(r"[A-Za-z0-9_.:-]{1,128}\Z")
_LABEL = re.compile(r"[A-Za-z0-9_.:-]{1,64}\Z")
_HASH = re.compile(r"[a-fA-F0-9]{64}\Z")
_SELF_BIRTH = {}
_INTERRUPTION_REASONS = {
    "input_focus_unknown", "input_focus_stale", "input_target_changed", "secure_field_denied",
    "background_internal_focus_unverified", "target_application_has_user_focus", "input_monitor_disabled",
    "escape", "sustained_mouse_movement", "sustained_keyboard_input", "manual_input", "input_target_unknown", "manual_input_targeted_application",
    "pointer_location_unknown", "pointer_context_unknown", "pointer_context_stale", "pointer_display_unknown",
    "pointer_on_target_window", "pointer_window_owner_unknown", "pointer_event_owner_unknown", "pointer_owner_conflict",
    "pointer_hit_test_unavailable",
    "input_owner_unknown",
}


class RuntimeCancelled(Exception):
    """A cancellation reached a completed-native-step boundary; partial proof remains."""


class NestedRuntimeError(Exception):
    """Use the existing context for transaction steps; do not enqueue recursively."""


def current_context():
    return getattr(_LOCAL, "context", None)


def _identifier(value, default=None):
    value = default if value is None else value
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ValueError("Runtime IDs must be bounded opaque ASCII identifiers")
    return value


def _label(value, fallback=None):
    return value if isinstance(value, str) and _LABEL.fullmatch(value) else fallback


def _flags(values):
    return {key: value for key, value in (values or {}).items() if key in FLAGS and type(value) is bool}


def _merge_operation_flags(previous, current):
    """Keep occurred effects across steps; final postcondition flags stay latest."""
    merged, current = _flags(previous), _flags(current)
    occurred = {"input_may_be_partial", "temporary_clipboard_used", "clipboard_external_change"}
    for key, value in current.items():
        if key in occurred:
            merged[key] = merged.get(key, False) or value
        elif key == "clipboard_isolated":
            # Status capabilities are not actual clipboard stages. A clear
            # reports used=False; it participates in isolation, not restoration.
            if "temporary_clipboard_used" in current:
                merged[key] = merged.get(key, True) and value
        elif key == "clipboard_restored":
            if current.get("temporary_clipboard_used") is True:
                merged[key] = merged.get(key, True) and value
        else:
            merged[key] = value
    return merged


def _encode(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def operation_duration(value):
    """Only recorded invocation boundaries; never aggregate a stable task ID."""
    row = dict(value)
    tool = str(row.get("tool", "")).removeprefix("desktop_")
    raw_timing = row.get("timing_json", row.get("timing", {}))
    if isinstance(raw_timing, str):
        try: raw_timing = json.loads(raw_timing)
        except (ValueError, TypeError): raw_timing = {}
    timing = raw_timing if isinstance(raw_timing, dict) else {}
    action = timing.get("invocation_action", row.get("invocation_action")) if tool == "script" else None
    action = action if isinstance(action, str) and action in SCRIPT_ACTIONS else None
    classified = tool != "script" or action is not None
    workflow = tool in {"chat", "transaction"} or tool == "script" and action == "run"
    basis = WORKFLOW_DURATION_BASIS if workflow else "queued_tool_invocation" if classified else "queued_unclassified_invocation"
    created, started, finished = (row.get(key) for key in ("created", "started", "finished"))
    valid = lambda stamp: type(stamp) in (int, float) and math.isfinite(stamp) and stamp >= 0
    complete = (valid(created) and valid(finished) and finished >= created and row.get("state") in TERMINAL
                and not row.get("native_pending") and not row.get("conflict_active")
                and (valid(started) and created <= started <= finished or row.get("state") == "cancelled" and started is None))
    return {"duration_basis": basis, "total_duration_ms": round((finished - created) * 1000, 3) if complete else None,
            "timing_complete": bool(complete), "workflow_invocation": workflow,
            "workflow_classification_complete": classified, "invocation_action": action}


def _process(pid):
    """Return a birth token/parent for a live process; zombies are already stopped."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        return ("unavailable", None)  # Unknown ownership is conservatively live.
    try:
        proc = Path(f"/proc/{pid}/stat")
        if proc.exists():
            text = proc.read_text()
            fields = text[text.rindex(")") + 2:].split()
            if fields[0] == "Z":
                return None
            return ("linux:" + fields[19], int(fields[1]))
        result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart=", "-o", "ppid=", "-o", "stat="],
                                capture_output=True, text=True, timeout=2)
        fields = result.stdout.split()
        if result.returncode or len(fields) < 7:
            return None
        if fields[-1].startswith("Z"):
            return None
        return ("ps:" + " ".join(fields[:-2]), int(fields[-2]))
    except (OSError, ValueError, subprocess.SubprocessError):
        return ("unavailable", None)


def _alive(pid, birth):
    if not pid:
        return False
    if pid == os.getpid():
        if pid not in _SELF_BIRTH:
            _SELF_BIRTH[pid] = (_process(pid) or ("unavailable", None))[0]
        return birth == "unavailable" or _SELF_BIRTH[pid] == "unavailable" or birth == _SELF_BIRTH[pid]
    process = _process(int(pid))
    return process is not None and (birth == "unavailable" or process[0] == "unavailable" or process[0] == birth)


def _native_metadata(response):
    if not isinstance(response, dict):
        return 0, {}, None, False
    result = response.get("result") if isinstance(response.get("result"), dict) else {}
    error = response.get("error") if isinstance(response.get("error"), dict) else {}
    details = error.get("details") if isinstance(error.get("details"), dict) else {}
    event_count = 0
    for source in (response, result, error, details):
        for key in ("events_posted", "event_count", "posted_events", "posted_event_count", "partial_event_count"):
            value = source.get(key)
            if type(value) is int and 0 <= value <= 1_000_000:
                event_count = value
                break
        if event_count:
            break
    flags = {}
    for source in (response, result, error, details):
        flags.update(_flags(source))
    unknown = any(source.get("completion_unknown") is True for source in (response, result, error, details))
    return event_count, flags, _label(error.get("code"), None), unknown


def _native_timing(response):
    if not isinstance(response, dict): return {}
    result = response.get("result") if isinstance(response.get("result"), dict) else {}
    timing = {}
    elapsed = response.get("elapsed_ms")
    if type(elapsed) in (int, float) and 0 <= elapsed <= 86_400_000 and math.isfinite(elapsed):
        timing["native_elapsed_ms"] = float(elapsed)
    error = response.get("error") if isinstance(response.get("error"), dict) else {}
    details = error.get("details") if isinstance(error.get("details"), dict) else {}
    values = result.get("native_stage_ms", details.get("native_stage_ms"))
    if isinstance(values, dict):
        stages = {key: float(value) for key, value in list(values.items())[:64]
                  if _label(key) is not None and type(value) in (int, float) and 0 <= value <= 86_400_000 and math.isfinite(value)}
        if stages: timing["native_stage_ms"] = stages
    counts = {}
    for source in (result, details):
        for key in ("ax_actions_attempted", "ax_menu_actions_attempted", "ax_composer_focus_actions_attempted", "key_events_posted", "notification_events_posted", "mouse_events_posted"):
            value = source.get(key)
            if type(value) is int and 0 <= value <= 1_000_000:
                counts[key] = value
    if counts: timing["native_action_counts"] = counts
    return timing


def _native_interruption(response):
    """Copy only the native monitor's fixed diagnostic path and structural fields."""
    if not isinstance(response, dict): return {}
    error = response.get("error")
    details = error.get("details") if isinstance(error, dict) else None
    event = details.get("last_interruption_event") if isinstance(details, dict) else None
    if not isinstance(event, dict): return {}

    def integer(value, maximum):
        return value if type(value) is int and 0 <= value <= maximum else None

    def number(value, minimum, maximum):
        if type(value) not in (int, float): return None
        # Bound first so enormous JSON integers never reach float conversion.
        return float(value) if minimum <= value <= maximum and math.isfinite(value) else None

    def fields(source, *, pointer=False):
        clean = {}
        states = {"unavailable", "no_application_window", "hit"} if pointer else {"unknown", "cached"}
        state = source.get("state")
        if type(state) is str and len(state) <= 32 and state in states: clean["state"] = state
        for key, maximum in (("pid", 2_147_483_647), ("window_id", 4_294_967_295)):
            value = integer(source.get(key), maximum)
            if value is not None: clean[key] = value
        age = number(source.get("sample_age_ms"), 0, 86_400_000)
        if age is not None: clean["sample_age_ms"] = age
        if type(source.get("fresh")) is bool: clean["fresh"] = source["fresh"]
        frame = source.get("window_frame") if pointer else None
        if isinstance(frame, dict):
            rectangle = {key: number(frame.get(key), -1_000_000 if key in {"x", "y"} else 0, 1_000_000)
                         for key in ("x", "y", "width", "height")}
            if all(value is not None for value in rectangle.values()) and rectangle["width"] > 0 and rectangle["height"] > 0:
                clean["window_frame"] = rectangle
        return clean

    clean = {}
    reason = event.get("reason")
    if type(reason) is str and len(reason) <= 64:
        if reason in _INTERRUPTION_REASONS:
            clean["reason"] = reason
        elif re.fullmatch(r"manual_[0-9]{1,10}", reason) and int(reason[7:]) <= 4_294_967_295:
            clean["reason"] = reason
    for key, maximum in (("event_type", 4_294_967_295), ("source_unix_process_id", 2_147_483_647),
                         ("target_unix_process_id", 2_147_483_647)):
        value = integer(event.get(key), maximum)
        if value is not None: clean[key] = value
    for key in ("pointer_owner", "keyboard_focus"):
        source = event.get(key)
        if isinstance(source, dict):
            value = fields(source, pointer=key == "pointer_owner")
            if value: clean[key] = value
    return clean


class RuntimeContext:
    def __init__(self, runtime, row):
        self.runtime = runtime
        self.task_id = row["task_id"]
        self.operation_id = row["operation_id"]
        self.transaction_id = row["transaction_id"]
        self.chain_id = row["chain_id"]
        self._outcome = None
        self._error_code = None
        self._flags = {}
        self._native_seen = set()
        self._registered_process = None
        self._native_pid = None
        self._source = None

    def record_phase(self, phase, substage=None, *, verified_flags=None, error_code=None):
        if phase not in {"precondition", "executing", "postcondition"}:
            raise ValueError("Executor may record only actual precondition/executing/postcondition phases")
        flags = _flags(verified_flags)
        self._flags = _merge_operation_flags(self._flags, flags)
        self.runtime._record(self.operation_id, phase, _label(substage), flags, _label(error_code))

    def boundary(self, substage=None):
        """Check cancellation before the next native step, after the prior one ended."""
        row = self.runtime.get_operation(self.operation_id, include_summary=False)
        if row is None or row["state"] not in ACTIVE or not row["conflict_active"] or row["owner_pid"] != os.getpid() or row["owner_birth"] != self.runtime.owner_birth:
            raise RuntimeError("Runtime execution lease is unavailable")
        if row["native_pending"]:
            raise RuntimeError("Native step has not reached a safe boundary")
        if row["cancel_requested"]:
            raise RuntimeCancelled()
        return True

    def register_native_pid(self, pid, *, process=None):
        # Reuse a birth token only for the same still-live Popen object. A PID
        # alone is insufficient: after reaping, it can identify another child.
        cached = self._registered_process
        if process is not None and getattr(process, "pid", None) == pid and process.poll() is None and cached and cached[0] is process:
            identity = cached[1]
        else:
            identity = _process(pid) if type(pid) is int and pid > 0 else None
        if identity is None or identity[1] != os.getpid():
            raise ValueError("Native PID must be a live direct child of the executor")
        if process is not None:
            if getattr(process, "pid", None) != pid or process.poll() is not None:
                raise ValueError("Native process already exited")
            self._registered_process = (process, identity)
        self._native_pid = pid
        with self.runtime._write() as db:
            self.runtime._require_lease(db, self.operation_id)
            db.execute("UPDATE operations SET native_pid=?,native_birth=?,native_pending=1 WHERE operation_id=?",
                       (pid, identity[0], self.operation_id))

    def record_native(self, response, substage=None, *, stage=None):
        """Call once per native response, including failures; never pass request values."""
        count, flags, error_code, unknown = _native_metadata(response)
        timing = _native_timing(response)
        interruption = _native_interruption(response)
        if interruption: timing["last_interruption_event"] = interruption
        native_id = response.get("id") if isinstance(response, dict) else None
        if type(native_id) is int:
            identity = (self._native_pid, native_id)
            if identity in self._native_seen:
                count = 0; timing = {}
            self._native_seen.add(identity)
        self._flags = _merge_operation_flags(self._flags, flags)
        with self.runtime._write() as db:
            row = self.runtime._require_lease(db, self.operation_id)
            saved = _merge_operation_flags(json.loads(row["flags_json"]), flags)
            total_timing = json.loads(row["timing_json"])
            if "native_elapsed_ms" in timing:
                total_timing["native_elapsed_ms"] = total_timing.get("native_elapsed_ms", 0) + timing["native_elapsed_ms"]
            for key, value in timing.get("native_stage_ms", {}).items():
                stages = total_timing.setdefault("native_stage_ms", {})
                stages[key] = stages.get(key, 0) + value
            for key, value in timing.get("native_action_counts", {}).items():
                actions = total_timing.setdefault("native_action_counts", {})
                actions[key] = actions.get(key, 0) + value
            if "last_interruption_event" in timing:
                total_timing["last_interruption_event"] = timing["last_interruption_event"]
            db.execute("UPDATE operations SET native_pending=?,event_count=event_count+?,flags_json=?,timing_json=? WHERE operation_id=?",
                       (int(unknown), count, _encode(saved), _encode(total_timing), self.operation_id))
            self.runtime._event(db, row, "executing", _label(substage or stage, "native_response"),
                                flags=flags, error_code=error_code, event_count=count, timing=timing)

    def record_source(self, script_id, source_sha256, plan_digest=None, parameter_names=None):
        source = {"script_id": _identifier(script_id)}
        if not isinstance(source_sha256, str) or not _HASH.fullmatch(source_sha256):
            raise ValueError("Source digest must be SHA256")
        source["source_sha256"] = source_sha256.lower()
        if plan_digest is not None:
            if not isinstance(plan_digest, str) or not _HASH.fullmatch(plan_digest):
                raise ValueError("Plan digest must be SHA256")
            source["plan_digest"] = plan_digest.lower()
        names = parameter_names or []
        if not isinstance(names, (list, tuple)) or len(names) > 64 or any(_label(name) is None for name in names):
            raise ValueError("Only bounded parameter names may be recorded")
        source["parameter_names"] = sorted(set(names))
        with self.runtime._write() as db:
            row = self.runtime._require_lease(db, self.operation_id)
            if row["source_json"] != "{}" and json.loads(row["source_json"]) != source:
                raise ValueError("A running operation cannot change registered source identity")
            db.execute("UPDATE operations SET source_json=? WHERE operation_id=?", (_encode(source), self.operation_id))
            self.runtime._event(db, row, "precondition", "registered_source", source=source)
        self._source = source

    def set_outcome(self, state, *, verified_flags=None, proof_flags=None, error_code=None):
        if state not in {"verified", "completed", "accepted_unverified", "failed", "interrupted", "unknown"}:
            raise ValueError("Unknown executor outcome")
        if verified_flags is not None and proof_flags is not None:
            raise ValueError("Use one postcondition flag mapping")
        flags = _flags(verified_flags if verified_flags is not None else proof_flags)
        if state == "verified" and not any(value is True for value in flags.values()):
            raise ValueError("Verified outcome needs actual postcondition checks")
        checks = _merge_operation_flags(self._flags, flags)
        if state == "verified" and self._source is not None:
            focus = any(checks.get(key) is True for key in ("focus_verified", "proof_focus_preserved", "foreground_preserved", "system_focus_preserved"))
            if checks.get("proof_full_value") is not True or checks.get("proof_same_target") is not True or not focus:
                raise ValueError("A registered script needs full-value, same-target and focus postconditions")
        self._flags = checks
        self._outcome = state
        self._error_code = _label(error_code)


class TaskRuntime:
    def __init__(self, directory=None, session_id=None, *, retention_days=14, max_events=100000):
        self.directory = Path(directory or Path.home() / ".codex/intel-desktop/runtime").expanduser()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.database = self.directory / "runtime.sqlite3"
        self.session_id = _identifier(session_id, str(uuid.uuid4()))
        if os.getpid() not in _SELF_BIRTH:
            _SELF_BIRTH[os.getpid()] = (_process(os.getpid()) or ("unavailable", None))[0]
        self.owner_birth = _SELF_BIRTH[os.getpid()]
        self.retention_days = max(1, min(int(retention_days), 365))
        self.max_events = max(100, min(int(max_events), 1_000_000))
        self._db_local = threading.local()
        self._db_lock = threading.Lock()
        self._db_connections = set()
        self._closed = False
        with closing(self._connect()) as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS operations (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL,
                    task_id TEXT NOT NULL, transaction_id TEXT, chain_id TEXT NOT NULL,
                    session_id TEXT NOT NULL, tool TEXT NOT NULL, app TEXT,
                    state TEXT NOT NULL, created REAL NOT NULL, expires REAL NOT NULL,
                    started REAL, finished REAL, queue_wait_ms REAL NOT NULL DEFAULT 0,
                    duration_ms REAL NOT NULL DEFAULT 0, owner_pid INTEGER NOT NULL, owner_birth TEXT NOT NULL,
                    native_pid INTEGER, native_birth TEXT, native_pending INTEGER NOT NULL DEFAULT 0,
                    conflict_active INTEGER NOT NULL DEFAULT 0, cancel_requested INTEGER NOT NULL DEFAULT 0,
                    event_count INTEGER NOT NULL DEFAULT 0, error_code TEXT,
                    flags_json TEXT NOT NULL DEFAULT '{}', source_json TEXT NOT NULL DEFAULT '{}', timing_json TEXT NOT NULL DEFAULT '{}', summary_json TEXT);
                CREATE UNIQUE INDEX IF NOT EXISTS one_executor ON operations(conflict_active) WHERE conflict_active=1;
                CREATE INDEX IF NOT EXISTS task_operations ON operations(task_id,seq);
                CREATE INDEX IF NOT EXISTS queue_state ON operations(state,seq);
                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL, task_id TEXT NOT NULL,
                    transaction_id TEXT, chain_id TEXT NOT NULL, tool TEXT NOT NULL, app TEXT,
                    phase TEXT NOT NULL, substage TEXT, created REAL NOT NULL,
                    queue_wait_ms REAL, duration_ms REAL, event_count INTEGER NOT NULL DEFAULT 0,
                    error_code TEXT, flags_json TEXT NOT NULL DEFAULT '{}', source_json TEXT NOT NULL DEFAULT '{}', timing_json TEXT NOT NULL DEFAULT '{}');
                CREATE INDEX IF NOT EXISTS operation_events ON events(operation_id,seq);
            """)
            for table in ("operations", "events"):
                if "timing_json" not in {row[1] for row in db.execute("PRAGMA table_info(" + table + ")")}:
                    db.execute("ALTER TABLE " + table + " ADD COLUMN timing_json TEXT NOT NULL DEFAULT '{}'")
        os.chmod(self.database, 0o600)
        atexit.register(self.close)

    def _connect(self):
        db = sqlite3.connect(self.database, timeout=5, isolation_level=None, check_same_thread=False)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=5000")
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=NORMAL")
        return db

    def _persistent_db(self):
        if self._closed: raise RuntimeError("Runtime is closed")
        db = getattr(self._db_local, "connection", None)
        if db is None:
            db = self._connect()
            with self._db_lock: self._db_connections.add(db)
            self._db_local.connection = db
        return db

    def close(self):
        """Release this session's SQLite handles; never cancel or terminate native work."""
        with self._db_lock:
            if self._closed: return
            self._closed = True
            connections = list(self._db_connections); self._db_connections.clear()
        for db in connections:
            try: db.close()
            except sqlite3.Error: pass

    class _Write:
        def __init__(self, runtime): self.runtime = runtime
        def __enter__(self):
            self.db = self.runtime._persistent_db(); self.db.execute("BEGIN IMMEDIATE"); return self.db
        def __exit__(self, kind, value, trace):
            self.db.execute("ROLLBACK" if kind else "COMMIT")

    def _write(self): return self._Write(self)

    def _require_lease(self, db, operation_id):
        row = db.execute("SELECT * FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
        if row is None or row["state"] not in ACTIVE or not row["conflict_active"] or row["owner_pid"] != os.getpid() or row["owner_birth"] != self.owner_birth:
            raise RuntimeError("Operation no longer owns desktop execution")
        return row

    def _event(self, db, row, phase, substage=None, *, flags=None, source=None, error_code=None, event_count=0, timing=None):
        action = operation_duration(row)["invocation_action"]
        event_timing = {"invocation_action": action} if action is not None else {}
        event_timing.update(timing or {})
        db.execute("""INSERT INTO events(operation_id,task_id,transaction_id,chain_id,tool,app,phase,substage,created,
                      queue_wait_ms,duration_ms,event_count,error_code,flags_json,source_json,timing_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                   (row["operation_id"], row["task_id"], row["transaction_id"], row["chain_id"], row["tool"], row["app"],
                    phase, substage, time.time(), row["queue_wait_ms"], row["duration_ms"], event_count,
                    error_code, _encode(flags or {}), _encode(source or {}), _encode(event_timing)))

    def _record(self, operation_id, phase, substage, flags, error_code):
        with self._write() as db:
            row = self._require_lease(db, operation_id)
            saved = _merge_operation_flags(json.loads(row["flags_json"]), flags)
            db.execute("UPDATE operations SET state=?,flags_json=? WHERE operation_id=?", (phase, _encode(saved), operation_id))
            self._event(db, row, phase, substage, flags=flags, error_code=error_code)

    def _summary(self, row):
        return {key: row[key] for key in ("operation_id", "task_id", "transaction_id", "chain_id", "tool", "app", "state",
                "created", "started", "finished", "queue_wait_ms", "duration_ms", "event_count", "error_code", "owner_pid", "native_pid")} | {
                "verified_flags": json.loads(row["flags_json"]), "source": json.loads(row["source_json"]),
                "timing": json.loads(row["timing_json"]),
                "cancel_requested": bool(row["cancel_requested"]), "native_pending": bool(row["native_pending"]),
                "conflict_active": bool(row["conflict_active"]), "queue_sequence": row["seq"], "automatic_replay_allowed": False,
                **operation_duration(row)}

    def _finish(self, db, row, state, error_code=None, flags=None, duration_ms=None, hold_native=False):
        now = time.time()
        merged = _merge_operation_flags(json.loads(row["flags_json"]), flags)
        elapsed = duration_ms if duration_ms is not None else max(0, (now - (row["started"] or now)) * 1000)
        db.execute("UPDATE operations SET state=?,finished=?,duration_ms=?,error_code=?,flags_json=?,conflict_active=?,native_pending=? WHERE operation_id=?",
                   (state, now, elapsed, error_code, _encode(merged), int(hold_native), int(hold_native), row["operation_id"]))
        updated = db.execute("SELECT * FROM operations WHERE operation_id=?", (row["operation_id"],)).fetchone()
        summary = self._summary(updated)
        db.execute("UPDATE operations SET summary_json=? WHERE operation_id=?", (_encode(summary), row["operation_id"]))
        total = {**operation_duration(updated), **{key: updated[key] for key in ("created", "started", "finished", "state", "native_pending", "conflict_active")}}
        self._event(db, updated, state, error_code=error_code, flags=merged, event_count=updated["event_count"], timing={"invocation_total": total})
        return summary

    def _repair(self, db):
        now = time.time()
        rows = db.execute("SELECT * FROM operations WHERE state='enqueue' OR conflict_active=1 ORDER BY seq").fetchall()
        for row in rows:
            if row["state"] == "enqueue":
                if row["expires"] <= now or not _alive(row["owner_pid"], row["owner_birth"]):
                    reason = "queue_expired" if row["expires"] <= now else "queued_owner_exited"
                    self._finish(db, row, "cancelled", reason, duration_ms=0)
            elif row["state"] in ACTIVE and not _alive(row["owner_pid"], row["owner_birth"]):
                hold = _alive(row["native_pid"], row["native_birth"])
                self._finish(db, row, "unknown", "owner_crashed", hold_native=hold)
            elif row["state"] == "unknown" and not _alive(row["native_pid"], row["native_birth"]):
                db.execute("UPDATE operations SET conflict_active=0,native_pending=0 WHERE operation_id=?", (row["operation_id"],))
                updated = db.execute("SELECT * FROM operations WHERE operation_id=?", (row["operation_id"],)).fetchone()
                db.execute("UPDATE operations SET summary_json=? WHERE operation_id=?", (_encode(self._summary(updated)), row["operation_id"]))
                self._event(db, updated, "unknown", "native_exited_no_replay")

    def _prune(self, db):
        # Compact operation summaries remain for operation-ID deduplication.
        # Only the detailed event log has bounded retention and row count.
        db.execute("DELETE FROM events WHERE created<?", (time.time() - self.retention_days * 86400,))
        db.execute("DELETE FROM events WHERE seq < COALESCE((SELECT seq FROM events ORDER BY seq DESC LIMIT 1 OFFSET ?),0)",
                   (self.max_events - 1,))

    def run(self, tool, args, executor, *, task_id=None, operation_id=None, transaction_id=None,
            wait_timeout=30, ttl=300):
        if current_context() is not None:
            raise NestedRuntimeError("A transaction executes its steps under its existing context")
        if not callable(executor) or not isinstance(args, dict) or _label(tool) is None:
            raise ValueError("Runtime requires a bounded tool name, arguments and callable executor")
        if not all(isinstance(value, (int, float)) and math.isfinite(value) and 0 <= value <= 86400 for value in (wait_timeout, ttl)):
            raise ValueError("Queue waits and lifetime must be bounded")
        task_id = _identifier(task_id or args.get("task_id"), self.session_id)
        operation_id = _identifier(operation_id or args.get("operation_id"), str(uuid.uuid4()))
        transaction_id = transaction_id or args.get("transaction_id")
        if transaction_id is not None: transaction_id = _identifier(transaction_id)
        app = args.get("app") if isinstance(args.get("app"), str) and _ID.fullmatch(args["app"]) else None
        action = args.get("action") if tool.removeprefix("desktop_") == "script" else None
        timing = {"invocation_action": action} if isinstance(action, str) and action in SCRIPT_ACTIONS else {}
        with self._write() as db:
            self._repair(db)
            row = db.execute("SELECT * FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
            if row is not None:
                if row["task_id"] != task_id:
                    raise ValueError("Operation ID belongs to another task")
                return {"executed": False, "duplicate": True, "response": None,
                        "summary": self._summary(row), "automatic_replay_allowed": False}
            db.execute("""INSERT INTO operations(operation_id,task_id,transaction_id,chain_id,session_id,tool,app,state,created,
                           expires,owner_pid,owner_birth,timing_json) VALUES(?,?,?,?,?,?,?,'enqueue',?,?,?,?,?)""",
                       (operation_id, task_id, transaction_id, str(uuid.uuid4()), self.session_id, tool, app,
                        time.time(), time.time() + ttl, os.getpid(), self.owner_birth, _encode(timing)))
            row = db.execute("SELECT * FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
            self._event(db, row, "enqueue")
        wait_until = time.monotonic() + wait_timeout
        while True:
            with self._write() as db:
                self._repair(db)
                row = db.execute("SELECT * FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
                if row["state"] in TERMINAL:
                    return {"executed": False, "duplicate": False, "response": None, "summary": self._summary(row)}
                active = db.execute("SELECT 1 FROM operations WHERE conflict_active=1").fetchone()
                head = db.execute("SELECT operation_id FROM operations WHERE state='enqueue' ORDER BY seq LIMIT 1").fetchone()
                if not active and head and head[0] == operation_id:
                    db.execute("UPDATE operations SET state='claim',conflict_active=1,started=?,queue_wait_ms=? WHERE operation_id=?",
                               (time.time(), max(0, (time.time() - row["created"]) * 1000), operation_id))
                    row = db.execute("SELECT * FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
                    self._event(db, row, "claim")
                    break
                if time.monotonic() >= wait_until:
                    summary = self._finish(db, row, "cancelled", "queue_wait_timeout", duration_ms=0)
                    return {"executed": False, "duplicate": False, "response": None, "summary": summary}
            time.sleep(0.025)
        context = RuntimeContext(self, row)
        response = None
        state, error_code = "unknown", "postcondition_unverified"
        started = time.monotonic()
        _LOCAL.context = context
        try:
            context.record_phase("precondition")
            context.boundary()
            context.record_phase("executing")
            response = executor(context)
            context.record_phase("postcondition")
            if context._outcome is not None:
                state, error_code = context._outcome, context._error_code
            elif isinstance(response, dict) and response.get("ok") is False:
                _, _, native_error, unknown = _native_metadata(response)
                state, error_code = ("unknown" if unknown else "failed"), native_error or "executor_failed"
                if not unknown and native_error in {"user_interrupted", "user_takeover", "background_input_contended", "input_contention"}:
                    state = "interrupted"
            elif isinstance(response, dict) and response.get("ok") is True:
                base_tool = tool.removeprefix("desktop_")
                readonly = base_tool in {"status", "inspect", "observe", "background_observe", "background_visual_read", "visual_read", "wait_text"}
                readonly = readonly or (base_tool == "chat" and args.get("action") in {"observe", "read", "history"})
                if readonly:
                    state, error_code = "completed", None
                elif base_tool in {"press", "click", "key", "scroll", "visual_click", "visual_scroll"} or (base_tool == "chat" and args.get("action") == "locate"):
                    state, error_code = "accepted_unverified", None
        except RuntimeCancelled:
            state, error_code = "interrupted", "cancelled_at_safe_boundary"
        except (TimeoutError, EOFError, BrokenPipeError):
            state, error_code = "unknown", "native_completion_unknown"
        except ValueError:
            state, error_code = "failed", "invalid_request"
        except Exception:
            state, error_code = "unknown", "executor_exception"
        finally:
            _LOCAL.context = None
        with self._write() as db:
            row = self._require_lease(db, operation_id)
            pending = bool(row["native_pending"])
            if pending:
                state, error_code = "unknown", error_code or "native_completion_unknown"
            hold = state == "unknown" and pending and _alive(row["native_pid"], row["native_birth"])
            summary = self._finish(db, row, state, error_code, context._flags,
                                   (time.monotonic() - started) * 1000, hold_native=hold)
            self._prune(db)
        return {"executed": True, "duplicate": False, "response": response, "summary": summary,
                "automatic_replay_allowed": False}

    def register_native_pid(self, pid, *, process=None):
        context = current_context()
        if context is None or context.runtime is not self:
            raise RuntimeError("Native registration requires the current queued executor")
        context.register_native_pid(pid, process=process)

    def get_operation(self, operation_id, *, include_summary=True):
        operation_id = _identifier(operation_id)
        row = self._persistent_db().execute("SELECT * FROM operations WHERE operation_id=?", (operation_id,)).fetchone()
        if row is None: return None
        return self._summary(row) if include_summary else dict(row)

    def record_task_completion(self, task_id, unit_id, purpose, operation_ids, verified_operation_id):
        """Append one metadata completion span to its real verified end source."""
        task_id, unit_id, verified_operation_id = map(_identifier, (task_id, unit_id, verified_operation_id))
        if not isinstance(purpose, str) or purpose not in COMPLETION_PURPOSES:
            raise ValueError("Task completion purpose must use a fixed metadata label")
        if not isinstance(operation_ids, list) or not 1 <= len(operation_ids) <= 128:
            raise ValueError("Provide a bounded explicit list of operation IDs")
        references = [_identifier(identifier) for identifier in operation_ids]
        if len(set(references)) != len(references) or verified_operation_id not in references:
            raise ValueError("Task completion references must be unique and contain its verified end source")
        with self._write() as db:
            placeholders = ",".join("?" for _ in references)
            rows = db.execute("SELECT * FROM operations WHERE operation_id IN (" + placeholders + ")", references).fetchall()
            if len(rows) != len(references) or any(row["task_id"] != task_id for row in rows):
                raise ValueError("Every completion reference must exist and belong to the caller task")
            for row in rows:
                created, finished = row["created"], row["finished"]
                if (row["state"] not in TERMINAL or row["native_pending"] or row["conflict_active"]
                        or type(created) not in (int, float) or type(finished) not in (int, float)
                        or not math.isfinite(created) or not math.isfinite(finished) or created < 0 or finished < created):
                    raise ValueError("Completion references require real terminal timestamp boundaries")
            final = next(row for row in rows if row["operation_id"] == verified_operation_id)
            finished = max(row["finished"] for row in rows)
            if (final["state"] != "verified" or not operation_duration(final)["timing_complete"] or final["finished"] != finished
                    or not any(_flags(json.loads(final["flags_json"])).values())):
                raise ValueError("The actual latest end source must have runtime verified postconditions")
            ordered = sorted(rows, key=lambda row: (row["created"], row["finished"], row["operation_id"]))
            counts = {state: sum(row["state"] == state for row in rows) for state in sorted(TERMINAL)}
            created = min(row["created"] for row in rows)
            completion = {"unit_id": unit_id, "task_id": task_id, "purpose": purpose,
                          "duration_basis": TASK_DURATION_BASIS, "created": created, "finished": finished,
                          "total_duration_ms": round((finished - created) * 1000, 3), "timing_complete": True,
                          "operation_ids": [row["operation_id"] for row in ordered],
                          "verified_operation_id": verified_operation_id, "verification_source": "runtime_postcondition",
                          "outcome": "verified", "attempt_outcomes": {state: count for state, count in counts.items() if count},
                          "failed_attempts": sum(counts[state] for state in ("failed", "interrupted", "unknown", "cancelled")),
                          "unknown_attempts": counts["unknown"], "normality_assessed": False}
            timing = json.loads(final["timing_json"])
            saved = timing.setdefault("task_completions", [])
            existing = next((unit for unit in saved if unit.get("unit_id") == unit_id), None)
            if existing is not None:
                if existing != completion:
                    raise ValueError("A recorded completion unit cannot change its references or endpoint")
                return {**existing, "recorded": False}
            if len(saved) >= 8:
                raise ValueError("This operation's completion metadata bound is reached")
            saved.append(completion)
            encoded = _encode(timing)
            if len(encoded.encode()) > 48 * 1024:
                raise ValueError("Completion metadata exceeds its bounded log projection")
            db.execute("UPDATE operations SET timing_json=? WHERE operation_id=?", (encoded, verified_operation_id))
            updated = db.execute("SELECT * FROM operations WHERE operation_id=?", (verified_operation_id,)).fetchone()
            db.execute("UPDATE operations SET summary_json=? WHERE operation_id=?", (_encode(self._summary(updated)), verified_operation_id))
            total = {**operation_duration(updated), **{key: updated[key] for key in ("created", "started", "finished", "state", "native_pending", "conflict_active")}}
            self._event(db, updated, "verified", "task_completion_total", timing={"task_completion": completion, "task_completions": saved, "invocation_total": total})
        return {**completion, "recorded": True}

    def queue(self, *, task_id=None, limit=100):
        limit = max(1, min(int(limit), 500))
        if task_id is not None: task_id = _identifier(task_id)
        with self._write() as db:
            self._repair(db)
            where = "(state='enqueue' OR conflict_active=1)" + (" AND task_id=?" if task_id else "")
            rows = db.execute(f"SELECT * FROM operations WHERE {where} ORDER BY seq LIMIT ?",
                              ((task_id, limit) if task_id else (limit,))).fetchall()
        return {"operations": [self._summary(row) for row in rows], "limit": limit,
                "execution": "global_fifo", "automatic_replay_allowed": False}

    def cancel(self, task_id, operation_id=None, *, requester_task_id=None):
        task_id = _identifier(task_id)
        requester = _identifier(requester_task_id, self.session_id)
        if task_id != requester:
            raise ValueError("Cancellation is limited to the caller's task")
        if operation_id is not None: operation_id = _identifier(operation_id)
        summaries = []
        with self._write() as db:
            self._repair(db)
            rows = db.execute("SELECT * FROM operations WHERE task_id=?" + (" AND operation_id=?" if operation_id else "") + " ORDER BY seq",
                              ((task_id, operation_id) if operation_id else (task_id,))).fetchall()
            for row in rows:
                if row["state"] == "enqueue":
                    db.execute("UPDATE operations SET cancel_requested=1 WHERE operation_id=?", (row["operation_id"],))
                    row = db.execute("SELECT * FROM operations WHERE operation_id=?", (row["operation_id"],)).fetchone()
                    summaries.append(self._finish(db, row, "cancelled", "cancelled_before_start", duration_ms=0))
                elif row["state"] in ACTIVE:
                    db.execute("UPDATE operations SET cancel_requested=1 WHERE operation_id=?", (row["operation_id"],))
                    row = db.execute("SELECT * FROM operations WHERE operation_id=?", (row["operation_id"],)).fetchone()
                    self._event(db, row, row["state"], "cancellation_requested")
                    summaries.append(self._summary(row))
                else:
                    summaries.append(self._summary(row))
        return {"operations": summaries, "processes_terminated": 0, "stop_at_safe_boundary": True}

    def logs(self, *, task_id=None, operation_id=None, after=0, limit=200):
        filters, parameters = ["seq> ?"], [max(0, int(after))]
        for key, value in (("task_id", task_id), ("operation_id", operation_id)):
            if value is not None: filters.append(key + "=?"); parameters.append(_identifier(value))
        limit = max(1, min(int(limit), 500))
        rows = self._persistent_db().execute("SELECT * FROM events WHERE " + " AND ".join(filters) + " ORDER BY seq LIMIT ?",
                                            (*parameters, limit + 1)).fetchall()
        events = []
        for row in rows[:limit]:
            entry = dict(row); entry["verified_flags"] = json.loads(entry.pop("flags_json"))
            entry["source"] = json.loads(entry.pop("source_json")); events.append(entry)
            entry["timing"] = json.loads(entry.pop("timing_json"))
        return {"events": events, "next_cursor": events[-1]["seq"] if events else max(0, int(after)),
                "truncated": len(rows) > limit, "retention_days": self.retention_days, "max_events": self.max_events}

    def script_execution_evidence(self, operation_id):
        summary = self.get_operation(operation_id)
        if summary is None or not summary["source"].get("script_id"): return None
        flags = summary["verified_flags"]
        focus = any(flags.get(key) is True for key in ("focus_verified", "proof_focus_preserved", "foreground_preserved", "system_focus_preserved"))
        full = flags.get("proof_full_value") is True and flags.get("proof_same_target") is True and focus
        passed = summary["state"] == "verified" and full and not summary["native_pending"] and not summary["conflict_active"]
        ended = summary["started"] is not None and summary["finished"] is not None and summary["state"] in TERMINAL and not summary["native_pending"] and not summary["conflict_active"]
        return {"operation_id": summary["operation_id"], "task_id": summary["task_id"], "app": summary["app"],
                **summary["source"], "executed": summary["started"] is not None,
                "complete": ended, "ok": summary["state"] in {"verified", "completed", "accepted_unverified"}, "duration_ms": summary["duration_ms"], "event_count": summary["event_count"],
                "verification": {"source": "runtime_postcondition", "complete": passed, "passed": passed,
                                 "checks": int(flags.get("proof_full_value") is True) + int(flags.get("proof_same_target") is True) + int(focus)},
                "error_code": summary["error_code"], "state": summary["state"]}
