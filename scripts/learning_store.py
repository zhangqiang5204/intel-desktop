"""Metadata-only collection of explicitly registered model scripts.

No source is copied, imported or executed. Maturity is evidence about a current
digest, never execution permission. Only the bounded desktop_plan/v1 runtime
can supply verified execution evidence; old Python/shell/etc. remain candidates.
"""
from __future__ import annotations

import ast
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time

DEFAULT_RUNTIME_DIR = Path.home() / ".codex" / "intel-desktop" / "runtime"
MAX_SOURCE_BYTES = 1024 * 1024
MAX_STORE_BYTES = 2 * 1024 * 1024
MAX_SCRIPTS = 200
IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,128}\Z")
BUNDLE_ID = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+\Z")
PARAMETER = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,63}\Z")
SENSITIVE_KEY = re.compile(r"(?:password|passwd|credential|secret|token|api_?key|authorization|cookie)", re.I)
INPUT_KEYS = {"text", "message", "chat", "recipient", "expected_value", "expected_text", "value", "equals", "contains"}
SOURCE_LANGUAGES = {".py": "python", ".js": "javascript", ".mjs": "javascript", ".ts": "typescript",
                    ".sh": "shell", ".zsh": "shell", ".swift": "swift", ".scpt": "applescript",
                    ".applescript": "applescript", ".json": "json"}


def _rejected_source(category):
    return {"source_available": False, "source_sha256": "", "size_bytes": 0,
            "language": "unknown", "format": "", "safety_findings": [category],
            "parameterization_candidate": False}


