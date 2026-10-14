"""Background edits never claim focus, send, navigate, or retry input."""
import copy
import unittest
from test_chat_workflows import WeChatFake, FeishuFake
from chat_workflows import WECHAT, FEISHU, STRUCTURE, execute_chat


class BackgroundFake:
    def __init__(self, app):
        self.base = WeChatFake() if app == WECHAT else FeishuFake()
        if app == FEISHU: self.base.history_web_area = True
        self.fail = False
        self.bad_proof = None

    def __call__(self, request):
        command = request["command"]
        if command == "background_chat_edit":
            self.base.calls.append(copy.deepcopy(request))
            if self.fail:
                return {"ok": False, "error": {"code": "background_postcondition_unknown", "message": "No replay", "details": {"events_posted": 2}}}
            if request.get('chat_title',self.base.title)!=self.base.title or (request['operation']=='clear' and request['expected_draft']!=self.base.draft) or (request['operation']=='type' and self.base.draft):
                return {'ok':False,'error':{'code':'background_draft_changed','message':'Changed state preserved','details':{'events_posted':0}}}
            self.base.draft = request.get("text", "")
            result={"target_pid":self.base.pid,"value_verified":True,"foreground_preserved":True,"events_posted":5,
                    'atomic_chat_edit':True,'recipient_verified':True,'composer_complete':True,
                    'chat_title':self.base.title,'draft_text':self.base.draft,'draft_value':self.base.draft,
                    'draft_empty':not self.base.draft,'activated_foreground':False}
            if self.bad_proof:result.pop(self.bad_proof)
            return {'ok':True,'result':result}
        return self.base(request)


class BackgroundChatTests(unittest.TestCase):
    def test_menu_success_preserves_full_actual_serialization_and_clipboard_receipt(self):
        fake=BackgroundFake(FEISHU)
        def menu(request):
            response=fake(request)
            if response.get('ok') and request['command']=='background_chat_edit':
                response['result'].update(events_posted=0,ax_actions_attempted=2,ax_menu_actions_attempted=1,
                    draft_value=fake.base.draft+STRUCTURE,temporary_clipboard_used=True,
                    clipboard_restored=True,clipboard_external_change=False,clipboard_isolated=False)
            return response
        r=execute_chat({'app':FEISHU,'action':'draft','background':True,'text':'完整正文'},menu,recipe_store=False)
        self.assertTrue(r['ok'],r)
        self.assertEqual(r['result']['draft_value'],'完整正文'+STRUCTURE)
        self.assertEqual(r['result']['events_posted'],0)
        self.assertEqual(r['result']['ax_menu_actions_attempted'],1)
        self.assertTrue(r['result']['clipboard_restored'])
        self.assertFalse(r['result']['clipboard_isolated'])
        self.assertEqual(len(fake.base.calls),1)

    def test_multiline_existing_clear_is_comparison_only_and_changed_content_is_preserved(self):
        for app in (WECHAT, FEISHU):
            owned = '第一段\u200b\n第二段\t完整末行'
            fake = BackgroundFake(app)
            fake.base.draft = owned + '用户追加'
            request = {'app': app, 'action': 'clear', 'background': True, 'expected_draft': owned}
            failed = execute_chat(request, fake, recipe_store=False)
            self.assertFalse(failed['ok'])
            self.assertEqual(fake.base.draft, owned + '用户追加')
            fake.base.draft = owned
            result = execute_chat(request, fake, recipe_store=False)
            self.assertTrue(result['ok'], result)
            self.assertEqual(fake.base.draft, '')
            self.assertNotIn('text', fake.base.calls[-1])

    def test_current_recipient_is_bound_when_chat_is_omitted(self):
        for app in (WECHAT, FEISHU):
            fake = BackgroundFake(app)
            result = execute_chat({"app": app, "action": "draft", "background": True,
                                   "text": "自有后台草稿"}, fake, recipe_store=False)
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["result"]["chat_title"], fake.base.title)
            self.assertEqual(len(fake.base.calls),1)
            self.assertNotIn('chat_title',fake.base.calls[0])

    def test_type_clear_no_shared_focus_for_both_apps(self):
        for app in (WECHAT, FEISHU):
            with self.subTest(app=app):
                fake = BackgroundFake(app)
                draft = execute_chat({"app": app, "action": "draft", "background": True,
                                      "chat": fake.base.title, "text": "后台中文验收"}, fake, recipe_store=False)
                self.assertTrue(draft["ok"], draft)
                clear = execute_chat({"app": app, "action": "clear", "background": True,
                                      "chat": fake.base.title, "expected_draft": "后台中文验收"}, fake, recipe_store=False)
                self.assertTrue(clear["ok"], clear)
                self.assertEqual(fake.base.draft, "")
                self.assertFalse(any(r["command"] in {"focus", "click", "key", "visual_click", "type_text", "submit_text", "batch"} for r in fake.base.calls))
                edits = [r for r in fake.base.calls if r["command"] == "background_chat_edit"]
                self.assertEqual([r["operation"] for r in edits], ["type", "clear"])
                self.assertNotIn("text", edits[-1])

    def test_failure_never_falls_back_or_replays(self):
        for app in (WECHAT, FEISHU):
            fake = BackgroundFake(app)
            fake.fail = True
            result = execute_chat({"app": app, "action": "draft", "background": True,
                                   "chat": fake.base.title, "text": "后台草稿"}, fake, recipe_store=False)
            self.assertFalse(result["ok"])
            self.assertEqual([r["command"] for r in fake.base.calls].count("background_chat_edit"), 1)
            self.assertFalse(any(r["command"] == "focus" for r in fake.base.calls))

    def test_changed_recipient_or_owned_draft_refuses_before_input(self):
        for app in (WECHAT, FEISHU):
            for wrong_chat in (True, False):
                fake = BackgroundFake(app)
                fake.base.draft = "用户原草稿"
                result = execute_chat({"app": app, "action": "clear", "background": True,
                                       "chat": "不同聊天" if wrong_chat else fake.base.title,
                                       "expected_draft": "测试草稿"}, fake, recipe_store=False)
                self.assertFalse(result["ok"])
                self.assertFalse(any(r["command"] in {"background_type_text", "focus"} for r in fake.base.calls))
                self.assertEqual(fake.base.draft, "用户原草稿")

    def test_complete_native_proof_required_without_a_second_read_or_replay(self):
        for field in ['atomic_chat_edit','value_verified','recipient_verified','composer_complete','draft_text','draft_value','foreground_preserved']:
            fake=BackgroundFake(WECHAT);fake.bad_proof=field
            r=execute_chat({'app':WECHAT,'action':'draft','background':True,'text':'本任务文字'},fake,recipe_store=False)
            self.assertFalse(r['ok'],field)
            self.assertEqual(len(fake.base.calls),1)

    def test_explicit_unproven_kind_stops_before_native(self):
        fake=BackgroundFake(FEISHU)
        r=execute_chat({'app':FEISHU,'action':'draft','background':True,'chat_kind':'person','text':'本任务文字'},fake,recipe_store=False)
        self.assertFalse(r['ok']);self.assertEqual(fake.base.calls,[])

    def test_background_sending_and_navigation_rejected_without_native_calls(self):
        for action in ("send", "locate", "history"):
            fake = BackgroundFake(WECHAT)
            result = execute_chat({"app": WECHAT, "action": action, "background": True,
                                   "chat": fake.base.title}, fake, recipe_store=False)
            self.assertFalse(result["ok"])
            self.assertEqual(fake.base.calls, [])
