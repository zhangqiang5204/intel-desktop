"""Failed own search cleanup uses fresh complete AX proof, never business replay."""
import copy
import itertools
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from test_chat_workflows import FeishuFake
from chat_workflows import FEISHU, SEARCH_MODAL, SEARCH_STRUCTURE, execute_chat


class OwnedSearchFake(FeishuFake):
    def __init__(self):
        super().__init__()
        self.search_input_role = "AXTextArea"
        self.modal = True
        seed = super().tree()
        self.modal = False
        self.fixture = {"window": copy.deepcopy(seed["windows"][0]),
                        "input": copy.deepcopy(next(row for row in seed["elements"] if row["element_id"] == "search-field")),
                        "input_with_hint_size": {"width": 400, "height": 60}}
        self.missing_result = True
        self.written = False
        self.result_reads = 0
        self.cleanup_change = None
        self.takeover = False
        self.foreground_pid = self.pid
        self.escape_error = False
        self.escape_keeps_modal = False
        self.claimed_modal = False
        self.main_changed = False
        self.main_changes_on_escape = False

    def tree(self):
        tree = super().tree()
        tree["display_topology_generation"] = 7
        tree["displays"] = [{"display_id": 1}]
        if not self.modal:
            if self.main_changed:
                tree["windows"][0]["position"]["x"] += 1
            return tree
        modal = copy.deepcopy(self.fixture["window"])
        tree["windows"] = [modal]
        field = copy.deepcopy(self.fixture["input"])
        field["element_id"] = "search-field"
        field["value"] = self.search_value()
        if self.query and self.search_hint:
            field["size"] = copy.deepcopy(self.fixture["input_with_hint_size"])
        tree["elements"] = [modal, field] + [r for r in tree["elements"] if r.get("element_id") not in {"modal", "search-field"}]
        if self.missing_result:
            tree["elements"] = [r for r in tree["elements"] if r.get("element_id") not in {"result-1", "hidden-same-name"}]
        if self.written:
            self.result_reads += 1
            if self.result_reads >= 2 and self.cleanup_change:
                self.cleanup_change(tree, field)
        tree["focused_element"] = {**copy.deepcopy(field), "available": True, "within_selected_window": True}
        return tree

    def __call__(self, request):
        command = request["command"]
        if command == "focus" and request.get("restore_previous"):
            self.calls.append(copy.deepcopy(request))
            if self.modal and not self.claimed_modal:
                return {"ok": True, "result": {"focus_restored": False, "focus_restore_attempted": False,
                    "restore_reason": "task_focus_changed", "events_posted": 0}}
            return {"ok": True, "result": {"focus_restored": True, "focus_restore_attempted": True,
                "restore_reason": "previous_window_verified", "focus_restored_app": True,
                "window_verified": True, "window_unknown": False, "restore_scope": "exact_window",
                "previous_focus_scope": "exact_window", "owned_navigation_focus_updated": self.claimed_modal and not self.modal,
                "events_posted": 0}}
        if command == "key" and request.get("key") == "escape" and self.escape_error:
            self.calls.append(copy.deepcopy(request))
            return {"ok": False, "error": {"code": "user_interrupted", "message": "Takeover before Escape",
                                             "details": {"events_posted": 0}}}
        if command == "focus":
            self.claimed_modal = request.get("window_title") == SEARCH_MODAL
        response = super().__call__(request)
        if command == "type_text" and response["ok"]:
            self.written = True
        if command == "status":
            response["result"].update(frontmost_pid=self.foreground_pid, interrupted="new_input" if self.takeover else None)
        if command == "key" and request.get("key") == "escape":
            self.main_changed |= self.main_changes_on_escape
            if self.escape_keeps_modal:
                self.modal = True
            response["result"].update(events_posted=2, navigation_only=True, window_closed_verified=False)
        return response


