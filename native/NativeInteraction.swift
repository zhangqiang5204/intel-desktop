import Foundation
import AppKit
import ApplicationServices

// AXSheets is a documented attribute string, absent from some Swift SDK constant exports.
let nativeAXSheetsAttribute = "AXSheets"

// Observed by the existing listen-only event tap even before a focus claim.
// No event is swallowed, replayed, or used to modify the user's current input.
struct NativeFocusQuietState {
    private(set) var revision: UInt64 = 0
    private(set) var lastKeyboard: Double?
    private(set) var lastPointer: Double?
    private var keys = Set<UInt16>()
    private var buttons = Set<CGEventType.RawValue>()
    private var modifiers = false
    private var activity = SustainedInputActivity()

    mutating func observe(type: CGEventType, key: UInt16, flags: CGEventFlags,
                          timestamp: CGEventTimestamp, observed: CGEventTimestamp,
                          point: CGPoint, own: Bool) {
        guard !own else { return }
        guard timestamp > 0, timestamp <= observed,
              observed - timestamp <= UInt64(SustainedInputActivity.maxDeliveryAge * 1e9) else {
            // An unknown/late keyboard event is not proof that the user stopped.
            if [.keyDown, .keyUp, .flagsChanged].contains(type) {
                lastKeyboard = Double(observed) / 1e9; revision &+= 1
                if type == .keyDown { keys.insert(key) }
                if type == .keyUp { keys.remove(key) }
                if type == .flagsChanged { modifiers = !flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty }
            }
            return
        }
        let time = Double(timestamp) / 1e9
        switch type {
        case .keyDown: keys.insert(key); lastKeyboard = time; revision &+= 1
        case .keyUp: keys.remove(key); lastKeyboard = time; revision &+= 1
        case .flagsChanged:
            modifiers = !flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty
            lastKeyboard = time; revision &+= 1
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            buttons.insert(type.rawValue); lastPointer = time; revision &+= 1
        case .leftMouseUp:
            buttons.remove(CGEventType.leftMouseDown.rawValue); lastPointer = time; revision &+= 1
        case .rightMouseUp:
            buttons.remove(CGEventType.rightMouseDown.rawValue); lastPointer = time; revision &+= 1
        case .otherMouseUp:
            buttons.remove(CGEventType.otherMouseDown.rawValue); lastPointer = time; revision &+= 1
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            lastPointer = time; revision &+= 1
        default: break
        }
        if activity.observe(type: type, timestamp: timestamp, observed: observed, location: point, own: own) == "sustained_mouse_movement" {
            lastPointer = time; revision &+= 1
        }
    }
    func quiet(at now: Double) -> Bool {
        now.isFinite && keys.isEmpty && buttons.isEmpty && !modifiers &&
            lastKeyboard.map { now >= $0 && now - $0 >= 0.6 } != false &&
            lastPointer.map { now >= $0 && now - $0 >= 0.6 } != false
    }
    func mayClaim(noticeStarted: Double, now: Double) -> Bool {
        noticeStarted.isFinite && now >= noticeStarted && now - noticeStarted >= 1 &&
            now - noticeStarted <= 2 && quiet(at: now)
    }
}

