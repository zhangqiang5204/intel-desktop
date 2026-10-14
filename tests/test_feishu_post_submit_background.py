"""Posted Feishu sends return once, then verify only through background AX."""
import unittest

from test_chat_completion import send_request
import test_feishu_send_latency as latency

SendLatencyFake = latency.SendLatencyFake


class PostSubmitFake(SendLatencyFake):
    def __init__(self, change=None, delay=0):
        super().__init__()
        self.change = change
        self.delay = delay
        self.returned = False
        self.background_reads = 0
        self.text = send_request(self)["text"]

    def __call__(self, request):
        if self.returned:
            assert request["command"] == "inspect", "No input, status or new focus after the return request"
            assert request["include_menus"] is False
        response = super().__call__(request)
        if request["command"] == "submit_text" and response["ok"] and self.change == "takeover":
            self.interrupted = "manual_keyboard"
        if request.get("restore_previous"):
            self.returned = True
            if self.change == "user_activity":
                self.front = ("com.example.user-app", 901)
                self.interrupted = "manual_keyboard"
        elif request["command"] == "inspect" and self.returned:
            self.background_reads += 1
            tree = response["result"]
            if self.change == "PID": tree["target_pid"] += 1
            if self.change == "frame": tree["windows"][0]["position"]["x"] += 1
            if self.change == "window": tree["windows"][0]["title"] = "other-window"
            if self.change == "recipient":
                next(r for r in tree["elements"] if r["element_id"] == "composer")["value"] = "发送给 其他收件人\n\u200b\n\u200b\n\u200b"
            if self.change == "incomplete_composer":
                next(r for r in tree["elements"] if r["element_id"] == "composer")["value_complete"] = False
            if self.change == "truncated": tree["truncated"] = True
            if self.change == "incomplete_message":
                for row in tree["elements"]:
                    if row.get("value") == self.text: row.update(value_complete=False, value_truncated=True)
            if self.background_reads <= self.delay:
                tree["elements"] = [r for r in tree["elements"] if r.get("value") != self.text]
        return response


