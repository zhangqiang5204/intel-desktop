"""Actual high-level Send entry, fake UI; no test messages or native events."""
import unittest
from test_chat_completion import WeChatSendFake, send_request
from test_wechat_post_action_reuse import PostActionFake
from chat_workflows import execute_chat

class RetainedSendFake(WeChatSendFake, PostActionFake):
    def __init__(self, retained=True, corrupt=None):
        super().__init__()
        self.retained = retained
        self.corrupt = corrupt
        self.invalidate_before_submit = False

    def __call__(self, request):
        if request.get('key') == 'return' and self.invalidate_before_submit:
            self.calls.append(dict(request))
            return {'ok':False,'error':{'code':'visual_input_not_focused','message':'Isolated external event invalidated native focus proof','details':{'events_posted':0,'submit_events_posted':False}}}
        response = super().__call__(request)
        if request['command'] == 'visual_type_text' and request.get('control_kind') == 'chat_composer':
            if self.retained is not None:
                response['result']['input_control_focus_retained'] = self.retained
        return response

class SendFocusReuseTests(unittest.TestCase):
    def run_send(self, fake):
        return execute_chat(send_request(fake), fake, recipe_store=False)

    def test_new_draft_retains_exact_focus_and_submits_once_without_second_click(self):
        fake=RetainedSendFake(); result=self.run_send(fake)
        self.assertTrue(result['ok'],result); self.assertTrue(result['result']['sent'])
        self.assertEqual(sum(c['command']=='visual_click' and c.get('control_kind')=='chat_composer' for c in fake.calls),1)
        self.assertEqual(sum(c.get('key')=='return' for c in fake.calls),1)
        typed=next(i for i,c in enumerate(fake.calls) if c['command']=='visual_type_text')
        self.assertFalse(any(c['command']=='visual_read' for c in fake.calls[typed+1:next(i for i,c in enumerate(fake.calls) if c.get('key')=='return')]))

    def test_absent_or_false_native_retained_proof_uses_normal_focus_click(self):
        for proof in (None,False):
            fake=RetainedSendFake(proof); result=self.run_send(fake)
            self.assertTrue(result['ok'],result)
            self.assertEqual(sum(c['command']=='visual_click' and c.get('control_kind')=='chat_composer' for c in fake.calls),2)
            self.assertEqual(sum(c.get('key')=='return' for c in fake.calls),1)

    def test_existing_authorized_draft_is_focused_normally(self):
        fake=RetainedSendFake(); fake.draft=send_request(fake)['text']; result=self.run_send(fake)
        self.assertTrue(result['ok'],result)
        self.assertEqual(sum(c['command']=='visual_type_text' for c in fake.calls),0)
        self.assertEqual(sum(c['command']=='visual_click' and c.get('control_kind')=='chat_composer' for c in fake.calls),1)

    def test_incomplete_post_edit_proof_cannot_enable_fast_send(self):
        for corrupt in [('edit_recipient_verified',False),('edit_recipient','别人'),('edit_proof_snapshot_id','old'),('captured_regions',[])]:
            fake=RetainedSendFake(corrupt=corrupt); result=self.run_send(fake)
            self.assertTrue(result['ok'],result)
            self.assertEqual(sum(c['command']=='visual_click' and c.get('control_kind')=='chat_composer' for c in fake.calls),2)

    def test_external_focus_invalidation_stops_submit_without_retyping_or_replay(self):
        fake=RetainedSendFake(); fake.invalidate_before_submit=True; result=self.run_send(fake)
        self.assertFalse(result['ok']); self.assertFalse(result['sent']); self.assertFalse(result['automatic_replay_allowed'])
        self.assertEqual(sum(c['command']=='visual_type_text' for c in fake.calls),1)
        self.assertEqual(sum(c.get('key')=='return' for c in fake.calls),1)

    def test_missing_human_authorization_still_makes_no_native_calls(self):
        fake=RetainedSendFake(); request=send_request(fake); del request['send_authorization']
        result=execute_chat(request,fake,recipe_store=False)
        self.assertFalse(result['ok']); self.assertEqual(fake.calls,[])
