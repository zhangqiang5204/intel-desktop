import tempfile
import unittest
from task_runtime import TaskRuntime, current_context, RuntimeCancelled


class CaptureScopeTests(unittest.TestCase):
    def test_cleanup_still_owns_fifo_on_success_failure_and_cancellation(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = TaskRuntime(directory, session_id='scope-tests')
            for ending in ('success', 'failure', 'cancelled'):
                releases = []
                def execute(context):
                    def release():
                        row = runtime.get_operation(context.operation_id, include_summary=False)
                        releases.append((row['conflict_active'], current_context() is context))
                        context.record_native({'id': 2, 'ok': True, 'result': {
                            'capture_scope_released': True, 'event_count': 0}})
                    context.on_finish('native', release)
                    context.on_finish('native', lambda: self.fail('duplicate cleanup'))
                    if ending == 'failure':
                        raise ValueError('invalid request')
                    if ending == 'cancelled':
                        raise RuntimeCancelled()
                    return {'ok': True}
                result = runtime.run('desktop_observe', {}, execute,
                                     task_id='scope-tests', operation_id=ending)
                self.assertEqual(releases, [(1, True)])
                self.assertFalse(result['summary']['conflict_active'])
                self.assertTrue(result['summary']['verified_flags']['capture_scope_released'])
                self.assertEqual(result['summary']['state'],
                                 {'success': 'completed', 'failure': 'failed', 'cancelled': 'interrupted'}[ending])
            runtime.close()

    def test_cleanup_failure_is_reported_without_replaying_executor(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = TaskRuntime(directory, session_id='scope-tests')
            executed = []
            def execute(context):
                executed.append(True)
                def failed_release():
                    raise RuntimeError('capture stop failed')
                context.on_finish('native', failed_release)
                return {'ok': True}
            result = runtime.run('desktop_observe', {}, execute,
                                 task_id='scope-tests', operation_id='failed-stop')
            self.assertEqual(executed, [True])
            self.assertEqual(result['summary']['state'], 'unknown')
            self.assertEqual(result['summary']['error_code'], 'native_scope_cleanup_failed')
            self.assertFalse(result['automatic_replay_allowed'])
            runtime.close()
