"""Exact semantic bindings and registered background plans; no native UI starts."""
import copy
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import server
from chat_workflows import FEISHU, WECHAT
from desktop_transactions import execute_transaction, select_element, validate_plan
from task_runtime import current_context
from test_background_chat_edit import BackgroundFake as EditFake
from test_model_observation import BackgroundFake as ObserveFake


ROOT = Path(__file__).resolve().parents[1]
PLANS = ROOT / "plans"
APP = "com.apple.TextEdit"
WINDOW = "SemanticFixture"
TEXT = "OFFLINE_SEMANTIC_PRIVATE_VALUE_68"
CHAT = "OFFLINE_CURRENT_RECIPIENT_68"


def node(identity, role, *, parent=None, depth=1, **fields):
    value = {"element_id": identity, "role": role, "secure": False, "enabled": True,
             "depth": depth, "title": "", "description": "", **fields}
    if parent is not None:
        value["parent_id"] = parent
    return value


class SemanticDispatch:
    allowed_arguments = staticmethod(server.action_arguments)

    def __init__(self):
        self.calls = []
        self.mutations = []
        self.text = ""
        self.reads = 0
        self.modify_read = None
        self.elements = [
            node("main", "AXWindow", depth=0, title=WINDOW, subrole="AXStandardWindow"),
            node("dialog", "AXWindow", depth=0, title="ConfirmFixture", subrole="AXDialog"),
            node("main-panel", "AXGroup", parent="main", identifier="message-panel"),
            node("dialog-panel", "AXGroup", parent="dialog", identifier="confirm-panel"),
            node("main-input", "AXTextArea", parent="main-panel", depth=2,
                 identifier="main-editor", subrole="AXContentEditor", value="", value_truncated=False),
            node("dialog-input", "AXTextArea", parent="dialog-panel", depth=2,
                 identifier="dialog-editor", subrole="AXContentEditor", value="", value_truncated=False),
        ]
        self.menus = [
            node("bar", "AXMenuBar", depth=0, menu_path=[]),
            node("file", "AXMenuBarItem", parent="bar", title="File", menu_path=["File"]),
            node("file-menu", "AXMenu", parent="file", depth=2, menu_path=["File"]),
            node("save", "AXMenuItem", parent="file-menu", depth=3, title="Save", menu_path=["File", "Save"]),
            node("window", "AXMenuBarItem", parent="bar", title="Window", menu_path=["Window"]),
            node("window-menu", "AXMenu", parent="window", depth=2, menu_path=["Window"]),
            node("other-save", "AXMenuItem", parent="window-menu", depth=3, title="Save", menu_path=["Window", "Save"]),
        ]

    def __call__(self, tool, arguments):
        server.validate(tool, arguments)
        self.calls.append((tool, copy.deepcopy(arguments)))
        result = {"app": APP, "window_title": arguments.get("window_title", WINDOW),
                  "target_pid": 777, "window_id": 12}
        if tool == "inspect":
            self.reads += 1
            elements = copy.deepcopy(self.elements)
            for item in elements:
                if item["role"] == "AXTextArea":
                    item["value"] = self.text
            result.update(elements=elements, windows=[e for e in elements if e["role"] == "AXWindow"],
                          truncated=False, values_max_characters=4000)
            if arguments.get("include_menus"):
                result.update(menu_elements=copy.deepcopy(self.menus), menus_available=True, menus_truncated=False)
            if self.modify_read:
                self.modify_read(result, self.reads)
        elif tool in {"set_text", "type_text", "clear_text", "press"}:
            self.mutations.append((tool, copy.deepcopy(arguments)))
            self.text = arguments.get("text", arguments.get("expected_empty_value", self.text))
            result.update(value_verified=True, events_posted=2)
        else:
            raise AssertionError("Extend this offline fixture deliberately: " + tool)
        return {"ok": True, "result": result}


def semantic_plan(selector=None, *, menu=False):
    selector = selector or {"role": "AXTextArea", "identifier": "main-editor"}
    action = "press" if menu else "set_text"
    arguments = {"element_id": {"$element": {"step": "before", **selector}}}
    if not menu:
        arguments["text"] = {"$param": "text"}
    return {"app": APP, "window_title": WINDOW, "parameters": {"text": TEXT},
            "steps": [{"id": "before", "tool": "inspect", "arguments": {"include_menus": menu}},
                      {"id": "write", "tool": action, "arguments": arguments},
                      {"id": "after", "tool": "inspect", "arguments": {}}],
            "postconditions": [{"step": "after", "element": {"role": "AXTextArea", "identifier": "main-editor"},
                                "attribute": "value", "equals": "" if menu else {"$param": "text"}}]}


