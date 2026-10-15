import Foundation
import CoreGraphics
import CoreFoundation

var clock: Double = 100
class ProcessInfo { static let processInfo = ProcessInfo(); var systemUptime: Double { clock += 0.01; return clock } }
enum AXError: Int { case success = 0, actionUnsupported = -1 }
typealias AXUIElement = FakeAX
class FakeAX {
    var pid: Int32
    var frame: CGRect
    var title: String
    var focused: FakeAX?
    var children: [FakeAX] = []
    init(_ pid: Int32, _ frame: CGRect, _ title: String = "") { self.pid = pid; self.frame = frame; self.title = title }
}
struct AppState { var bundle: String; var terminated = false; let root: FakeAX }
var apps: [Int32: AppState] = [:]
var frontPID: Int32 = 900
var topology = "screen"
var logs: [String] = []
var activationHook: ((Int32) -> Void)?
var rootSetterWritable = false
var rootSetterChangesFocus = true
var drains: [Bool] = []
class NSRunningApplication {
    let processIdentifier: Int32
    var bundleIdentifier: String? { apps[processIdentifier]?.bundle }
    var isTerminated: Bool { apps[processIdentifier]?.terminated != false }
    init?(processIdentifier: Int32) { guard apps[processIdentifier] != nil else { return nil }; self.processIdentifier = processIdentifier }
    enum ActivationOption { case activateIgnoringOtherApps }
    func activate(options: [ActivationOption]) -> Bool {
        guard !isTerminated else { return false }
        logs.append("activate_\(processIdentifier)")
        if processIdentifier == 900 { logs.append("return_armed_\(currentHelper?.monitor.armed == true)") }
        frontPID = processIdentifier; activationHook?(processIdentifier); return true
    }
}
let kAXFocusedWindowAttribute = "AXFocusedWindow"
let kAXFrontmostAttribute = "AXFrontmost"
let kAXTitleAttribute = "AXTitle"
let kAXMainAttribute = "AXMain"
let kAXFocusedAttribute = "AXFocused"
let kAXRaiseAction = "AXRaise"
func CFEqual(_ left: FakeAX, _ right: FakeAX) -> Bool { left === right }
func AXUIElementCreateApplication(_ pid: Int32) -> FakeAX { apps[pid]!.root }
func AXUIElementGetPid(_ element: FakeAX, _ pid: inout Int32) -> AXError { pid = element.pid; return .success }
func AXUIElementSetMessagingTimeout(_ element: FakeAX, _ timeout: Double) {}
func AXUIElementSetAttributeValue(_ element: FakeAX, _ field: CFString, _ value: Any) -> AXError {
    if field as String == kAXFocusedWindowAttribute, let window = value as? FakeAX {
        logs.append("root_focus_set")
        if rootSetterChangesFocus { element.focused = window }
    }
    return .success
}
func AXUIElementIsAttributeSettable(_ element: FakeAX, _ field: CFString, _ value: inout DarwinBoolean) -> AXError {
    value = DarwinBoolean(field as String == kAXFocusedWindowAttribute && rootSetterWritable)
    return .success
}
func AXUIElementPerformAction(_ element: FakeAX, _ action: CFString) -> AXError { logs.append("raise_\(element.pid)"); return .success }
func axBounds(_ element: FakeAX) -> CGRect? { element.frame }
func windows(_ root: FakeAX) -> [FakeAX] { root.children }
func axElement(_ root: FakeAX, _ field: String) -> FakeAX? { field == kAXFocusedWindowAttribute ? root.focused : nil }
func axBool(_ root: FakeAX, _ field: String) -> Bool? { field == kAXFrontmostAttribute ? frontPID == root.pid : nil }
func axString(_ element: FakeAX, _ field: String) -> String? { field == kAXTitleAttribute ? element.title : nil }
func axResult(_ result: AXError) -> [String: Any] { ["code": result.rawValue] }
func foregroundMetadata() -> (pid: Int32?, source: String) { (frontPID, "fixture") }
func inputClaimTimestamp() -> CGEventTimestamp { 500 }
@discardableResult func CFRunLoopRunInMode(_ mode: Int, _ seconds: Double, _ stopped: Bool) -> Int { clock += 0.2; logs.append("pump"); return 0 }
extension Int { static let defaultMode = 0 }
struct Target {
    let bundleID: String
    let application: NSRunningApplication
    let axApplication: FakeAX
    let window: FakeAX
    let expectedTitle: String?
    let displaySignature: String
    var pid: Int32 { application.processIdentifier }
}
struct OwnedFeishuMainReturn {}
struct OwnedFeishuSearchOpen {}
// PRODUCTION_SUPPORT

