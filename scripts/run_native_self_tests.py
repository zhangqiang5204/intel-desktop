#!/usr/bin/env python3
"""Run only whitelisted non-GUI native self-tests after an explicit native build."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SUITES = {
    "geometry": "--geometry-self-test",
    "text-selection": "--text-selection-self-test",
    "focus-claim": "--focus-claim-self-test",
    "submit-guards": "--submit-self-test",
    "native-interaction": "--native-interaction-self-test",
    "visual": "--visual-self-test",
    "window-snapshot": "--visual-window-snapshot-self-test",
}


def run_suites(helper, suites):
    helper = Path(helper).resolve()
    if not helper.is_file():
        raise ValueError("Build native/build.sh first; no native binary is distributed")
    if any(suite not in SUITES for suite in suites):
        raise ValueError("Only explicit non-GUI suites are supported")
    results = []
    event_counts = []
    for suite in suites:
        completed = subprocess.run([str(helper), SUITES[suite]], capture_output=True, text=True,
                                   timeout=30, check=False)
        try:
            if len(completed.stdout.encode()) > 256 * 1024:
                raise ValueError("Bounded self-test metadata required")
            payload = json.loads(completed.stdout)
            events = payload.get("events_posted", 0)
            events = events if type(events) is int and events >= 0 else None
            no_events = events == 0
            no_live_work = all(payload.get(key) is not True for key in
                               ("capture_executed", "live_AX_probe_executed", "live_submit_executed", "live_capture",
                                "UI_created", "AX_reads_executed", "event_tap_created"))
            passed = completed.returncode == 0 and payload.get("ok") is True and no_events and no_live_work
            count = payload.get("case_count", payload.get("count", len(payload.get("cases", []))))
            count = count if type(count) is int and count >= 0 else None
        except (ValueError, TypeError, AttributeError):
            passed, count, events, no_live_work = False, None, None, False
        event_counts.append(events)
        results.append({"suite": suite, "passed": passed, "case_count": count, "no_live_work_reported": no_live_work})
    return {"ok": bool(results) and all(row["passed"] for row in results), "suites": results,
            "GUI_operations": 0 if all(row["no_live_work_reported"] for row in results) else None,
            "HID_events": sum(event_counts) if all(count is not None for count in event_counts) else None,
            "live_app_acceptance": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, default=ROOT / "bin/IntelDesktopHelper")
    parser.add_argument("--suite", action="append", choices=tuple(SUITES))
    parser.add_argument("--list", action="store_true", help="List pure suites without starting the helper")
    options = parser.parse_args(argv)
    if options.list:
        print(json.dumps({"suites": SUITES, "native_execution_started": False}, indent=2))
        return 0
    try:
        report = run_suites(options.helper, options.suite or list(SUITES))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        parser.exit(2, "Native self-tests unavailable: missing build, invalid source, or bounded execution failure.\n")
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
