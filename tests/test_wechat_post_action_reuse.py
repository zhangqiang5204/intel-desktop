"""Complete post-action evidence avoids a second capture, never input replay."""
import copy
import unittest
from test_chat_workflows import WeChatFake
from chat_workflows import WECHAT, ChatSession, execute_chat


class PostActionFake(WeChatFake):
    def __init__(self, corrupt=None):
        super().__init__()
        self.corrupt = corrupt

    def visual(self, request, region_only=False):
        value = super().visual(request, region_only)
        background = request.get("command") == "background_visual_read"
        value.update(window_id=91, display_topology_signature="one-screen",
                     focused_window_frame=dict(self.frame), captured_regions=[dict(self.frame)],
                     read_only_background=background, input_eligible=not background, target_identity_verified=True)
        return value

    def __call__(self, request):
        response = super().__call__(request)
        if request["command"] == "visual_type_text" and request.get("control_kind") == "chat_composer":
            value = response["result"]
            regions = ChatSession({"app": WECHAT, "action": "draft", "text": "测试"}, self)
            regions.frame = self.frame
            rois = regions.wechat_regions()
            complete = self.visual({**request, "regions": [rois["header"], rois["composer"]]})
            value.update(complete, value_verified=True, edit_recipient_verified=True,
                         edit_recipient=self.title, edit_proof_snapshot_id=complete["snapshot_id"],
                         ocr_scope="post_action_recipient_and_complete_composer",
                         ocr_regions=[rois["header"], rois["composer"]])
            if self.corrupt:
                key, replacement = self.corrupt
                value[key] = copy.deepcopy(replacement)
        return response


class PostActionReuseTests(unittest.TestCase):
    def test_complete_bound_proof_avoids_capture_after_single_type(self):
        fake = PostActionFake()
        result = execute_chat({"app": WECHAT, "action": "draft", "text": "中文自有草稿"}, fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        typed = next(i for i, r in enumerate(fake.calls) if r["command"] == "visual_type_text")
        self.assertFalse(any(r["command"] == "visual_read" for r in fake.calls[typed + 1:]))
        self.assertEqual(fake.calls[typed]["chat_title"], fake.title)

    def test_incomplete_or_wrong_binding_falls_back_to_read_never_retypes(self):
        cases = [("edit_recipient_verified", False), ("edit_recipient", "其他人"),
                 ("edit_proof_snapshot_id", "older"), ("target_pid", 124),
                 ("window_id", 92), ("display_topology_signature", "changed"),
                 ("ocr_truncated", True), ("ocr_regions", []), ("captured_regions", []),
                 ("read_only_background", True), ("input_eligible", False)]
        for corruption in cases:
            with self.subTest(field=corruption[0]):
                fake = PostActionFake(corruption)
                result = execute_chat({"app": WECHAT, "action": "draft", "text": "自有草稿"}, fake, recipe_store=False)
                if corruption[0] == "target_pid":
                    self.assertFalse(result["ok"])
                    self.assertEqual(result["error"]["code"], "target_changed")
                    self.assertEqual(sum(r["command"] == "visual_type_text" for r in fake.calls), 1)
                    continue
                self.assertTrue(result["ok"], result)
                typed = next(i for i, r in enumerate(fake.calls) if r["command"] == "visual_type_text")
                self.assertTrue(any(r["command"] == "visual_read" for r in fake.calls[typed + 1:]))
                self.assertEqual(sum(r["command"] == "visual_type_text" for r in fake.calls), 1)
