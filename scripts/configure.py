#!/usr/bin/env python3
"""Print portable local MCP configuration. Never writes user settings or installs."""
from __future__ import annotations

import argparse
import ast
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def configuration(root=ROOT, interpreter=None):
    root = Path(root).resolve()
    server = root / "scripts/server.py"
    if not server.is_file():
        raise ValueError("Selected plugin root has no scripts/server.py")
    return {"mcpServers": {"intel_desktop": {
        "command": str(Path(interpreter or sys.executable).resolve()),
        "args": [str(server)], "cwd": str(root), "enabled": True,
        "startup_timeout_sec": 10, "tool_timeout_sec": 180,
    }}}


def toml_configuration(config):
    server = config["mcpServers"]["intel_desktop"]
    return "\n".join([
        "[mcp_servers.intel_desktop]",
        "command = " + json.dumps(server["command"]),
        "args = " + json.dumps(server["args"]),
        "cwd = " + json.dumps(server["cwd"]),
        "enabled = true", "startup_timeout_sec = 10", "tool_timeout_sec = 180", "",
    ])


def check_source(root=ROOT):
    root = Path(root).resolve()
    manifest = json.loads((root / ".codex-plugin/plugin.json").read_text())
    configuration(root)
    scripts = sorted((root / "scripts").glob("*.py"))
    for path in scripts:
        ast.parse(path.read_text(), filename=path.name)
    for path in (root / "plans").glob("*.json"):
        plan = json.loads(path.read_text())
        if plan.get("format") != "desktop_plan/v1" or "parameters" in plan:
            raise ValueError("Example plans must retain placeholders, not invocation values")
    return {"source_ready": True, "version": manifest["version"],
            "python_sources": len(scripts), "native_build_script_present": (root / "native/build.sh").is_file(),
            "helper_built": (root / "bin/IntelDesktopHelper").is_file(),
            "user_configuration_modified": False, "native_execution_started": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="Plugin source/installed root; resolved dynamically")
    parser.add_argument("--format", choices=("json", "toml"), default="json")
    parser.add_argument("--check", action="store_true", help="Check source/configuration without building or calling native code")
    options = parser.parse_args(argv)
    try:
        if options.check:
            print(json.dumps(check_source(options.root), indent=2))
        else:
            config = configuration(options.root)
            print(json.dumps(config, indent=2) if options.format == "json" else toml_configuration(config), end="\n")
    except (OSError, ValueError, SyntaxError, KeyError):
        parser.exit(2, "Configuration check failed: selected source is incomplete or invalid.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
