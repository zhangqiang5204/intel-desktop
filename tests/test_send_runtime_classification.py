"""Send proof classification through the offline runtime. All desktop calls are fake."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'tests'))
from chat_workflows import execute_chat
from task_runtime import TaskRuntime
from test_chat_completion import FeishuSendFake, WeChatSendFake, send_request
from workflow_tools import classify_result

SOURCE = 'fresh_same_chat_empty_composer_and_increased_complete_exact_text_row_occurrence'
PRIVATE = 'PRIVATE SEND BODY MUST NOT ENTER RUNTIME METADATA'


def verified_send():
    return {'ok': True, 'focus_restored': True, 'result': {
        'sent': True, 'send_verified': True, 'submission_state': 'observed_in_chat',
        'draft_empty': True, 'recipient_verified': True, 'send_verification_source': SOURCE,
        'delivery_verified': False, 'visible_text': PRIVATE, 'reply_baseline_text': PRIVATE,
    }}


class SendClassificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.runtime = TaskRuntime(Path(self.temporary.name))
        self.sequence = 0

    def tearDown(self):
        self.runtime.close()
        self.temporary.cleanup()

    def classify(self, response, *, command='chat', action='send', prior=None):
        self.sequence += 1
        def execute(context):
            context.record_native({'ok': True, 'result': {'events_posted': 2, 'value_verified': False}})
            if prior:
                context.set_outcome(prior, error_code='fixture_existing_outcome')
            classify_result(command, {'action': action}, response, context)
            return response
        return self.runtime.run('desktop_' + command, {'action': action, 'app': 'com.tencent.xinWeChat', 'text': PRIVATE},
                                execute, task_id='send-classification-fixture', operation_id='send-' + str(self.sequence))['summary']

    def test_complete_local_send_is_verified_without_remote_delivery(self):
        summary = self.classify(verified_send())
        self.assertEqual(summary['state'], 'verified')
        for key in ('proof_full_value', 'proof_same_target', 'recipient_verified', 'value_verified', 'focus_verified'):
            self.assertIs(summary['verified_flags'][key], True)
        events = self.runtime.logs(task_id='send-classification-fixture')['events']
        self.assertEqual(sum(event['substage'] == 'complete_chat_send' for event in events), 1)
        self.assertNotIn(PRIVATE, json.dumps(self.runtime.logs(task_id='send-classification-fixture')))
        self.assertNotIn(PRIVATE, json.dumps(summary))

    def test_each_boolean_postcondition_requires_literal_true_and_cannot_be_missing(self):
        for field in ('sent', 'send_verified', 'draft_empty', 'recipient_verified'):
            for bad in (False, None, 1, 'true', 'missing'):
                with self.subTest(field=field, bad=bad):
                    response = verified_send()
                    if bad == 'missing':
                        response['result'].pop(field)
                    else:
                        response['result'][field] = bad
                    summary = self.classify(response)
                    self.assertEqual(summary['state'], 'accepted_unverified')
                    self.assertNotIn('proof_full_value', summary['verified_flags'])

    def test_full_send_source_and_observed_submission_state_are_required(self):
        for field, bad_values in (
            ('send_verification_source', (None, '', 'posted_only', 'remote_delivery_verified', {'source': SOURCE}, 'missing')),
            ('submission_state', (None, '', 'posted_unverified', 'unknown', 'not_posted', 'missing')),
        ):
            for bad in bad_values:
                with self.subTest(field=field, bad=bad):
                    response = verified_send()
                    if bad == 'missing':
                        response['result'].pop(field)
                    else:
                        response['result'][field] = bad
                    response['result'].update(delivery_verified=True, submit_events_posted=True)
                    self.assertEqual(self.classify(response)['state'], 'accepted_unverified')

    def test_posted_events_and_preconditions_do_not_substitute_for_send_echo(self):
        response = {'ok': True, 'focus_restored': True, 'result': {
            'sent': None, 'send_verified': False, 'submission_state': 'posted_unverified',
            'submit_events_posted': True, 'submit_preconditions_verified': True,
            'recipient_verified': True, 'draft_empty': True, 'events_posted': 2,
        }}
        self.assertEqual(self.classify(response)['state'], 'accepted_unverified')

    def test_send_proof_does_not_classify_another_action_or_command(self):
        for command, action in (('chat', 'draft'), ('chat', 'clear'), ('chat', 'read'), ('script', 'run')):
            with self.subTest(command=command, action=action):
                self.assertEqual(self.classify(verified_send(), command=command, action=action)['state'], 'accepted_unverified')

    def test_focus_metadata_can_come_from_result_or_outer_response_without_invention(self):
        for location in ('outer', 'result'):
            for field in ('focus_restored', 'focus_isolated', 'foreground_preserved', 'system_focus_preserved'):
                with self.subTest(location=location, field=field):
                    response = verified_send()
                    response.pop('focus_restored')
                    (response if location == 'outer' else response['result'])[field] = True
                    self.assertTrue(self.classify(response)['verified_flags']['focus_verified'])
        response = verified_send()
        response['focus_restored'] = False
        summary = self.classify(response)
        self.assertEqual(summary['state'], 'verified')  # Retain independently proven local send.
        self.assertFalse(summary['verified_flags']['focus_verified'])

    def test_failed_unknown_or_existing_outcome_cannot_be_promoted_by_stale_send_fields(self):
        for unknown in (False, True):
            response = verified_send()
            response.update(ok=False, completion_unknown=unknown, error={'code': 'fixture_failed'})
            self.assertEqual(self.classify(response)['state'], 'unknown' if unknown else 'failed')
        self.assertEqual(self.classify(verified_send(), prior='unknown')['state'], 'unknown')
        response = verified_send()
        response['ok'] = 1
        self.assertEqual(self.classify(response)['state'], 'accepted_unverified')

    def test_real_highlevel_fake_wechat_and_feishu_send_feed_verified_runtime_metadata(self):
        for factory in (WeChatSendFake, FeishuSendFake):
            with self.subTest(factory=factory):
                fake = factory()
                request = send_request(fake, PRIVATE)
                def execute(context):
                    def native(payload):
                        response = fake(payload)
                        if payload['command'] == 'focus' and payload.get('restore_previous') is True and response['ok']:
                            response = copy.deepcopy(response)
                            response['result'].update(focus_restored=True, focus_restore_attempted=True)
                        context.record_native(response)
                        return response
                    response = execute_chat(request, native, recipe_store=False)
                    context.record_native({'ok': True, 'result': {'value_verified': False}})
                    classify_result('chat', request, response, context)
                    return response
                packet = self.runtime.run('desktop_chat', request, execute, task_id='send-classification-fixture',
                                          operation_id='producer-' + factory.__name__)
                self.assertTrue(packet['response']['ok'])
                self.assertEqual(packet['summary']['state'], 'verified')
                self.assertTrue(packet['summary']['verified_flags']['value_verified'])
                self.assertTrue(packet['summary']['verified_flags']['focus_verified'])
                submits = [call for call in fake.calls if call['command'] == 'submit_text' or call.get('key') == 'return']
                self.assertEqual(len(submits), 1)
                self.assertNotIn(PRIVATE, json.dumps(packet['summary']))


if __name__ == '__main__':
    unittest.main()