class FeishuPostSubmitBackgroundTests(unittest.TestCase):
    def send(self, fake, **kwargs):
        return latency.FeishuSendLatencyTests().send(fake, **kwargs)

    def assert_one_return_no_replay(self, fake):
        self.assertEqual(fake.restore_calls, 1)
        self.assertEqual(sum(c["command"] == "submit_text" for c in fake.calls), 1)
        self.assertEqual(sum(c["command"] == "focus" and not c.get("restore_previous") for c in fake.calls), 1)
        submit = next(i for i, c in enumerate(fake.calls) if c["command"] == "submit_text")
        self.assertTrue(fake.calls[submit + 1].get("restore_previous"))
        self.assertTrue(all(c["command"] == "inspect" for c in fake.calls[submit + 2:]))

    def test_submit_return_inspect_order_and_delayed_echo_do_not_hold_foreground(self):
        fake = PostSubmitFake(delay=3)
        response = self.send(fake)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["scope_completed"])
        self.assertTrue(response["result"]["send_verified"])
        self.assertEqual(fake.background_reads, 4)
        self.assertEqual(fake.front, fake.origin)
        self.assert_one_return_no_replay(fake)
        timing = response["send_call_timing"]
        self.assertEqual(timing["focus_return_after_submit_call_ms"], 50)
        self.assertGreater(timing["submit_call_finished_to_confirmation_ms"], 3000)
        self.assertEqual(timing["confirmation_evidence"]["before_exact_body_occurrences"], 0)
        self.assertEqual([r["exact_body_occurrences"] for r in timing["confirmation_evidence"]["read_summaries"]], [0, 0, 0, 1])
        self.assertNotIn(fake.text, str(timing))

    def test_no_echo_is_unknown_business_and_scope_with_verified_historical_return(self):
        fake = PostSubmitFake()
        fake.no_echo = True
        response = self.send(fake)
        self.assertTrue(response["ok"])
        self.assertIsNone(response["result"]["sent"])
        self.assertEqual(response["result"]["submission_state"], "posted_unverified")
        self.assertFalse(response["business_completed"])
        self.assertFalse(response["scope_completed"])
        self.assertTrue(response["focus_restored"])
        self.assert_one_return_no_replay(fake)

    def test_background_PID_window_frame_and_recipient_changes_stop_without_focus_reclaim(self):
        for change in ("PID", "window", "frame", "recipient"):
            with self.subTest(change=change):
                fake = PostSubmitFake(change)
                response = self.send(fake)
                self.assertFalse(response["ok"])
                self.assertIsNone(response["sent"])
                self.assertTrue(response["completion_unknown"])
                self.assertFalse(response["business_completed"])
                self.assertTrue(response["focus_restored"])
                self.assert_one_return_no_replay(fake)

    def test_incomplete_composer_or_tree_cannot_verify_posted_send(self):
        for change in ("incomplete_composer", "truncated"):
            with self.subTest(change=change):
                fake = PostSubmitFake(change)
                response = self.send(fake)
                self.assertFalse(response["ok"])
                self.assertEqual(response["error"]["code"], "send_state_unknown")
                self.assertTrue(response["completion_unknown"])
                self.assertFalse(response["business_completed"])
                self.assert_one_return_no_replay(fake)

    def test_exact_truncated_value_is_not_complete_message_evidence(self):
        fake = PostSubmitFake("incomplete_message")
        response = self.send(fake)
        self.assertIsNone(response.get("result", response)["sent"])
        self.assertEqual(response["error"]["code"], "send_state_unknown")
        self.assertFalse(response["business_completed"])
        self.assertTrue(all(r["exact_body_occurrences"] == 0 for r in response["send_call_timing"]["confirmation_evidence"]["read_summaries"]))
        self.assert_one_return_no_replay(fake)

    def test_user_activity_after_return_does_not_stop_readonly_proof_or_reclaim_focus(self):
        fake = PostSubmitFake("user_activity")
        response = self.send(fake, reply_contains="尚未出现的标记", wait_timeout_ms=3000)
        self.assertTrue(response["ok"], response)
        self.assertTrue(response["result"]["send_verified"])
        self.assertEqual(fake.front, ("com.example.user-app", 901))
        self.assert_one_return_no_replay(fake)

    def test_native_return_failure_preserves_verified_send_without_second_return(self):
        for reason in ("task_focus_changed", "previous_activation_failed"):
            with self.subTest(reason=reason):
                fake = PostSubmitFake()
                fake.restore_reason = reason
                response = self.send(fake)
                self.assertFalse(response["ok"])
                self.assertEqual(response["error"]["code"], "focus_restore_unverified")
                self.assertTrue(response["business_completed"])
                self.assertTrue(response["sent"])
                self.assertFalse(response["scope_completed"])
                self.assert_one_return_no_replay(fake)

    def test_true_takeover_at_return_yields_and_keeps_verified_or_unknown_send_evidence(self):
        for no_echo in (False, True):
            with self.subTest(no_echo=no_echo):
                fake = PostSubmitFake("takeover")
                fake.no_echo = no_echo
                response = self.send(fake)
                self.assertFalse(response["ok"])
                self.assertEqual(response["error"]["code"], "user_interrupted")
                self.assertEqual(response["focus_lifecycle"], "yielded_to_user")
                self.assertEqual(response["business_completed"], not no_echo)
                self.assertFalse(response["scope_completed"])
                self.assert_one_return_no_replay(fake)

    def test_return_transport_unknown_is_cached_even_when_later_proof_succeeds(self):
        fake = PostSubmitFake()
        fake.restore_error = True
        response = self.send(fake)
        self.assertFalse(response["ok"])
        self.assertTrue(response["sent"])
        self.assertFalse(response["focus_restored"])
        self.assertEqual(fake.restore_calls, 1)
        self.assertEqual(sum(c["command"] == "submit_text" for c in fake.calls), 1)

    def test_missing_submit_proof_never_enters_early_return_or_confirmation(self):
        for missing in ("submit_preconditions_verified", "submit_events_posted"):
            with self.subTest(missing=missing):
                class MissingReceiptFake(PostSubmitFake):
                    def __call__(self, request):
                        response = super().__call__(request)
                        if request["command"] == "submit_text": response["result"].pop(missing)
                        return response
                fake = MissingReceiptFake()
                response = self.send(fake)
                self.assertFalse(response["ok"])
                self.assertIsNone(response["sent"])
                self.assertTrue(response["completion_unknown"])
                self.assertFalse(response["send_call_timing"]["focus_return_requested_after_submit"])
                self.assertNotIn("focus_return_after_submit_call_ms", response["send_call_timing"])
                self.assertEqual(fake.background_reads, 0)
                self.assertEqual(fake.restore_calls, 1)
                self.assertEqual(sum(c["command"] == "submit_text" for c in fake.calls), 1)


if __name__ == "__main__":
    unittest.main()
