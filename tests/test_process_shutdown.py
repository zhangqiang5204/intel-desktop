import subprocess
import sys
import unittest

from process_shutdown import drain_process_after_eof


class ProcessShutdownTests(unittest.TestCase):
    def child(self, source):
        return subprocess.Popen([sys.executable, '-c', source], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, bufsize=0)

    def test_full_unread_response_does_not_block_eof_cleanup(self):
        child = self.child('import sys; sys.stdout.buffer.write(b"x"*1048576); '
                           'sys.stdout.buffer.flush(); sys.stdin.buffer.read()')
        try:
            self.assertTrue(drain_process_after_eof(child, timeout=3))
            self.assertEqual(child.returncode, 0)
        finally:
            if child.poll() is None:
                child.kill(); child.wait()

    def test_pending_cleanup_is_not_killed_or_reported_complete(self):
        child = self.child('import sys,time; sys.stdin.buffer.read(); time.sleep(.15)')
        try:
            self.assertFalse(drain_process_after_eof(child, timeout=.03))
            self.assertIsNone(child.poll())
            self.assertFalse(child.stdout.closed)
            self.assertTrue(drain_process_after_eof(child, timeout=3))
            self.assertEqual(child.returncode, 0)
        finally:
            if child.poll() is None:
                child.kill(); child.wait()


if __name__ == '__main__':
    unittest.main()
