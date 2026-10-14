"""Production AX child traversal with fake count/copy APIs; no live AX reads."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('AX_CHILDREN_SOURCE_ROOT', ROOT))


def harness():
    main = (SOURCE / 'native/main.swift').read_text()
    observation = (SOURCE / 'native/NativeObservation.swift').read_text()
    helpers = 'let navigationChildAttributes' + main.split('let navigationChildAttributes', 1)[1].split('\nfunc number(', 1)[0]
    # Include the original helper too: the frozen candidate calls it and loses
    # both the second count failure and the copy failure there.
    helpers += '\nfunc axElements(' + main.split('\nfunc axElements(', 1)[1].split('\nfunc inspectionWindowList(', 1)[0]
    helpers = helpers.replace('AXUIElementGetAttributeValueCount(', 'fakeCount(').replace('AXUIElementCopyAttributeValues(', 'fakeCopy(')
    wrappers = []
    for name, body, reason, count_end in [
        ('menu', main.split('    func inspectMenus(', 1)[1].split('    func inspect(', 1)[0], 'reasons', 'if !secure'),
        ('inspect', main.split('    func inspect(', 1)[1], 'truncationReasons', 'if !secure'),
        ('observation', observation.split('    func read(_ request:', 1)[1], 'reasons', 'if depth < maxDepth'),
    ]:
        count_block = 'let counts = ' + body.split('let counts = ', 1)[1].split(count_end, 1)[0]
        traversal = ('let children = axNavigationChildren' + body.split('let children = axNavigationChildren', 1)[1]).splitlines()[:2]
        # Execute the actual per-node propagation, including the count phase
        # that runs even when the traversal is already at its depth limit.
        prefix = 'var reasons: Set<String> = [], truncationReasons: Set<String> = []; let element = item; let secure = false; '
        wrappers.append(f'func {name}CountReasons(_ item: AXUIElement) -> Set<String> {{ {prefix}\n{count_block}\nreturn {reason}\n}}')
        wrappers.append(f'func {name}ReadReasons(_ item: AXUIElement) -> Set<String> {{ {prefix}\nlet counts = axChildCounts(item); let available = 16\n' + '\n'.join(traversal) + f'\nreturn {reason}\n}}')
    menu = main.split('    func inspectMenus(', 1)[1].split('    func inspect(', 1)[0]
    guard = 'guard readResult == ' + menu.split('guard readResult == ', 1)[1].split('        let menuBar =', 1)[0]
    wrappers.append('func menuRoot(_ readResult: AXError, _ raw: CFTypeRef?) -> (elements: [[String: Any]], metadata: [String: Any], reasons: Set<String>) {\nvar metadata: [String: Any] = [:]\n' + guard + '\nreturn ([], metadata, [])\n}')
    return '\n'.join([
        'import Foundation\nimport ApplicationServices',
        (ROOT / 'tests/ax_children_fakes.swift').read_text(), helpers,
        *wrappers, (ROOT / 'tests/ax_children_completeness_main.swift').read_text(),
    ])


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'macOS Swift toolchain required')
class AXChildrenCompletenessTests(unittest.TestCase):
    def test_production_helpers_and_three_consumers(self):
        with tempfile.TemporaryDirectory(prefix='intel-ax-children-') as directory:
            directory = Path(directory)
            main = directory / 'main.swift'; main.write_text(harness())
            binary = directory / 'ax-children-tests'
            built = subprocess.run(['xcrun', 'swiftc', '-target', 'x86_64-apple-macosx13.0', str(main),
                '-framework', 'ApplicationServices', '-o', str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report['ok'], report)
            self.assertGreaterEqual(len(report['cases']), 9)
            self.assertFalse(report['live_ax_reads_performed'])

    def test_background_mutation_consumers_still_require_complete_children(self):
        body = (SOURCE / 'native/BackgroundChatEdit.swift').read_text()
        self.assertIn('guard !list.truncated else { throw fail("background_menu_unverified"', body)
        self.assertIn('guard !values.truncated else { throw fail("background_composer_unverified"', body)
        # Their unchanged guards now reject true count/copy failures as well as
        # size limits; no new mutation path or retry is introduced.


if __name__ == '__main__':
    unittest.main()
