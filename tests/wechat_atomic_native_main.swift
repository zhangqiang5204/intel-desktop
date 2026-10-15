import Foundation
import CoreGraphics
import CoreFoundation

struct VisualIdentity: Equatable { let pid: Int32; let windowID: UInt32; let frame: CGRect; let topology: String }
struct VisualFrame {
    var completeSerial: Int
    var time: Double
    var idleConfirmed = false
    var capturedRegions: [CGRect]?
    var screenWindows = [1]
    var excludedInputRegions: [CGRect] = []
    var searchOverlay: Int?
    var searchQuery: String?
}
struct VisualSnapshot {
    let id: String
    let identity: VisualIdentity
    let frame: VisualFrame
    let anchors = ["搜索", "发送"]
    let confirmed = true
    let focusedWindow = 1
}
let fixtureWindow = CGRect(x: 356, y: 25, width: 855, height: 1079)
let fixtureIdentity = VisualIdentity(pid: 7, windowID: 9, frame: fixtureWindow, topology: "fixture")
var eventLog: [String] = []
var eventHook: ((String) -> Void)?
class CGEvent {
    let label: String
    var flags: CGEventFlags = []
    init?(mouseEventSource: Int, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) {
        label = mouseType == .leftMouseDown ? "click_down" : "click_up"
    }
    init?(keyboardEventSource: Int, virtualKey: Int, keyDown: Bool) { label = keyDown ? "unicode_down" : "unicode_up" }
    func setIntegerValueField(_ field: CGEventField, value: Int64) {}
    func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UInt16>?) {}
    func post(tap: CGEventTapLocation) { eventLog.append(label); eventHook?(label) }
}
class Monitor {
    var interactionRevision: UInt64 = 4
    let marker: Int64 = 1
    var failure: String?
    func check() throws { if let failure { throw fail(failure, "fixture guard") } }
}
struct FixtureTarget { let window = 1 }
class Helper {
    let source = 1
    let monitor = Monitor()
    var failDown = false
    var verifyFailure = false
    var secureFailure = false
    func post(_ event: CGEvent, target: FixtureTarget) throws {
        try monitor.check()
        if failDown { throw fail("post_failed", "fixture") }
        event.post(tap: .cghidEventTap)
    }
    func verify(_ target: FixtureTarget, focusedWindow: Bool) throws {
        if verifyFailure { throw fail("visual_target_changed", "fixture") }
    }
    func denySecure(_ window: Int) throws { if secureFailure { throw fail("secure_field_denied", "fixture") } }
}

// PRODUCTION_SUPPORT

func visualMergeOCRRows(_ groups: [[[String: Any]]]) -> [[String: Any]] { groups.flatMap { $0 } }
func visualRowsWithoutEmptyComposerHint(_ frame: VisualFrame, window: CGRect, rows: [[String: Any]], now: Double) -> [[String: Any]] { rows }
func row(_ text: String, _ bounds: CGRect) -> [String: Any] { ["text": text, "bounds": rectJSON(bounds)] }
typealias Batch = (rows: [[String: Any]], regionRows: [[[String: Any]]], stageMS: [String: Double])

class Harness {
    var snapshot: VisualSnapshot?
    var selectedInput: (VisualIdentity, String, CGRect, Int)?
    var selectedInputRevision: UInt64?
    var searchActivation: Int?
    var focusClickRevision: UInt64?
    let helper = Helper()
    let target = FixtureTarget()
    var count = 0
    var composerFocusEvents = 0
    var text = "完整消息"
    var draft = ""
    var mode = "valid"
    var captureCalls = 0
    var ocrCalls = 0
    var snapshotCalls = 0
    var observedROICount = 0
    var guardCalls = 0
    var inputEvidenceFrame = VisualFrame(completeSerial: 2, time: 0, capturedRegions: [fixtureWindow])