private final class NativeFocusNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// A transient, nonactivating notice. Creation never brings an editable app
// forward; callers retain and verify the original focus throughout the wait.
final class NativeFocusNotice {
    private let panel: NativeFocusNoticePanel
    init() throws {
        guard Thread.isMainThread, let screen = NSScreen.main else {
            throw fail("handoff_notice_unavailable", "A visible handoff notice requires the main desktop thread")
        }
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        let width: CGFloat = 350, height: CGFloat = 64
        panel = NativeFocusNoticePanel(contentRect: NSRect(x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.maxY - height - 18, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97)
        panel.isOpaque = false; panel.hasShadow = true
        let label = NSTextField(labelWithString: "Codex 即将接管，请暂停输入\n您停手后才会切换应用；继续输入则保持原焦点。")
        label.frame = NSRect(x: 16, y: 10, width: width - 32, height: 44)
        label.font = NSFont.systemFont(ofSize: 13); label.alignment = .center
        label.maximumNumberOfLines = 2; label.isSelectable = false
        panel.contentView?.addSubview(label)
        panel.orderFrontRegardless(); panel.displayIfNeeded()
        guard panel.isVisible else { panel.close(); throw fail("handoff_notice_unavailable", "The nonactivating handoff notice was not displayed") }
    }
    func close() { panel.orderOut(nil); panel.close() }
}

func nativeDialogRole(_ role: String?, subrole: String?, modal: Bool?) -> Bool {
    role == kAXSheetRole || (role == kAXWindowRole &&
        (["AXDialog", "AXSystemDialog"].contains(subrole ?? "") || modal == true))
}

// Public AX identity edges only. A process name, title, matching rectangle or
// another window in the same process can never establish this relationship.
func nativeIdentityAncestor<T>(_ element: T, root: T, equal: (T, T) -> Bool, parent: (T) -> T?) -> Bool {
    var cursor: T? = element
    var seen: [T] = []
    for _ in 0..<32 {
        guard let item = cursor, !seen.contains(where: { equal($0, item) }) else { return false }
        if equal(item, root) { return true }
        seen.append(item); cursor = parent(item)
    }
    return false
}
func nativeAXDescendant(_ element: AXUIElement, of root: AXUIElement) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + 0.35
    return nativeIdentityAncestor(element, root: root, equal: { CFEqual($0, $1) }, parent: { item in
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        AXUIElementSetMessagingTimeout(item, 0.08)
        return axElement(item, kAXParentAttribute)
    })
}

func nativeDialogAttached(_ dialog: AXUIElement, to owner: AXUIElement, applicationRoot: AXUIElement, ownerPID: pid_t) -> Bool {
    var actualOwner: pid_t = 0
    guard AXUIElementGetPid(applicationRoot, &actualOwner) == .success, actualOwner == ownerPID,
          axElements(applicationRoot, kAXWindowsAttribute, limit: 128).contains(where: { CFEqual($0, owner) }),
          nativeDialogRole(axString(dialog, kAXRoleAttribute), subrole: axString(dialog, kAXSubroleAttribute),
                           modal: axBool(dialog, kAXModalAttribute)) else { return false }
    if CFEqual(dialog, owner) { return true }
    if nativeAXDescendant(dialog, of: owner) { return true }
    var count: CFIndex = 0
    guard AXUIElementGetAttributeValueCount(owner, nativeAXSheetsAttribute as CFString, &count) == .success,
          (1...16).contains(count) else { return false }
    return axElements(owner, nativeAXSheetsAttribute, limit: 16).contains { CFEqual($0, dialog) }
}

func nativeElementInDialog(_ element: AXUIElement, dialog: AXUIElement) -> Bool {
    if CFEqual(element, dialog) { return true }
    AXUIElementSetMessagingTimeout(element, 0.12)
    return axElement(element, kAXWindowAttribute).map { CFEqual($0, dialog) } == true ||
        axElement(element, kAXTopLevelUIElementAttribute).map { CFEqual($0, dialog) } == true ||
        nativeAXDescendant(element, of: dialog)
}

struct NativeInspectedDialog {
    let runtimeTaskID: String
    let bundleID: String
    let ownerPID: pid_t
    let ownerWindow: AXUIElement
    let dialog: AXUIElement
    let frame: CGRect
}


