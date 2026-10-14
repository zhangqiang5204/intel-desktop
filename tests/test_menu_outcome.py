"""AX menu effects remain uncertain with zero CG events; queue stays usable."""
import json, sys, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from task_runtime import TaskRuntime, _native_timing
from workflow_tools import classify_result

class MenuOutcome(unittest.TestCase):
    def test_zero_CG_menu_failure_is_unknown_without_replay_or_permanent_lease(self):
        secret='PRIVATE_CLIPBOARD_DO_NOT_STORE_58'
        response={'id':7,'ok':False,'elapsed_ms':42.0,'error':{'code':'background_postcondition_unknown',
            'message':secret,'details':{'events_posted':0,'ax_actions_attempted':2,
            'ax_menu_actions_attempted':1,'ax_composer_focus_actions_attempted':1,'input_may_be_partial':True,'temporary_clipboard_used':True,
            'clipboard_restored':True,'clipboard_isolated':False,'native_stage_ms':{'paste':13.0},
            'clipboard_data':secret,'AXValue':secret}}}
        with tempfile.TemporaryDirectory() as directory:
            runtime=TaskRuntime(directory,session_id='menu-session');calls=[]
            def execute(context):
                calls.append('paste');context.record_native(response)
                classify_result('chat',{'action':'draft'},response,context)
                return response
            args={'app':'com.bytedance.macos.feishu','action':'draft'}
            first=runtime.run('desktop_chat',args,execute,task_id='task-a',operation_id='menu-op')
            self.assertEqual(first['summary']['state'],'unknown')
            self.assertFalse(first['summary']['conflict_active'])
            self.assertEqual(first['summary']['event_count'],0)
            self.assertEqual(first['summary']['timing']['native_action_counts']['ax_menu_actions_attempted'],1)
            self.assertEqual(first['summary']['timing']['native_action_counts']['ax_composer_focus_actions_attempted'],1)
            self.assertTrue(first['summary']['verified_flags']['clipboard_restored'])
            again=runtime.run('desktop_chat',args,execute,task_id='task-a',operation_id='menu-op')
            self.assertFalse(again['executed']);self.assertEqual(calls,['paste'])
            successor=runtime.run('desktop_status',{},lambda c:{'ok':True,'result':{}},task_id='task-b',operation_id='read-op')
            self.assertEqual(successor['summary']['state'],'completed')
            self.assertNotIn(secret,json.dumps(runtime.logs(task_id='task-a'),ensure_ascii=False))

    def test_action_metadata_rejects_unbounded_bool_and_private_fields(self):
        value={'error':{'details':{'ax_actions_attempted':True,'ax_menu_actions_attempted':10**1000,
            'key_events_posted':3,'native_stage_ms':{'good':2.0,'bad':10**1000},'clipboard_data':'PRIVATE'}}}
        self.assertEqual(_native_timing(value),{'native_stage_ms':{'good':2.0},'native_action_counts':{'key_events_posted':3}})

if __name__=='__main__':unittest.main()
