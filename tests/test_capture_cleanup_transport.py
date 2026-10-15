import io
import json
import os
import tempfile
import types
import unittest
from unittest.mock import patch

import server
import task_runtime
from task_runtime import TaskRuntime


class Selector:
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def register(self, *args): pass


class CaptureCleanupTransportTests(unittest.TestCase):
    def bridge(self):
        bridge = server.NativeBridge()
        bridge.process = types.SimpleNamespace(stdin=io.BytesIO(), stdout=io.BytesIO(),
                                               pid=4242, poll=lambda: None)
        return bridge

    def test_ax_focus_scope_finalizes_notice_on_success_and_known_failure(self):
        for ok in (True, False):
            with self.subTest(ok=ok), tempfile.TemporaryDirectory() as directory:
                bridge = self.bridge()
                first = {'id': 1, 'ok': ok, 'result': {}} if ok else {
                    'id': 1, 'ok': False, 'error': {'code': 'user_interrupted', 'details': {'events_posted': 0}}}
                bridge.buffer = (json.dumps(first) + '\n' + json.dumps({'id': 2, 'ok': True, 'result': {
                    'capture_scope_released': True, 'notice_scope_released': True}}) + '\n').encode()
                runtime = TaskRuntime(directory, session_id='notice-tests')
                original = task_runtime._process
                with patch.object(server.selectors, 'DefaultSelector', Selector), patch.object(
                        task_runtime, '_process', side_effect=lambda pid: ('fake-native', os.getpid())
                        if pid == 4242 else original(pid)):
                    packet = runtime.run('desktop_focus', {}, lambda ctx: bridge.call('focus', {
                        'app': 'com.apple.TextEdit', 'window_title': 'fixture'}),
                        task_id='notice-tests', operation_id='notice-focus')
                commands = [json.loads(line)['command'] for line in bridge.process.stdin.getvalue().splitlines()]
                self.assertEqual(commands, ['focus', '_finish_operation'])
                self.assertFalse(packet['summary']['conflict_active'])
                self.assertTrue(packet['summary']['verified_flags']['capture_scope_released'])
                runtime.close()

    def test_generic_image_inspect_also_releases_its_capture_scope(self):
        bridge = self.bridge()
        bridge.buffer = b''.join((json.dumps({'id':i, 'ok':True, 'result':value})+'\n').encode()
                                  for i, value in [(1, {}), (2, {'capture_scope_released':True})])
        with tempfile.TemporaryDirectory() as directory:
            runtime = TaskRuntime(directory, session_id='capture-tests')
            original = task_runtime._process
            with patch.object(server.selectors, 'DefaultSelector', Selector), patch.object(
                    task_runtime, '_process', side_effect=lambda pid:('fake-native', os.getpid())
                    if pid==4242 else original(pid)):
                packet = runtime.run('desktop_inspect', {}, lambda ctx:bridge.call(
                    'inspect', {'app':'com.apple.TextEdit', 'window_title':'sample', 'include_image':True}),
                    task_id='capture-tests', operation_id='generic-image')
            commands = [json.loads(line)['command'] for line in bridge.process.stdin.getvalue().splitlines()]
            self.assertEqual(commands, ['inspect', '_finish_operation'])
            self.assertTrue(packet['summary']['verified_flags']['capture_scope_released'])
            runtime.close()

    def test_unfinished_capture_cleanup_retains_fifo_until_native_exit(self):
        bridge = self.bridge()
        with tempfile.TemporaryDirectory() as directory:
            runtime = TaskRuntime(directory, session_id='capture-tests')
            original = task_runtime._process
            def stage(ctx):
                ctx.register_native_pid(4242)
                ctx.record_native({'id':1,'ok':True,'result':{}})
                ctx.on_finish('native', lambda:bridge._finish_capture_scope(ctx, bridge.process))
                return {'ok':True}
            with patch.object(task_runtime, '_process', side_effect=lambda pid:('fake-native', os.getpid())
                              if pid==4242 else original(pid)), patch.object(
                    bridge, '_exchange', return_value={'ok':False}), patch.object(bridge, 'close', return_value=False):
                packet = runtime.run('desktop_inspect', {}, stage,
                                     task_id='capture-tests', operation_id='pending-cleanup')
            self.assertEqual(packet['summary']['state'], 'unknown')
            self.assertTrue(packet['summary']['native_pending'])
            self.assertTrue(packet['summary']['conflict_active'])
            self.assertFalse(packet['automatic_replay_allowed'])
            runtime.close()

    def test_closing_helper_cannot_be_reused_or_replaced(self):
        bridge = self.bridge()
        process = bridge.process
        process.stdin.close()
        with self.assertRaisesRegex(RuntimeError, 'draining capture'):
            bridge.start()
        self.assertIs(bridge.process, process)

    def test_atomic_background_chat_edit_finishes_capture_on_known_outcomes(self):
        cases = [
            ({'operation':'type','text':'fixture'}, {'ok':True,'result':{}}),
            ({'operation':'clear','expected_draft':''}, {'ok':True,'result':{}}),
            ({'operation':'clear','expected_draft':'fixture'},
             {'ok':False,'error':{'code':'background_draft_changed','details':{'events_posted':0}}}),
        ]
        for index, (arguments, native) in enumerate(cases):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                bridge = self.bridge()
                bridge.buffer = (json.dumps({'id':1, **native})+'\n'+json.dumps(
                    {'id':2,'ok':True,'result':{'capture_scope_released':True}})+'\n').encode()
                runtime = TaskRuntime(directory, session_id='capture-tests')
                original = task_runtime._process
                with patch.object(server.selectors, 'DefaultSelector', Selector), patch.object(
                        task_runtime, '_process', side_effect=lambda pid:('fake-native', os.getpid())
                        if pid==4242 else original(pid)):
                    packet = runtime.run('desktop_chat', {}, lambda ctx:bridge.call(
                        'background_chat_edit', {'app':'com.tencent.xinWeChat',
                                                 'window_title':'微信', **arguments}),
                        task_id='capture-tests', operation_id='atomic-background-edit')
                commands = [json.loads(line)['command'] for line in bridge.process.stdin.getvalue().splitlines()]
                self.assertEqual(commands, ['background_chat_edit', '_finish_operation'])
                self.assertTrue(packet['summary']['verified_flags']['capture_scope_released'])
                self.assertFalse(packet['summary']['native_pending'])
                runtime.close()