struct Quiet { var revision: UInt64 = 1; var idle = true; func quiet(at: Double) -> Bool { idle } }
struct Activity { mutating func reset(at: CGEventTimestamp) {} }
enum ScopeMode { case sharedHID }
class InputMonitor {
    var available = true
    let lock = NSLock()
    var sharedClaimActive = false
    var interruption: String?
    var reason: String? { interruption }
    var externalInteractionRevision: UInt64 = 2
    var focusQuietState = Quiet()
    var armed = false
    var claimEventTimestamp: CGEventTimestamp?
    var focusHandoffPending = false
    var scopedMode = ScopeMode.sharedHID
    var scopedTarget: Int?
    var scopedCache: Int?
    var scopedInterruption: String?
    var sharedActivity = Activity(), scopedActivity = Activity()
    func stop() { available = false; armed = false; logs.append("monitor_stop") }
    // PRODUCTION_MONITOR
}
enum NativeFocusNoticeStage { case preparing, controlling, verifying, yielded }
class Notice { var visible = true; var stage = NativeFocusNoticeStage.controlling; func update(_ next: NativeFocusNoticeStage) { stage = next; logs.append("notice_yield") } }
class Visual { func stop() { logs.append("visual_stop") } }
func visualWarmCaptureRelease() { logs.append("release") }
func visualCaptureDrain(timeout: Double, shuttingDown: Bool = false) -> Bool {
    let result = drains.isEmpty ? true : drains.removeFirst(); logs.append(result ? "drained" : "pending"); return result
}
class ServiceInput { var onShutdown: (() -> Void)? }
var currentHelper: DesktopHelper?
class DesktopHelper {
    let monitor = InputMonitor()
    let visual = Visual()
    var focusNotice: Notice? = Notice()
    var previousFocus: PreviousFocusRecord?
    var currentRuntimeTaskID = "task"
    var runtimeOperationID: String? = "operation"
    var forceWindowMismatch = false
    var claimWasManufactured = false
    func currentDisplays() throws -> (signature: String, other: Int) { (topology, 0) }
    func verifyDisplayTopology(_ target: Target) throws { if topology != target.displaySignature { throw fail("display_topology_changed", "fixture") } }
    func adoptOwnedFeishuMainReturn() -> Bool { false }
    func adoptOwnedFeishuSearchOpen(_ target: Target? = nil) -> Bool { false }
    func taskStillFocused(_ target: Target) -> Bool { frontPID == target.pid && target.axApplication.focused === target.window }
    func currentInspectedDialog(_ target: Target) throws -> Int? { nil }
    func focusScopeChangedDetails(_ target: Target) -> [String: Any] { [:] }
    func waitForFocusHandoff(_ target: Target) throws -> (revision: UInt64, elapsedMS: Double) { (monitor.focusQuietState.revision, 1000) }
    func verify(_ target: Target, foreground: Bool = true, focusedWindow: Bool = true) throws {
        try monitor.check(); try verifyDisplayTopology(target)
        if foreground && frontPID != target.pid { throw fail("foreground_mismatch", "fixture") }
        if focusedWindow && (forceWindowMismatch || target.axApplication.focused !== target.window) { throw fail("window_mismatch", "fixture") }
    }
    func showFocusNotice(_ stage: NativeFocusNoticeStage) throws { focusNotice?.stage = stage }
    func updateFocusNotice(_ stage: NativeFocusNoticeStage) { focusNotice?.stage = stage }
    func finishFocusNotice() { focusNotice?.visible = false; logs.append("close") }
    func closeFocusNotice() { finishFocusNotice() }
    // PRODUCTION_OWNER