def _credential_filename(path):
    name = path.name.lower()
    if name == ".env" or name.startswith(".env.") or name in {".netrc", ".npmrc", ".pypirc"}:
        return True
    if path.suffix.lower() in {".pem", ".key", ".p12", ".pfx", ".p8"}:
        return True
    stem = re.sub(r"(?:\s*\(\d+\))+$", "", path.stem.lower()).lstrip(".")
    if stem in {"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "private_key", "private-key"}:
        return True
    # Credential JSON data has recognizable names. An ordinary auth.py or
    # token.py source module is not classified as a credential by its name.
    return path.suffix.lower() == ".json" and bool(re.fullmatch(
        r"(?:auth|authentication|credentials?|tokens?|secrets?|passwords?|api[_-]?key|(?:access|refresh|session)[_-]token)(?:[_-]\d+)?", stem))


def _identifier(value, label="identifier"):
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise ValueError(f"{label} must be a bounded metadata identifier")
    return value


def _names(value):
    if not isinstance(value, list) or len(value) > 32 or any(not isinstance(x, str) or not PARAMETER.fullmatch(x) for x in value):
        raise ValueError("parameter_names must contain at most 32 identifiers, never values")
    return sorted(set(value))


def _parameter_reference(value, names):
    if isinstance(value, dict):
        return set(value) == {"$param"} and value["$param"] in names
    if not isinstance(value, str):
        return False
    # The runtime accepts only exact structured $param objects. String-looking
    # placeholders are still literal input and cannot become reusable evidence.
    return False


def _source_metadata(source_path, parameter_names):
    """Inspect this one explicit source; return categories only, not its bytes."""
    path = Path(source_path)
    findings = set()
    try:
        # Check names/types before opening any bytes, including the explicit
        # source's symlink target. No directory scan or credential parsing.
        if _credential_filename(path):
            return _rejected_source("credential_source_denied")
        resolved = path.resolve()
        if _credential_filename(resolved):
            return _rejected_source("credential_source_denied")
        if path.suffix.lower() not in SOURCE_LANGUAGES or resolved.suffix.lower() not in SOURCE_LANGUAGES:
            return _rejected_source("source_extension_not_supported")
        if not path.is_file() or path.stat().st_size > MAX_SOURCE_BYTES:
            raise ValueError("Source is unavailable or exceeds the 1 MiB bound")
        with path.open("rb") as stream:
            data = stream.read(MAX_SOURCE_BYTES + 1)
        if len(data) > MAX_SOURCE_BYTES:
            raise ValueError("Source exceeds the 1 MiB bound")
    except (OSError, ValueError, RuntimeError):
        return _rejected_source("source_unavailable")
    suffix = path.suffix.lower()
    language = SOURCE_LANGUAGES[suffix]
    source_format = ""
    try:
        source = data.decode("utf-8")
    except UnicodeDecodeError:
        findings.add("source_not_utf8")
        source = ""
    if language == "json" and source:
        try:
            plan = json.loads(source)
            if isinstance(plan, dict) and plan.get("format") == "desktop_plan/v1":
                source_format = "desktop_plan/v1"
                try:
                    declared_names = _names(plan.get("parameter_names"))
                except ValueError:
                    declared_names = None
                if declared_names != parameter_names:
                    findings.add("parameter_names_mismatch")
            else:
                findings.add("unsupported_plan_format")
            def visit(value):
                if isinstance(value, dict):
                    if "$param" in value and not _parameter_reference(value, parameter_names):
                        findings.add("undeclared_or_invalid_parameter")
                    for key, item in value.items():
                        if SENSITIVE_KEY.search(key) and item and not _parameter_reference(item, parameter_names):
                            findings.add("hardcoded_sensitive_value")
                        if key in INPUT_KEYS and isinstance(item, str) and item and not _parameter_reference(item, parameter_names):
                            findings.add("hardcoded_input_value")
                        visit(item)
                elif isinstance(value, list):
                    for item in value:
                        visit(item)
            visit(plan)
        except (ValueError, RecursionError):
            findings.add("source_parse_failed")
    elif language == "python" and source:
        try:
            for node in ast.walk(ast.parse(source)):
                if isinstance(node, (ast.Assign, ast.AnnAssign)):
                    value = node.value
                    targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                    if isinstance(value, ast.Constant) and isinstance(value.value, str) and value.value:
                        if any(isinstance(t, ast.Name) and SENSITIVE_KEY.search(t.id) for t in targets):
                            findings.add("hardcoded_sensitive_value")
                if isinstance(node, ast.keyword) and node.arg and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str) and node.value.value:
                    if SENSITIVE_KEY.search(node.arg):
                        findings.add("hardcoded_sensitive_value")
                    if node.arg in INPUT_KEYS:
                        findings.add("hardcoded_input_value")
                if isinstance(node, ast.Dict):
                    for key, item in zip(node.keys, node.values):
                        if isinstance(key, ast.Constant) and isinstance(key.value, str) and isinstance(item, ast.Constant) and isinstance(item.value, str) and item.value:
                            if SENSITIVE_KEY.search(key.value):
                                findings.add("hardcoded_sensitive_value")
                            if key.value in INPUT_KEYS:
                                findings.add("hardcoded_input_value")
        except (ValueError, SyntaxError, RecursionError):
            findings.add("source_parse_failed")
    elif source:
        # A coarse screen informs redaction advice; it is never a safety proof.
        if re.search(r"(?:password|secret|token|api_?key|credential)\s*[:=]\s*['\"][^'\"]+", source, re.I):
            findings.add("hardcoded_sensitive_value")
        if re.search(r"(?:text|message|chat|recipient)\s*[:=]\s*['\"][^'\"]+", source, re.I):
            findings.add("hardcoded_input_value")
    if source_format != "desktop_plan/v1":
        findings.add("conversion_to_desktop_plan_required")
    return {"source_available": True, "source_sha256": hashlib.sha256(data).hexdigest(),
            "size_bytes": len(data), "language": language, "format": source_format,
            "safety_findings": sorted(findings), "parameterization_candidate": not findings}


