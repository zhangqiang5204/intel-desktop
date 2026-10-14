"""Run the actual ROI scheduler and post-edit call with fake OCR; no UI/capture."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('POST_EDIT_OCR_SOURCE_ROOT', ROOT))


def harness():
    desktop = (SOURCE / 'native/VisualDesktop.swift').read_text()
    capture = (SOURCE / 'native/NativeWindowCapture.swift').read_text()
    scheduler = '    func ocrRegions(' + desktop.split('    func ocrRegions(', 1)[1].split('\n    func anchors(', 1)[0]
    completion = 'final class VisualCompletion' + desktop.split('final class VisualCompletion', 1)[1].split('\nfunc visualAwait', 1)[0]
    metrics = 'final class VisualCaptureMetrics' + capture.split('final class VisualCaptureMetrics', 1)[1].split('\nstruct VisualWarmCapture', 1)[0]
    header = 'func visualSubmitHeader' + desktop.split('func visualSubmitHeader', 1)[1].split('\nfunc visualMergeOCRRows', 1)[0]
    # Execute the real producer wiring too: detecting only an unused scheduler
    # option would not prove that the intended post-edit batch reaches it.
    producer = desktop.split('if parallelComposerProof {', 1)[1].split('recordOCRStages(', 1)[0]
    producer = producer.replace('old.identity', 'identity').replace('try ocrRegions(', 'try harness.ocrRegions(')
    template = (ROOT / 'tests/post_edit_ocr_scheduling_main.swift').read_text()
    return (template.replace('// PRODUCTION_SUPPORT', completion + '\n' + metrics + '\n' + header)
            .replace('    // PRODUCTION_SCHEDULER', scheduler)
            .replace('    // PRODUCTION_POST_EDIT_CALL', producer))


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'macOS Swift toolchain required')
class PostEditOCRSchedulingTests(unittest.TestCase):
    def test_real_scheduler_and_producer(self):
        with tempfile.TemporaryDirectory(prefix='intel-post-edit-ocr-') as temporary:
            directory = Path(temporary)
            main = directory / 'main.swift'; main.write_text(harness())
            binary = directory / 'post-edit-ocr-tests'
            built = subprocess.run(['xcrun', 'swiftc', '-target', 'x86_64-apple-macosx13.0',
                                    str(main), '-o', str(binary)], capture_output=True, text=True, timeout=90)
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
