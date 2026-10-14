"""Bounded per-call timing distinguishes waits without retaining native content."""
import json
import unittest
from unittest.mock import patch

from test_chat_workflows import WeChatFake
from chat_workflows import ChatSession, WECHAT, execute_chat


class NativeTimingTests(unittest.TestCase):
    def test_real_workflow_reports_call_duration_with_command_only_on_success(self):
        fake = WeChatFake()
        fake.title, fake.pages = "私密收件人", [["私密消息正文"]]
        now = [0.0]
        durations = {"status": .001, "inspect": .012, "focus": .006, "visual_read": .250}
        def callback(request):
            response = fake(request)
            now[0] += durations[request["command"]]
            return response
        with patch("chat_workflows.time.monotonic", side_effect=lambda: now[0]), patch("chat_workflows.time.perf_counter", side_effect=lambda: now[0]):
            result = execute_chat({"app": WECHAT, "action": "read", "chat": fake.title}, callback, recipe_store=False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["native_timings_count"], result["native_calls"])
        self.assertFalse(result["native_timings_truncated"])
        self.assertEqual([r["command"] for r in result["native_timings"]], result["commands"])
        for row in result["native_timings"]:
            self.assertEqual(set(row), {"command", "elapsed_ms"})
            self.assertEqual(row["elapsed_ms"], durations[row["command"]] * 1000)
        encoded = json.dumps(result["native_timings"], ensure_ascii=False)
        self.assertNotIn(fake.title, encoded)
        self.assertNotIn("私密消息正文", encoded)
        self.assertNotIn("window_title", encoded)
        self.assertNotIn("app", encoded)

    def test_failed_transport_is_timed_and_list_is_bounded_with_true_total_count(self):
        for calls in (1, 40):
            with self.subTest(calls=calls):
                now = [0.0]
                def callback(request):
                    now[0] += .025 if request["command"] == "type_text" else .002
                    if request["command"] == "type_text":
                        raise RuntimeError("私密正文必须不落耗时")
                    return {"ok": True, "result": {}}
                def run(session):
                    for _ in range(calls):
                        session.call("status")
                    session.call("type_text", text="私密正文必须不落耗时")
                with patch.object(ChatSession, "run", run), patch("chat_workflows.time.monotonic", side_effect=lambda: now[0]), patch("chat_workflows.time.perf_counter", side_effect=lambda: now[0]):
                    result = execute_chat({"app": WECHAT, "action": "read"}, callback, recipe_store=False)
                self.assertEqual(result["error"]["code"], "native_transport_error")
                self.assertEqual(result["native_timings_count"], calls + 1)
                self.assertEqual(len(result["native_timings"]), min(32, calls + 1))
                self.assertEqual(result["native_timings_truncated"], calls >= 32)
                self.assertNotIn("私密", json.dumps(result["native_timings"], ensure_ascii=False))
                if calls == 1:
                    self.assertEqual(result["native_timings"][-1], {"command": "type_text", "elapsed_ms": 25.0})


if __name__ == "__main__":
    unittest.main()
