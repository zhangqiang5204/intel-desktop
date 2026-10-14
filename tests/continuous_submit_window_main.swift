import Foundation
import AppKit
import ApplicationServices

struct VisualSearchOverlay {}
// PRODUCTION_TYPES

final class FakeMonitor { var interactionRevision: UInt64 = 4 }
final class FakeHelper { let monitor = FakeMonitor() }

final class VisualDesktop {
    var nativeCommandScope: VisualNativeCommandScope?
    private var continuousSubmitProof: VisualContinuousSubmitProof?
    // PRODUCTION_SCOPE_AND_LIFECYCLE

    func prepare(age: Double, finished: Double = 9.9, security: Bool = true,
                 revision: UInt64? = 4, focused: Bool = true, exact: Bool = true,
                 bound: Bool = true) -> Bool {
        continuousSubmitProof = nil
        nativeCommandScope = bound ? VisualNativeCommandScope(taskID: "task", operationID: "op") : nil
        let helper = FakeHelper()
        let window = CGRect(x: 356, y: 25, width: 855, height: 1079)
        let identity = VisualIdentity(pid: 7, windowID: 9, frame: window, topology: "offline")
        let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let finalFrame = VisualFrame(image: image, completeSerial: 2, time: 10, completeTime: 10.09,
            idleConfirmed: false, capturedRegions: [window])
        let guardFrame = VisualFrame(image: image, completeSerial: 1, time: 9, completeTime: 9.1,
            idleConfirmed: false, capturedRegions: [window])
        let app = AXUIElementCreateApplication(7)
        let next = VisualSnapshot(id: "proof", identity: identity, frame: finalFrame, created: 10 + age,
            focusedWindow: app, focusedFrame: window, focusedTitle: "", rows: [], anchors: [],
            confirmed: true, confirmationSource: "offline")
        let old = next
        let control = CGRect(x: 686, y: 943, width: 495, height: 113)
        let controlled = ("chat_composer", control)
        let safetyRegion = control.insetBy(dx: -12, dy: -12)
        let roiRows: [[String: Any]] = [["text": "message", "bounds": rectJSON(control)]]
        let finalPostEditProof: (serial: Int, headerRows: [[String: Any]], securityRows: [[String: Any]]?)? =
            (2, roiRows, security ? roiRows : nil)
        let inputDispatchFinished: Double? = finished
        let selectedInputRevision = revision
        let result: [String: Any] = ["input_control_focus_retained": focused]
        let request: [String: Any] = ["expected_text": exact ? "message" : "different"]
        let command = "visual_type_text", title = "recipient"
        let proofNow = 10 + age
        // PRODUCTION_PREPARATION
        return continuousSubmitProof != nil
    }
}

// PRODUCTION_SELF_TESTS

var cases = visualContinuousSubmitSelfTests()
func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
let desktop = VisualDesktop()
check("preparation_accepts_observed_D_1_4s_frame", desktop.prepare(age: 1.4))
check("preparation_accepts_exact_two_second_boundary", desktop.prepare(age: 2))
check("preparation_rejects_over_two_seconds", !desktop.prepare(age: 2.001))
check("preparation_rejects_frame_before_input_finished", !desktop.prepare(age: 1.4, finished: 10.01))
check("preparation_rejects_missing_security", !desktop.prepare(age: 1.4, security: false))
check("preparation_rejects_revision_change", !desktop.prepare(age: 1.4, revision: 5))
check("preparation_rejects_missing_focus", !desktop.prepare(age: 1.4, focused: false))
check("preparation_rejects_nonexact_full_value", !desktop.prepare(age: 1.4, exact: false))
check("preparation_rejects_missing_operation_binding", !desktop.prepare(age: 1.4, bound: false))
let report: [String: Any] = ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "cases": cases,
    "capture_performed": false, "input_performed": false]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
if report["ok"] as? Bool != true { exit(1) }