    func selectedIdentity(_ target: FixtureTarget) throws -> VisualIdentity {
        mode == "target_changed" ? VisualIdentity(pid: 8, windowID: 9, frame: fixtureWindow, topology: "fixture") : fixtureIdentity
    }
    func guardPoint(_ point: CGPoint, snapshot: VisualSnapshot) throws {
        if mode == "point_changed" { throw fail("coordinate_target_mismatch", "fixture") }
    }
    func guardUnchangedFocus(_ count: Int) throws {
        guardCalls += 1
        try helper.monitor.check()
        guard selectedInputRevision == helper.monitor.interactionRevision else { throw fail("visual_input_focus_changed", "fixture") }
        guard ProcessInfo.processInfo.systemUptime - inputEvidenceFrame.time <= 2 else { throw fail("stale_visual_snapshot", "fixture") }
        if mode == "guard_after_ocr" && ocrCalls > 0 { throw fail("visual_target_changed", "fixture") }
    }
    func waitFrame(helper: Helper, target: FixtureTarget, timeout: Double, after: Int) throws -> VisualFrame? {
        captureCalls += 1
        var frame = VisualFrame(completeSerial: after + 1, time: ProcessInfo.processInfo.systemUptime, capturedRegions: [fixtureWindow])
        if mode == "old_frame" { frame.time -= 3 }
        if mode == "idle" { frame.idleConfirmed = true }
        if mode == "serial" { frame.completeSerial = after }
        if mode == "coverage" { frame.capturedRegions = [] }
        if mode == "scene" { frame.screenWindows = [2] }
        return frame
    }
    func ocrRegions(_ frame: VisualFrame, identity: VisualIdentity, regions: [CGRect], measurePerformance: Bool, postEditComposerProof: Bool) throws -> Batch {
        ocrCalls += 1; observedROICount = regions.count
        let title = mode == "recipient" ? "其他人" : "文件助手"
        var groups = [[row(title, regions[0])], draft.isEmpty ? [] : [row(draft, regions[1])],
                      mode == "security" ? [row("验证码", regions[2])] : [], [row("发送", regions[3])]]
        if mode == "header_ambiguous" { groups[0].append(row(title, regions[0])) }
        if mode == "missing_Send" { groups[3] = [] }
        if mode == "truncated" { groups[2] = Array(repeating: row("x", regions[2]), count: 128) }
        return (groups.flatMap { $0 }, groups, [:])
    }
    func currentSceneMatches(_ frame: VisualFrame, identity: VisualIdentity, helper: Helper) throws -> Bool { mode != "scene_after_ocr" }
    func recordOCRStages(_ prefix: String, _ stages: [String: Double]) {}
    func makeSnapshot(_ frame: VisualFrame, target: FixtureTarget, helper: Helper, anchors: [String], confirmed: Bool,
                      continuation: VisualSnapshot, preparedRows: [[String: Any]]) throws -> VisualSnapshot {
        snapshotCalls += 1
        return VisualSnapshot(id: "focused", identity: fixtureIdentity, frame: frame)
    }
    func json(_ snapshot: VisualSnapshot, rows: [[String: Any]]) -> [String: Any] {
        ["snapshot_id": snapshot.id, "ocr": rows]
    }
    func matches(_ expected: String, rows: [[String: Any]]) -> Bool { rows.contains { $0["text"] as? String == expected } }
    func ocr(_ frame: VisualFrame, identity: VisualIdentity, region: CGRect) throws -> [[String: Any]] { [] }
    func postKey(_ code: Int, flags: CGEventFlags, helper: Helper, target: FixtureTarget, count: inout Int, beforePost: (Int) throws -> Void) throws { fatalError("search is excluded") }
    // PRODUCTION_SECURITY

    func validateAtomic(_ request: [String: Any]) throws {
        let focusBeforeType = try boolean(request, "focus_before_type")
        let kind = try string(request, "control_kind")!
        let replaceSearch = try boolean(request, "replace_search")
        // PRODUCTION_ATOMIC_VALIDATION
    }

    func edit() throws -> [String: Any] {
        let focusBeforeType = true, replaceSearch = false
        let visible = text
        let created = ProcessInfo.processInfo.systemUptime
        let guardFrame = VisualFrame(completeSerial: 2, time: created, capturedRegions: [fixtureWindow])
        let old = VisualSnapshot(id: "before", identity: fixtureIdentity, frame: guardFrame)
        let controlled = ("chat_composer", CGRect(x: 686, y: 943, width: 495, height: 113))
        let verificationRegion = controlled.1
        let safetyRegion = controlled.1.insetBy(dx: -12, dy: -12).intersection(fixtureWindow)
        let request: [String: Any] = ["chat_title": "文件助手", "expected_draft": ""]
        var expected: String?
        var inputDispatchStarted: Double?
        var inputDispatchFinished: Double?
        var actionStageMS: [String: Double] = [:]
        var freshControlRows: [[String: Any]] = []
        var typingStarted = false
        inputEvidenceFrame = guardFrame
        // PRODUCTION_ATOMIC_TYPE
        return ["events_posted": count, "composer_focus_events_posted": composerFocusEvents,
                "text_events_posted": count - composerFocusEvents, "typed": typingStarted]
    }

    func submit() throws -> [String: Any] {
        let submit = true
        let inputDispatchStarted: Double? = ProcessInfo.processInfo.systemUptime - 0.002
        let inputDispatchFinished: Double? = ProcessInfo.processInfo.systemUptime - 0.001
        let old = VisualSnapshot(id: "consumed", identity: fixtureIdentity, frame: inputEvidenceFrame)
        let submitGuardFrameReused = false, continuousSubmitReused = true
        let continuousProofFrameAgeMS: Double? = 100
        let actionStarted = inputDispatchStarted! - 0.001
        let actionStageMS: [String: Double] = [:]
        snapshot = old; selectedInputRevision = 4
        selectedInput = (fixtureIdentity, "chat_composer", fixtureWindow, 1)
        // PRODUCTION_TERMINAL_RECEIPT
        captureCalls += 1; ocrCalls += 1; snapshotCalls += 1
        return ["unexpected_fallthrough": true]
    }
}