class LearningStore:
    def __init__(self, runtime_dir=None, *, runtime=None):
        self.runtime_dir = Path(runtime_dir) if runtime_dir is not None else DEFAULT_RUNTIME_DIR
        self.path = self.runtime_dir / "learning.json"
        self.runtime = runtime

    def _load(self):
        if not self.path.exists():
            return {"version": 1, "scripts": {}}
        if self.path.stat().st_size > MAX_STORE_BYTES:
            raise ValueError("Learning metadata exceeds its bound")
        value = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(value, dict) or value.get("version") != 1 or not isinstance(value.get("scripts"), dict):
            raise ValueError("Unsupported learning metadata; existing file preserved")
        return value

    def _update(self, edit):
        self.runtime_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.path.with_suffix(".lock").open("a", encoding="utf-8") as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            value = self._load()
            answer = edit(value)
            if len(value["scripts"]) > MAX_SCRIPTS:
                raise ValueError("Registered script limit reached")
            payload = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
            if len(payload.encode("utf-8")) > MAX_STORE_BYTES:
                raise ValueError("Learning metadata exceeds its bound")
            fd, temporary = tempfile.mkstemp(prefix=".learning-", dir=self.runtime_dir)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as stream:
                    stream.write(payload)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
            return answer

    @staticmethod
    def _reset(row):
        row.update(status="candidate", reusable=False, executable=False, successes=0, failures=0,
                   verified_successes=0, verification_count=0, duration_ms_total=0,
                   verified_task_ids=[], evidence_operation_ids=[], last_error_code="",
                   last_operation_id="", last_execution_verified=False)

    def _refresh(self, row):
        metadata = _source_metadata(row["source_path"], row["parameter_names"])
        if row.get("source_sha256") != metadata["source_sha256"] or not metadata["source_available"]:
            self._reset(row)
            row["digest_changed_at"] = int(time.time())
        row.update(metadata)
        # Screening/conversion findings cannot become a trusted script from stats.
        if not row["parameterization_candidate"]:
            row.update(status="candidate", reusable=False, executable=False)
        return row

    def register(self, task_id, app, source_path, parameter_names, purpose="desktop_workflow"):
        task_id = _identifier(task_id, "task_id")
        purpose = _identifier(purpose, "purpose")
        if not isinstance(app, str) or len(app) > 255 or not BUNDLE_ID.fullmatch(app):
            raise ValueError("app must be a bundle identifier")
        if not isinstance(source_path, str) or not Path(source_path).is_absolute() or len(source_path) > 1024 or any(ord(c) < 32 for c in source_path):
            raise ValueError("source_path must be an absolute local path without control characters")
        names = _names(parameter_names)
        path = os.path.normpath(source_path)
        identifier = "script-" + hashlib.sha256((app + "\0" + path).encode()).hexdigest()[:24]
        def edit(value):
            row = value["scripts"].get(identifier)
            if row is None:
                row = {"id": identifier, "source_path": path, "app": app, "created_at": int(time.time()),
                       "total_successes": 0, "total_failures": 0, "total_verification_count": 0}
                self._reset(row)
            elif row["parameter_names"] != names:
                self._reset(row)
            row.update(task_id=task_id, parameter_names=names, purpose=purpose, updated_at=int(time.time()))
            self._refresh(row)
            value["scripts"][identifier] = row
            return dict(row)
        return self._update(edit)

    def list(self):
        if not self.path.exists():
            return {"scripts": [], "script_execution": False, "content_retention": "registered paths, digests and metadata only"}
        def edit(value):
            return {"scripts": [dict(self._refresh(row)) for row in value["scripts"].values()],
                    "script_execution": False, "content_retention": "registered paths, digests and metadata only"}
        return self._update(edit)

    def _execution_evidence(self, operation_id):
        runtime = self.runtime
        if runtime is None:
            from task_runtime import TaskRuntime
            runtime = TaskRuntime(self.runtime_dir)
        return runtime.script_execution_evidence(operation_id)

    def record_verified_execution(self, script_id, operation_id):
        """Record a complete runtime execution, never a caller-supplied flag.

        Complete failures are counted too. Posting events or merely completing
        transport is insufficient for verification and cannot promote maturity.
        """
        script_id = _identifier(script_id, "script_id")
        operation_id = _identifier(operation_id, "operation_id")
        # Persist invalidation even when stale proof is rejected below.
        self.list()
        evidence = self._execution_evidence(operation_id)
        if not isinstance(evidence, dict) or evidence.get("operation_id") != operation_id:
            raise ValueError("Runtime execution evidence is unavailable")
        if evidence.get("executed") is not True or evidence.get("complete") is not True:
            raise ValueError("Only complete actual runtime executions may be recorded")
        duration = evidence.get("duration_ms")
        if not isinstance(duration, (int, float)) or isinstance(duration, bool) or not math.isfinite(duration) or duration < 0:
            raise ValueError("Runtime duration evidence is invalid")
        task_id = _identifier(evidence.get("task_id"), "runtime task_id")
        verification = evidence.get("verification")
        checks = verification.get("checks") if isinstance(verification, dict) else 0
        evidence_verified = (evidence.get("ok") is True and isinstance(verification, dict)
                    and verification.get("source") == "runtime_postcondition"
                    and verification.get("complete") is True and verification.get("passed") is True
                    and isinstance(checks, int) and not isinstance(checks, bool) and 0 < checks <= 1000)
        def edit(value):
            row = value["scripts"].get(script_id)
            if row is None:
                raise ValueError("Script is not registered")
            self._refresh(row)
            if evidence.get("script_id") != script_id or evidence.get("app") != row["app"] or evidence.get("source_sha256") != row["source_sha256"]:
                raise ValueError("Runtime evidence does not match the current script digest and app")
            if operation_id in row["evidence_operation_ids"]:
                return {"id": script_id, "status": row["status"], "recorded": False, "reason": "already_recorded"}
            if len(row["evidence_operation_ids"]) >= 1000:
                raise ValueError("Execution evidence bound reached for this source digest")
            ok = evidence.get("ok") is True
            row["successes" if ok else "failures"] += 1
            row["total_successes" if ok else "total_failures"] += 1
            # Legacy code may collect execution metadata but never promotion.
            verified = bool(evidence_verified and row["parameterization_candidate"] and row["format"] == "desktop_plan/v1")
            row["verified_successes"] += int(verified)
            row["verification_count"] += checks if verified else 0
            row["total_verification_count"] += checks if verified else 0
            row["duration_ms_total"] = round(row["duration_ms_total"] + duration, 3)
            row["evidence_operation_ids"].append(operation_id)
            if verified and task_id not in row["verified_task_ids"]:
                row["verified_task_ids"].append(task_id)
            if verified:
                row.update(status="verified", reusable=False)
            if row["verified_successes"] >= 3 and len(row["verified_task_ids"]) >= 2 and row["failures"] == 0:
                row.update(status="reusable", reusable=True)
            elif row["failures"] and row["status"] == "reusable":
                row.update(status="verified", reusable=False)
            category = evidence.get("error_code", "")
            row["last_error_code"] = category if not ok and isinstance(category, str) and re.fullmatch(r"[a-z_]{1,64}", category) else "" if ok else "execution_failed"
            row.update(updated_at=int(time.time()), last_operation_id=operation_id, last_execution_verified=verified)
            return {"id": script_id, "status": row["status"], "recorded": True, "verified": verified,
                    "verification_count": row["verification_count"], "executable": False}
        return self._update(edit)

    def analyze(self):
        scripts = self.list()["scripts"]
        candidates, reusable = [], []
        actions = {action: 0 for action in ("conversion", "repair", "verification", "reuse")}
        for row in scripts:
            if row["status"] == "reusable":
                reason, action = "reuse_with_fresh_target_and_postconditions", "reuse"
            else:
                reason = ("use_noncredential_script_source" if "credential_source_denied" in row["safety_findings"]
                          else "use_supported_script_extension" if "source_extension_not_supported" in row["safety_findings"]
                          else "restore_registered_source" if not row["source_available"]
                          else "redact_hardcoded_values" if any(x.startswith("hardcoded_") for x in row["safety_findings"])
                          else "convert_to_desktop_plan" if row["format"] != "desktop_plan/v1"
                          else "repair_plan_parameter_contract" if row["safety_findings"]
                          else "repair_execution_failure" if row["failures"] else "verify_current_digest")
                action = ("conversion" if reason == "convert_to_desktop_plan" else
                          "verification" if reason == "verify_current_digest" else "repair")
            actions[action] += 1
            score = min(100, row["failures"] * 15 + row["successes"] * 3 + (20 if reason == "redact_hardcoded_values" else 0))
            item = {"id": row["id"], "app": row["app"], "source_path": row["source_path"],
                    "source_sha256": row["source_sha256"], "language": row["language"], "purpose": row["purpose"],
                    "status": row["status"], "priority": score, "recommendation": reason, "next_action": action,
                    "safety_findings": row["safety_findings"], "successes": row["successes"],
                    "failures": row["failures"], "verification_count": row["verification_count"],
                    "verified_successes": row["verified_successes"], "verified_task_count": len(row["verified_task_ids"]),
                    "last_operation_id": row["last_operation_id"], "last_error_code": row["last_error_code"],
                    "last_execution_verified": row["last_execution_verified"], "automatic_execution": False}
            (reusable if action == "reuse" else candidates).append(item)
        candidates.sort(key=lambda x: (-x["priority"], x["id"]))
        reusable.sort(key=lambda x: (x["app"], x["id"]))
        return {"registered_count": len(scripts), "levels": {level: sum(r["status"] == level for r in scripts) for level in ("candidate", "verified", "reusable")},
                "candidates": candidates[:30], "omitted_candidates": max(0, len(candidates) - 30),
                "reusable_scripts": reusable[:30], "omitted_reusable_scripts": max(0, len(reusable) - 30),
                "next_action_counts": actions, "evidence_basis": "current_registered_source_digest",
                "automatic_execution": False, "source_contents_retained": False}
