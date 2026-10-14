"""Send uses complete same-chat AX values; visible read rows remain clipped."""
import copy
import unittest

from chat_workflows import ChatSession, FEISHU, STRUCTURE, Stopped
from test_chat_workflows import ax, bounds
from test_feishu_post_submit_background import PostSubmitFake
import test_feishu_send_latency as latency


class ClippedSendFake(PostSubmitFake):
    def __init__(self, change=None):
        super().__init__()
        self.proof_change = change

    def tree(self):
        tree = super().tree()
        if self.modal:
            return tree
        for row in tree["elements"]:
            if row.get("role") != "AXStaticText" or row.get("value") != self.text:
                continue
            index = int(row["element_id"].split("-")[-1]) if row["element_id"].startswith("message-") else 0
            row.update(position={"x": 680 + index * 4, "y": 211}, size={"width": 220, "height": 1})
            if not self.submitted:
                continue
            if self.proof_change == "sidebar":
                row.update(parent_id="main", position={"x": 445, "y": 200})
            elif self.proof_change == "header":
                row.update(parent_id="header", position={"x": 650, "y": 180})
            elif self.proof_change == "composer":
                row["parent_id"] = "composer"
            elif self.proof_change == "ancestor":
                row["parent_id"] = "main"
            elif self.proof_change == "missing_parent":
                row["parent_id"] = "missing-node"
            elif self.proof_change == "incomplete":
                row.update(value_complete=False, value_truncated=True)
            elif self.proof_change == "far":
                row["position"] = {"x": 1500, "y": 211}
            elif self.proof_change == "contains":
                row["value"] += " extra serialization"
            elif self.proof_change == "title_only":
                row.update(value="", title=self.text)
            elif self.proof_change == "role":
                row["role"] = "AXGroup"
            elif self.proof_change == "secure":
                row["secure"] = True
            elif self.proof_change in {"zero_height", "negative_height", "zero_width", "negative_width"}:
                dimension = "height" if "height" in self.proof_change else "width"
                row["size"][dimension] = 0 if self.proof_change.startswith("zero") else -1
        return tree


