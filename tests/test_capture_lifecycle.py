"""Execute the production lifecycle with fake transports; never capture pixels."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'macOS Swift toolchain required')
class CaptureLifecycleTests(unittest.TestCase):
    def test_async_lifecycle_sequences(self):
        with tempfile.TemporaryDirectory(prefix='intel-capture-lifecycle-') as directory:
            directory = Path(directory)
            main = directory / 'main.swift'
            main.write_text((ROOT / 'tests/capture_lifecycle_main.swift').read_text())
            binary = directory / 'capture-lifecycle-tests'
            built = subprocess.run(['xcrun', 'swiftc', '-target', 'x86_64-apple-macosx13.0', str(ROOT / 'native/CaptureLifecycle.swift'),
                                    str(main), '-o', str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertTrue(report['ok'], report)
            required = {
                'pending_cleanup_wait_accepts_delayed_stop_before_next_registration',
                'pending_cleanup_wait_timeout_retains_entry_and_registration_gate',
                'pending_cleanup_wait_does_not_retry_failed_stop',
                'pending_cleanup_wait_never_stops_existing_running_stream',
                'pending_cleanup_wait_shutdown_rejects_even_after_all_stops_finish',
                'pending_cleanup_wait_cancelled_start_needs_both_callbacks',
                'pending_cleanup_wait_detects_shutdown_while_polling',
                'pending_cleanup_wait_pumps_default_runloop_without_capturing',
            }
            self.assertTrue(required.issubset(report['cases']), required - report['cases'].keys())
            self.assertTrue(all(report['cases'][name] is True for name in required))
            self.assertGreaterEqual(len(report['cases']), 23)
            self.assertEqual(report['failures'], {})
            self.assertFalse(report['capture_performed'])
            self.assertFalse(report['input_performed'])

    def test_all_framework_start_stop_calls_are_managed(self):
        # Prevent a new capture path from bypassing the lifecycle tested above.
        native = (ROOT / 'native/NativeWindowCapture.swift').read_text()
        desktop = (ROOT / 'native/VisualDesktop.swift').read_text()
        self.assertEqual(native.count('.startCapture('), 1)
        self.assertEqual(native.count('.stopCapture('), 1)
        self.assertNotIn('.startCapture(', desktop)
        self.assertNotIn('.stopCapture(', desktop)
        self.assertIn('try visualCaptureRegister(stream)', native)
        self.assertIn('visualCaptureDidStop(stream)', native)
        self.assertIn('visualCaptureDidStop(stream)', desktop)

    def test_framework_registration_waits_before_strict_registry_admission(self):
        # The pure sequence harness alone cannot detect a disconnected real
        # SCStream wrapper. Check this observed failure's producer/consumer link.
        native = (ROOT / 'native/NativeWindowCapture.swift').read_text()
        body = native.split('func visualCaptureRegister(', 1)[1].split('func visualCaptureStart(', 1)[0]
        compact = ''.join(body.split())
        wait = 'guardvisualCaptureLifecycles.waitForPendingCleanup(timeout:1.5)else'
        self.assertIn(wait, compact)
        self.assertLess(compact.index(wait), compact.index('tryvisualCaptureLifecycles.register('))
        self.assertIn('throwCaptureLifecycle.Failure.cleanupPending', compact)
        self.assertIn('throwfail("capture_cleanup_pending"', compact)
        self.assertNotIn('.drain(', compact)


if __name__ == '__main__':
    unittest.main()
