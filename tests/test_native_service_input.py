import shutil
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(shutil.which('swiftc') and shutil.which('xcrun'), 'macOS Swift toolchain required')
class NativeServiceInputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        root = Path(cls.directory.name)
        main = root / 'main.swift'
        main.write_text('''import Foundation
let input = NativeServiceInput()
try! FileHandle.standardOutput.write(contentsOf: Data("ready\\n".utf8))
while let line = input.nextLine() {
    try! FileHandle.standardOutput.write(contentsOf: Data((line + "\\n").utf8))
}
try! FileHandle.standardOutput.write(contentsOf: Data("shutdown\\n".utf8))
''')
        cls.binary = root / 'input-probe'
        source = Path(__file__).resolve().parents[1] / 'native/NativeServiceInput.swift'
        subprocess.run(['xcrun', 'swiftc', str(source), str(main), '-o', str(cls.binary)],
                       check=True, capture_output=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def child(self):
        child = subprocess.Popen([str(self.binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.assertEqual(child.stdout.readline(), b'ready\n')
        return child

    def finish(self, child):
        if child.poll() is None:
            child.kill(); child.wait()
        child.stdin.close(); child.stdout.close()

    def test_unicode_multiline_protocol_is_preserved_on_eof(self):
        child = self.child()
        try:
            child.stdin.write('中文\nsecond\n'.encode()); child.stdin.flush(); child.stdin.close()
            self.assertEqual(child.wait(timeout=3), 0)
            self.assertEqual(child.stdout.read(), '中文\nsecond\nshutdown\n'.encode())
        finally:
            self.finish(child)

    def test_idle_stdin_does_not_block_sigterm_shutdown_callback(self):
        child = self.child()
        try:
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=3), 0)
            self.assertEqual(child.stdout.read(), b'shutdown\n')
        finally:
            self.finish(child)
