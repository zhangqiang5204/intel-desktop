"""Exercise actual native proof creation, match and one-use lifecycle without UI."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('CONTINUOUS_SUBMIT_SOURCE_ROOT', ROOT))


def declaration(text, marker):
    start = text.index(marker)
    opened = text.index('{', start)
    depth = 1
    for cursor in range(opened + 1, len(text)):
        depth += (text[cursor] == '{') - (text[cursor] == '}')
        if depth == 0:
            return text[start:cursor + 1]
    raise ValueError(marker)


def harness():
    desktop = (SOURCE / 'native/VisualDesktop.swift').read_text()
    main = (SOURCE / 'native/main.swift').read_text()
    current = (ROOT / 'native/VisualDesktop.swift').read_text()
    blocks = [declaration(main, marker) for marker in [
        'struct HelperError', 'func fail(', 'func integer(', 'func boolean(',
        'func number(', 'func rectJSON(', 'func pointIsInsideRect(']]
    blocks += [declaration(desktop, marker) for marker in [
        'struct VisualIdentity', 'func visualRect(', 'func visualContains(', 'func visualNormalizedText(',
        'func visualSubtract(', 'func visualCovered(', 'func visualSubmitHeader(', 'func visualControlSafetyRegion(',
        'struct VisualScreenWindow', 'func visualAuxiliaryExclusionMetadata(',
        'struct VisualFrame', 'struct VisualSnapshot', 'struct VisualNativeCommandScope',
        'func visualContinuousSubmitRowsComplete(', 'struct VisualContinuousSubmitProof',
        'func visualContinuousSubmitSceneMatches(', 'func visualCornerSubmitNeedsFreshRevalidation(']]
    # The baseline intentionally keeps its original one-second predicates;
    # the candidate tests must distinguish them from the repaired predicates.
    constant = next(line for line in current.splitlines() if line.startswith('let visualContinuousSubmitMaximumFrameAge:'))
    if 'let visualContinuousSubmitMaximumFrameAge:' in desktop:
        constant = next(line for line in desktop.splitlines() if line.startswith('let visualContinuousSubmitMaximumFrameAge:'))
    scope = declaration(desktop, '    func beginNativeCommand(')
    take = declaration(desktop, '    private func takeContinuousSubmitProof(')
    lifecycle = declaration(desktop, '    fileprivate func continuousSubmitLifecycleSelfTests(')
    preparation = desktop.split('                let proofNow = ProcessInfo.processInfo.systemUptime', 1)[1]
    preparation = preparation.split('                result["continuous_submit_proof_prepared"]', 1)[0]
    template = (ROOT / 'tests/continuous_submit_window_main.swift').read_text()
    return (template.replace('// PRODUCTION_TYPES', '\n'.join(blocks) + '\n' + constant)
            .replace('    // PRODUCTION_SCOPE_AND_LIFECYCLE', '\n'.join([scope, take, lifecycle]))
            .replace('    // PRODUCTION_PREPARATION', preparation)
            .replace('// PRODUCTION_SELF_TESTS', declaration(current, 'func visualContinuousSubmitSelfTests()')))


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'macOS Swift toolchain required')
class ContinuousSubmitWindowTests(unittest.TestCase):
    def test_production_creation_match_and_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix='intel-submit-proof-') as temporary:
            directory = Path(temporary)
            main = directory / 'main.swift'; main.write_text(harness())
            binary = directory / 'submit-proof-tests'
            built = subprocess.run(['xcrun', 'swiftc', '-target', 'x86_64-apple-macosx13.0', str(main),
                                    '-framework', 'ApplicationServices', '-o', str(binary)],
                                   capture_output=True, text=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report['ok'], report)
            self.assertGreaterEqual(len(report['cases']), 50)
            self.assertFalse(report['capture_performed'])
            self.assertFalse(report['input_performed'])


if __name__ == '__main__':
    unittest.main()