    func executeFocus(_ target: Target) throws -> [String: Any] {
        defer { monitor.end() }
        return try focus(target)
    }
    func ordinaryUnconfirmedReturn(_ target: Target) throws -> [String: Any] {
        try capturePreviousFocus(target)
        return try restorePreviousFocus(["app": target.bundleID])
    }
    func finishOperation() throws -> [String: Any] {
        let command = "_finish_operation"
        // PRODUCTION_RELEASE
        return [:]
    }
}
let mainFrame = CGRect(x: 356, y: 25, width: 855, height: 1079)
let otherFrame = CGRect(x: 74, y: 77, width: 1718, height: 1010)
func setup() -> (DesktopHelper, Target, FakeAX, FakeAX) {
    clock = 100; logs = []; frontPID = 900; topology = "screen"; activationHook = nil
    rootSetterWritable = false; rootSetterChangesFocus = true
    let origin = FakeAX(900, CGRect(x: 1, y: 1, width: 600, height: 800), "Origin")
    let originRoot = FakeAX(900, .zero); originRoot.children = [origin]; originRoot.focused = origin
    let main = FakeAX(7, mainFrame, "微信")
    let other = FakeAX(7, otherFrame, "微信 (窗口)")
    let third = FakeAX(7, CGRect(x: 4, y: 4, width: 300, height: 400), "Third")
    let root = FakeAX(7, .zero); root.children = [main, other, third]; root.focused = other
    apps = [900: AppState(bundle: "origin", root: originRoot), 7: AppState(bundle: "com.tencent.xinWeChat", root: root)]
    let helper = DesktopHelper(); currentHelper = helper
    let target = Target(bundleID: "com.tencent.xinWeChat", application: NSRunningApplication(processIdentifier: 7)!,
        axApplication: root, window: main, expectedTitle: "微信", displaySignature: "screen")
    return (helper, target, other, third)
}
var cases: [[String: Any]] = []
func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
func failedFocus(_ helper: DesktopHelper, _ target: Target) -> HelperError? {
    do { _ = try helper.executeFocus(target); return nil } catch let error as HelperError { return error } catch { return fail("unexpected", "") }
}
let (normal, selected, _, _) = setup()
let original = failedFocus(normal, selected)
let returned = original?.details["focus_acquisition_return"] as? [String: Any]
check("real_focus_preserves_window_mismatch", original?.code == "window_mismatch" && original?.details["events_posted"] as? Int == 0)
check("known_other_window_failure_restores_exact_origin", frontPID == 900 && returned?["focus_restored"] as? Bool == true && returned?["window_verified"] as? Bool == true)
check("return_precedes_monitor_end", logs.contains("return_armed_true"))
check("failed_acquisition_never_completes_input_claim", !normal.monitor.sharedClaimActive && normal.previousFocus == nil)
check("one_target_activation_one_origin_return", logs.filter { $0.hasPrefix("activate_") } == ["activate_7", "activate_900"])
let (mainLanding, mainTarget, _, _) = setup()
mainTarget.axApplication.focused = mainTarget.window; mainLanding.forceWindowMismatch = true
let mainFailure = failedFocus(mainLanding, mainTarget)
check("selected_main_is_the_other_known_rollback_landing", mainFailure?.code == "window_mismatch" && frontPID == 900 &&
    (mainFailure?.details["focus_acquisition_return"] as? [String: Any])?["focus_restored"] as? Bool == true)