class OwnedSearchCleanupTests(unittest.TestCase):
    def run_search(self, fake, wanted="不存在验收目标"):
        ticks = itertools.count(0, 4)
        with patch("chat_workflows.time.monotonic", side_effect=lambda: next(ticks)), patch("chat_workflows.time.sleep"):
            return execute_chat({"app": FEISHU, "action": "locate", "chat": wanted}, fake, recipe_store=False)

    def escapes(self, fake):
        return [c for c in fake.calls if c["command"] == "key" and c.get("key") == "escape"]

    def test_actual_main_to_modal_missing_result_closes_owned_query_and_restores_exact_origin(self):
        fake = OwnedSearchFake()
        result = self.run_search(fake)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "target_not_found")
        self.assertEqual(result["error"]["details"]["matching_count"], 0)
        self.assertTrue(result["owned_search_modal_closed"])
        self.assertEqual(result["owned_search_cleanup_events_posted"], 2)
        self.assertTrue(result["focus_restored"])
        self.assertTrue(result["window_verified"])
        self.assertFalse(result["owned_navigation_focus_updated"])
        self.assertEqual(len(self.escapes(fake)), 1)
        self.assertEqual(self.escapes(fake)[0]["window_title"], SEARCH_MODAL)
        self.assertTrue(fake.calls[-1].get("restore_previous"))
        self.assertEqual(fake.calls[-1]["window_title"], "飞书")
        self.assertEqual(len([c for c in fake.calls if c["command"] == "type_text"]), 1)
        self.assertFalse(any(c["command"] in {"clear_text", "submit_text"} for c in fake.calls))
        self.assertFalse(result["automatic_replay_allowed"])
        self.assertEqual(fake.draft, "")

    def test_existing_modal_replacement_known_hint_closes_and_preserves_native_return_receipt(self):
        fake = OwnedSearchFake()
        fake.modal, fake.query, fake.search_hint = True, "原搜索", True
        result = self.run_search(fake)
        self.assertEqual(result["error"]["code"], "target_not_found")
        self.assertTrue(result["owned_search_modal_closed"])
        self.assertTrue(result["focus_restored"])
        self.assertTrue(result["owned_navigation_focus_updated"])
        typed = [c for c in fake.calls if c["command"] == "type_text"]
        self.assertEqual(len(typed), 1)
        self.assertEqual(typed[0]["expected_before"], "原搜索\u200b\n\n回车查看答案")
        self.assertTrue(typed[0]["replace_search"])
        self.assertEqual(len(self.escapes(fake)), 1)
        self.assertFalse(any(c["command"] in {"clear_text", "submit_text"} for c in fake.calls))

    def test_same_query_without_this_call_write_is_never_owned(self):
        fake = OwnedSearchFake()
        fake.modal, fake.query = True, "不存在验收目标"
        result = self.run_search(fake)
        self.assertEqual(result["error"]["code"], "target_not_found")
        self.assertTrue(fake.modal)
        self.assertFalse(fake.written)
        self.assertEqual(self.escapes(fake), [])
        self.assertNotIn("owned_search_cleanup_attempted", result)

    def test_changed_unknown_or_collision_query_never_closes_or_restores(self):
        for changed in ("不同查询" + SEARCH_STRUCTURE, "不存在验收目标" + SEARCH_STRUCTURE + "\n未知提示",
                        "不存在验收目标额外文字" + SEARCH_STRUCTURE,
                        "不存在验收目标" + SEARCH_STRUCTURE + "\n回车查看答案\n额外行"):
            with self.subTest(changed=changed):
                fake = OwnedSearchFake()
                fake.cleanup_change = lambda tree, field: field.update(value=changed)
                result = self.run_search(fake)
                self.assertEqual(result["error"]["code"], "target_not_found")
                self.assertFalse(result["owned_search_cleanup_attempted"])
                self.assertEqual(result["owned_search_cleanup_reason"], "search_cleanup_query_changed")
                self.assertEqual(self.escapes(fake), [])
                self.assertFalse(result["focus_restore_attempted"])
                self.assertFalse(any(c.get("restore_previous") for c in fake.calls))

    def test_unknown_or_ambiguous_actual_focus_geometry_and_topology_stop_without_escape(self):
        cases = {
            "unfocused": lambda tree, field: field.update(focused=False),
            "secure": lambda tree, field: field.update(secure=True),
            "moved": lambda tree, field: field["position"].update(x=301),
            "incomplete": lambda tree, field: tree.update(truncated=True),
            "topology": lambda tree, field: tree.update(display_topology_generation=8),
            "ambiguous": lambda tree, field: tree["elements"].append({**copy.deepcopy(field), "element_id": "other-field"}),
        }
        for label, mutation in cases.items():
            with self.subTest(label=label):
                fake = OwnedSearchFake()
                fake.cleanup_change = mutation
                result = self.run_search(fake)
                self.assertEqual(result["error"]["code"], "target_not_found")
                self.assertFalse(result["owned_search_modal_closed"])
                self.assertEqual(self.escapes(fake), [])
                self.assertFalse(any(c.get("restore_previous") for c in fake.calls))

    def test_takeover_pid_change_or_disappeared_modal_never_escape(self):
        for mode in ("takeover", "foreground", "pid", "gone"):
            with self.subTest(mode=mode):
                fake = OwnedSearchFake()
                original = fake.__call__
                modal_inspects = 0
                def callback(request):
                    nonlocal modal_inspects
                    if request["command"] == "inspect" and fake.written and request.get("window_title") == SEARCH_MODAL:
                        modal_inspects += 1
                        if modal_inspects >= 2:
                            if mode == "takeover": fake.takeover = True
                            elif mode == "foreground": fake.foreground_pid = 999
                            elif mode == "pid": fake.pid = 999
                            else: fake.modal = False
                    return original(request)
                ticks = itertools.count(0, 4)
                with patch("chat_workflows.time.monotonic", side_effect=lambda: next(ticks)), patch("chat_workflows.time.sleep"):
                    result = execute_chat({"app": FEISHU, "action": "locate", "chat": "不存在验收目标"}, callback, recipe_store=False)
                self.assertEqual(result["error"]["code"], "target_not_found")
                self.assertEqual(self.escapes(fake), [])
                self.assertFalse(result["focus_restore_attempted"])

    def test_native_focused_diagnostic_must_prove_the_exact_current_editor(self):
        for changed in ({"available": False}, {"within_selected_window": False},
                        {"element_id": "different-actual-field"}, {"value": "另一查询" + SEARCH_STRUCTURE}):
            with self.subTest(changed=changed):
                fake = OwnedSearchFake()
                def callback(request):
                    response = fake(request)
                    if request["command"] == "inspect" and fake.result_reads >= 2 and request.get("window_title") == SEARCH_MODAL:
                        response["result"]["focused_element"].update(changed)
                    return response
                ticks = itertools.count(0, 4)
                with patch("chat_workflows.time.monotonic", side_effect=lambda: next(ticks)), patch("chat_workflows.time.sleep"):
                    result = execute_chat({"app": FEISHU, "action": "locate", "chat": "不存在验收目标"}, callback, recipe_store=False)
                self.assertEqual(result["error"]["code"], "target_not_found")
                self.assertEqual(result["owned_search_cleanup_reason"],
                                 "ambiguous_target" if "element_id" in changed else "search_cleanup_focus_unverified")
                self.assertEqual(self.escapes(fake), [])
                self.assertFalse(result["focus_restore_attempted"])

    def test_escape_not_closed_or_native_refusal_never_replays(self):
        for mode in ("no_close", "refused", "main_changed"):
            with self.subTest(mode=mode):
                fake = OwnedSearchFake()
                fake.escape_keeps_modal = mode == "no_close"
                fake.escape_error = mode == "refused"
                fake.main_changes_on_escape = mode == "main_changed"
                result = self.run_search(fake)
                self.assertEqual(result["error"]["code"], "target_not_found")
                self.assertEqual(len(self.escapes(fake)), 1)
                self.assertFalse(result["owned_search_modal_closed"])
                self.assertFalse(result["focus_restore_attempted"])
                self.assertEqual(result["owned_search_cleanup_events_posted"], 0 if mode == "refused" else 2)
                self.assertEqual(len([c for c in fake.calls if c["command"] == "type_text"]), 1)

    def test_successful_modal_to_main_navigation_keeps_existing_receipt_and_has_no_cleanup(self):
        fake = OwnedSearchFake()
        fake.modal, fake.query, fake.missing_result = True, "原查询", False
        result = self.run_search(fake)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["focus_restored"])
        self.assertTrue(result["owned_navigation_focus_updated"])
        self.assertNotIn("owned_search_cleanup_attempted", result)
        self.assertEqual(self.escapes(fake), [])

    def test_partial_or_unverified_input_is_never_cleanup_authority(self):
        fake = OwnedSearchFake()
        fake.fail_on_type = True
        result = self.run_search(fake)
        self.assertEqual(result["error"]["code"], "postcondition_failed")
        self.assertFalse(result["focus_restore_attempted"])
        self.assertEqual(self.escapes(fake), [])
        fake = OwnedSearchFake()
        def callback(request):
            response = fake(request)
            if request["command"] == "type_text" and response["ok"]:
                response["result"]["value_verified"] = False
            return response
        ticks = itertools.count(0, 4)
        with patch("chat_workflows.time.monotonic", side_effect=lambda: next(ticks)), patch("chat_workflows.time.sleep"):
            result = execute_chat({"app": FEISHU, "action": "locate", "chat": "不存在验收目标"}, callback, recipe_store=False)
        self.assertEqual(result["error"]["code"], "target_not_found")
        self.assertEqual(self.escapes(fake), [])


if __name__ == "__main__":
    unittest.main()