class ExactSemanticTests(unittest.TestCase):
    def run_plan(self, plan=None, fake=None):
        fake = fake or SemanticDispatch()
        return execute_transaction(plan or semantic_plan(), fake), fake

    def assert_stopped_before_input(self, response, fake):
        self.assertFalse(response["ok"], response)
        self.assertEqual(fake.mutations, [])
        self.assertFalse(response["result"]["verified"])

    def test_identifier_and_subrole_bind_and_check_exact_current_node(self):
        selector = {"role": "AXTextArea", "identifier": "main-editor", "subrole": "AXContentEditor"}
        plan = semantic_plan(selector)
        plan["postconditions"][0]["element"] = selector
        response, fake = self.run_plan(plan)
        self.assertTrue(response["ok"], response)
        self.assertEqual(fake.mutations[0][1]["element_id"], "main-input")
        self.assertEqual(response["result"]["verification"]["checks"], 1)

    def test_exact_identifiers_never_use_normalization_prefix_or_fuzzy_matching(self):
        for identity in ("main-edit", "MAIN-EDITOR", "main-editor ", "main editor"):
            with self.subTest(identity=identity):
                response, fake = self.run_plan(semantic_plan({"role": "AXTextArea", "identifier": identity}))
                self.assert_stopped_before_input(response, fake)

    def test_parent_scope_disambiguates_same_role_in_two_windows(self):
        selector = {"role": "AXTextArea", "parent": {"role": "AXGroup", "identifier": "message-panel"}}
        response, fake = self.run_plan(semantic_plan(selector))
        self.assertTrue(response["ok"], response)
        self.assertEqual(fake.mutations[0][1]["element_id"], "main-input")

    def test_ancestor_scope_and_nested_parent_use_native_parent_identity(self):
        for selector in (
            {"role": "AXTextArea", "ancestor": {"role": "AXWindow", "title": WINDOW, "subrole": "AXStandardWindow"}},
            {"role": "AXTextArea", "parent": {"role": "AXGroup", "parent": {"role": "AXWindow", "title": WINDOW}}},
        ):
            with self.subTest(selector=selector):
                response, fake = self.run_plan(semantic_plan(selector))
                self.assertTrue(response["ok"], response)
                self.assertEqual(fake.mutations[0][1]["element_id"], "main-input")

    def test_direct_parent_is_not_interchangeable_with_ancestor(self):
        response, fake = self.run_plan(semantic_plan({"role": "AXTextArea", "parent": {"role": "AXWindow", "title": WINDOW}}))
        self.assert_stopped_before_input(response, fake)

    def test_dialog_selector_binds_only_its_exact_window_root(self):
        selector = {"role": "AXTextArea", "ancestor": {"role": "AXWindow", "subrole": "AXDialog", "title": "ConfirmFixture"}}
        plan = semantic_plan(selector)
        plan["window_title"] = "ConfirmFixture"
        plan["postconditions"][0]["element"] = selector
        response, fake = self.run_plan(plan)
        self.assertTrue(response["ok"], response)
        self.assertEqual(fake.mutations[0][1]["element_id"], "dialog-input")

    def test_cross_window_identity_ref_and_selector_stop_before_input(self):
        for reference in ({"$element": {"step": "before", "role": "AXTextArea", "identifier": "dialog-editor"}},
                          {"$ref": "before/result/elements/5/element_id"}):
            with self.subTest(reference=reference):
                plan = semantic_plan()
                plan["steps"][1]["arguments"]["element_id"] = reference
                response, fake = self.run_plan(plan)
                self.assert_stopped_before_input(response, fake)

    def test_same_title_window_roots_are_ambiguous_even_with_one_exact_editor(self):
        fake = SemanticDispatch()
        fake.elements[1]["title"] = WINDOW
        response, _ = self.run_plan(fake=fake)
        self.assert_stopped_before_input(response, fake)

    def test_duplicate_identifiers_need_exact_scope_and_unscoped_ambiguity_stops(self):
        fake = SemanticDispatch()
        fake.elements[5]["identifier"] = "main-editor"
        response, _ = self.run_plan(fake=fake)
        self.assert_stopped_before_input(response, fake)
        selector = {"role": "AXTextArea", "identifier": "main-editor", "ancestor": {"role": "AXWindow", "title": WINDOW}}
        plan = semantic_plan(selector)
        plan["postconditions"][0]["element"] = selector
        fake = SemanticDispatch()
        fake.elements[5]["identifier"] = "main-editor"
        response, _ = self.run_plan(plan, fake)
        self.assertTrue(response["ok"], response)

    def test_ambiguous_scope_is_not_replaced_by_first_matching_parent(self):
        fake = SemanticDispatch()
        fake.elements[3]["identifier"] = "message-panel"
        response, _ = self.run_plan(semantic_plan({"role": "AXTextArea", "parent": {"role": "AXGroup", "identifier": "message-panel"}}), fake)
        self.assert_stopped_before_input(response, fake)

    def test_incomplete_or_cyclic_parent_chain_cannot_prove_scope(self):
        for parent in ("missing-parent", "main-input"):
            with self.subTest(parent=parent):
                fake = SemanticDispatch()
                fake.elements[4]["parent_id"] = parent
                response, _ = self.run_plan(semantic_plan({"role": "AXTextArea", "ancestor": {"role": "AXWindow", "title": WINDOW}}), fake)
                self.assert_stopped_before_input(response, fake)

    def test_menu_path_selects_actual_menu_elements_and_exact_parent_scope(self):
        for selector in ({"role": "AXMenuItem", "menu_path": ["File", "Save"]},
                         {"role": "AXMenuItem", "title": "Save", "parent": {"role": "AXMenu", "parent": {"role": "AXMenuBarItem", "title": "File"}}}):
            with self.subTest(selector=selector):
                fake = SemanticDispatch()
                fake.elements = [item for item in fake.elements if not item["element_id"].startswith("dialog")]
                response, _ = self.run_plan(semantic_plan(selector, menu=True), fake)
                self.assertTrue(response["ok"], response)
                self.assertEqual(fake.mutations[0][1]["element_id"], "save")

    def test_menu_title_alone_is_ambiguous_and_wrong_path_never_guesses(self):
        for selector in ({"role": "AXMenuItem", "title": "Save"}, {"role": "AXMenuItem", "menu_path": ["file", "Save"]}):
            with self.subTest(selector=selector):
                response, fake = self.run_plan(semantic_plan(selector, menu=True))
                self.assert_stopped_before_input(response, fake)

    def test_menu_binding_cannot_cross_ambiguous_window_roots(self):
        response, fake = self.run_plan(semantic_plan({"role": "AXMenuItem", "menu_path": ["File", "Save"]}, menu=True))
        self.assert_stopped_before_input(response, fake)

    def test_truncated_inspect_cannot_bind_selector_or_element_id_reference(self):
        for reference in ({"$element": {"step": "before", "role": "AXTextArea", "identifier": "main-editor"}},
                          {"$ref": "before/result/elements/4/element_id"}):
            for truncated in (True, None):
                with self.subTest(reference=reference, truncated=truncated):
                    fake = SemanticDispatch()
                    fake.modify_read = lambda result, count: result.update(truncated=truncated)
                    plan = semantic_plan()
                    plan["steps"][1]["arguments"]["element_id"] = reference
                    response, _ = self.run_plan(plan, fake)
                    self.assert_stopped_before_input(response, fake)

    def test_menu_completeness_must_be_explicit(self):
        for field, value in (("menus_truncated", True), ("menus_truncated", None), ("menus_available", False)):
            with self.subTest(field=field, value=value):
                fake = SemanticDispatch()
                fake.elements = [item for item in fake.elements if not item["element_id"].startswith("dialog")]
                fake.modify_read = lambda result, count: result.update({field: value})
                response, _ = self.run_plan(semantic_plan({"role": "AXMenuItem", "menu_path": ["File", "Save"]}, menu=True), fake)
                self.assert_stopped_before_input(response, fake)

    def test_secure_unknown_security_and_disabled_nodes_cannot_bind_input(self):
        for field, value in (("secure", True), ("secure", None), ("enabled", False), ("subrole", "AXSecureTextField")):
            for reference in ({"$element": {"step": "before", "role": "AXTextArea", "identifier": "main-editor"}},
                              {"$ref": "before/result/elements/4/element_id"}):
                with self.subTest(field=field, value=value, reference=reference):
                    fake = SemanticDispatch()
                    fake.elements[4][field] = value
                    plan = semantic_plan()
                    plan["steps"][1]["arguments"]["element_id"] = reference
                    response, _ = self.run_plan(plan, fake)
                    self.assert_stopped_before_input(response, fake)

    def test_unknown_selector_fields_are_rejected_before_any_native_call(self):
        for selector in ({"role": "AXTextArea", "contains": "editor"},
                         {"role": "AXTextArea", "parent": {"role": "AXGroup", "nearest": True}}):
            with self.subTest(selector=selector):
                fake = SemanticDispatch()
                with self.assertRaises(ValueError):
                    execute_transaction(semantic_plan(selector), fake)
                self.assertEqual(fake.calls, [])

    def test_parameterized_scope_is_exact_and_missing_parameter_stops_before_inspect(self):
        selector = {"role": "AXTextArea", "ancestor": {"role": "AXWindow", "title": {"$param": "window"}}}
        plan = semantic_plan(selector)
        plan["parameters"]["window"] = WINDOW
        response, _ = self.run_plan(plan)
        self.assertTrue(response["ok"], response)
        plan["parameters"].pop("window")
        fake = SemanticDispatch()
        with self.assertRaises(ValueError):
            execute_transaction(plan, fake)
        self.assertEqual(fake.calls, [])

    def test_only_a_prior_inspect_in_this_invocation_can_supply_an_element(self):
        for step in ("after", "absent"):
            with self.subTest(step=step):
                plan = semantic_plan()
                plan["steps"][1]["arguments"]["element_id"]["$element"]["step"] = step
                fake = SemanticDispatch()
                with self.assertRaises(ValueError):
                    execute_transaction(plan, fake)
                self.assertEqual(fake.calls, [])

    def test_element_id_reference_cannot_bind_an_arbitrary_inspection_attribute(self):
        plan = semantic_plan()
        plan["steps"][1]["arguments"]["element_id"] = {"$ref": "before/result/elements/4/identifier"}
        fake = SemanticDispatch()
        with self.assertRaises(ValueError):
            execute_transaction(plan, fake)
        self.assertEqual(fake.calls, [])

    def test_truncated_or_unknown_full_ax_value_cannot_complete_postcondition(self):
        for change in ({"value_truncated": True}, {"value_complete": False}, {"value": None}, {"drop_value": True}):
            with self.subTest(change=change):
                fake = SemanticDispatch()

                def alter(result, count):
                    if count == 2:
                        item = result["elements"][4]
                        item.update({key: value for key, value in change.items() if key != "drop_value"})
                        if change.get("drop_value"):
                            item.pop("value", None)

                fake.modify_read = alter
                response, _ = self.run_plan(fake=fake)
                self.assertFalse(response["ok"], response)
                self.assertEqual(len(fake.mutations), 1)

    def test_native_value_cap_without_explicit_completeness_is_not_full_value(self):
        for text in (TEXT, "x" * 4000):
            with self.subTest(length=len(text)):
                fake = SemanticDispatch()
                plan = semantic_plan()
                plan["parameters"]["text"] = text

                def alter(result, count):
                    for item in result["elements"]:
                        if item["role"] == "AXTextArea":
                            item.pop("value_truncated")

                fake.modify_read = alter
                response, _ = self.run_plan(plan, fake)
                self.assertFalse(response["ok"])
                self.assertEqual(len(fake.mutations), 1)

    def test_exact_value_at_native_cap_passes_with_positive_complete_value_proof(self):
        fake = SemanticDispatch()
        plan = semantic_plan()
        plan["parameters"]["text"] = "x" * 4000

        def alter(result, count):
            for item in result["elements"]:
                if item["role"] == "AXTextArea":
                    item["value_complete"] = True

        fake.modify_read = alter
        response, _ = self.run_plan(plan, fake)
        self.assertTrue(response["ok"], response)

    def test_before_complete_value_check_stops_before_later_input(self):
        fake = SemanticDispatch()
        fake.text = TEXT + " existing"
        plan = semantic_plan()
        plan["postconditions"].insert(0, {"step": "before", "element": {"role": "AXTextArea", "identifier": "main-editor"},
                                        "attribute": "value", "equals": ""})
        response, _ = self.run_plan(plan, fake)
        self.assert_stopped_before_input(response, fake)
        self.assertEqual(response["result"]["failed_step"], "before")

    def test_parameter_names_unknown_fields_and_self_referenced_equals_fail_preflight(self):
        for change in ("unknown", "missing", "extra", "self_ref", "bad_name"):
            with self.subTest(change=change):
                plan = semantic_plan()
                if change == "unknown":
                    plan["guessed_fallback"] = True
                elif change in {"missing", "extra"}:
                    plan["parameter_names"] = ["text"]
                    if change == "missing":
                        plan["parameters"].pop("text")
                    else:
                        plan["parameters"]["retained_chat"] = CHAT
                elif change == "self_ref":
                    plan["postconditions"][0]["equals"] = {"$ref": "after/result/elements/4/value"}
                else:
                    plan["parameter_names"] = ["text", {}]
                fake = SemanticDispatch()
                with self.assertRaises(ValueError):
                    execute_transaction(plan, fake)
                self.assertEqual(fake.calls, [])


