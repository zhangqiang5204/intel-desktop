// Included after extracted production boundaries and consumers by the Python
// runner. All transport and event producers below are fakes.
enum TestFailure: Error { case assertion(String) }
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure.assertion(message) }
}
var results: [String: Bool] = [:], failures: [String: String] = [:]
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); results[name] = true }
    catch { results[name] = false; failures[name] = String(describing: error) }
}
func errorCode(_ attempt: () throws -> Void) -> String? {
    do { try attempt(); return nil } catch let error as HelperError { return error.code }
    catch { return "unwrapped_error" }
}
func captureThroughBothBoundaries<T>(stage: String = "before_shareable_content", _ attempt: () throws -> T) throws -> T {
    try frameBoundary {
        try visualCaptureConnectionRecovery(deadline: ProcessInfo.processInfo.systemUptime + 5, check: {}) {
            try captureBoundary(stage: stage, attempt)
        }.0
    }
}

test("legacy_wrapping_reproduces_sanitized_live_error_signature") {
    for error: Error in [VisualSearchObservationChanged(), VisualNavigationHintObservationChanged()] {
        let diagnostic = VisualCaptureSystemFailure(error)
        try expect(diagnostic.domain == "unrecognized_domain" && diagnostic.code == 1,
                   "Internal control errors bridge to the same redacted domain/code as the live failure")
    }
}
test("read_read_click_transition_waits_for_actual_stop_and_never_replays_click") {
    let registry = CaptureLifecycleRegistry(), old = NSObject(), next = NSObject()
    let oldKey = ObjectIdentifier(old), nextKey = ObjectIdentifier(next)
    var stopCompletion: ((Error?) -> Void)?, starts = 0, stops = 0, fakeEvents = 0
    var receiver = VisualWarmEpoch(), serial = 0
    try registry.register(key: oldKey, start: { completion in starts += 1; completion(nil) }, stop: { completion in
        stops += 1; stopCompletion = completion
    })
    registry.start(key: oldKey) { _ in }
    // Two reads share one healthy stream but establish separate PTS epochs.
    for tick in [10.0, 20.0] {
        let accepted = try captureThroughBothBoundaries {
            receiver.prepare(at: tick); receiver.finish()
            return receiver.accepts(complete: true, pts: tick + 1)
        }
        try expect(accepted, "Both pre-action reads need distinct complete frames"); serial += 1
    }
    fakeEvents += 2 // The mouse pair is outside the capture-only retry loop.
    var attempts = 0, polls = 0
    let result: Int = try visualSettleSearchObservation(enabled: true,
        deadline: ProcessInfo.processInfo.systemUptime + 5, check: {}) {
        attempts += 1
        return try captureThroughBothBoundaries {
            if attempts == 1 {
                // Same ownership semantics as the failed attempt's production
                // defer: release the old pool, retain transport until callback.
                defer { _ = registry.stop(keys: [oldKey]) }
                throw VisualSearchObservationChanged(details: ["fixture": "known_popup"])
            }
            try expect(registry.status["capture_lifecycle_cleanup_pending_count"] as? Int == 1,
                       "An in-flight stop cannot become a terminal claim")
            var prematureAdmission = false
            do { try registry.register(key: nextKey, start: { _ in }, stop: { _ in }) }
            catch CaptureLifecycle.Failure.cleanupPending { prematureAdmission = true }
            try expect(prematureAdmission, "Strict registration gate remains effective")
            var time = 0.0
            try expect(registry.waitForPendingCleanup(timeout: 1.5, now: { time }, poll: {
                polls += 1; time += 0.1; stopCompletion?(nil); stopCompletion = nil
            }), "Only real stop completion may release the next capture")
            try registry.register(key: nextKey, start: { completion in starts += 1; completion(nil) },
                stop: { completion in stops += 1; completion(nil) })
            registry.start(key: nextKey) { _ in }
            receiver.prepare(at: 30); receiver.finish()
            try expect(!receiver.accepts(complete: true, pts: 21), "Old complete pixels cannot verify the click")
            try expect(!receiver.accepts(complete: false, pts: 31), "Idle frame cannot verify the click")
            try expect(receiver.accepts(complete: true, pts: 31), "Reobservation needs a fresh complete frame")
            serial += 1; return serial
        }
    }
    try expect(result == 3 && attempts == 2 && fakeEvents == 2, "Reobserve pixels once, never repeat input")
    try expect(starts == 2 && stops == 1 && polls == 1, "Replace only after real old-stream stop")
    try expect(registry.drain(timeout: 0) && stops == 2, "Operation end stops the final capture too")
}
test("search_transition_details_survive_capture_and_frame_boundaries") {
    var attempts = 0
    var caught: HelperError?
    do {
        let _: Int = try visualSettleSearchObservation(enabled: true,
            deadline: ProcessInfo.processInfo.systemUptime + 5, check: {}) {
            attempts += 1
            return try captureThroughBothBoundaries {
                throw VisualSearchObservationChanged(details: ["phase": "matching_shareable_search_popup", "fixture": 7])
            }
        }
    } catch let error as HelperError { caught = error }
    try expect(attempts == 4 && caught?.code == "visual_target_changed", "Existing four-attempt bound stays intact")
    try expect(caught?.details["fixture"] as? Int == 7, "Do not erase the reason while propagating")
}
test("navigation_transition_crosses_both_boundaries_with_two_attempt_limit") {
    var attempts = 0
    let result: Int = try visualSettleNavigationHint(enabled: true,
        deadline: ProcessInfo.processInfo.systemUptime + 5, check: {}) {
        attempts += 1
        return try captureThroughBothBoundaries {
            if attempts == 1 { throw VisualNavigationHintObservationChanged() }; return 9
        }
    }
    try expect(result == 9 && attempts == 2, "Known hint transition reaches the original consumer")
    attempts = 0
    let code = errorCode {
        let _: Int = try visualSettleNavigationHint(enabled: true,
            deadline: ProcessInfo.processInfo.systemUptime + 5, check: {}) {
            attempts += 1
            return try captureThroughBothBoundaries { throw VisualNavigationHintObservationChanged() }
        }
    }
    try expect(code == "visual_target_changed" && attempts == 2, "No added attempts for unsettled hints")
}
test("unbound_search_and_hint_transitions_never_retry") {
    for navigation in [false, true] {
        var attempts = 0
        let code = errorCode {
            if navigation {
                let _: Int = try visualSettleNavigationHint(enabled: false,
                    deadline: ProcessInfo.processInfo.systemUptime + 5, check: {}) {
                    attempts += 1
                    return try captureThroughBothBoundaries { throw VisualNavigationHintObservationChanged() }
                }
            } else {
                let _: Int = try visualSettleSearchObservation(enabled: false,
                    deadline: ProcessInfo.processInfo.systemUptime + 5, check: {}) {
                    attempts += 1
                    return try captureThroughBothBoundaries { throw VisualSearchObservationChanged() }
                }
            }
        }
        try expect(code == "visual_target_changed" && attempts == 1, "A typed signal alone does not authorize retry")
    }
}
test("original_deadline_remains_binding") {
    var attempts = 0
    let code = errorCode {
        let _: Int = try visualSettleSearchObservation(enabled: true, deadline: 0, check: {}) {
            attempts += 1
            return try captureThroughBothBoundaries { throw VisualSearchObservationChanged() }
        }
    }
    try expect(code == "visual_target_changed" && attempts == 1, "No fresh retry deadline")
}
test("foreign_change_and_takeover_errors_are_not_retried") {
    for expected in ["visual_target_changed", "user_interrupted", "secure_field_denied"] {
        var attempts = 0
        let code = errorCode {
            let _: Int = try visualSettleSearchObservation(enabled: true,
                deadline: ProcessInfo.processInfo.systemUptime + 5, check: {}) {
                attempts += 1
                return try captureThroughBothBoundaries { throw fail(expected, "fixture") }
            }
        }
        try expect(code == expected && attempts == 1, "Preserve failure without treating it as a transition")
    }
}
test("takeover_between_attempts_blocks_capture_without_input_replay") {
    var attempts = 0, guards = 0
    let code = errorCode {
        let _: Int = try visualSettleSearchObservation(enabled: true,
            deadline: ProcessInfo.processInfo.systemUptime + 5, check: {
                guards += 1; if guards == 2 { throw fail("user_interrupted", "fixture") }
            }) {
            attempts += 1
            return try captureThroughBothBoundaries { throw VisualSearchObservationChanged() }
        }
    }
    try expect(code == "user_interrupted" && attempts == 1 && guards == 2, "Second attempt still requires its input guard")
}
test("actual_system_errors_keep_redacted_diagnostics_and_are_not_retried") {
    var attempts = 0, caught: HelperError?
    do {
        let _: Int = try visualSettleSearchObservation(enabled: true,
            deadline: ProcessInfo.processInfo.systemUptime + 5, check: {}) {
            attempts += 1
            return try captureThroughBothBoundaries {
                throw NSError(domain: "untrusted_fixture_domain", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "private_fixture_text"])
            }
        }
    } catch let error as HelperError { caught = error }
    try expect(attempts == 1 && caught?.code == "visual_capture_failed", "Unknown OS errors are never transition retries")
    try expect(caught?.details["capture_error_domain"] as? String == "unrecognized_domain" &&
        caught?.details["capture_error_code"] as? Int == 1, "Preserve existing privacy-safe diagnostics")
    let data = try JSONSerialization.data(withJSONObject: caught!.details)
    try expect(!String(decoding: data, as: UTF8.self).contains("private_fixture_text"), "Never expose NSError contents")
}
test("helper_errors_keep_original_details_and_capture_stage") {
    var caught: HelperError?
    do {
        let _: Int = try captureThroughBothBoundaries { throw fail("capture_cleanup_pending", "fixture", ["pending": 1]) }
    } catch let error as HelperError { caught = error }
    try expect(caught?.code == "capture_cleanup_pending" && caught?.details["pending"] as? Int == 1,
               "Lifecycle cleanup failures remain fail closed")
    try expect(caught?.details["capture_stage"] as? String == "before_shareable_content",
               "Capture failure stage remains available")
}
test("shareable_API_failure_has_its_own_stage_without_retry") {
    // The old candidate lacks this label; report a failed check, not a trap.
    try expect(VisualWarmCaptureStage(rawValue: "requesting_shareable_content") != nil &&
        VisualWarmCaptureStage(rawValue: "binding_capture_session") != nil,
        "Initial guard, shareable API and session binding need separate attribution")
    var caught: HelperError?
    do {
        let _: Int = try captureThroughBothBoundaries(stage: "requesting_shareable_content") {
            throw NSError(domain: NSCocoaErrorDomain, code: 1)
        }
    } catch let error as HelperError { caught = error }
    try expect(caught?.details["capture_stage"] as? String == "requesting_shareable_content" &&
        caught?.details["capture_error_domain"] as? String == NSCocoaErrorDomain,
        "Actual API diagnostics must identify the API boundary")
}

let output: [String: Any] = ["ok": failures.isEmpty, "cases": results, "failures": failures,
    "capture_performed": false, "input_performed": false]
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
exit(failures.isEmpty ? 0 : 1)
