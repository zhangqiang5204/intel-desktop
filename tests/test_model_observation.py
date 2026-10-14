"""Pure fixture and real stdio-contract tests. Never starts the native helper/UI."""
import base64
import copy
import json
from pathlib import Path
import struct
import sys
import unittest
import os
import tempfile
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import server
from desktop_client import MCPClient, client_payload
from desktop_observation import execute_observation, OBSERVE_TOOL
from chat_workflows import execute_chat, WECHAT, FEISHU, STRUCTURE
from mcp_images import mcp_content, MAX_PNG_BYTES
from test_chat_workflows import WeChatFake, FeishuFake, bounds

def setUpModule():
    global _RUNTIME_TEMP,_PREVIOUS_RUNTIME,_RUNTIME_ENV
    from task_runtime import TaskRuntime
    _RUNTIME_TEMP=tempfile.TemporaryDirectory()
    _PREVIOUS_RUNTIME=server._RUNTIME
    server._RUNTIME=TaskRuntime(_RUNTIME_TEMP.name)
    _RUNTIME_ENV=patch.dict(os.environ,{'INTEL_DESKTOP_RUNTIME_DIR':_RUNTIME_TEMP.name})
    _RUNTIME_ENV.__enter__()

def tearDownModule():
    server._RUNTIME=_PREVIOUS_RUNTIME
    _RUNTIME_ENV.__exit__(None,None,None)
    _RUNTIME_TEMP.cleanup()


def png(width=2, height=2):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    raw = (b'\x00' + bytes([22, 33, 44, 255]) * width) * height
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def native_frame():
    frame = bounds(-900, 20, 900, 800)
    return {'app': WECHAT, 'target_pid': 123, 'window_title': '微信', 'window_frame': frame,
            'snapshot_id': 'verified-frame-1', 'display_topology_generation': 9,
            'window_id': 600, 'display_topology_signature': 'mixed-scale-fixture', 'frame_complete_serial': 8,
            'pixel_size': {'width': 2, 'height': 2},
            'displays': [{'id': 11, 'scale_x': 1}, {'id': 22, 'scale_x': 2}],
            'captured_regions': [frame], 'display_fragment_count': 2, 'read_only_background': True,
            'image': {'mime_type': 'image/png', 'data': base64.b64encode(png()).decode(),
                      'width': 2, 'height': 2, 'snapshot_id': 'verified-frame-1', 'masked': True,
                      'target_pid': 123, 'window_id': 600, 'display_topology_signature': 'mixed-scale-fixture', 'frame_complete_serial': 8,
                      'pixel_to_point_scale_x': 1, 'pixel_to_point_scale_y': 1,
                      'window_frame': frame, 'source': 'verified_masked_frame', 'read_only_background': True}}


class BackgroundFake:
    def __init__(self, backend):
        self.backend, self.calls = backend, []
        self.broken_image = False
        self.truncated = False

    def __call__(self, request):
        self.calls.append(copy.deepcopy(request))
        command = request['command']
        if command == 'status':
            return {'ok': True, 'result': {'frontmost_app_bundle_id': 'com.apple.TextEdit', 'frontmost_pid': 789,
                                          'frontmost_window_id': 801, 'frontmost_window_frame': bounds(0, 0, 400, 300),
                                          'frontmost_window_title': 'private title must not be emitted',
                                          'frontmost_app_path': '/private/path', 'interrupted': 'old_keyboard_activity',
                                          'displays': [{'id': 1}, {'id': 2}], 'display_topology_generation': 10}}
        if command == 'background_visual_read':
            self.assert_app(request, WECHAT)
            result = self.backend.visual(request)
            result.update(app=WECHAT, window_title='微信', read_only_background=True, snapshot_authorizes_input=False,
                          displays=[{'id': 1}, {'id': 2}], display_topology_generation=10,
                          captured_regions=[dict(self.backend.frame)], ocr_scope='full_window', ocr_regions=[dict(self.backend.frame)])
            if request.get('include_image'):
                result['image'] = native_frame()['image']
                result['image'].update(snapshot_id=result['snapshot_id'], window_frame=result['window_frame'])
                for field in ('window_id', 'display_topology_signature', 'frame_complete_serial'):
                    result[field] = result['image'][field]
            return {'ok': True, 'result': result}
        if command == 'background_observe':
            self.assert_app(request, FEISHU)
            result = self.backend.tree()
            result.update(app=FEISHU, window_title='飞书', observation_id='native-observe-2',
                          observation_mode='full', read_only_background=True, values_max_characters=4000)
            result['truncated'] = self.truncated
            return {'ok': True, 'result': result}
        raise AssertionError('Read-only observation attempted ' + command)

    def assert_app(self, request, app):
        if request.get('app') != app:
            raise AssertionError('Target app changed')


