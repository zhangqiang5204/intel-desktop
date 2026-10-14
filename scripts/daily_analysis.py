#!/usr/bin/env python3
"""Daily, bounded analysis of Intel Desktop metadata. Never executes or repairs code.

Run ``daily_analysis.py analyze --date YYYY-MM-DD``. The default date is
yesterday in the machine's local timezone. A Codex heartbeat may use this
report as evidence for an authorized semantic source repair; this CLI does
not infer authorization, replay input, create schedules or send messages.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from contextlib import closing
from datetime import date as Date, datetime, time as Time, timedelta, timezone as UTC
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import tempfile
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from learning_store import BUNDLE_ID, DEFAULT_RUNTIME_DIR, IDENTIFIER, LearningStore
from task_runtime import (_native_interruption, operation_duration, COMPLETION_PURPOSES,
                          WORKFLOW_DURATION_BASIS, TASK_DURATION_BASIS, TERMINAL)

MAX_RECORDS = 100_000
MAX_LINE_BYTES = 64 * 1024
MAX_REPORT_BYTES = 256 * 1024
MAX_GROUPS = 30
SAFE_TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_.:-]{0,79}\Z")
SAFE_ERROR = re.compile(r"[a-z_]{1,64}\Z")
TERMINAL_STATES = {"verified", "completed", "accepted_unverified", "unknown", "succeeded", "unverified", "failed", "interrupted", "cancelled", "completion_unknown"}
STATES = TERMINAL_STATES | {"enqueue", "claim", "precondition", "executing", "postcondition", "queued", "running", "waiting"}


def local_timezone(name=None):
    if name:
        return ZoneInfo(name)
    configured = os.environ.get("TZ", "").lstrip(":")
    if configured:
        try:
            return ZoneInfo(configured)
        except (ZoneInfoNotFoundError, ValueError):
            pass
    target = str(Path("/etc/localtime").resolve())
    if "/zoneinfo/" in target:
        try:
            return ZoneInfo(target.split("/zoneinfo/", 1)[1])
        except (ZoneInfoNotFoundError, ValueError):
            pass
    return datetime.now().astimezone().tzinfo


def _day_bounds(day, tz):
    if day is not None and (not isinstance(day, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day)):
        raise ValueError("date must use YYYY-MM-DD")
    selected = Date.fromisoformat(day) if day else datetime.now(tz).date() - timedelta(days=1)
    start = datetime.combine(selected, Time.min, tz)
    end = datetime.combine(selected + timedelta(days=1), Time.min, tz)
    return selected, start, end


def _timestamp(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        try:
            return datetime.fromtimestamp(value, UTC.utc)
        except (ValueError, OverflowError, OSError):
            return None
    if isinstance(value, str) and len(value) <= 40:
        try:
            result = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return result if result.tzinfo else None
        except ValueError:
            return None
    return None


def _number(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and 0 <= value <= 86_400_000:
        return round(float(value), 3)
    return None


def _token(value, default="unknown", pattern=SAFE_TOKEN):
    return value if isinstance(value, str) and len(value) <= 255 and pattern.fullmatch(value) else default


def _dictionary(value):
    if isinstance(value, dict):
        return value
    if isinstance(value, str) and len(value) <= MAX_LINE_BYTES:
        try:
            result = json.loads(value)
            return result if isinstance(result, dict) else {}
        except (ValueError, RecursionError):
            pass
    return {}


def _total_number(value):
    if type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 366 * 86_400_000:
        return round(float(value), 3)
    return None


def _completion_unit(value, task_id, operation_id):
    if (not isinstance(value, dict) or value.get("duration_basis") != TASK_DURATION_BASIS
            or not isinstance(value.get("purpose"), str) or value["purpose"] not in COMPLETION_PURPOSES):
        return None
    refs = value.get("operation_ids")
    unit_id = _token(value.get("unit_id"), "", IDENTIFIER)
    verified = _token(value.get("verified_operation_id"), "", IDENTIFIER)
    if (not unit_id or not isinstance(refs, list) or not 1 <= len(refs) <= 128
            or any(not _token(ref, "", IDENTIFIER) for ref in refs) or len(set(refs)) != len(refs)
            or value.get("task_id") != task_id or verified != operation_id or verified not in refs
            or value.get("verification_source") != "runtime_postcondition" or value.get("outcome") != "verified"):
        return None
    created, finished = _timestamp(value.get("created")), _timestamp(value.get("finished"))
    if created is None or finished is None or finished < created:
        return None
    elapsed = _total_number((finished - created).total_seconds() * 1000)
    recorded = _total_number(value.get("total_duration_ms"))
    if elapsed is None or elapsed != recorded or value.get("timing_complete") is not True:
        return None
    outcomes = value.get("attempt_outcomes", {})
    if not isinstance(outcomes, dict):
        return None
    counts = {state: count for state, count in outcomes.items() if state in TERMINAL and type(count) is int and 0 <= count <= 128}
    if sum(counts.values()) != len(refs):
        return None
    return {"unit_id": unit_id, "task_id": task_id, "purpose": value["purpose"], "duration_basis": TASK_DURATION_BASIS,
            "created": created.timestamp(), "finished": finished.timestamp(), "total_duration_ms": elapsed,
            "verified_operation_id": verified, "first_operation_id": refs[0], "reference_count": len(refs),
            "attempt_outcomes": counts, "unknown_attempts": counts.get("unknown", 0),
            "failed_attempts": sum(counts.get(state, 0) for state in ("failed", "unknown", "interrupted", "cancelled")),
            "outcome": "verified", "normality_assessed": False}


def safe_metadata(value):
    """Project an event/operation to identifiers, numbers and explicit outcomes."""
    if not isinstance(value, dict):
        return None
    summary = _dictionary(value.get("summary_json"))
    flags = _dictionary(value.get("flags_json", value.get("verified_flags")))
    source = _dictionary(value.get("source_json", value.get("source")))
    timing = _dictionary(value.get("timing_json", value.get("timing")))
    interruption = _native_interruption({"error": {"details": {
        "last_interruption_event": timing.get("last_interruption_event")}}})
    raw_stages = timing.get("native_stage_ms", value.get("native_stage_ms", {}))
    stages = {}
    if isinstance(raw_stages, dict):
        for name, elapsed in list(raw_stages.items())[:64]:
            safe_name, safe_elapsed = _token(name, ""), _number(elapsed)
            if safe_name and safe_elapsed is not None:
                stages[safe_name] = safe_elapsed
    invocation = _dictionary(timing.get("invocation_total"))
    stamp = _timestamp(value.get("finished") or invocation.get("finished") or value.get("timestamp") or value.get("ts") or value.get("created"))
    if stamp is None:
        return None
    state = value.get("state", value.get("status", value.get("phase", "unknown")))
    state = state if isinstance(state, str) and state in STATES else "unknown"
    error = value.get("error_code", summary.get("error_code", ""))
    if not error and isinstance(value.get("error"), dict):
        error = value["error"].get("code", "")
    error = _token(error, "operation_failed", SAFE_ERROR) if error else ""
    if not error and state in {"failed", "completion_unknown", "interrupted"}:
        error = "operation_failed" if state == "failed" else state
    verified = state == "verified" or value.get("verified") is True or flags.get("verified") is True
    ok = value.get("ok") is True or state in {"verified", "completed", "succeeded"}
    count = value.get("event_count", value.get("events_posted", 0))
    count = count if isinstance(count, int) and not isinstance(count, bool) and 0 <= count <= 10_000_000 else 0
    duration = _number(value.get("duration_ms", value.get("execution_ms")))
    queue_wait = _number(value.get("queue_wait_ms"))
    if ("finished" in value and value["finished"] is None) or state in {"enqueue", "queued", "waiting"}:
        duration = None
    if "started" in value and value["started"] is None:
        queue_wait = None
    boundaries = {**invocation, **{key: value[key] for key in ("created", "started", "finished", "native_pending", "conflict_active") if key in value}}
    # Event.created is the event-write time, not the invocation's enqueue time.
    if invocation and "finished" not in value:
        boundaries = invocation
    total = operation_duration({**boundaries, "tool": value.get("tool"), "state": state, "timing": timing})
    task_id = _token(value.get("task_id"), "", IDENTIFIER)
    operation_id = _token(value.get("operation_id", value.get("op_id")), "", IDENTIFIER)
    raw_units = timing.get("task_completions", [])
    if "task_completions" not in timing and "task_completion" in timing:
        raw_units = [timing["task_completion"]]
    units = [_completion_unit(unit, task_id, operation_id) for unit in raw_units[:8]] if isinstance(raw_units, list) else []
    unit_records = len(raw_units) if isinstance(raw_units, list) else 1
    return {"timestamp": stamp, "operation_id": _token(value.get("operation_id", value.get("op_id")), "", IDENTIFIER),
            "task_id": _token(value.get("task_id"), "", IDENTIFIER),
            "chain_id": _token(value.get("chain_id"), "", IDENTIFIER),
            "tool": _token(value.get("tool")), "app": _token(value.get("app"), "unknown", BUNDLE_ID),
            "phase": _token(value.get("phase", summary.get("phase", "outcome"))),
            "state": state, "error_code": error, "verified": verified, "ok": ok,
            "event_count": count, "duration_ms": duration, "queue_wait_ms": queue_wait,
            "native_elapsed_ms": _number(timing.get("native_elapsed_ms", value.get("native_elapsed_ms"))),
            "native_stage_ms": stages,
            "interruption_reason": interruption.get("reason", ""),
            **total, "task_completions": [unit for unit in units if unit is not None],
            "task_completion_records": unit_records,
            "invalid_task_completion_records": unit_records - sum(unit is not None for unit in units),
            "script_id": _token(value.get("script_id", source.get("script_id")), "", IDENTIFIER)}


def _sqlite_rows(runtime_dir, start, end):
    database = runtime_dir / "runtime.sqlite3"
    if not database.is_file():
        return None, {"kind": "jsonl", "complete": True}
    try:
        with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)) as db:
            db.row_factory = sqlite3.Row
            columns = {r[1] for r in db.execute("PRAGMA table_info(operations)")}
            if not {"operation_id", "created"}.issubset(columns):
                return None, {"kind": "jsonl", "complete": True, "sqlite_gap": "operation_schema_unavailable"}
            # Runtime timestamps are UTC epoch seconds. Outcome belongs to its
            # completion day; an unfinished queue item belongs to creation day.
            clock = "COALESCE(finished,created)" if "finished" in columns else "created"
            selected = [x for x in ("operation_id", "task_id", "chain_id", "tool", "app", "state", "created", "started", "finished",
                                   "queue_wait_ms", "duration_ms", "event_count", "flags_json", "source_json", "timing_json", "summary_json", "error_code", "native_pending", "conflict_active") if x in columns]
            query = f"SELECT {','.join(selected)} FROM operations WHERE {clock} >= ? AND {clock} < ? ORDER BY {clock},operation_id LIMIT ?"
            rows = [dict(row) for row in db.execute(query, (start.timestamp(), end.timestamp(), MAX_RECORDS + 1))]
        complete = len(rows) <= MAX_RECORDS
        return rows[:MAX_RECORDS], {"kind": "sqlite", "path": str(database), "table": "operations", "available": True, "complete": complete,
                                   "record_limit": MAX_RECORDS, "date_basis": "finished_else_created", "records_read": min(len(rows), MAX_RECORDS)}
    except sqlite3.Error:
        return None, {"kind": "jsonl", "complete": False, "sqlite_gap": "metadata_database_unavailable"}


def _jsonl_rows(runtime_dir, paths=None):
    if paths is None:
        paths = [runtime_dir / "metadata.jsonl", runtime_dir / "events.jsonl"]
        log_dir = runtime_dir / "logs"
        if log_dir.is_dir():
            paths.extend(sorted(log_dir.glob("*.jsonl"))[:33])
    omitted_files = max(0, len(paths) - 34)
    if omitted_files and paths is not None:
        paths = paths[:34]
    rows, rejected, sources = [], 0, []
    complete = omitted_files == 0
    for raw_path in paths:
        path = Path(raw_path)
        if not path.is_file():
            continue
        sources.append(str(path))
        try:
            with path.open("rb") as stream:
                while True:
                    line = stream.readline(MAX_LINE_BYTES + 1)
                    if not line:
                        break
                    if len(line) > MAX_LINE_BYTES:
                        rejected += 1
                        complete = False
                        # Do not load an unbounded raw envelope to skip it.
                        while line and not line.endswith(b"\n"):
                            line = stream.readline(MAX_LINE_BYTES + 1)
                        continue
                    try:
                        row = json.loads(line)
                        if not isinstance(row, dict):
                            raise ValueError("Not metadata")
                    except (ValueError, UnicodeDecodeError, RecursionError):
                        rejected += 1
                        continue
                    rows.append(row)
                    if len(rows) >= MAX_RECORDS:
                        complete = False
                        break
        except OSError:
            rejected += 1
            complete = False
        if not complete and len(rows) >= MAX_RECORDS:
            break
    return rows, {"kind": "jsonl", "paths": sources, "available": bool(sources), "complete": complete and bool(sources) and rejected == 0,
                  "record_limit": MAX_RECORDS, "records_read": len(rows), "malformed_records": rejected,
                  "omitted_source_files": omitted_files,
                  "date_basis": "metadata_timestamp"}


def _percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * fraction
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    return round(ordered[lower] + (ordered[upper] - ordered[lower]) * (rank - lower), 3)


def _stats(rows):
    execution = [r["duration_ms"] for r in rows if r["duration_ms"] is not None]
    queued = [r["queue_wait_ms"] for r in rows if r["queue_wait_ms"] is not None]
    native = [r["native_elapsed_ms"] for r in rows if r["native_elapsed_ms"] is not None]
    return {"count": len(rows), "failures": sum(bool(r["error_code"]) for r in rows),
            "verified": sum(r["verified"] for r in rows), "events_posted": sum(r["event_count"] for r in rows),
            "execution_ms": {"samples": len(execution), "p50": _percentile(execution, .5), "p95": _percentile(execution, .95)},
            "native_elapsed_ms": {"samples": len(native), "p50": _percentile(native, .5), "p95": _percentile(native, .95)},
            "queue_wait_ms": {"samples": len(queued), "p50": _percentile(queued, .5), "p95": _percentile(queued, .95)}}


def _stage_stats(rows):
    stages = defaultdict(list)
    for row in rows:
        for name, elapsed in row["native_stage_ms"].items():
            stages[name].append(elapsed)
    result = [{"stage": name, "samples": len(values), "p50": _percentile(values, .5), "p95": _percentile(values, .95)}
              for name, values in stages.items()]
    result.sort(key=lambda x: (-x["p95"], x["stage"]))
    return {"basis": "per_operation_cumulative", "stages": result[:MAX_GROUPS], "omitted_stages": max(0, len(result) - MAX_GROUPS)}


def _task_total_stats(rows, source):
    workflows = [row for row in rows if row["workflow_invocation"]]
    unclassified = sum(not row["workflow_classification_complete"] for row in rows)
    values = [row["total_duration_ms"] for row in workflows if row["total_duration_ms"] is not None]
    pending = sum(row["state"] not in TERMINAL_STATES for row in workflows)
    unknown = sum(row["state"] in {"unknown", "completion_unknown"} for row in workflows)
    missing = len(workflows) - len(values)
    units = {}
    for row in rows:
        for unit in row["task_completions"]:
            key = (unit["task_id"], unit["unit_id"])
            if key not in units or unit["finished"] > units[key]["finished"]:
                units[key] = unit
    completed = list(units.values())
    invalid_units = sum(row["invalid_task_completion_records"] for row in rows)
    records = sum(row["task_completion_records"] for row in rows)
    elapsed = [unit["total_duration_ms"] for unit in completed]
    by_purpose = []
    for purpose in sorted({unit["purpose"] for unit in completed}):
        samples = [unit["total_duration_ms"] for unit in completed if unit["purpose"] == purpose]
        by_purpose.append({"purpose": purpose, "samples": len(samples), "p50": _percentile(samples, .5), "p95": _percentile(samples, .95)})
    return {"workflow_invocations": {"duration_basis": WORKFLOW_DURATION_BASIS, "count": len(workflows), "samples": len(values),
                                      "p50": _percentile(values, .5), "p95": _percentile(values, .95),
                                      "missing_or_incomplete_timing": missing, "in_progress": pending, "unknown_outcomes": unknown,
                                      "unclassified_invocations": unclassified,
                                      "classification_coverage_complete": source["complete"] and not unclassified,
                                      "coverage_complete": source["complete"] and bool(workflows) and not (missing or pending or unknown or unclassified)},
            "completed_task_units": {"duration_basis": TASK_DURATION_BASIS, "count": len(completed), "samples": len(elapsed),
                                      "p50": _percentile(elapsed, .5), "p95": _percentile(elapsed, .95), "by_purpose": by_purpose,
                                      "units": sorted(completed, key=lambda unit: (unit["finished"], unit["unit_id"]))[:MAX_GROUPS],
                                      "omitted_units": max(0, len(completed) - MAX_GROUPS),
                                      "unknown_attempts": sum(unit["unknown_attempts"] for unit in completed),
                                      "records_available": records, "invalid_or_incomplete_records": invalid_units,
                                      "coverage_complete": source["complete"] and bool(completed) and not invalid_units
                                                           and not any(unit["unknown_attempts"] for unit in completed)},
            "normality_assessed": False, "automatic_optimization": False,
            "scope": "explicit recorded boundaries only; no stable-task historical accumulation or inferred user-message time"}


def _group(rows, keys):
    grouped = defaultdict(list)
    for row in rows:
        grouped[tuple(row[k] for k in keys)].append(row)
    result = [{**dict(zip(keys, key)), **_stats(items)} for key, items in grouped.items()]
    result.sort(key=lambda x: (-x["failures"], -x["count"], tuple(x[k] for k in keys)))
    return result[:MAX_GROUPS], max(0, len(result) - MAX_GROUPS)


def _repair_candidates(rows, source):
    failures = [r for r in rows if r["error_code"]]
    groups = defaultdict(list)
    for row in failures:
        groups[(row["error_code"], row["tool"], row["app"])].append(row)
    repairs = []
    code_repairs = {"native_protocol_error": "inspect_native_protocol_and_add_bounded_fixture",
                    "native_transport_error": "inspect_transport_lifecycle_and_add_bounded_fixture",
                    "unknown_command": "reconcile_tool_dispatch_with_schema",
                    "invalid_argument": "inspect_argument_validation_and_add_bounded_fixture",
                    "operation_completion_unknown": "inspect_completion_tracking_without_input_replay"}
    for (code, tool, app), items in groups.items():
        ids = sorted({r["operation_id"] for r in items if r["operation_id"]})[:3]
        repairs.append({"kind": "exception", "priority": min(100, len(items) * 10), "error_code": code,
                        "tool": tool, "app": app, "frequency": len(items),
                        "suggested_action": code_repairs.get(code, "inspect_owner_and_reproduce_observed_failure"),
                        "safe_local_repair_candidate": code in code_repairs,
                        "evidence": {"kind": source["kind"], "operation_ids": ids, "date_basis": source["date_basis"]},
                        "automatic_input_replay": False})
    queue_stats = _stats(rows)["queue_wait_ms"]
    execution = _stats(rows)["execution_ms"]
    if queue_stats["p95"] is not None and queue_stats["p95"] > 1000 and queue_stats["p95"] > (execution["p95"] or 0):
        repairs.append({"kind": "queue_latency", "priority": 30, "suggested_action": "inspect_queue_contention_and_active_conflict_owners",
                        "safe_local_repair_candidate": True, "queue_p95_ms": queue_stats["p95"],
                        "execution_p95_ms": execution["p95"], "evidence": {"kind": source["kind"], "date_basis": source["date_basis"]},
                        "automatic_input_replay": False})
    repairs.sort(key=lambda x: (-x["priority"], x.get("error_code", ""), x.get("tool", "")))
    return repairs[:20]


def human_report(report):
    total = report["totals"]
    def number(value):
        return "n/a" if value is None else str(value)
    lines = [f"Intel Desktop daily analysis — {report['date']} ({report['timezone']})",
             f"Operations: {total['count']}; exceptions: {total['failures']}; verified outcomes: {total['verified']}; posted events: {total['events_posted']}",
             f"Execution p50/p95: {number(total['execution_ms']['p50'])}/{number(total['execution_ms']['p95'])} ms ({total['execution_ms']['samples']} samples)",
             f"Queue p50/p95: {number(total['queue_wait_ms']['p50'])}/{number(total['queue_wait_ms']['p95'])} ms ({total['queue_wait_ms']['samples']} samples)",
             f"Coverage: {'complete' if report['source']['complete'] else 'partial'}; source: {report['source']['kind']}; invalid records: {report['invalid_records']}"]
    workflows = report["task_totals"]["workflow_invocations"]
    units = report["task_totals"]["completed_task_units"]
    lines.append(f"Workflow total p50/p95: {number(workflows['p50'])}/{number(workflows['p95'])} ms ({workflows['samples']}/{workflows['count']} recorded invocations; basis={workflows['duration_basis']})")
    lines.append(f"Workflow timing coverage: {'complete' if workflows['coverage_complete'] else 'partial or unavailable'}; missing={workflows['missing_or_incomplete_timing']}; in-progress={workflows['in_progress']}; unknown={workflows['unknown_outcomes']}; unclassified={workflows['unclassified_invocations']}")
    lines.append(f"Explicit completed task units: {units['count']}; total p50/p95={number(units['p50'])}/{number(units['p95'])} ms; basis={units['duration_basis']}; unknown attempts={units['unknown_attempts']}; invalid/incomplete={units['invalid_or_incomplete_records']}")
    lines.append("Normality is not inferred from PASS or missing timings; review recorded totals and exceptions before choosing any optimization.")
    for group in report["by_error_tool_app"][:10]:
        lines.append(f"Exception {group['error_code']} / {group['tool']} / {group['app']}: {group['count']}")
    for group in report["by_interruption_reason"][:5]:
        lines.append(f"Interruption {group['error_code'] or 'no_terminal_error'} / {group['interruption_reason']} / {group['tool']} / {group['app']}: {group['count']}")
    levels = report["script_learning"]["levels"]
    for stage in report["native_stage_ms"]["stages"][:5]:
        lines.append(f"Native stage {stage['stage']} p50/p95: {stage['p50']}/{stage['p95']} ms ({stage['samples']} samples)")
    lines.append(f"Registered scripts: {report['script_learning']['registered_count']}; candidate/verified/reusable: {levels['candidate']}/{levels['verified']}/{levels['reusable']}")
    for candidate in report["repair_candidates"][:5]:
        lines.append(f"Priority {candidate['priority']}: {candidate['suggested_action']}")
    lines.append("Reports are evidence for model decisions. This analyzer performs no source repair, script execution or input replay.")
    return "\n".join(lines) + "\n"


def _write(path, payload):
    if len(payload.encode("utf-8")) > MAX_REPORT_BYTES:
        raise ValueError("Daily report exceeds its bound")
    fd, temporary = tempfile.mkstemp(prefix=".daily-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def analyze(runtime_dir=None, date=None, timezone=None, *, log_paths=None, write=True):
    runtime_dir = Path(runtime_dir) if runtime_dir is not None else DEFAULT_RUNTIME_DIR
    tz = local_timezone(timezone)
    day, start, end = _day_bounds(date, tz)
    rows, source = _sqlite_rows(runtime_dir, start, end) if log_paths is None else (None, {})
    sqlite_gap = source.get("sqlite_gap")
    if rows is None:
        rows, source = _jsonl_rows(runtime_dir, log_paths)
        if sqlite_gap:
            source["sqlite_gap"] = sqlite_gap
            source["complete"] = False
    sanitized, invalid = [], 0
    for raw in rows:
        row = safe_metadata(raw)
        if row is None:
            invalid += 1
        elif start <= row["timestamp"] < end:
            sanitized.append(row)
    invalid += source.get("malformed_records", 0)
    if invalid:
        source["complete"] = False
    # Logs can contain many phases for one operation. Pick a terminal record,
    # then the most recent metadata; never sum its posted events repeatedly.
    distinct = {}
    anonymous = []
    for row in sanitized:
        if not row["operation_id"]:
            anonymous.append(row)
            continue
        previous = distinct.get(row["operation_id"])
        score = (row["state"] in TERMINAL_STATES or row["phase"] in {"outcome", "complete", "failed"}, row["timestamp"])
        previous_score = ((previous["state"] in TERMINAL_STATES or previous["phase"] in {"outcome", "complete", "failed"}), previous["timestamp"]) if previous else None
        if previous is None or score >= previous_score:
            distinct[row["operation_id"]] = row
    selected = list(distinct.values()) + anonymous
    by_tool, omitted_tools = _group(selected, ["tool"])
    by_app, omitted_apps = _group(selected, ["app"])
    by_error, omitted_errors = _group([r for r in selected if r["error_code"]], ["error_code", "tool", "app"])
    by_reason, omitted_reasons = _group([r for r in selected if r["interruption_reason"]], ["error_code", "interruption_reason", "tool", "app"])
    report = {"version": 1, "date": day.isoformat(), "timezone": str(tz),
              "generated_at": datetime.now(UTC.utc).isoformat(), "source": source,
              "invalid_records": invalid, "deduplicated_records": len(sanitized) - len(selected),
              "totals": _stats(selected), "by_tool": by_tool, "by_app": by_app, "by_error_tool_app": by_error,
              "task_totals": _task_total_stats(selected, source),
              "by_interruption_reason": by_reason, "interruption_reason_basis": "last_native_event_per_operation",
              "native_stage_ms": _stage_stats(selected),
              "omitted_groups": {"tool": omitted_tools, "app": omitted_apps, "error_tool_app": omitted_errors, "interruption_reason": omitted_reasons},
              "repair_candidates": _repair_candidates(selected, source), "script_learning": LearningStore(runtime_dir).analyze(),
              "source_repair_performed": False, "automatic_script_execution": False,
              "content_retention": "metadata identifiers, digests, registered paths, counts and durations only"}
    if write:
        destination = runtime_dir / "reports"
        destination.mkdir(parents=True, exist_ok=True, mode=0o700)
        encoded = json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
        readable = human_report(report)
        for path, payload in ((destination / f"{day}.json", encoded), (destination / f"{day}.txt", readable),
                              (destination / "current.json", encoded), (destination / "current.txt", readable)):
            _write(path, payload)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    command = subparsers.add_parser("analyze", help="Analyze metadata for a local calendar day")
    command.add_argument("--date", help="YYYY-MM-DD; default yesterday")
    command.add_argument("--timezone", help="IANA timezone; default machine timezone")
    command.add_argument("--runtime-dir", type=Path, default=DEFAULT_RUNTIME_DIR)
    command.add_argument("--log-file", action="append", type=Path, help="Explicit metadata-only fixture/log; skips SQLite")
    command.add_argument("--format", choices=("text", "json"), default="text")
    options = parser.parse_args()
    try:
        report = analyze(options.runtime_dir, options.date, options.timezone, log_paths=options.log_file)
    except (ValueError, OSError, ZoneInfoNotFoundError, json.JSONDecodeError):
        parser.exit(2, "Daily analysis failed: invalid input or unavailable metadata; raw error omitted.\n")
    print(json.dumps(report, ensure_ascii=False, sort_keys=True) if options.format == "json" else human_report(report), end="\n" if options.format == "json" else "")


if __name__ == "__main__":
    main()