class FullAXBodyProofTests(unittest.TestCase):
    def send(self, fake):
        return latency.FeishuSendLatencyTests().send(fake)

    def assert_no_replay_and_early_return(self, fake):
        self.assertEqual(sum(c["command"] == "submit_text" for c in fake.calls), 1)
        self.assertEqual(fake.restore_calls, 1)
        index = next(i for i, c in enumerate(fake.calls) if c["command"] == "submit_text")
        self.assertTrue(fake.calls[index + 1].get("restore_previous"))
        self.assertTrue(all(c["command"] == "inspect" for c in fake.calls[index + 2:]))
        self.assertEqual(fake.front, fake.origin)

    def test_new_complete_clipped_value_verifies_without_claiming_visibility(self):
        fake = ClippedSendFake()
        result = self.send(fake)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["result"]["sent"])
        proof = result["result"]["full_AX_body_proof"]
        self.assertEqual(proof["baseline_text_node_occurrences"], 0)
        self.assertEqual(proof["exact_text_node_occurrences"], 1)
        self.assertEqual(proof["clipped_exact_text_node_occurrences"], 1)
        self.assertFalse(proof["viewport_visibility_verified"])
        self.assertFalse(proof["message_count_verified"])
        self.assertTrue(proof["same_chat_ancestry_verified"])
        self.assertNotIn(fake.text, result["result"]["visible_text"])
        self.assertFalse(result["result"]["delivery_verified"])
        self.assertEqual(result["send_call_timing"]["confirmation_read_count"], 1)
        self.assert_no_replay_and_early_return(fake)

    def test_old_clipped_value_is_in_baseline_and_cannot_verify_a_missing_echo(self):
        fake = ClippedSendFake(); fake.no_echo = True
        fake.pages[0].append(fake.text)
        result = self.send(fake)
        self.assertIsNone(result["result"]["sent"])
        self.assertFalse(result["business_completed"])
        evidence = result["send_call_timing"]["confirmation_evidence"]
        self.assertEqual(evidence["before_exact_body_occurrences"], 1)
        self.assertTrue(all(x["exact_body_occurrences"] == 1 for x in evidence["read_summaries"]))
        self.assert_no_replay_and_early_return(fake)

    def test_old_clipped_baseline_requires_an_actual_extra_distinct_geometry(self):
        fake = ClippedSendFake(); fake.pages[0].append(fake.text)
        result = self.send(fake)
        self.assertTrue(result["result"]["send_verified"], result)
        proof = result["result"]["full_AX_body_proof"]
        self.assertEqual(proof["baseline_text_node_occurrences"], 1)
        self.assertEqual(proof["exact_text_node_occurrences"], 2)
        self.assert_no_replay_and_early_return(fake)

    def test_sidebar_header_composer_wrong_ancestor_contains_or_far_value_cannot_verify(self):
        for change in ("sidebar", "header", "composer", "ancestor", "contains", "title_only", "far", "role", "secure"):
            with self.subTest(change=change):
                fake = ClippedSendFake(change)
                result = self.send(fake)
                self.assertIsNone(result["result"]["sent"], result)
                self.assertFalse(result["business_completed"])
                self.assertTrue(all(x["exact_body_occurrences"] == 0 for x in result["send_call_timing"]["confirmation_evidence"]["read_summaries"]))
                self.assert_no_replay_and_early_return(fake)

    def test_incomplete_values_missing_parent_and_nonpositive_bounds_fail_closed(self):
        for change in ("incomplete", "missing_parent", "zero_height", "negative_height", "zero_width", "negative_width"):
            with self.subTest(change=change):
                fake = ClippedSendFake(change)
                result = self.send(fake)
                self.assertFalse(result["ok"], result)
                self.assertEqual(result["error"]["code"], "send_state_unknown")
                self.assertIsNone(result["sent"])
                self.assertTrue(result["completion_unknown"])
                self.assert_no_replay_and_early_return(fake)

    def scene(self):
        # Actual D metadata geometry/ancestry shape, with synthetic values only.
        text, title = "synthetic_message", "synthetic_recipient"
        tree = {"target_pid": 456, "truncated": False, "windows": [], "elements": []}
        elements = [ax("main", "AXWindow", 201, 40, 1316, 750, title="飞书"),
                    ax("web", "AXWebArea", 835, 46, 676, 738, title="messenger-chat", parent_id="main"),
                    ax("composer", "AXTextArea", 868, 727, 353, 22, value="发送给 " + title + "\n" + STRUCTURE, parent_id="web"),
                    ax("header", "AXStaticText", 895, 71, 105, 19, value=title, parent_id="web"),
                    ax("body", "AXGroup", 835, 114, 676, 600, parent_id="web"),
                    ax("bubble", "AXGroup", 897, 114, 576, 15, parent_id="body"),
                    ax("outbound", "AXStaticText", 984, 114, 132, 1, value=text, parent_id="bubble"),
                    ax("quote", "AXStaticText", 952, 114, 154, 1, value=text, parent_id="bubble")]
        for row in elements:
            row["element_pid"] = 456
        tree["elements"], tree["windows"] = elements, [elements[0]]
        session = ChatSession({"app": FEISHU, "action": "read", "chat": title}, lambda request: self.fail("Pure proof must not invoke native"))
        session.target = {"app": FEISHU, "window_title": "飞书"}
        session.pid, session.title, session.frame = 456, title, bounds(201, 40, 1316, 750)
        return session, tree, text

    def test_actual_clipped_geometry_counts_two_ax_nodes_and_zero_visible_rows(self):
        session, tree, text = self.scene()
        proof = session.feishu_full_ax_body_proof(tree, text)
        self.assertEqual(proof["exact_text_node_occurrences"], 2)
        self.assertEqual(proof["clipped_exact_text_node_occurrences"], 2)
        self.assertEqual(session.visible_rows(tree), [])
        self.assertFalse(proof["message_count_verified"])

    def test_duplicate_same_geometry_is_one_occurrence(self):
        session, tree, text = self.scene()
        duplicate = copy.deepcopy(tree["elements"][-1]); duplicate["element_id"] = "duplicate"
        tree["elements"].append(duplicate)
        self.assertEqual(session.feishu_full_ax_body_proof(tree, text)["exact_text_node_occurrences"], 2)

    def test_missing_body_container_or_foreign_element_pid_cannot_count(self):
        for change in ("container", "pid"):
            session, tree, text = self.scene()
            for row in tree["elements"][-2:]:
                if change == "container": row["parent_id"] = "web"
                else: row["element_pid"] += 1
            self.assertEqual(session.feishu_full_ax_body_proof(tree, text)["exact_text_node_occurrences"], 0)

    def test_ambiguous_chat_or_mismatched_independent_header_is_unavailable(self):
        for change in ("area", "header"):
            session, tree, text = self.scene()
            if change == "area":
                duplicate = copy.deepcopy(tree["elements"][1]); duplicate["element_id"] = "other-web"
                tree["elements"].append(duplicate)
            else:
                tree["elements"][3]["value"] = "other_recipient"
            with self.assertRaises(Stopped):
                session.feishu_full_ax_body_proof(tree, text)

    def test_incomplete_baseline_stops_before_typing_or_submission(self):
        fake = ClippedSendFake(); fake.pages[0].append(fake.text)
        original = fake.tree
        def incomplete():
            value = original()
            for row in value["elements"]:
                if row.get("value") == fake.text:
                    row.update(value_complete=False, value_truncated=True)
            return value
        fake.tree = incomplete
        result = self.send(fake)
        self.assertFalse(result["ok"])
        self.assertFalse(result["sent"])
        self.assertFalse(any(c["command"] in {"type_text", "submit_text", "batch"} for c in fake.calls))


if __name__ == "__main__":
    unittest.main()
