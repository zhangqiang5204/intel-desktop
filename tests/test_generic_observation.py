"""Model-driven app observation must survive missing pixels and new dialogs."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from desktop_observation import execute_observation


class GenericObservationTests(unittest.TestCase):
    def backend(self, state=None):
        self.calls = []
        state = state or {'app': 'com.apple.TextEdit', 'target_pid': 42,
                          'windows': [{'title': 'Owned document'}],
                          'elements': [{'element_id': 'g1-e2', 'role': 'AXTextArea'}],
                          'image_available': False, 'image_unavailable_reason': 'inspection_image_privacy_unknown'}
        def call(request):
            self.calls.append(copy.deepcopy(request))
            if request['command'] == 'status':
                return {'ok': True, 'result': {'frontmost_pid': 123, 'frontmost_app_bundle_id': 'org.example.origin',
                                              'frontmost_window_title': 'private origin text'}}
            if request['command'] == 'inspect':
                return {'ok': True, 'result': copy.deepcopy(state)}
            raise AssertionError('Observation attempted input')
        return call

    def test_generic_missing_image_keeps_actionable_ax_and_original_focus(self):
        result = execute_observation({'app': 'com.apple.TextEdit', 'window_title': 'Owned document',
                                      'include_image': True}, self.backend())
        self.assertTrue(result['ok'])
        value = result['result']
        self.assertEqual(value['route'], 'model_driven')
        self.assertEqual(value['state']['elements'][0]['element_id'], 'g1-e2')
        self.assertFalse(value['image_available'])
        self.assertEqual(value['image_unavailable_reason'], 'inspection_image_privacy_unknown')
        self.assertFalse(value['snapshot_authorizes_input'])
        self.assertEqual(value['events_posted'], 0)
        self.assertNotIn('frontmost_window_title', value['focus_context_before'])
        self.assertEqual([r['command'] for r in self.calls], ['status', 'inspect', 'status'])

    def test_next_read_returns_new_dialog_controls_without_replay(self):
        state = {'app': 'com.apple.TextEdit', 'target_pid': 42,
                 'windows': [{'title': 'Owned document'}],
                 'elements': [{'element_id': 'g2-e3', 'role': 'AXButton', 'associated_dialog': True,
                               'element_pid': 66, 'authorized_owner_pid': 42}],
                 'associated_dialogs': [{'owner_pid': 42}], 'image_available': False}
        value = execute_observation({'app': 'com.apple.TextEdit', 'window_title': 'Owned document'},
                                    self.backend(state))['result']
        self.assertEqual(value['state']['elements'][0]['element_id'], 'g2-e3')
        self.assertEqual(value['state']['associated_dialogs'], state['associated_dialogs'])
        self.assertFalse(value['automatic_replay_allowed'])

    def test_foreign_app_or_window_binding_is_rejected(self):
        for field, value in [('app', 'org.example.foreign'), ('windows', [{'title': 'Other document'}]), ('target_pid', 0)]:
            state = {'app': 'com.apple.TextEdit', 'target_pid': 42, 'windows': [{'title': 'Owned document'}], 'elements': []}
            state[field] = value
            result = execute_observation({'app': 'com.apple.TextEdit', 'window_title': 'Owned document'}, self.backend(state))
            self.assertFalse(result['ok'])
            self.assertEqual(result['error']['code'], 'native_protocol_error')

    def test_generic_chat_arguments_and_unbound_image_rejected_before_native(self):
        for extra in [{'chat': 'Recipient'}, {'max_text_rows': 10}, {'include_image': True}, {'app': 'not a bundle'}]:
            result = execute_observation({'app': 'com.apple.TextEdit', **extra}, self.backend())
            self.assertFalse(result['ok'])
            self.assertEqual(self.calls, [])

    def test_supported_image_is_retained_for_current_model(self):
        state = {'app': 'com.apple.TextEdit', 'target_pid': 42, 'windows': [{'title': 'Owned document'}],
                 'elements': [], 'image_available': True, 'image': {'masked': True}, 'ax_image_atomic': False}
        result = execute_observation({'app': 'com.apple.TextEdit', 'window_title': 'Owned document', 'include_image': True},
                                     self.backend(state))
        self.assertTrue(result['result']['image_available'])
        self.assertFalse(result['result']['state']['ax_image_atomic'])


if __name__ == '__main__':
    unittest.main()
