import io,json,types,unittest,tempfile,os
import task_runtime
from task_runtime import TaskRuntime
from unittest.mock import patch,Mock
import server
class Selector:
 def __enter__(self):return self
 def __exit__(self,*a):pass
 def register(self,*a):pass
class NativeTaskContextTests(unittest.TestCase):
 def bridge(self):
  b=server.NativeBridge();b.process=types.SimpleNamespace(stdin=io.BytesIO(),stdout=io.BytesIO(),pid=4242,poll=lambda:None)
  return b
 def call(self,b,ctx,seq):
  b.buffer=(json.dumps({'id':seq,'ok':True,'result':{}})+'\n').encode()
  with patch.object(server,'current_context',return_value=ctx),patch.object(server.selectors,'DefaultSelector',Selector):return b.call('status',{})
 def test_actual_bridge_attaches_each_current_task_after_validation(self):
  b=self.bridge()
  for n,task in enumerate(['logical-task-a','logical-task-b'],1):
   ctx=Mock();ctx.task_id=task;ctx.operation_id="logical-op-"+str(n);self.assertTrue(self.call(b,ctx,n)['ok']);ctx.boundary.assert_called_once_with('status')
  rows=[json.loads(x) for x in b.process.stdin.getvalue().splitlines()]
  self.assertEqual([x['_runtime_task_id'] for x in rows],['logical-task-a','logical-task-b'])
  self.assertEqual([x['id'] for x in rows],[1,2])
  self.assertEqual([x['_runtime_operation_id'] for x in rows],['logical-op-1','logical-op-2'])
 def test_direct_bridge_enters_actual_global_queue_and_binds_native_task(self):
  b=self.bridge();b.buffer=(json.dumps({'id':1,'ok':True,'result':{}})+'\n').encode()
  with tempfile.TemporaryDirectory() as directory:
   engine=TaskRuntime(directory,session_id='direct-script-owner')
   original=task_runtime._process
   with patch.object(server,'runtime',return_value=engine),patch.object(server.selectors,'DefaultSelector',Selector),patch.object(task_runtime,'_process',side_effect=lambda pid:('fake-native',os.getpid()) if pid==4242 else original(pid)):
    response=b.call('status',{})
   self.assertTrue(response['ok'])
   self.assertEqual(response['execution']['state'],'completed')
   self.assertEqual(response['execution']['task_id'],'direct-script-owner')
   self.assertEqual(json.loads(b.process.stdin.getvalue())['_runtime_task_id'],'direct-script-owner')
   events=engine.logs(task_id='direct-script-owner')['events']
   self.assertEqual(events[0]['phase'],'enqueue')
   self.assertTrue(any(e['phase']=='claim' for e in events))
 def test_public_caller_cannot_override_internal_task_correlation(self):
  b=self.bridge()
  with self.assertRaisesRegex(ValueError,'Unknown argument'):b.call('status',{'_runtime_task_id':'someone-else'})
  self.assertEqual(b.process.stdin.getvalue(),b'')
 def test_visual_bridge_releases_once_after_all_steps_under_same_lease(self):
  b=self.bridge()
  b.buffer=b''.join((json.dumps({'id':n,'ok':True,'result':({'capture_scope_released':True} if n==3 else {})})+'\n').encode() for n in range(1,4))
  with tempfile.TemporaryDirectory() as directory:
   engine=TaskRuntime(directory,session_id='scope-owner');original=task_runtime._process
   def stage(ctx):
    for _ in range(2):self.assertTrue(b.call('background_visual_read',{'app':'com.tencent.xinWeChat','window_title':'微信'})['ok'])
    self.assertEqual(len(b.process.stdin.getvalue().splitlines()),2)
    return {'ok':True}
   with patch.object(server.selectors,'DefaultSelector',Selector),patch.object(task_runtime,'_process',side_effect=lambda pid:('fake-native',os.getpid()) if pid==4242 else original(pid)):
    result=engine.run('desktop_observe',{},stage,task_id='scope-owner',operation_id='one-stage')
   rows=[json.loads(x) for x in b.process.stdin.getvalue().splitlines()]
   self.assertEqual([x['command'] for x in rows],['background_visual_read','background_visual_read','_finish_operation'])
   self.assertEqual({x['_runtime_operation_id'] for x in rows},{'one-stage'})
   self.assertEqual(result['summary']['state'],'completed')
   self.assertTrue(result['summary']['verified_flags']['capture_scope_released'])
   engine.close()
