"""Run actual atomic pretype/Unicode and terminal-receipt wiring without UI."""
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
    desktop = (ROOT / "native/VisualDesktop.swift").read_text()
    main = (ROOT / "native/main.swift").read_text()
    blocks = [declaration(main, marker) for marker in (
        "struct HelperError", "func fail(", "func string(", "func boolean(", "func number(", "func rectJSON(")]
    blocks += [declaration(desktop, marker) for marker in (
        "func visualRect(", "func visualNormalizedText(", "func visualContains(", "func visualSubtract(", "func visualCovered(",
        "func visualSubmitHeader(", "func visualFreshPreinputFrame(", "func visualPostedSubmitReceipt(")]
    start = desktop.index("                if focusBeforeType {", desktop.index("let baselineSerial ="))
    end = desktop.index('\n            } else if command == "visual_key", requestedKey == "clear_draft"', start)
    producer = desktop[start:end]
    receipt = declaration(desktop, "            if submit, let started = inputDispatchStarted")
    validation = declaration(desktop.split("    func validate(", 1)[1], "            if focusBeforeType {")
    template = (ROOT / "tests/wechat_atomic_native_main.swift").read_text()
    return (template.replace("// PRODUCTION_SUPPORT", "\n".join(blocks))
            .replace("        // PRODUCTION_ATOMIC_TYPE", producer)
            .replace("        // PRODUCTION_TERMINAL_RECEIPT", receipt)
            .replace("        // PRODUCTION_ATOMIC_VALIDATION", validation)
            .replace("    // PRODUCTION_SECURITY", declaration(desktop, "    func denySensitiveRows(")))


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "macOS Swift toolchain required")
class AtomicNativeTests(unittest.TestCase):
    def test_production_ordering_counting_guards_and_terminal_submit(self):
        with tempfile.TemporaryDirectory(prefix="intel-atomic-edit-") as temporary:
            directory = Path(temporary)
            source = directory / "main.swift"
            source.write_text(harness())
            binary = directory / "atomic-edit-tests"
            built = subprocess.run(["xcrun", "swiftc", "-target", "x86_64-apple-macosx13.0", str(source),
                                    "-o", str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report["ok"], report)
            self.assertGreaterEqual(len(report["cases"]), 20)
            self.assertFalse(report["capture_performed"])
            self.assertFalse(report["input_performed"])


if __name__ == "__main__":
    unittest.main()