class ChatNativeBridge:
    """Existing native edit/observation fakes sharing the same selected composer."""

    def __init__(self, app):
        self.edit = EditFake(app)
        self.base = self.edit.base
        self.base.title = CHAT
        self.observation = ObserveFake(self.base)
        self.calls = []
        self.reads = 0
        self.edit_count = 0
        self.draft_on_read = {}
        self.title_on_read = {}
        self.incomplete_on_read = None
        self.target_change_on_read = None
        self.target_change_field = "window_id"
        self.identity_change_on_read = None
        self.identity_change_kind = None
        self.omit_cg_window_id = False
        self.failure_on_edit = None

    def call(self, command, arguments):
        server.validate(command, arguments)
        self.calls.append((command, copy.deepcopy(arguments)))
        request = {"command": command, **arguments}
        if command == "background_chat_edit":
            self.edit_count += 1
            self.edit.fail = self.edit_count == self.failure_on_edit
            response = self.edit(request)
        else:
            if command in {"background_visual_read", "background_observe"}:
                self.reads += 1
                if self.reads in self.draft_on_read:
                    self.base.draft = self.draft_on_read[self.reads]
                if self.reads in self.title_on_read:
                    self.base.title = self.title_on_read[self.reads]
            response = self.observation(request)
            if response["ok"] and command != "status":
                value = response["result"]
                value["window_id"] = 600
                value["window_frame"] = dict(self.base.frame)
                value["display_topology_signature"] = "semantic-fixture-topology"
                if command == "background_observe":
                    value.update(generation=7, read_strategy="fresh_full_tree_batched_attributes",
                                 observer_policy="advisory_invalidation_always_refetch_no_background_polling")
                else:
                    value["generation"] = 100 + self.reads
                if self.reads == self.target_change_on_read:
                    value[self.target_change_field] += 1
                if self.reads == self.identity_change_on_read:
                    if self.identity_change_kind == "frame":
                        value["window_frame"]["x"] += 5
                    elif self.identity_change_kind == "topology":
                        value["display_topology_signature"] = "changed-semantic-topology"
                    elif self.identity_change_kind == "generation":
                        value["generation"] += 1
                if self.omit_cg_window_id:
                    value.pop("window_id", None)
                if self.reads == self.incomplete_on_read:
                    if command == "background_visual_read":
                        value["ocr_truncated"] = True
                    else:
                        for item in value["elements"]:
                            if item.get("element_id") == "composer":
                                item["value_truncated"] = True
                                item["value_complete"] = False
        context = current_context()
        if context:
            context.record_native(response, substage=command)
        return response


class RegisteredBackgroundPlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.previous_bridge, self.previous_runtime = server.BRIDGE, server._RUNTIME
        server._RUNTIME = None
        self.environment = patch.dict(os.environ, {"INTEL_DESKTOP_RUNTIME_DIR": str(self.directory)})
        self.environment.start()
        self.guard = patch.object(server.NativeBridge, "start", side_effect=AssertionError("Native start forbidden"))
        self.guard.start()
        self.sequence = 0

    def tearDown(self):
        self.guard.stop()
        self.environment.stop()
        if server._RUNTIME is not None:
            server._RUNTIME.close()
        server.BRIDGE, server._RUNTIME = self.previous_bridge, self.previous_runtime
        self.temp.cleanup()

    def call(self, name, arguments, *, operation_id=None):
        self.sequence += 1
        result = server.handle({"jsonrpc": "2.0", "id": self.sequence, "method": "tools/call", "params": {
            "name": "desktop_" + name, "arguments": {**arguments, "task_id": "semantic-fixture-task",
                                                        "operation_id": operation_id or "semantic-operation-" + str(self.sequence)}}})
        return json.loads(result["content"][0]["text"])

    def prepare(self, app):
        name = "wechat" if app == WECHAT else "feishu"
        source = self.directory / (name + "-template.json")
        source.write_bytes((PLANS / (name + "-background-draft-owned-clear.json")).read_bytes())
        server.BRIDGE = ChatNativeBridge(app)
        response = self.call("script", {"action": "register", "app": app, "source_path": str(source),
                                        "parameter_names": ["chat", "text"], "purpose": "background_draft_owned_clear"})
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["parameterization_candidate"], response)
        return source, response["result"], server.BRIDGE

    def run_registered(self, app, row, **extra):
        return self.call("script", {"action": "run", "app": app, "script_id": row["id"],
                                    "parameters": {"chat": CHAT, "text": TEXT}}, **extra)

    def test_both_templates_register_execute_one_fifo_and_verify_all_current_checks(self):
        for app in (WECHAT, FEISHU):
            with self.subTest(app=app):
                source, row, fake = self.prepare(app)
                response = self.run_registered(app, row)
                self.assertTrue(response["ok"], response)
                self.assertTrue(response["result"]["verified"])
                self.assertEqual(response["result"]["verification"]["checks"], 16)
                self.assertEqual(response["result"]["completed_steps"], 5)
                self.assertEqual(fake.base.draft, "")
                self.assertEqual(fake.edit_count, 2)
                self.assertEqual(fake.reads, 3)
                self.assertTrue(all(command in {"status", "background_chat_edit", "background_visual_read", "background_observe"}
                                    for command, _ in fake.calls))
                self.assertEqual([arguments["operation"] for command, arguments in fake.calls if command == "background_chat_edit"], ["type", "clear"])
                evidence = server.runtime().script_execution_evidence(response["operation_id"])
                self.assertEqual(evidence["source_sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
                self.assertEqual(evidence["source_sha256"], row["source_sha256"])
                self.assertTrue(evidence["verification"]["passed"])
                self.assertEqual(evidence["parameter_names"], ["chat", "text"])
                with closing(sqlite3.connect(self.directory / "runtime.sqlite3")) as database:
                    metadata = json.dumps(database.execute("SELECT * FROM operations").fetchall())
                    metadata += json.dumps(database.execute("SELECT * FROM events").fetchall())
                metadata += (self.directory / "learning.json").read_text()
                self.assertNotIn(TEXT, metadata)
                self.assertNotIn(CHAT, metadata)

    def test_initial_nonempty_complete_draft_blocks_all_mutations(self):
        for app in (WECHAT, FEISHU):
            with self.subTest(app=app):
                _, row, fake = self.prepare(app)
                fake.base.draft = TEXT + " existing"
                response = self.run_registered(app, row)
                self.assertFalse(response["ok"])
                self.assertEqual(response["result"]["failed_step"], "before")
                self.assertEqual(fake.edit_count, 0)
                self.assertEqual(fake.base.draft, TEXT + " existing")

    def test_after_draft_full_value_mismatch_preserves_changed_draft_and_never_clears(self):
        for app in (WECHAT, FEISHU):
            with self.subTest(app=app):
                _, row, fake = self.prepare(app)
                fake.draft_on_read[2] = TEXT + " external edit"
                response = self.run_registered(app, row)
                self.assertFalse(response["ok"])
                self.assertEqual(response["result"]["failed_step"], "after_draft")
                self.assertEqual(fake.edit_count, 1)
                self.assertEqual(fake.base.draft, TEXT + " external edit")

    def test_initial_or_restored_wrong_recipient_stops_before_next_input(self):
        for read in (1, 2):
            for app in (WECHAT, FEISHU):
                with self.subTest(read=read, app=app):
                    _, row, fake = self.prepare(app)
                    fake.title_on_read[read] = "OFFLINE_OTHER_RECIPIENT"
                    response = self.run_registered(app, row)
                    self.assertFalse(response["ok"])
                    self.assertEqual(fake.edit_count, read - 1)

    def test_incomplete_composer_before_or_after_draft_stops_remaining_input(self):
        for read in (1, 2):
            for app in (WECHAT, FEISHU):
                with self.subTest(read=read, app=app):
                    _, row, fake = self.prepare(app)
                    fake.incomplete_on_read = read
                    response = self.run_registered(app, row)
                    self.assertFalse(response["ok"], response)
                    self.assertEqual(fake.edit_count, read - 1)

    def test_native_target_window_change_prevents_owned_clear(self):
        for app in (WECHAT, FEISHU):
            for field in ("window_id", "target_pid"):
                with self.subTest(app=app, field=field):
                    _, row, fake = self.prepare(app)
                    fake.target_change_on_read = 2
                    fake.target_change_field = field
                    response = self.run_registered(app, row)
                    self.assertFalse(response["ok"])
                    self.assertEqual(fake.edit_count, 1)
                    self.assertEqual(fake.base.draft, TEXT)

    def test_stable_pid_frame_or_topology_change_stops_after_draft_before_clear(self):
        for app in (WECHAT, FEISHU):
            for change in ("frame", "topology"):
                with self.subTest(app=app, change=change):
                    _, row, fake = self.prepare(app)
                    original_pid = fake.base.pid
                    fake.omit_cg_window_id = True
                    fake.identity_change_on_read = 2
                    fake.identity_change_kind = change
                    response = self.run_registered(app, row)
                    self.assertFalse(response["ok"], response)
                    self.assertEqual(fake.base.pid, original_pid)
                    self.assertEqual(fake.edit_count, 1)
                    self.assertEqual(fake.base.draft, TEXT)
                    self.assertEqual(fake.reads, 2)

    def test_native_observation_generation_change_without_cg_id_stops_owned_clear(self):
        _, row, fake = self.prepare(FEISHU)
        fake.omit_cg_window_id = True
        fake.identity_change_on_read = 2
        fake.identity_change_kind = "generation"
        original_pid = fake.base.pid
        response = self.run_registered(FEISHU, row)
        self.assertFalse(response["ok"], response)
        self.assertEqual(fake.base.pid, original_pid)
        self.assertEqual(fake.edit_count, 1)
        self.assertEqual(fake.base.draft, TEXT)
        self.assertEqual(fake.reads, 2)

    def test_visual_snapshot_generation_changes_do_not_masquerade_as_window_changes(self):
        _, row, fake = self.prepare(WECHAT)
        fake.omit_cg_window_id = True
        response = self.run_registered(WECHAT, row)
        self.assertTrue(response["ok"], response)
        generations = [step["response"]["result"]["state"]["generation"] for step in response["result"]["steps"]
                       if step["tool"] == "observe"]
        self.assertEqual(generations, [101, 102, 103])
        self.assertEqual(fake.edit_count, 2)

    def test_final_read_is_complete_empty_and_same_target_without_replaying_clear(self):
        for app in (WECHAT, FEISHU):
            for change in ("draft", "incomplete", "window"):
                with self.subTest(app=app, change=change):
                    _, row, fake = self.prepare(app)
                    if change == "draft":
                        fake.draft_on_read[3] = TEXT + " newly entered"
                    elif change == "incomplete":
                        fake.incomplete_on_read = 3
                    else:
                        fake.target_change_on_read = 3
                    response = self.run_registered(app, row)
                    self.assertFalse(response["ok"], response)
                    self.assertEqual(fake.edit_count, 2)
                    self.assertFalse(response["result"]["verified"])
                    self.assertEqual(fake.reads, 3)

    def test_unknown_native_edit_completion_never_falls_back_or_replays(self):
        for app in (WECHAT, FEISHU):
            with self.subTest(app=app):
                _, row, fake = self.prepare(app)
                fake.failure_on_edit = 1
                response = self.run_registered(app, row, operation_id="unknown-edit-" + app)
                self.assertFalse(response["ok"])
                count = len(fake.calls)
                duplicate = self.run_registered(app, row, operation_id="unknown-edit-" + app)
                self.assertFalse(duplicate["execution"]["executed"])
                self.assertEqual(len(fake.calls), count)
                self.assertEqual(fake.edit_count, 1)

    def test_missing_extra_parameters_and_unknown_template_field_execute_nothing(self):
        for change in ("missing", "extra", "unknown"):
            with self.subTest(change=change):
                source, row, fake = self.prepare(WECHAT)
                parameters = {"chat": CHAT, "text": TEXT}
                if change == "missing":
                    parameters.pop("chat")
                elif change == "extra":
                    parameters["authority"] = True
                else:
                    plan = json.loads(source.read_text())
                    plan["on_failure"] = "replay"
                    source.write_text(json.dumps(plan))
                response = self.call("script", {"action": "run", "app": WECHAT, "script_id": row["id"], "parameters": parameters})
                self.assertFalse(response["ok"])
                self.assertEqual(fake.calls, [])

    def test_new_source_digest_is_bound_to_each_execution_without_old_maturity(self):
        source, row, fake = self.prepare(WECHAT)
        first = self.run_registered(WECHAT, row)
        self.assertTrue(first["ok"], first)
        source.write_bytes(source.read_bytes() + b"\n")
        listing = self.call("script", {"action": "list"})
        current = next(item for item in listing["result"]["scripts"] if item["id"] == row["id"])
        self.assertEqual(current["verified_successes"], 0)
        self.assertNotEqual(current["source_sha256"], row["source_sha256"])
        second = self.run_registered(WECHAT, current)
        self.assertTrue(second["ok"], second)
        evidence = server.runtime().script_execution_evidence(second["operation_id"])
        self.assertEqual(evidence["source_sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
        self.assertEqual(fake.edit_count, 4)

    def test_background_receipt_checks_cannot_be_dynamic_or_replace_final_complete_read(self):
        source = PLANS / "wechat-background-draft-owned-clear.json"
        for change in ("wrong_boolean", "dynamic_expected", "content_path", "parameter_action", "parameter_background", "no_final_full_read"):
            with self.subTest(change=change):
                plan = json.loads(source.read_text())
                receipt = next(item for item in plan["postconditions"] if item["step"] == "draft")
                if change == "wrong_boolean":
                    receipt["equals"] = False
                elif change == "dynamic_expected":
                    receipt["equals"] = {"$param": "text"}
                elif change == "content_path":
                    receipt["path"] = "/result/draft"
                elif change == "parameter_action":
                    plan["steps"][1]["arguments"]["action"] = {"$param": "text"}
                elif change == "parameter_background":
                    plan["steps"][1]["arguments"]["background"] = {"$param": "text"}
                else:
                    plan["postconditions"] = [item for item in plan["postconditions"] if item.get("path") != "/result/composer/draft"]
                with self.assertRaises(ValueError):
                    validate_plan(plan)


class SelectionDispatch(SemanticDispatch):
    """AX selection-only fixture with new current identities after each inspect."""

    def __init__(self):
        super().__init__()
        self.text = "🙂离线原始内容\n末行"
        self.selection = {"location": 2, "length": 2}
        self.modify_receipt = None
        self.change_selection_on_read = None
        self.latest_editor_id = None

    def __call__(self, tool, arguments):
        if tool != "select_text":
            hook = self.modify_read if tool == "inspect" else None
            self.modify_read = None
            try:
                response = super().__call__(tool, arguments)
            finally:
                self.modify_read = hook
            if tool == "inspect":
                if self.reads == self.change_selection_on_read:
                    self.selection = {"location": 2, "length": 1}
                items = response["result"]["elements"]
                identities = {item["element_id"]: "selection-" + str(self.reads) + "-" + item["element_id"] for item in items}
                for item in items:
                    original_id = item["element_id"]
                    item["element_id"] = identities[original_id]
                    if "parent_id" in item:
                        item["parent_id"] = identities[item["parent_id"]]
                    if item["role"] == "AXTextArea":
                        item["value_complete"] = True
                        item["selected_range"] = dict(self.selection)
                    if original_id == "main-input":
                        self.latest_editor_id = item["element_id"]
                if hook:
                    hook(response["result"], self.reads)
            return response
        server.validate(tool, arguments)
        self.calls.append((tool, copy.deepcopy(arguments)))
        if (arguments["element_id"] != self.latest_editor_id or arguments["expected_value"] != self.text
                or arguments.get("expected_selection", self.selection) != self.selection):
            return {"ok": False, "error": {"code": "selection_precondition_changed", "message": "Offline exact selection guard", "details": {"events_posted": 0}}}
        previous = dict(self.selection)
        if "text" in arguments:
            if arguments["text"] != self.text:
                raise AssertionError("This fixture selects only the complete exact value")
            self.selection = {"location": 0, "length": len(self.text.encode("utf-16-le")) // 2}
        else:
            self.selection = dict(arguments["range"])
        self.mutations.append((tool, copy.deepcopy(arguments)))
        result = {"selection_verified": True, "value_verified": True, "text_unchanged": True,
                  "system_focus_preserved": True, "events_posted": 0,
                  "selection": dict(self.selection), "previous_selection": previous}
        if self.modify_receipt:
            self.modify_receipt(result, len(self.mutations))
        return {"ok": True, "result": result}

    def call(self, tool, arguments):
        response = self(tool, arguments)
        context = current_context()
        if context:
            context.record_native(response, substage=tool)
        return response


class BackgroundSelectionPlanTests(unittest.TestCase):
    def plan(self, fake):
        plan = json.loads((PLANS / "textedit-background-select-restore.json").read_text())
        plan["parameters"] = {"window_title": WINDOW, "value": fake.text,
                              "original_location": fake.selection["location"], "original_length": fake.selection["length"],
                              "selected_length": len(fake.text.encode("utf-16-le")) // 2}
        return plan

    def test_third_template_selects_and_restores_without_text_or_focus_events(self):
        fake = SelectionDispatch()
        value, original = fake.text, dict(fake.selection)
        response = execute_transaction(self.plan(fake), fake)
        self.assertTrue(response["ok"], response)
        self.assertEqual(response["result"]["verification"]["checks"], 15)
        self.assertEqual(fake.text, value)
        self.assertEqual(fake.selection, original)
        self.assertEqual([tool for tool, _ in fake.calls], ["inspect", "select_text", "inspect", "select_text", "inspect"])
        self.assertEqual([args["element_id"] for tool, args in fake.mutations], ["selection-1-main-input", "selection-2-main-input"])
        self.assertTrue(all(args["background"] is True for _, args in fake.mutations))

    def test_before_value_or_original_selection_mismatch_prevents_all_selection_changes(self):
        for field in ("value", "original_location", "original_length"):
            with self.subTest(field=field):
                fake = SelectionDispatch()
                plan = self.plan(fake)
                plan["parameters"][field] = "different value" if field == "value" else 3
                response = execute_transaction(plan, fake)
                self.assertFalse(response["ok"])
                self.assertEqual(response["result"]["failed_step"], "before")
                self.assertEqual(fake.mutations, [])

    def test_selected_value_change_stops_before_restore_without_rewriting_text(self):
        fake = SelectionDispatch()
        plan = self.plan(fake)

        def change(result, count):
            if count == 2:
                fake.text += " external text"
                for item in result["elements"]:
                    if item["role"] == "AXTextArea":
                        item["value"] = fake.text

        fake.modify_read = change
        response = execute_transaction(plan, fake)
        self.assertFalse(response["ok"])
        self.assertEqual(response["result"]["failed_step"], "selected")
        self.assertEqual(len(fake.mutations), 1)
        self.assertTrue(fake.text.endswith(" external text"))

    def test_changed_current_selection_refuses_restore_without_replay(self):
        fake = SelectionDispatch()
        fake.change_selection_on_read = 2
        response = execute_transaction(self.plan(fake), fake)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "selection_precondition_changed")
        self.assertEqual(len(fake.mutations), 1)
        self.assertEqual(sum(tool == "select_text" for tool, _ in fake.calls), 2)
        self.assertEqual(fake.selection, {"location": 2, "length": 1})

    def test_failed_selection_or_background_focus_receipt_stops_remaining_steps(self):
        for field in ("selection_verified", "system_focus_preserved"):
            with self.subTest(field=field):
                fake = SelectionDispatch()
                fake.modify_receipt = lambda result, count: result.update({field: False})
                response = execute_transaction(self.plan(fake), fake)
                self.assertFalse(response["ok"])
                self.assertEqual(response["result"]["failed_step"], "select")
                self.assertEqual([tool for tool, _ in fake.calls], ["inspect", "select_text"])

    def test_actual_selection_range_mismatch_stops_before_restore(self):
        fake = SelectionDispatch()
        plan = self.plan(fake)
        plan["parameters"]["selected_length"] -= 1
        response = execute_transaction(plan, fake)
        self.assertFalse(response["ok"])
        self.assertEqual(response["result"]["failed_step"], "select")
        self.assertEqual(len(fake.mutations), 1)

    def test_final_original_selection_requires_fresh_complete_inspect(self):
        for change in ("range", "value", "complete"):
            with self.subTest(change=change):
                fake = SelectionDispatch()

                def alter(result, count):
                    if count == 3:
                        item = next(item for item in result["elements"] if item.get("identifier") == "main-editor")
                        if change == "range":
                            item["selected_range"]["length"] += 1
                        elif change == "value":
                            item["value"] += " unverified"
                        else:
                            item["value_complete"] = False

                fake.modify_read = alter
                response = execute_transaction(self.plan(fake), fake)
                self.assertFalse(response["ok"], response)
                self.assertEqual(len(fake.mutations), 2)
                self.assertEqual(fake.reads, 3)

    def test_foreground_missing_or_parameterized_background_plans_fail_before_any_read(self):
        for background in (False, None, {"$param": "original_length"}):
            with self.subTest(background=background):
                fake = SelectionDispatch()
                plan = self.plan(fake)
                if background is None:
                    plan["steps"][1]["arguments"].pop("background")
                else:
                    plan["steps"][1]["arguments"]["background"] = background
                with self.assertRaises(ValueError):
                    execute_transaction(plan, fake)
                self.assertEqual(fake.calls, [])

    def test_receipt_api_fixed_flags_and_previous_range_fields_are_exact(self):
        checks = [("selection_verified", True), ("value_verified", True), ("text_unchanged", True),
                  ("system_focus_preserved", True), ("events_posted", 0),
                  ("previous_selection/location", {"$param": "original_location"}),
                  ("previous_selection/length", {"$param": "original_length"})]
        for field, expected in checks:
            with self.subTest(field=field):
                fake = SelectionDispatch()
                plan = self.plan(fake)
                check = next(check for check in plan["postconditions"] if check["step"] == "select")
                check.update(path="/result/" + field, equals=expected)
                response = execute_transaction(plan, fake)
                self.assertTrue(response["ok"], response)

    def test_invalid_receipt_fields_dynamic_safety_values_and_self_references_fail_preflight(self):
        for field, expected in (("events_posted", True), ("system_focus_preserved", {"$param": "value"}),
                                ("value", {"$param": "value"}), ("previous_selection/location", -1),
                                ("previous_selection/length", {"$ref": "select/result/selection/length"})):
            with self.subTest(field=field, expected=expected):
                fake = SelectionDispatch()
                plan = self.plan(fake)
                check = next(check for check in plan["postconditions"] if check["step"] == "select")
                check.update(path="/result/" + field, equals=expected)
                with self.assertRaises(ValueError):
                    execute_transaction(plan, fake)
                self.assertEqual(fake.calls, [])

    def test_only_selection_metadata_cannot_replace_final_full_value_check(self):
        fake = SelectionDispatch()
        plan = self.plan(fake)
        plan["postconditions"] = [check for check in plan["postconditions"] if not (check["step"] == "after" and check.get("attribute") == "value")]
        with self.assertRaises(ValueError):
            execute_transaction(plan, fake)
        self.assertEqual(fake.calls, [])

    def test_missing_empty_and_invalid_numeric_caller_parameters_execute_nothing(self):
        for field, value in (("value", ""), ("original_location", True), ("selected_length", -1), ("selected_length", "10")):
            with self.subTest(field=field, value=value):
                fake = SelectionDispatch()
                plan = self.plan(fake)
                plan["parameters"][field] = value
                with self.assertRaises(ValueError):
                    execute_transaction(plan, fake)
                self.assertEqual(fake.calls, [])
        fake = SelectionDispatch()
        plan = self.plan(fake)
        plan["parameters"].pop("original_length")
        with self.assertRaises(ValueError):
            execute_transaction(plan, fake)
        self.assertEqual(fake.calls, [])

    def test_registered_selection_closure_runs_under_one_FIFO_and_retains_no_value(self):
        fake = SelectionDispatch()
        parameters = self.plan(fake)["parameters"]
        previous = server.BRIDGE, server._RUNTIME
        try:
            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"INTEL_DESKTOP_RUNTIME_DIR": directory}), \
                    patch.object(server.NativeBridge, "start", side_effect=AssertionError("Native selection start forbidden")):
                server.BRIDGE, server._RUNTIME = fake, None

                def call(arguments, operation):
                    output = server.handle({"method": "tools/call", "params": {"name": "desktop_script", "arguments": {
                        **arguments, "task_id": "selection-plan-fixture", "operation_id": operation}}})
                    return json.loads(output["content"][0]["text"])

                source = PLANS / "textedit-background-select-restore.json"
                registered = call({"action": "register", "app": APP, "source_path": str(source),
                                   "parameter_names": list(parameters), "purpose": "background_selection_restore"}, "selection-register")
                self.assertTrue(registered["ok"], registered)
                self.assertTrue(registered["result"]["parameterization_candidate"])
                request = {"action": "run", "app": APP, "script_id": registered["result"]["id"], "parameters": parameters}
                response = call(request, "selection-FIFO")
                self.assertTrue(response["ok"], response)
                self.assertEqual(response["execution"]["state"], "verified")
                self.assertEqual(response["execution"]["event_count"], 0)
                evidence = server.runtime().script_execution_evidence(response["operation_id"])
                self.assertEqual(evidence["source_sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
                self.assertEqual(fake.text, parameters["value"])
                self.assertEqual(fake.selection, {"location": parameters["original_location"], "length": parameters["original_length"]})
                calls = len(fake.calls)
                duplicate = call(request, "selection-FIFO")
                self.assertFalse(duplicate["execution"]["executed"])
                self.assertEqual(len(fake.calls), calls)
                with closing(sqlite3.connect(Path(directory) / "runtime.sqlite3")) as database:
                    metadata = json.dumps(database.execute("SELECT * FROM operations").fetchall())
                    metadata += json.dumps(database.execute("SELECT * FROM events").fetchall())
                metadata += (Path(directory) / "learning.json").read_text()
                self.assertNotIn(parameters["value"], metadata)
                self.assertNotIn(parameters["window_title"], metadata)
        finally:
            if server._RUNTIME:
                server._RUNTIME.close()
            server.BRIDGE, server._RUNTIME = previous


if __name__ == "__main__":
    unittest.main()