for mode in ["interaction", "quiet", "keyboard", "monitor", "third", "owner", "frame", "origin", "topology", "scope", "foreign"] {
    let (helper, target, other, third) = setup()
    activationHook = { pid in
        guard pid == 7 else { return }
        switch mode {
        case "interaction": helper.monitor.externalInteractionRevision += 1
        case "quiet": helper.monitor.focusQuietState.revision += 1
        case "keyboard": helper.monitor.interruption = "keyboard_input_during_handoff"
        case "monitor": helper.monitor.available = false
        case "third": target.axApplication.focused = third
        case "owner": other.pid = 8
        case "frame": other.frame.origin.x += 1
        case "origin": apps[900]?.terminated = true
        case "topology": topology = "other"
        case "scope": helper.runtimeOperationID = "different"
        case "foreign": frontPID = 999
        default: break
        }
    }
    let error = failedFocus(helper, target)
    let receipt = error?.details["focus_acquisition_return"] as? [String: Any]
    check("\(mode)_yields_without_origin_activation", error != nil && receipt?["focus_restored"] as? Bool != true && !logs.contains("activate_900") && !helper.monitor.sharedClaimActive)
}
let (before, beforeTarget, _, _) = setup(); before.monitor.focusQuietState.idle = false
check("prepare_denial_leaves_origin_and_never_activates", failedFocus(before, beforeTarget) != nil && frontPID == 900 && !logs.contains("activate_7"))
let (duringReturn, returnTarget, _, _) = setup()
activationHook = { pid in if pid == 900 { duringReturn.monitor.externalInteractionRevision += 1; frontPID = 999 } }
let returnFailure = failedFocus(duringReturn, returnTarget)
let yieldReceipt = returnFailure?.details["focus_acquisition_return"] as? [String: Any]
check("input_during_return_yields_without_raise_or_reclaim", frontPID == 999 && yieldReceipt?["focus_restored"] as? Bool == false &&
    yieldReceipt?["restore_reason"] as? String == "user_takeover" && !logs.contains("raise_900") && logs.filter { $0 == "activate_7" }.count == 1)
let (publicSetter, setterTarget, _, _) = setup(); rootSetterWritable = true
let success = try publicSetter.executeFocus(setterTarget)
check("advertised_root_setter_selects_exact_main", success["foreground_verified"] as? Bool == true && setterTarget.axApplication.focused === setterTarget.window && logs.filter { $0 == "root_focus_set" }.count == 1)
let (falseSuccess, falseTarget, _, _) = setup(); rootSetterWritable = true; rootSetterChangesFocus = false
let falseResult = failedFocus(falseSuccess, falseTarget)
check("setter_acceptance_without_exact_readback_still_fails_and_returns", falseResult?.code == "window_mismatch" && frontPID == 900)
let (ordinary, ordinaryTarget, _, _) = setup()
let denied = try ordinary.ordinaryUnconfirmedReturn(ordinaryTarget)
check("ordinary_unconfirmed_restore_remains_forbidden", denied["restore_reason"] as? String == "focus_claim_unconfirmed" && !logs.contains("activate_900"))

let (releaseHelper, _, _, _) = setup(); drains = [false]
do { _ = try releaseHelper.finishOperation() } catch {}
check("release_pending_keeps_existing_notice", releaseHelper.focusNotice?.visible == true && releaseHelper.focusNotice?.stage == .yielded && !logs.contains("close"))
drains = [true]; _ = try releaseHelper.finishOperation()
check("successful_drain_closes_notice", logs.suffix(2) == ["drained", "close"])
func shutdown() {
    let (helper, _, _, _) = setup()
    let serviceInput = ServiceInput()
    drains = [false, false, true]
    // PRODUCTION_SHUTDOWN
    serviceInput.onShutdown?()
    check("shutdown_callback_does_not_hide_undrained_notice", helper.focusNotice?.visible == true && !logs.contains("close"))
    // PRODUCTION_EOF
    check("EOF_pumps_until_drained_before_close", logs.firstIndex(of: "close")! > logs.lastIndex(of: "pending")! && logs.firstIndex(of: "close")! > logs.lastIndex(of: "drained")! && logs.filter { $0 == "pump" }.count == 2)
}
shutdown()
let absent = DesktopHelper(); absent.focusNotice = nil; absent.prepareFocusNoticeRelease()
check("read_only_shutdown_does_not_create_notice", absent.focusNotice == nil)
let report: [String: Any] = ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "cases": cases, "UI_created": false, "HID_events": 0]
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
if report["ok"] as? Bool != true { exit(1) }
