"""Portable configuration and offline-only launch checks; no native process runs."""
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from configure import check_source, configuration, toml_configuration
from desktop_client import MCPClient
from desktop_transactions import validate_plan
from run_native_self_tests import SUITES, run_suites


class PackagingTests(unittest.TestCase):
    def test_dynamic_config_is_absolute_and_never_modifies_user_configuration(self):
        config = configuration(ROOT)
        server = config["mcpServers"]["intel_desktop"]
        self.assertEqual(Path(server["args"][0]), ROOT / "scripts/server.py")
        self.assertTrue(Path(server["command"]).is_absolute())
        self.assertEqual(server["cwd"], str(ROOT))
        report = check_source(ROOT)
        self.assertTrue(report["source_ready"])
        self.assertFalse(report["user_configuration_modified"])
        self.assertFalse(report["native_execution_started"])
        self.assertIn('[mcp_servers.intel_desktop]', toml_configuration(config))

    def test_current_manifests_match_and_keep_plugin_root_placeholder(self):
        portable = json.loads((ROOT / "plugin.json").read_text())
        legacy = json.loads((ROOT / ".codex-plugin/plugin.json").read_text())
        self.assertEqual(portable["name"], legacy["name"])
        self.assertEqual(portable["version"], legacy["version"])
        for name in ("mcp.json", ".mcp.json"):
            config = json.loads((ROOT / name).read_text())["mcpServers"]["intel_desktop"]
            self.assertEqual(config["args"], ['${PLUGIN_ROOT}/scripts/server.py'])
            self.assertEqual(config["cwd"], '${PLUGIN_ROOT}')

    def test_fresh_mcp_initialize_and_tools_list_work_without_native_binary_or_runtime(self):
        config = json.loads((ROOT / ".mcp.json").read_text())["mcpServers"]["intel_desktop"]
        client = MCPClient(config)
        try:
            initialized = client.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}})
            listed = client.request("tools/list", {})
            self.assertEqual(initialized["serverInfo"]["name"], "intel-desktop")
            self.assertEqual(len(listed["tools"]), 27)
            self.assertIn("desktop_select_text", {tool["name"] for tool in listed["tools"]})
        finally:
            client.close()

    def test_examples_are_valid_parameterized_plans_with_no_invocation_values(self):
        paths = sorted((ROOT / "plans").glob("*.json"))
        self.assertEqual(len(paths), 3)
        for path in paths:
            plan = json.loads(path.read_text())
            self.assertNotIn("parameters", plan)
            validate_plan(plan)

    def test_public_source_contains_no_host_identity_or_private_framework_path(self):
        needles = ("/Users/" + "zhangqiang/", "Documents" + "/Codex/", "/System/Library/" + "PrivateFrameworks/")
        for directory in ("native", "scripts", "skills", "plans", "tests", ".codex-plugin"):
            for path in (ROOT / directory).rglob("*"):
                if path.is_file() and path.suffix in {".py", ".swift", ".sh", ".md", ".json"}:
                    self.assertFalse(any(needle in path.read_text() for needle in needles), path.relative_to(ROOT))
        manifest = json.loads((ROOT / "SOURCE_MANIFEST.json").read_text())
        self.assertFalse(any(entry["destination"].startswith("bin/") for entry in manifest["files"]))

    def test_native_driver_only_selects_whitelisted_pure_flags(self):
        self.assertEqual(SUITES["native-interaction"], "--native-interaction-self-test")
        self.assertEqual(SUITES["visual"], "--visual-self-test")
        self.assertEqual(SUITES["window-snapshot"], "--visual-window-snapshot-self-test")
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "fake-helper"
            helper.write_text("This is never executed; subprocess is mocked.")
            completed = types.SimpleNamespace(returncode=0, stdout=json.dumps({"ok": True, "events_posted": 0, "case_count": 3}))
            with patch("run_native_self_tests.subprocess.run", return_value=completed) as invoke:
                report = run_suites(helper, list(SUITES))
            self.assertTrue(report["ok"])
            self.assertEqual(report["HID_events"], 0)
            self.assertEqual([call.args[0][1] for call in invoke.call_args_list], list(SUITES.values()))
            with patch("run_native_self_tests.subprocess.run") as invoke:
                with self.assertRaises(ValueError):
                    run_suites(helper, ["live-desktop"])
                invoke.assert_not_called()

    def test_native_driver_never_reports_posted_input_or_live_capture_as_a_pure_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "fake-helper"
            helper.write_text("Not executed")
            for payload in ({"ok": True, "events_posted": 2},
                            *[{"ok": True, "events_posted": 0, field: True} for field in
                              ("capture_executed", "UI_created", "AX_reads_executed", "event_tap_created")]):
                completed = types.SimpleNamespace(returncode=0, stdout=json.dumps(payload))
                with patch("run_native_self_tests.subprocess.run", return_value=completed):
                    report = run_suites(helper, ["geometry"])
                self.assertFalse(report["ok"])
                if payload["events_posted"]:
                    self.assertEqual(report["HID_events"], 2)
                if any(payload.get(field) is True for field in ("capture_executed", "UI_created", "AX_reads_executed", "event_tap_created")):
                    self.assertIsNone(report["GUI_operations"])


if __name__ == "__main__":
    unittest.main()
