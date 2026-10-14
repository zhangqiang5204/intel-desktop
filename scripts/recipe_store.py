"""Small local metadata ledger. Registered scripts are observations, never code.

Only the fixed chat templates are executable, through chat_workflows.py. This
module never opens, imports or executes a registered script and never records
chat names, messages, AX values, OCR rows, credentials or native envelopes.
"""
from __future__ import annotations

import fcntl
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time

APPS = {"com.tencent.xinWeChat", "com.bytedance.macos.feishu"}
ACTIONS = {"locate", "read", "draft", "clear", "clear_prefix", "history", "send"}
PARAMETERS = ["chat", "chat_kind", "text", "expected_draft", "prefix", "pages", "reply_contains", "baseline_text", "previous_visible_text", "wait_timeout_ms", "send_authorization"]
BUILTIN_VERSION = "chat-v1"
DEFAULT_PATH = Path.home() / ".codex" / "intel-desktop" / "recipes.json"

RECIPE_TOOL = {
    "name": "desktop_recipe",
    "description": "List reusable built-in chat recipes and register a model-authored local script as metadata only. Registered scripts are never imported or executed. No chat/message content is retained.",
    "inputSchema": {"type": "object", "properties": {
        "action": {"type": "string", "enum": ["list", "register"]},
        "source_path": {"type": "string", "description": "Absolute path of the model-authored script; metadata only."},
        "app": {"type": "string"},
        "parameter_names": {"type": "array", "items": {"type": "string"}, "maxItems": 32},
    }, "required": ["action"], "additionalProperties": False},
    "annotations": {"readOnlyHint": False, "destructiveHint": False, "openWorldHint": False},
}


class RecipeStore:
    def __init__(self, path: str | Path | None = None):
        self.path = Path(path) if path is not None else DEFAULT_PATH

    @staticmethod
    def _empty():
        return {"version": 1, "recipes": {}}

    def _load(self):
        if not self.path.exists():
            return self._empty()
        if self.path.stat().st_size > 1024 * 1024:
            raise ValueError("Recipe metadata exceeds the 1 MiB bound")
        value = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(value, dict) or value.get("version") != 1 or not isinstance(value.get("recipes"), dict):
            raise ValueError("Unsupported recipe metadata format; existing file preserved")
        return value

    def _update(self, edit):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.path.with_suffix(self.path.suffix + ".lock").open("a", encoding="utf-8") as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            value = self._load()
            answer = edit(value)
            if len(value["recipes"]) > 200:
                raise ValueError("Recipe limit reached; existing metadata preserved")
            data = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
            if len(data.encode()) > 1024 * 1024:
                raise ValueError("Recipe metadata exceeds the 1 MiB bound")
            fd, temporary = tempfile.mkstemp(prefix=".recipes-", suffix=".json", dir=self.path.parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
            return answer

    def list(self):
        value = self._load()
        return {"recipes": list(value["recipes"].values())[:200], "script_execution": False,
                "content_retention": "parameter names and aggregate outcomes only"}

    def register(self, source_path: str, app: str = "", parameter_names=None):
        if not isinstance(source_path, str) or not Path(source_path).is_absolute() or "\x00" in source_path or len(source_path) > 1024:
            raise ValueError("source_path must be an absolute local path of at most 1024 characters")
        if not isinstance(app, str) or (app and not re.fullmatch(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+", app)):
            raise ValueError("app must be a bundle identifier")
        names = [] if parameter_names is None else parameter_names
        if not isinstance(names, list) or len(names) > 32 or any(not isinstance(x, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", x) for x in names):
            raise ValueError("parameter_names must contain identifiers, never values")
        # Use an opaque local identifier. The source path is explicitly supplied
        # metadata; no file contents or unsolicited script discovery is read.
        import hashlib
        path = os.path.normpath(source_path)
        identifier = "script-" + hashlib.sha256(path.encode()).hexdigest()[:16]
        def edit(value):
            row = value["recipes"].get(identifier) or {
                "id": identifier, "source": {"kind": "model_script", "path": path},
                "status": "candidate", "reusable": False, "executable": False,
                "successes": 0, "failures": 0, "duration_ms_total": 0,
            }
            row.update(app=app, parameter_names=sorted(set(names)), updated_at=int(time.time()))
            value["recipes"][identifier] = row
            return row
        return self._update(edit)

    def record_builtin(self, app: str, action: str, *, ok: bool, verified: bool, duration_ms: float, error_code: str = ""):
        if app not in APPS or action not in ACTIONS:
            return None
        if not isinstance(duration_ms, (int, float)) or not math.isfinite(duration_ms) or duration_ms < 0:
            raise ValueError("duration_ms must be finite and nonnegative")
        # Error categories are identifiers only. Raw exception messages and
        # envelopes may contain chat content and are deliberately discarded.
        category = error_code if isinstance(error_code, str) and re.fullmatch(r"[a-z_]{1,64}", error_code) else "operation_failed"
        identifier = f"{BUILTIN_VERSION}:{app}:{action}"
        def edit(value):
            row = value["recipes"].get(identifier) or {
                "id": identifier, "source": {"kind": "builtin", "template": BUILTIN_VERSION},
                "app": app, "action": action, "parameter_names": PARAMETERS,
                "status": "candidate", "reusable": False, "executable": True,
                "template_safety_tests": "tests/test_wechat_clear_prefix.py" if action == "clear_prefix" else "tests/test_chat_workflows.py",
                "successes": 0, "verified_successes": 0, "failures": 0, "duration_ms_total": 0,
            }
            if action == "history" and row.get("verification_criterion") != "changed_visible_pages":
                # Older aggregate success did not establish that pagination
                # actually moved. Preserve usage totals while correcting that
                # unsupported maturity claim on the next observation.
                row.update(verification_criterion="changed_visible_pages", verified_successes=0,
                           status="candidate", reusable=False)
            if action == "send" and row.get("verification_criterion") != "same_chat_empty_composer_and_new_visible_message":
                row.update(verification_criterion="same_chat_empty_composer_and_new_visible_message", verified_successes=0,
                           status="candidate", reusable=False)
            row["successes" if ok else "failures"] += 1
            row["verified_successes"] += int(ok and verified)
            row["duration_ms_total"] = round(row["duration_ms_total"] + duration_ms, 3)
            row["duration_ms_last"] = round(duration_ms, 3)
            row["last_error_code"] = "" if ok else category
            row["updated_at"] = int(time.time())
            # Promotion refers only to this tested deterministic built-in. An
            # arbitrary script's statistics cannot turn it into executable code.
            if row["verified_successes"]:
                row.update(status="reusable", reusable=True)
            value["recipes"][identifier] = row
            return {"id": identifier, "status": row["status"]}
        return self._update(edit)


def execute_recipe(request: dict, store: RecipeStore | None = None):
    try:
        if not isinstance(request, dict) or set(request) - {"action", "source_path", "app", "parameter_names"}:
            raise ValueError("Unknown recipe argument")
        store = store or RecipeStore()
        if request.get("action") == "list":
            if set(request) != {"action"}:
                raise ValueError("list accepts only action")
            result = store.list()
        elif request.get("action") == "register":
            result = store.register(request.get("source_path"), request.get("app", ""), request.get("parameter_names", []))
        else:
            raise ValueError("Recipe action must be list or register")
        return {"ok": True, "result": result}
    except (ValueError, OSError, json.JSONDecodeError) as error:
        return {"ok": False, "error": {"code": "recipe_metadata_error", "message": str(error)}}
