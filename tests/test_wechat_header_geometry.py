"""Title-column evidence, without stripping icon OCR or unknown draft text."""
import copy
import unittest

from test_chat_workflows import WeChatFake, bounds
from chat_workflows import ChatSession, Stopped, WECHAT, execute_chat


ACTUAL_NAME = "保利上城（东区）10-2单元业主群"
ACTUAL_LABEL = ACTUAL_NAME + "（178）"
# Offline Vision on Root's saved /tmp/wechat33-group-live.png, cropped to the
# existing +326,+5,513,45 header ROI. Coordinates use its 855x1079 window frame.
ACTUAL_ROWS = [
    {"text": ACTUAL_LABEL + "D>", "bounds": bounds(402.9504427166621, 51.00000012908905, 274.1896362304687, 17.731707572937015)},
    {"text": "©~", "bounds": bounds(793.2284474611089, 52.268292923233105, 42.01293182373045, 15.365853309631344)},
    {"text": "。。", "bounds": bounds(877.254310636052, 56.50000000835735, 18.79525756835942, 6.743902444839477)},
]


class HeaderGeometryTests(unittest.TestCase):
    def session(self, frame=None):
        session = ChatSession({"app": WECHAT, "action": "read"}, WeChatFake())
        session.frame = frame or bounds(67, 33, 855, 1079)
        return session

    def test_actual_toolbar_rows_are_excluded_without_trimming_title_badge_text(self):
        session = self.session()
        value = {"ocr": copy.deepcopy(ACTUAL_ROWS)}
        self.assertEqual(session.wechat_header_rows(value), [ACTUAL_ROWS[0]])
        self.assertEqual(session.wechat_header(value), ACTUAL_LABEL + "D>")
        with self.assertRaises(Stopped) as failure:
            session.wechat_header(value, ACTUAL_NAME)
        self.assertEqual(failure.exception.code, "target_not_found")
        self.assertEqual(value["ocr"], ACTUAL_ROWS)

    def test_complete_fresh_label_still_requires_exact_name_and_member_count(self):
        # Root independently read this complete label from the 266pt lane on
        # both displays. The fake row retains the original geometry; no string
        # transformation inside the adapter is permitted to create this value.
        value = {"ocr": copy.deepcopy(ACTUAL_ROWS)}
        value["ocr"][0]["text"] = ACTUAL_LABEL
        session = self.session()
        self.assertEqual(session.wechat_header(value, ACTUAL_NAME), ACTUAL_LABEL)
        session.wechat_header_group(value, ACTUAL_NAME)
        self.assertEqual(session.kind_evidence["member_count"], 178)
        for wanted in (ACTUAL_NAME[:-1], ACTUAL_NAME + "其他群"):
            with self.assertRaises(Stopped):
                session.wechat_header(value, wanted)

    def test_two_title_column_rows_remain_ambiguous(self):
        value = {"ocr": [{"text": "甲", "bounds": bounds(403, 51, 20, 18)},
                         {"text": "乙", "bounds": bounds(407, 52, 20, 18)}]}
        with self.assertRaises(Stopped) as failure:
            self.session().wechat_header(value)
        self.assertEqual(failure.exception.code, "ambiguous_target")
        self.assertEqual(failure.exception.details["matching_count"], 2)

    def test_literal_punctuation_ai_and_short_titles_are_not_blacklisted(self):
        for frame in (bounds(67, 33, 855, 1079), bounds(211, 25, 932, 1079), bounds(1900, 33, 855, 1079)):
            session = self.session(frame)
            for label, wanted in (("f", "f"), ("姓名D>", "姓名D>"), ("助手 AI", "助手"), ("短群（12）", "短群")):
                value = {"ocr": [{"text": label, "bounds": bounds(frame["x"] + 336, frame["y"] + 18, 100, 18)},
                                 {"text": "©~", "bounds": bounds(frame["x"] + frame["width"] - 128, frame["y"] + 19, 30, 15)}]}
                self.assertEqual(session.wechat_header(value, wanted), label)

    def test_missing_header_reports_current_header_only_not_sidebar_or_old_title(self):
        session=self.session(bounds(1710,33,855,1079))
        value={"snapshot_id":"fresh-current","target_visible_verified":True,
               "ocr":[{"text":"助手 AI","bounds":bounds(1828,231,45,15)}]}
        with self.assertRaises(Stopped) as failure:session.wechat_header(value,"助手")
        self.assertEqual(failure.exception.details["matching_count"],0)
        self.assertEqual(failure.exception.details["header_candidates"],[])
        self.assertFalse(failure.exception.details["header_present"])
        self.assertEqual(failure.exception.details["snapshot_id"],"fresh-current")
        self.assertNotIn("助手 AI",str(failure.exception.details))

    def test_unknown_actual_year_suffix_preserves_complete_draft_and_posts_no_clear(self):
        fake = WeChatFake()
        fake.frame, fake.title = bounds(1900, 33, 855, 1079), ACTUAL_LABEL
        known_marker = "双屏微信验收20261012"
        fake.draft = known_marker + "年"
        result = execute_chat({"app": WECHAT, "action": "clear", "chat": ACTUAL_NAME,
                               "chat_kind": "group", "expected_draft": known_marker}, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_changed")
        self.assertEqual(fake.draft, known_marker + "年")
        self.assertFalse(any(call["command"] in {"batch", "visual_click", "visual_type_text", "visual_key"} for call in fake.calls))


if __name__ == "__main__":
    unittest.main()
