"""Execute production focus/return code against deterministic AX/app fakes."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def declaration(text, marker):
    start = text.index(marker)
    opened = text.index("{", start)
    depth = 1
    for cursor in range(opened + 1, len(text)):
        depth += (text[cursor] == "{") - (text[cursor] == "}")
        if depth == 0:
            return text[start:cursor + 1]
    raise ValueError(marker)


def harness():
    source = (ROOT / "native/main.swift").read_text()
    support = [declaration(source, marker) for marker in (
        "struct HelperError", "func fail(", "func string(", "func focusOriginAppMatches(",
        "func focusRecordTaskMatches(", "func focusRestoreKeepsWindow(", "func focusRestoreShouldRaise(",
        "func focusRestoreSuppression(", "func failedFocusReturnSuppression(", "struct FocusAcquisitionActivity",
        "struct FocusAcquisitionLanding", "struct FailedFocusAcquisition", "struct PreviousFocusRecord")]
    monitor = [declaration(source, marker) for marker in (
        "    func prepareExplicitFocus(", "    func focusAcquisitionUnchanged(",
        "    func completeExplicitFocus(", "    func discardClaim(", "    func check()", "    func end()")]
    owner = [declaration(source, marker) for marker in (
        "    func capturePreviousFocus(", "    private func acquisitionWindowMatches(",
        "    private func failedAcquisitionFocusMatches(", "    private func failedAcquisitionReturnReason(",
        "    private func restorePreviousFocus(", "    func focus(_ target:", "    func prepareFocusNoticeRelease()")]
    release = declaration(source, '        if command == "_finish_operation" {')
    shutdown = next(line for line in source.splitlines() if line.startswith("serviceInput.onShutdown ="))
    eof = source[source.rindex("helper.prepareFocusNoticeRelease()\nhelper.monitor.stop()"):
                 source.rindex("helper.monitor.stop()") + len("helper.monitor.stop()")]
    template = (ROOT / "tests/failed_focus_native_main.swift").read_text()
    return (template.replace("// PRODUCTION_SUPPORT", "\n".join(support))
            .replace("    // PRODUCTION_MONITOR", "\n".join(monitor))
            .replace("    // PRODUCTION_OWNER", "\n".join(owner))
            .replace("        // PRODUCTION_RELEASE", release)
            .replace("    // PRODUCTION_SHUTDOWN", shutdown)
            .replace("    // PRODUCTION_EOF", eof))


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "macOS Swift toolchain required")
class FailedFocusNativeTests(unittest.TestCase):
    def test_actual_focus_failure_guarded_return_and_notice_drain_order(self):
        with tempfile.TemporaryDirectory(prefix="intel-focus-return-") as temporary:
            directory = Path(temporary)
            source = directory / "main.swift"
            source.write_text(harness())
            binary = directory / "focus-return-tests"
            built = subprocess.run(["xcrun", "swiftc", "-target", "x86_64-apple-macosx13.0", str(source),
                                    "-o", str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report["ok"], report)
            self.assertGreaterEqual(len(report["cases"]), 25)
            self.assertFalse(report["UI_created"])
            self.assertEqual(report["HID_events"], 0)


if __name__ == "__main__":
    unittest.main()