func nativeInteractionSelfTests() -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
    func ns(_ time: Double) -> UInt64 { UInt64((time * 1e9).rounded()) }
    var quiet = NativeFocusQuietState()
    func event(_ type: CGEventType, _ time: Double, key: UInt16 = 0, flags: CGEventFlags = [],
               own: Bool = false, observed: Double? = nil, point: CGPoint = .zero) {
        quiet.observe(type: type, key: key, flags: flags, timestamp: ns(time), observed: ns(observed ?? time), point: point, own: own)
    }
    check("notice_keeps_original_focus_for_at_least_one_second", !quiet.mayClaim(noticeStarted: 10, now: 10.99))
    check("quiet_one_second_boundary_can_claim", quiet.mayClaim(noticeStarted: 10, now: 11))
    check("notice_never_authorizes_after_bounded_deadline", !quiet.mayClaim(noticeStarted: 10, now: 12.01))
    event(.keyDown, 10.8); event(.keyUp, 10.9)
    check("recent_typing_delays_activation", !quiet.mayClaim(noticeStarted: 10, now: 11))
    check("stopped_typing_can_claim_within_two_seconds", quiet.mayClaim(noticeStarted: 10, now: 11.51))
    quiet = NativeFocusQuietState()
    for time in [10.1, 10.4, 10.7, 11, 11.3, 11.6, 11.9] { event(.keyDown, time); event(.keyUp, time + 0.02) }
    check("continuous_typing_never_yields_focus_at_deadline", !quiet.mayClaim(noticeStarted: 10, now: 12))
    quiet = NativeFocusQuietState(); event(.keyDown, 10.1)
    check("held_key_is_not_keyboard_idle", !quiet.quiet(at: 11.9))
    event(.keyUp, 11.1)
    check("released_key_requires_fresh_quiet_interval", !quiet.quiet(at: 11.6) && quiet.quiet(at: 11.71))
    quiet = NativeFocusQuietState(); event(.flagsChanged, 10.1, flags: .maskCommand)
    check("held_command_modifier_blocks_activation", !quiet.quiet(at: 11.9))
    event(.flagsChanged, 11.1)
    check("released_modifier_can_settle", quiet.quiet(at: 11.71))
    quiet = NativeFocusQuietState(); event(.keyDown, 10.9, own: true)
    check("own_tagged_events_do_not_extend_handoff", quiet.mayClaim(noticeStarted: 10, now: 11) && quiet.revision == 0)
    event(.keyDown, 0, observed: 10.9)
    check("unknown_keyboard_timestamp_is_not_idle_proof", !quiet.mayClaim(noticeStarted: 10, now: 11))
    quiet = NativeFocusQuietState(); event(.mouseMoved, 10.9, point: CGPoint(x: 100, y: 100))
    check("isolated_mouse_move_does_not_block_handoff", quiet.mayClaim(noticeStarted: 10, now: 11))
    quiet = NativeFocusQuietState()
    for index in 0...8 { event(.mouseMoved, 10 + Double(index) * 0.1, point: CGPoint(x: Double(index * 10), y: 0)) }
    check("sustained_mouse_use_retains_original_focus", !quiet.mayClaim(noticeStarted: 10, now: 11))
    quiet = NativeFocusQuietState(); event(.leftMouseDown, 10.1)
    check("held_mouse_button_blocks_handoff", !quiet.quiet(at: 11.9))
    event(.leftMouseUp, 11)
    check("released_mouse_button_can_settle", quiet.quiet(at: 11.61))
    let originalRevision = quiet.revision; event(.keyDown, 11.7)
    check("input_after_notice_changes_atomic_claim_revision", quiet.revision != originalRevision)
    check("same_app_sheet_role_recognized", nativeDialogRole("AXSheet", subrole: nil, modal: nil))
    check("AppKit_dialog_subrole_recognized", nativeDialogRole("AXWindow", subrole: "AXDialog", modal: nil))
    check("AppKit_modal_window_recognized", nativeDialogRole("AXWindow", subrole: nil, modal: true))
    check("ordinary_same_PID_window_not_dialog", !nativeDialogRole("AXWindow", subrole: "AXStandardWindow", modal: false))
    check("group_named_dialog_not_dialog", !nativeDialogRole("AXGroup", subrole: "AXDialog", modal: true))
    func linked(_ item: Int, root: Int, parents: [Int: Int]) -> Bool {
        nativeIdentityAncestor(item, root: root, equal: ==, parent: { parents[$0] })
    }
    check("exact_child_parent_dialog_identity", linked(4, root: 1, parents: [4: 3, 3: 2, 2: 1]))
    check("same_name_or_PID_without_identity_edge_rejected", !linked(4, root: 1, parents: [4: 3, 3: 9]))
    check("closed_detached_dialog_rejected", !linked(4, root: 1, parents: [4: 3]))
    check("cyclic_AX_ancestry_is_bounded_and_rejected", !linked(4, root: 1, parents: [4: 3, 3: 4]))
    let deep = Dictionary(uniqueKeysWithValues: (1...40).map { ($0, $0 + 1) })
    check("ancestry_depth_limit_is_fail_closed", !linked(1, root: 41, parents: deep))
    check("exact_dialog_root_identity_is_allowed", linked(1, root: 1, parents: [:]))
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count, "cases": cases,
        "events_posted": 0, "event_tap_created": false, "UI_created": false, "AX_reads_executed": false]
}
