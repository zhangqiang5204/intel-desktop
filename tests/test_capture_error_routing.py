"""Run production error boundaries/settlers with fake capture; no GUI or HID.

The older tests called the settlers directly, skipping the capture boundary that
converted their control errors into OS failures. Extract that exact catch chain
as well as its consumer so reverting the production fix fails this test.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('CAPTURE_ROUTING_SOURCE_ROOT', ROOT))


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


def production_harness():
    capture = (SOURCE / 'native/NativeWindowCapture.swift').read_text()
    desktop = (SOURCE / 'native/VisualDesktop.swift').read_text()
    main = (SOURCE / 'native/main.swift').read_text()
    warm = between(capture, 'func visualWarmWindowCapture(', '\nfunc visualWarmCaptureSelfTests()')
    catch_chain = '\n    } catch' + warm.split('\n    } catch', 1)[1]
    frame = between(desktop, '    func captureFrame(', '\n    func visibleFrame(')
    frame_control_catches = '} catch' + frame.split('} catch', 1)[1].split('catch var error as HelperError', 1)[0]
    return '\n'.join([
        'import Foundation\nimport CoreFoundation\nimport ScreenCaptureKit',
        'struct HelperError' + between(main, 'struct HelperError', '\nfunc string('),
        'private struct VisualCaptureSystemFailure' + between(capture, 'private struct VisualCaptureSystemFailure', '\nprivate enum VisualWarmCaptureStage'),
        'private enum VisualWarmCaptureStage' + between(capture, 'private enum VisualWarmCaptureStage', '\n// The observed cold-start'),
        'func visualCaptureConnectionRecovery' + between(capture, 'func visualCaptureConnectionRecovery', '\n// Each request'),
        'struct VisualWarmEpoch' + between(capture, 'struct VisualWarmEpoch', '\nprivate final class VisualWarmReceiver'),
        'final class VisualCaptureMetrics' + between(capture, 'final class VisualCaptureMetrics', '\nstruct VisualWarmCapture'),
        'struct VisualSearchObservationChanged' + between(desktop, 'struct VisualSearchObservationChanged', '\nfunc visualSearchPopupHeightRace'),
        'struct VisualNavigationHintObservationChanged' + between(desktop, 'struct VisualNavigationHintObservationChanged', '\nfunc visualSystemCursorWindow'),
        # Replace only the framework body with an injectable producer, preserving
        # every real catch clause including timing/metadata and Swift bridging.
        'func captureBoundary<T>(stage: String = "before_shareable_content", _ attempt: () throws -> T) throws -> T {\n'
        '    let timing = VisualCaptureMetrics()\n'
        '    let captureStage = VisualWarmCaptureStage(rawValue: stage)!\n'
        '    do { return try attempt()' + catch_chain,
        'func frameBoundary<T>(_ attempt: () throws -> T) throws -> T {\n'
        '    do { return try attempt()\n' + frame_control_catches + 'catch { throw error }\n}',
        (ROOT / 'tests/capture_error_routing_main.swift').read_text(),
    ])


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'macOS Swift toolchain required')
class CaptureErrorRoutingTests(unittest.TestCase):
    def test_production_boundaries_and_consumers(self):
        with tempfile.TemporaryDirectory(prefix='intel-capture-routing-') as directory:
            directory = Path(directory)
            main = directory / 'main.swift'
            main.write_text(production_harness())
            binary = directory / 'capture-routing-tests'
            built = subprocess.run([
                'xcrun', 'swiftc', '-target', 'x86_64-apple-macosx13.0',
                str(SOURCE / 'native/CaptureLifecycle.swift'), str(main),
                '-framework', 'ScreenCaptureKit', '-o', str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report['ok'], report)
            self.assertGreaterEqual(len(report['cases']), 10)
            self.assertFalse(report['capture_performed'])
            self.assertFalse(report['input_performed'])


if __name__ == '__main__':
    unittest.main()
