"""Only the observed housekeeper title/status pair narrows the title lane."""
import copy
import unittest

from chat_workflows import ChatSession, Stopped, WECHAT, execute_chat
from test_chat_completion import WeChatSendFake, send_request
from test_chat_workflows import bounds


FRAME = bounds(356, 25, 855, 1079)
PRIMARY = {"text": "管家 AI", "bounds": bounds(693.056, 36.5, 47.54, 14.5)}
STATUS = {"text": "暂无法连接 OpenClaw", "bounds": bounds(693.056, 57.439, 119.405, 13.171)}


class HousekeeperFake(WeChatSendFake):
    def __init__(self, status=STATUS["text"]):
        super().__init__()
        self.frame, self.title, self.subtitle = dict(FRAME), PRIMARY["text"], status

    def visual(self, request, region_only=False):
        result = super().visual(request, region_only)
        for row in result["ocr"]:
            if row["text"] == self.title:
                row["bounds"] = dict(PRIMARY["bounds"])
        for match in result.get("anchor_matches", []):
            for row in match["matching_ocr"]:
                if row["text"] == self.title:
                    row["bounds"] = dict(PRIMARY["bounds"])
        if any(row["text"] == self.title for row in result["ocr"]):
            result["ocr"].append({"text": self.subtitle, "bounds": dict(STATUS["bounds"])})
        return result


class HousekeeperStatusTests(unittest.TestCase):
    def session(self):
        session = ChatSession({"app": WECHAT, "action": "read"}, HousekeeperFake())
        session.frame = dict(FRAME)
        return session

    def value(self, rows=None):
        return {"ocr": copy.deepcopy(rows if rows is not None else [PRIMARY, STATUS]), "ocr_truncated": False}

    def assert_ambiguous(self, value):
        with self.assertRaises(Stopped) as failure:
            self.session().wechat_header(value)
        self.assertEqual(failure.exception.code, "ambiguous_target")

    def test_actual_geometry_filters_only_known_status_without_mutating_rows(self):
        value = self.value()
        self.assertEqual(self.session().wechat_header_rows(value), [PRIMARY])
        self.assertEqual(self.session().wechat_header(value), PRIMARY["text"])
        self.assertEqual(self.session().wechat_header(value, "管家"), PRIMARY["text"])
        self.assertEqual(value["ocr"], [PRIMARY, STATUS])

    def test_row_order_does_not_select_a_generic_first_row(self):
        self.assertEqual(self.session().wechat_header(self.value([STATUS, PRIMARY])), PRIMARY["text"])

    def test_status_literal_alone_remains_an_independent_chat_title(self):
        for row in (STATUS, {"text": STATUS["text"], "bounds": dict(PRIMARY["bounds"])}):
            with self.subTest(bounds=row["bounds"]):
                self.assertEqual(self.session().wechat_header(self.value([row]), STATUS["text"]), STATUS["text"])

    def test_reversed_or_overlapping_geometry_remains_ambiguous(self):
        for change in ("reversed", "overlap"):
            value = self.value()
            if change == "reversed":
                value["ocr"][0]["bounds"]["y"], value["ocr"][1]["bounds"]["y"] = STATUS["bounds"]["y"], PRIMARY["bounds"]["y"]
            else:
                value["ocr"][1]["bounds"]["y"] = PRIMARY["bounds"]["y"] + 10
            self.assert_ambiguous(value)

    def test_unknown_subtitle_or_unknown_primary_is_not_whitelisted(self):
        for index, text in ((1, "暂无法连接其他服务"), (1, STATUS["text"] + "其他"),
                            (1, "暂无法连接 openclaw"), (0, "管家其他"), (0, "其他助手 AI")):
            value = self.value()
            value["ocr"][index]["text"] = text
            self.assert_ambiguous(value)

    def test_misaligned_or_wrong_band_or_large_status_stays_ambiguous(self):
        for field, amount in (("x", 5), ("y", -7), ("height", 3)):
            value = self.value()
            value["ocr"][1]["bounds"][field] += amount
            self.assert_ambiguous(value)

    def test_third_title_or_incomplete_ocr_cannot_be_discarded(self):
        value = self.value()
        value["ocr"].append({"text": "另一标题", "bounds": bounds(693, 44, 80, 14)})
        self.assert_ambiguous(value)
        for truncated in (True, None):
            value = self.value()
            value["ocr_truncated"] = truncated
            self.assert_ambiguous(value)

    def test_observed_status_does_not_change_independently_verified_send(self):
        fake = HousekeeperFake()
        result = execute_chat(send_request(fake), fake, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["result"]["send_verified"])
        self.assertEqual(sum(c["command"] == "visual_key" and c.get("key") == "return" for c in fake.calls), 1)

    def test_unknown_subtitle_stops_highlevel_send_before_any_input(self):
        fake = HousekeeperFake("未知状态")
        result = execute_chat(send_request(fake), fake, recipe_store=False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "ambiguous_target")
        self.assertFalse(any(c["command"] in {"visual_click", "visual_type_text", "visual_key", "batch"} for c in fake.calls))

    def test_existing_different_draft_and_exact_send_authorization_remain_required(self):
        fake = HousekeeperFake()
        fake.draft = "既有草稿"
        result = execute_chat(send_request(fake), fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "draft_present")
        self.assertEqual(fake.draft, "既有草稿")
        self.assertFalse(any(c["command"] in {"visual_click", "visual_type_text", "visual_key", "batch"} for c in fake.calls))
        fake = HousekeeperFake()
        request = send_request(fake)
        request["send_authorization"]["chat"] = "另一个收件人"
        result = execute_chat(request, fake, recipe_store=False)
        self.assertEqual(result["error"]["code"], "send_denied")
        self.assertEqual(fake.calls, [])


if __name__ == "__main__":
    unittest.main()
