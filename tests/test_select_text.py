"""Selection MCP/schema guards. No desktop helper or real application is used."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import server

BASE = {'app': 'com.apple.TextEdit', 'window_title': 'Fixture', 'element_id': 'fresh-e1',
        'expected_value': '🙂中文中文', 'text': '中文', 'occurrence': 2, 'background': True}


class SelectionSchemaTests(unittest.TestCase):
    def invalid(self, **updates):
        request = {**BASE, **updates}
        with self.assertRaises(ValueError): server.validate('select_text', request)

    def test_literal_exact_and_explicit_occurrence_supported(self):
        server.validate('select_text', BASE)
        server.validate('select_text', {**BASE, 'expected_selection': {'location': 0, 'length': 0}})

    def test_restore_owned_UTF16_selection_with_current_range_guard(self):
        request = {k: v for k, v in BASE.items() if k not in {'text', 'occurrence'}}
        server.validate('select_text', {**request, 'range': {'location': 0, 'length': 0},
                                       'expected_selection': {'location': 2, 'length': 2}})

    def test_text_and_range_are_exclusive(self): self.invalid(range={'location': 0, 'length': 1})
    def test_selection_text_cannot_be_empty(self): self.invalid(text='')
    def test_value_must_be_a_complete_string(self): self.invalid(expected_value=None)
    def test_control_identity_required(self): self.invalid(element_id='')
    def test_exact_window_required(self): self.invalid(window_title='')
    def test_occurrence_cannot_be_boolean(self): self.invalid(occurrence=True)
    def test_occurrence_cannot_be_zero(self): self.invalid(occurrence=0)
    def test_background_cannot_be_a_truthy_string(self): self.invalid(background='true')
    def test_unknown_argument_denied(self): self.invalid(allow_submit=True)

    def test_range_bounds_and_surrogate_boundaries_are_validated_before_native(self):
        request = {k: v for k, v in BASE.items() if k not in {'text', 'occurrence'}}
        for r in ({'location': 1, 'length': 1}, {'location': 3, 'length': 99},
                  {'location': -1, 'length': 1}, {'location': 0, 'length': True},
                  {'location': 0, 'length': 1, 'extra': 3}):
            with self.subTest(r=r), self.assertRaises(ValueError):
                server.validate('select_text', {**request, 'range': r})

    def test_occurrence_cannot_be_used_with_explicit_range(self):
        request = {k: v for k, v in BASE.items() if k != 'text'}
        with self.assertRaises(ValueError): server.validate('select_text', {**request, 'range': {'location': 0, 'length': 0}})

    def test_schema_exposes_selection_and_plans_require_literal_background_selection(self):
        tool = next(t for t in server.TOOLS if t['name'] == 'desktop_select_text')
        self.assertTrue({'window_title', 'element_id', 'expected_value'}.issubset(tool['inputSchema']['required']))
        from desktop_transactions import ALLOWED, validate_plan, preflight
        self.assertIn('select_text', ALLOWED)
        plan = {'app': BASE['app'], 'window_title': BASE['window_title'], 'steps': [
            {'id': 'before', 'tool': 'inspect', 'arguments': {}},
            {'id': 'select', 'tool': 'select_text', 'arguments': {
                'element_id': {'$element': {'step': 'before', 'role': 'AXTextArea'}},
                'background': True, 'expected_value': BASE['expected_value'], 'text': BASE['text']}},
            {'id': 'after', 'tool': 'inspect', 'arguments': {}}],
            'postconditions': [{'step': 'after', 'element': {'role': 'AXTextArea'},
                                'attribute': 'value', 'equals': BASE['expected_value']}]}
        validate_plan(plan)
        preflight(plan, server.dispatch_plain)
        for background in (False, None, {'$param': 'background'}):
            rejected = copy.deepcopy(plan)
            rejected['parameters'] = {'background': True}
            if background is None:
                rejected['steps'][1]['arguments'].pop('background')
            else:
                rejected['steps'][1]['arguments']['background'] = background
            with self.subTest(background=background), self.assertRaises(ValueError):
                validate_plan(rejected)

    def test_MCP_outcome_requires_value_selection_and_focus_proof(self):
        class Fake:
            def __init__(self): self.proof = True; self.calls = []
            def call(self, command, arguments):
                server.validate(command, arguments)
                self.calls.append(command)
                return {'ok': True, 'result': {'selection_verified': True, 'value_verified': True,
                        'text_unchanged': True, 'system_focus_preserved': self.proof, 'events_posted': 0}}
        fake = Fake()
        previous = server.BRIDGE, server._RUNTIME
        try:
            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'INTEL_DESKTOP_RUNTIME_DIR': directory}):
                server.BRIDGE = fake; server._RUNTIME = None
                def call(arguments, operation):
                    reply = server.handle({'method': 'tools/call', 'params': {'name': 'desktop_select_text',
                            'arguments': {**arguments, 'task_id': 'selection-fixture', 'operation_id': operation}}})
                    return json.loads(reply['content'][0]['text'])
                good = call(BASE, 'selection-good')
                self.assertTrue(good['ok']); self.assertEqual(good['execution']['state'], 'verified')
                fake.proof = False
                weaker = call(BASE, 'selection-unproven-focus')
                self.assertEqual(weaker['execution']['state'], 'accepted_unverified')
                bad = call({**BASE, 'text': ''}, 'selection-invalid')
                self.assertFalse(bad['ok']); self.assertEqual(fake.calls, ['select_text', 'select_text'])
                self.assertEqual(bad['execution']['event_count'], 0)
        finally:
            if server._RUNTIME: server._RUNTIME.close()
            server.BRIDGE, server._RUNTIME = previous


if __name__ == '__main__': unittest.main()