var cases: [[String: Any]] = []
func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
func code(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as HelperError { return error.code } catch { return "unexpected" }
}
eventLog = []
let valid = Harness()
let edited = try valid.edit()
check("exactly_one_click_and_one_unicode_pair", eventLog == ["click_down", "click_up", "unicode_down", "unicode_up"])
check("all_events_counted", edited["events_posted"] as? Int == 4 && edited["text_events_posted"] as? Int == 2)
check("one_postclick_capture_without_second_type_guard_capture", valid.captureCalls == 1)
check("four_independent_ROIs", valid.ocrCalls == 1 && valid.observedROICount == 4)
check("no_intermediate_snapshot_binding", valid.snapshotCalls == 0)
check("guards_bracket_ocr_and_unicode", valid.guardCalls >= 3)
let atomicRequest: [String: Any] = ["focus_before_type": true, "control_kind": "chat_composer",
    "expected_draft": "", "chat_title": "文件助手", "text": "完整消息", "expected_text": "完整消息"]
check("atomic_request_contract_accepts_exact_empty_draft", code { try valid.validateAtomic(atomicRequest) } == nil)
for (key, value) in [("expected_draft", "其他草稿" as Any), ("control_kind", "search" as Any),
                     ("chat_title", "" as Any), ("chat_title", "换\n行" as Any),
                     ("expected_text", "其他消息" as Any), ("replace_search", true as Any)] {
    var request = atomicRequest; request[key] = value
    check("atomic_contract_\(key)_rejects", code { try valid.validateAtomic(request) } == "invalid_request")
}
var missingDraft = atomicRequest; missingDraft.removeValue(forKey: "expected_draft")
check("missing_empty_draft_refuses_before_input", code { try valid.validateAtomic(missingDraft) } == "invalid_request")
for mode in ["old_frame", "idle", "serial", "coverage", "scene", "recipient", "security", "header_ambiguous", "missing_Send", "truncated", "guard_after_ocr", "scene_after_ocr"] {
    eventLog = []
    let fixture = Harness(); fixture.mode = mode
    let failure = code { _ = try fixture.edit() }
    check("\(mode)_blocks_unicode_with_exact_click_count", failure != nil && fixture.count == 2 && eventLog == ["click_down", "click_up"])
}
eventLog = []
let changedRevision = Harness()
eventHook = { if $0 == "click_up" { changedRevision.helper.monitor.interactionRevision += 1 } }
check("interaction_after_click_blocks_unicode", code { _ = try changedRevision.edit() } == "visual_input_focus_changed" && changedRevision.count == 2)
eventHook = nil
eventLog = []
let multiChunk = Harness(); multiChunk.text = String(repeating: "文", count: 45)
eventHook = { if $0 == "unicode_up" { multiChunk.helper.monitor.interactionRevision += 1 } }
check("interruption_between_unicode_chunks_counts_only_completed_prefix", code { _ = try multiChunk.edit() } == "visual_input_focus_changed" && multiChunk.count == 4 && eventLog.count == 4)
eventHook = nil
let changedDraft = Harness(); changedDraft.draft = "保留草稿"
let stopped = try changedDraft.edit()
check("changed_draft_returns_known_click_only_receipt", stopped["atomic_composer_precondition_failed"] as? Bool == true && stopped["text_events_posted"] as? Int == 0)
check("changed_draft_receipt_has_no_input_capability", stopped["input_eligible"] as? Bool == false && changedDraft.snapshot == nil && changedDraft.selectedInput == nil)
let failedDown = Harness(); failedDown.helper.failDown = true
check("failed_click_down_counts_zero", code { _ = try failedDown.edit() } == "post_failed" && failedDown.count == 0)

let posted = Harness(); posted.count = 2
let receipt = try posted.submit()
check("submit_returns_before_any_capture_OCR_snapshot", posted.captureCalls == 0 && posted.ocrCalls == 0 && posted.snapshotCalls == 0)
check("submit_clears_all_input_capability", posted.snapshot == nil && posted.selectedInput == nil && posted.selectedInputRevision == nil && receipt["snapshot_id"] == nil && receipt["input_eligible"] as? Bool == false)
check("posted_is_not_send_proof", receipt["submit_events_posted"] as? Bool == true && receipt["send_verified"] as? Bool == false && receipt["post_submit_verification_required"] as? Bool == true)
let timing = receipt["input_event_timing"] as? [String: Any]
check("receipt_clock_does_not_claim_new_observation", timing?["receipt_materialized_ms"] != nil && timing?["complete_observation_ms"] == nil)
for eventCount in [0, 1, 3] {
    let partial = Harness(); partial.count = eventCount
    check("submit_count_\(eventCount)_denies_complete_receipt", code { _ = try partial.submit() } == "send_state_unknown")
}
let changed = Harness(); changed.count = 2; changed.mode = "target_changed"
check("post_Return_changed_target_does_not_invent_receipt", code { _ = try changed.submit() } == "visual_target_changed" && changed.captureCalls == 0)
let interrupted = Harness(); interrupted.count = 2; interrupted.helper.monitor.failure = "user_interrupted"
check("post_Return_takeover_propagates_without_capture", code { _ = try interrupted.submit() } == "user_interrupted" && interrupted.captureCalls == 0)
let report: [String: Any] = ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "cases": cases,
    "capture_performed": false, "input_performed": false]
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
if report["ok"] as? Bool != true { exit(1) }