class ImageTests(unittest.TestCase):
    def test_real_image_block_and_bound_metadata(self):
        source = {'ok': True, 'result': native_frame()}
        output = mcp_content(source)
        self.assertFalse(output['isError'])
        self.assertEqual([row['type'] for row in output['content']], ['text', 'image'])
        self.assertEqual(output['content'][1]['mimeType'], 'image/png')
        self.assertEqual(base64.b64decode(output['content'][1]['data']), png())
        metadata = json.loads(output['content'][0]['text'])['result']
        self.assertNotIn('data', metadata['image'])
        self.assertEqual(len(metadata['image']['sha256']), 64)
        self.assertEqual(metadata['image']['mcp_content_index'], 1)
        for field in ('app', 'target_pid', 'window_frame', 'snapshot_id', 'displays', 'display_topology_generation', 'captured_regions', 'display_fragment_count'):
            self.assertEqual(metadata[field], source['result'][field])
        self.assertIn('data', source['result']['image'])  # Does not mutate producer evidence.

    def test_default_legacy_text_is_preserved(self):
        source = {'ok': True, 'id': 7, 'result': {'ocr': [], 'snapshot_id': 's', 'target_pid': 5}}
        output = mcp_content(source)
        self.assertEqual(len(output['content']), 1)
        self.assertEqual(json.loads(output['content'][0]['text']), source)

    def test_nested_observe_state_image_becomes_a_block(self):
        output = mcp_content({'ok': True, 'result': {'state': native_frame(), 'action': 'observe'}})
        self.assertEqual(len(output['content']), 2)
        self.assertNotIn('data', json.loads(output['content'][0]['text'])['result']['state']['image'])

    def test_invalid_images_fail_closed_without_binary_leak(self):
        alterations = [('mime_type', 'image/jpeg'), ('data', 'not base64@@'), ('data', base64.b64encode(b'not a PNG').decode()),
                       ('data', base64.b64encode(png()[:-3]).decode()), ('data', base64.b64encode(png()[:-5] + b'wrong').decode()),
                       ('width', 3), ('height', True), ('snapshot_id', 'another-frame'), ('masked', False),
                       ('pixel_to_point_scale_x', 0), ('window_frame', bounds(0, 0, 5, 5)),
                       ('target_pid', 124), ('window_id', 601), ('display_topology_signature', 'changed'), ('frame_complete_serial', 9),
                       ('data', 'A' * ((((MAX_PNG_BYTES + 2) // 3) * 4) + 4))]
        for field, value in alterations:
            with self.subTest(field=field, kind=str(value)[:20]):
                native = native_frame()
                native['image'][field] = value
                output = mcp_content({'ok': True, 'result': native})
                self.assertTrue(output['isError'])
                self.assertEqual(len(output['content']), 1)
                metadata = json.loads(output['content'][0]['text'])
                self.assertTrue(metadata['image_delivery_failed'])
                self.assertFalse(metadata['automatic_replay_allowed'])
                self.assertNotIn('data', metadata['result']['image'])

    def test_missing_pid_and_window_binding_fail(self):
        for key in ('target_pid', 'window_frame', 'snapshot_id'):
            native = native_frame()
            del native[key]
            self.assertTrue(mcp_content({'ok': True, 'result': native})['isError'])

    def test_explicit_model_image_downsample_keeps_original_ocr_frame_binding(self):
        native = native_frame()
        native['pixel_size'] = {'width': 4, 'height': 4}
        native['image'].update(downsampled=True, original_width=4, original_height=4, ocr_frame_unchanged=True)
        output = mcp_content({'ok': True, 'result': native})
        self.assertFalse(output['isError'], output)
        self.assertEqual(len(output['content']), 2)
        image = json.loads(output['content'][0]['text'])['result']['image']
        self.assertTrue(image['downsampled'])
        self.assertEqual(image['original_width'], 4)
        self.assertEqual(image['width'], 2)
        for field, value in (('original_width', 5), ('original_height', None), ('ocr_frame_unchanged', False), ('downsampled', False)):
            changed = copy.deepcopy(native)
            changed['image'][field] = value
            self.assertTrue(mcp_content({'ok': True, 'result': changed})['isError'])

    def test_client_defaults_to_metadata_and_can_forward_actual_blocks(self):
        output = mcp_content({'ok': True, 'result': native_frame()})
        metadata = client_payload(output)
        self.assertFalse(metadata['image_blocks_forwarded'])
        self.assertNotIn('images', metadata)
        self.assertNotIn(native_frame()['image']['data'], json.dumps(metadata))
        forwarded = client_payload(output, include_images=True)
        self.assertTrue(forwarded['image_blocks_forwarded'])
        self.assertEqual(forwarded['images'], output['content'][1:])

    def test_real_persistent_stdio_mcp_shape(self):
        # A subprocess running the actual server JSONL loop, with only its native
        # boundary replaced by the deterministic fixture. No GUI helper starts.
        code = "import sys,json;sys.path.insert(0," + repr(str(ROOT / 'scripts')) + ");import server;fixture=json.loads(" + repr(json.dumps({'ok': True, 'result': native_frame()})) + ");server.BRIDGE.call=lambda cmd,args:fixture;server.main()"
        client = MCPClient({'command': sys.executable, 'args': ['-u', '-c', code]})
        try:
            initialized = client.request('initialize', {'protocolVersion': '2025-03-26'})
            self.assertEqual(initialized['serverInfo']['version'], json.loads((ROOT / '.codex-plugin/plugin.json').read_text())['version'])
            response = client.request('tools/call', {'name': 'desktop_background_visual_read', 'arguments': {'app': WECHAT, 'window_title': '微信', 'include_image': True}})
            self.assertEqual(response['content'][1]['type'], 'image')
            self.assertEqual(base64.b64decode(response['content'][1]['data']), png())
            self.assertIn('bridge_elapsed_ms', json.loads(response['content'][0]['text']))
            self.assertEqual(json.loads(response['content'][0]['text'])['image_request_target'], {'app': WECHAT, 'window_title': '微信'})
            tools = client.request('tools/list', {})['tools']
            self.assertIn('desktop_observe', {row['name'] for row in tools})
        finally:
            client.close()

    def test_persistent_client_accepts_more_than_old_four_mib_and_enforces_eight(self):
        for size, valid in ((5 * 1024 * 1024, True), (8 * 1024 * 1024, False)):
            code = "import sys,json\nfor line in sys.stdin:\n r=json.loads(line);print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':{'fixture':'x'*" + str(size) + "}}),flush=True)"
            client = MCPClient({'command': sys.executable, 'args': ['-u', '-c', code]})
            try:
                if valid:
                    self.assertEqual(len(client.request('ping', {})['fixture']), size)
                else:
                    with self.assertRaisesRegex(RuntimeError, 'exceeds 8 MiB'):
                        client.request('ping', {})
            finally:
                client.close()


class ObserveTests(unittest.TestCase):
    def test_wechat_background_ignores_old_interruption_and_never_focuses(self):
        backend = WeChatFake()
        backend.draft = '保留草稿'
        fake = BackgroundFake(backend)
        output = execute_observation({'app': WECHAT, 'include_image': True}, fake)
        self.assertTrue(output['ok'], output)
        result = output['result']
        self.assertEqual(output['commands'], ['status', 'background_visual_read', 'status'])
        self.assertFalse(result['focus_attempted'])
        self.assertEqual(result['events_posted'], 0)
        self.assertFalse(result['sent'])
        self.assertFalse(result['snapshot_authorizes_input'])
        self.assertEqual(result['composer']['value'], '保留草稿')
        self.assertEqual(result['visible_text'], '新消息\n最后回复')
        self.assertEqual(result['focus_context_after']['frontmost_app_bundle_id'], 'com.apple.TextEdit')
        self.assertEqual(result['focus_context_after']['interrupted'], 'old_keyboard_activity')
        self.assertNotIn('frontmost_window_title', result['focus_context_after'])
        self.assertNotIn('frontmost_app_path', result['focus_context_after'])
        self.assertEqual(len(mcp_content(output)['content']), 2)

    def test_feishu_bounded_native_background_semantics_and_explicit_no_image(self):
        backend = FeishuFake()
        backend.draft = '飞书保留'
        fake = BackgroundFake(backend)
        output = execute_observation({'app': FEISHU, 'include_image': True, 'max_nodes': 320, 'max_depth': 30}, fake)
        self.assertTrue(output['ok'], output)
        self.assertEqual(output['commands'], ['status', 'background_observe', 'status'])
        self.assertEqual(fake.calls[1]['max_nodes'], 320)
        self.assertEqual(fake.calls[1]['max_depth'], 30)
        result = output['result']
        self.assertEqual(result['chat_title'], backend.title)
        self.assertEqual(result['composer']['value'], '飞书保留' + STRUCTURE)
        self.assertTrue(result['composer']['value_complete'])
        self.assertFalse(result['image_available'])
        self.assertEqual(result['image_unavailable_reason'], 'unsupported_app_AX_only')
        self.assertFalse(result['focus_attempted'])

    def test_application_status_and_display_topology_do_not_prove_keyboard_window(self):
        result = execute_observation({'app': WECHAT}, BackgroundFake(WeChatFake()))['result']
        self.assertEqual(result['focus_context_scope'], 'application_and_display_topology')
        self.assertFalse(result['focus_context_complete'])
        self.assertFalse(result['focused_window_verified'])
        self.assertEqual(result['keyboard_focus_display_ids'], [])
        self.assertEqual(result['native_current_focus_context'], {})

    def test_native_exact_current_keyboard_window_supplies_only_its_display_ids(self):
        fake = BackgroundFake(WeChatFake())
        context = {'available': True, 'pid': 789, 'bundle_id': 'com.apple.TextEdit', 'window_id': 801,
                   'window_frame': bounds(-800, 0, 400, 300), 'display_ids': [11, 22], 'source': 'public_system_AX'}
        def native_focus(request):
            response = fake(request)
            if request['command'] == 'background_visual_read':
                response['result']['focus_context'] = context
            if request['command'] == 'status':
                response['result']['pointer_display_id'] = 99
            return response
        result = execute_observation({'app': WECHAT}, native_focus)['result']
        self.assertTrue(result['focus_context_complete'])
        self.assertTrue(result['focused_window_verified'])
        self.assertEqual(result['keyboard_focus_display_ids'], [11, 22])
        self.assertEqual(result['native_current_focus_context'], context)

    def test_native_before_known_after_unknown_does_not_reuse_previous_keyboard_window(self):
        fake = BackgroundFake(FeishuFake())
        context = {'before': {'available': True, 'pid': 789, 'window_id': 801, 'window_frame': bounds(0, 0, 400, 300), 'display_ids': [11]},
                   'after': {'available': False, 'source': 'public_system_AX'}, 'scope': 'metadata_only_no_foreign_content'}
        def native_focus(request):
            response = fake(request)
            if request['command'] == 'background_observe':
                response['result']['focus_context'] = context
            return response
        result = execute_observation({'app': FEISHU}, native_focus)['result']
        self.assertFalse(result['focus_context_complete'])
        self.assertFalse(result['focused_window_verified'])
        self.assertEqual(result['keyboard_focus_display_ids'], [])
        self.assertEqual(result['native_current_focus_context'], context)

    def test_native_incomplete_keyboard_identity_and_foreign_content_are_not_promoted(self):
        fake = BackgroundFake(WeChatFake())
        context = {'available': True, 'pid': 789, 'window_id': None, 'window_frame': bounds(0, 0, 400, 300),
                   'display_ids': [11], 'window_title': 'private title', 'path': '/private', 'value': 'private content'}
        def native_focus(request):
            response = fake(request)
            if request['command'] == 'background_visual_read':
                response['result']['focus_context'] = context
            return response
        result = execute_observation({'app': WECHAT}, native_focus)['result']
        self.assertFalse(result['focused_window_verified'])
        self.assertFalse(result['focus_context_complete'])
        self.assertEqual(result['keyboard_focus_display_ids'], [])
        for key in ('window_title', 'path', 'value'):
            self.assertNotIn(key, result['native_current_focus_context'])
            self.assertNotIn(key, result['state']['focus_context'])

    def test_actual_native_feishu_shape_without_legacy_windows(self):
        backend = FeishuFake()
        fake = BackgroundFake(backend)
        def current_native_shape(request):
            response = fake(request)
            if request['command'] == 'background_observe':
                response['result'].pop('windows')
                response['result'].update(window_frame=backend.frame, generation=2,
                                          observation_id='native-observe-2', read_only=True)
            return response
        output = execute_observation({'app': FEISHU}, current_native_shape)
        self.assertTrue(output['ok'], output)
        self.assertEqual(output['result']['chat_title'], backend.title)
        self.assertTrue(output['result']['composer']['available'])
        self.assertEqual(output['result']['visible_text'], '新消息\n最后回复')

    def test_wechat_partial_capture_or_missing_composer_ocr_never_proves_empty(self):
        backend = WeChatFake()
        fake = BackgroundFake(backend)
        for kind in ('partial_capture', 'no_composer_ocr', 'missing_scope'):
            def partial(request):
                response = fake(request)
                if request['command'] == 'background_visual_read':
                    state = response['result']
                    if kind == 'partial_capture':
                        state['captured_regions'] = [bounds(backend.frame['x'], backend.frame['y'], backend.frame['width'], 200)]
                    elif kind == 'no_composer_ocr':
                        state.update(ocr_scope='requested_regions', ocr_regions=[bounds(backend.frame['x'], backend.frame['y'], backend.frame['width'], 200)])
                    else:
                        state.pop('ocr_scope')
                        state.pop('ocr_regions')
                return response
            with self.subTest(kind=kind):
                result = execute_observation({'app': WECHAT}, partial)['result']
                self.assertFalse(result['composer']['available'])
                self.assertFalse(result['composer']['value_complete'])
                self.assertNotIn('value', result['composer'])
                self.assertNotIn('draft', result['composer'])

    def test_wechat_full_capture_and_full_ocr_can_report_empty_composer(self):
        result = execute_observation({'app': WECHAT}, BackgroundFake(WeChatFake()))['result']
        self.assertTrue(result['composer']['available'])
        self.assertTrue(result['composer']['value_complete'])
        self.assertEqual(result['composer']['value'], '')

    def test_wechat_mixed_display_union_must_cover_full_composer_without_gap(self):
        backend = WeChatFake()
        fake = BackgroundFake(backend)
        for gap in (0, 4):
            def fragments(request):
                response = fake(request)
                if request['command'] == 'background_visual_read':
                    f = backend.frame
                    response['result']['captured_regions'] = [bounds(f['x'], f['y'], 500, f['height']),
                                                              bounds(f['x'] + 500 + gap, f['y'], f['width'] - 500 - gap, f['height'])]
                return response
            result = execute_observation({'app': WECHAT}, fragments)['result']
            self.assertEqual(result['composer']['value_complete'], gap == 0)

    def test_feishu_4000_value_is_honestly_incomplete_and_native_complete_flag_wins(self):
        backend = FeishuFake()
        backend.draft = '文' * (4000 - len(STRUCTURE))
        fake = BackgroundFake(backend)
        value = execute_observation({'app': FEISHU}, fake)['result']
        self.assertFalse(value['composer']['value_complete'])
        def complete(request):
            response = fake(request)
            if request['command'] == 'background_observe':
                for row in response['result']['elements']:
                    if row.get('element_id') == 'composer':
                        row['value_complete'] = True
            return response
        self.assertTrue(execute_observation({'app': FEISHU}, complete)['result']['composer']['value_complete'])

    def test_unknown_feishu_pane_returns_state_without_pressing_messages(self):
        backend = FeishuFake()
        backend.tab = 'contacts'
        fake = BackgroundFake(backend)
        output = execute_observation({'app': FEISHU}, fake)
        self.assertTrue(output['ok'], output)
        self.assertFalse(output['result']['composer']['available'])
        self.assertTrue(output['result']['semantic_gaps'])
        self.assertTrue(output['result']['state']['elements'])
        self.assertNotIn('press', output['commands'])

    def test_unknown_wechat_layout_still_returns_native_model_image(self):
        backend = WeChatFake()
        backend.frame = bounds(0, 20, 380, 300)
        fake = BackgroundFake(backend)
        output = execute_observation({'app': WECHAT, 'include_image': True}, fake)
        self.assertTrue(output['ok'], output)
        self.assertTrue(output['result']['semantic_gaps'])
        self.assertEqual(len(mcp_content(output)['content']), 2)

    def test_wechat_unknown_header_file_list_is_fragment_never_a_complete_composer(self):
        backend = WeChatFake()
        backend.title = ''
        fake = BackgroundFake(backend)
        def files_pane(request):
            response = fake(request)
            if request['command'] == 'background_visual_read':
                f = backend.frame
                response['result']['ocr'] += [{'text': text, 'bounds': bounds(f['x'] + 336, f['y'] + f['height'] * .86 + i * 20, 60, 15)}
                                             for i, text in enumerate(('HIS', 'SK', 'WGSK'))]
            return response
        output = execute_observation({'app': WECHAT, 'include_image': True}, files_pane)
        self.assertTrue(output['ok'], output)
        result = output['result']
        self.assertIsNone(result['chat_title'])
        self.assertFalse(result['recipient_verified'])
        self.assertFalse(result['composer']['available'])
        self.assertFalse(result['composer']['value_complete'])
        self.assertNotIn('value', result['composer'])
        self.assertNotIn('draft', result['composer'])
        self.assertIn('HIS', result['composer']['visible_text_fragment'])
        self.assertIn({'field': 'composer', 'reason': 'chat_header_unverified'}, result['semantic_gaps'])
        self.assertEqual(len(mcp_content(output)['content']), 2)
        self.assertEqual(output['commands'], ['status', 'background_visual_read', 'status'])

    def test_wechat_ambiguous_header_does_not_establish_composer(self):
        backend = WeChatFake()
        backend.draft = '可见片段'
        fake = BackgroundFake(backend)
        def ambiguous(request):
            response = fake(request)
            if request['command'] == 'background_visual_read':
                f = backend.frame
                response['result']['ocr'].append({'text': '第二个标题', 'bounds': bounds(f['x'] + 338, f['y'] + 32, 80, 15)})
            return response
        result = execute_observation({'app': WECHAT}, ambiguous)['result']
        self.assertFalse(result['composer']['available'])
        self.assertFalse(result['composer']['value_complete'])
        self.assertEqual(result['composer']['visible_text_fragment'], '可见片段')

    def test_feishu_missing_header_ax_area_is_fragment_never_a_chat_composer(self):
        backend = FeishuFake()
        backend.draft = '可见AX片段'
        fake = BackgroundFake(backend)
        def missing_header(request):
            response = fake(request)
            if request['command'] == 'background_observe':
                response['result']['elements'] = [row for row in response['result']['elements'] if row.get('element_id') != 'header']
            return response
        result = execute_observation({'app': FEISHU}, missing_header)['result']
        self.assertFalse(result['recipient_verified'])
        self.assertFalse(result['composer']['available'])
        self.assertFalse(result['composer']['value_complete'])
        self.assertNotIn('value', result['composer'])
        self.assertNotIn('draft', result['composer'])
        self.assertEqual(result['composer']['visible_text_fragment'], '可见AX片段')

    def test_chat_mismatch_is_reported_without_navigation(self):
        fake = BackgroundFake(FeishuFake())
        output = execute_observation({'app': FEISHU, 'chat': '其他群'}, fake)
        self.assertTrue(output['ok'], output)
        self.assertFalse(output['result']['requested_chat_matches'])
        self.assertEqual(output['commands'], ['status', 'background_observe', 'status'])

    def test_chat_observe_alias_keeps_read_only_route(self):
        fake = BackgroundFake(WeChatFake())
        output = execute_chat({'app': WECHAT, 'action': 'observe', 'background': True}, fake, recipe_store=False)
        self.assertTrue(output['ok'], output)
        self.assertEqual(output['commands'], ['status', 'background_visual_read', 'status'])
        self.assertNotIn('recipe', output)

    def test_old_actions_do_not_silently_accept_background_or_images(self):
        for field in ('background', 'include_image', 'max_nodes'):
            fake = WeChatFake()
            output = execute_chat({'app': WECHAT, 'action': 'draft', 'text': '不得输入', field: False if field == 'background' else True}, fake, recipe_store=False)
            self.assertFalse(output['ok'])
            self.assertEqual(fake.calls, [])

    def test_observe_bad_args_stop_before_native(self):
        for args in ({'app': 'not a bundle'}, {'app': WECHAT, 'background': False}, {'app': FEISHU, 'max_nodes': 2001},
                     {'app': WECHAT, 'include_image': 1}, {'app': WECHAT, 'text': '禁止输入'}, {'app': FEISHU, 'send_authorization': {}},
                     {'app': WECHAT, 'window_title': ''}):
            calls = []
            output = execute_observation(args, lambda row: calls.append(row))
            self.assertFalse(output['ok'])
            self.assertEqual(calls, [])

    def test_native_errors_do_not_replay_or_focus(self):
        calls = []
        def fail(request):
            calls.append(request['command'])
            if request['command'] == 'status':
                return {'ok': True, 'result': {'interrupted': 'old'}}
            return {'ok': False, 'error': {'code': 'occluded', 'message': 'No verified frame'}}
        output = execute_observation({'app': WECHAT}, fail)
        self.assertFalse(output['ok'])
        self.assertEqual(calls, ['status', 'background_visual_read'])
        self.assertFalse(output['automatic_replay_allowed'])


class SchemaTests(unittest.TestCase):
    def test_schema_and_versions(self):
        self.assertEqual(len(server.TOOLS), 27)
        observe = next(row for row in server.TOOLS if row['name'] == 'desktop_observe')
        self.assertTrue(observe['annotations']['readOnlyHint'])
        self.assertFalse(observe['annotations']['destructiveHint'])
        self.assertEqual(server.handle({'method': 'initialize'})['serverInfo']['version'], json.loads((ROOT / '.codex-plugin/plugin.json').read_text())['version'])
        for command in ('visual_read', 'background_visual_read'):
            self.assertEqual(server.PROPS[command]['include_image']['type'], 'boolean')
            server.validate(command, {'app': WECHAT, 'window_title': '微信', 'include_image': True})

    def test_invalid_native_image_request_never_starts_helper(self):
        for args in ({'include_image': 1}, {'include_image': True, 'debug_image_path': '/tmp/raw.png'}, {'background_capture': 'foreign'}):
            bridge = server.NativeBridge()
            with patch.object(bridge, 'start') as start:
                with self.assertRaises(ValueError):
                    bridge.call('background_visual_read', {'app': WECHAT, 'window_title': '微信', **args})
                start.assert_not_called()

    def test_hidden_native_feishu_route_is_bounded_and_exact(self):
        self.assertNotIn('desktop_background_observe', {row['name'] for row in server.TOOLS})
        server.validate('background_observe', {'app': FEISHU, 'window_title': '飞书', 'include_image': True, 'max_nodes': 300, 'since_observation_id': 'obs'})
        for args in ({'app': WECHAT, 'window_title': '微信'}, {'app': FEISHU, 'window_title': '飞书', 'max_nodes': 2001}):
            with self.assertRaises(ValueError):
                server.validate('background_observe', args)

    def test_image_batch_cannot_publish_a_separate_raw_debug_path(self):
        with self.assertRaises(ValueError):
            server.validate('batch', {'app': WECHAT, 'window_title': '微信', 'actions': [
                {'command': 'visual_read', 'debug_image_path': '/tmp/raw.png'},
                {'command': 'visual_read', 'include_image': True}]})


if __name__ == '__main__':
    unittest.main()
