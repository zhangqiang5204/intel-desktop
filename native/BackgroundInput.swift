import Foundation
import AppKit
import ApplicationServices
import Darwin

// Public AX focus evidence and scoped takeover policy. Sampling is explicitly
// bounded to the lifetime of a background command; event-tap callbacks never
// perform AX reads. No global event posting or activation is used by this module.

enum ScopedInputMode { case sharedHID, targetedBackground, readOnly }
enum ScopedInputDecision: Equatable { case allow, interrupt(String), invalidateRead(String) }
enum ScopedInputKind { case keyDown, keyUp, modifiers, pointerButton, pointerDrag, pointerMove, scroll, monitorDisabled, unknown }

struct ScopedInputEvent {
    let kind: ScopedInputKind
    let observedAt: Double       // ProcessInfo.systemUptime at callback entry.
    var ownMarker = false
    var keyCode: UInt16? = nil
    var targetPID: pid_t = 0     // Optional corroboration, never the sole proof.
    var pointer: CGPoint? = nil // Deliberately ignored for every keyboard event.
    var sustainedMovement = false
    var sustainedKeyboard = false
}

struct ScopedDisplay {
    let id: CGDirectDisplayID
    let bounds: CGRect
}

struct ScopedDisplayLayout {
    let displays: [ScopedDisplay]
    // Supplied by the existing active-display owner, including scale/rotation.
    let signature: String
    func screens(for rect: CGRect, requireFullCoverage: Bool = true) -> Set<CGDirectDisplayID>? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        var remaining = [rect]
        var matched = Set<CGDirectDisplayID>()
        for display in displays {
            let overlap = rect.intersection(display.bounds)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            matched.insert(display.id)
            remaining = remaining.flatMap { region -> [CGRect] in
                let cut = region.intersection(display.bounds)
                guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [region] }
                return [CGRect(x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
                        CGRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY),
                        CGRect(x: region.minX, y: cut.minY, width: cut.minX - region.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: region.maxX - cut.maxX, height: cut.height)]
                    .filter { $0.width > 0 && $0.height > 0 }
            }
        }
        guard !matched.isEmpty, !requireFullCoverage || remaining.reduce(0, { $0 + $1.width * $1.height }) < 0.000001 else { return nil }
        return matched
    }
    func screens(at point: CGPoint) -> Set<CGDirectDisplayID> {
        Set(displays.filter { point.x >= $0.bounds.minX && point.x < $0.bounds.maxX &&
            point.y >= $0.bounds.minY && point.y < $0.bounds.maxY }.map { $0.id })
    }
}

struct ScopedWindowFocus: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let screenIDs: Set<CGDirectDisplayID>
}

struct ScopedBackgroundTarget: Equatable {
    let window: ScopedWindowFocus
    let processLaunchTime: Double
    let controlID: UUID          // Local binding identity, never a caller wire field.
    let topologySignature: String
}

struct ScopedTargetEvidence {
    let target: ScopedBackgroundTarget
    let internalFocusedWindowID: CGWindowID
    let focusedControlID: UUID
    let controlPID: pid_t
    let controlWindowID: CGWindowID
    let controlRole: String
    let enabled: Bool? // nil means AXEnabled is unsupported, never implicitly true.
    let protected: Bool
    var textEditWritableValue = false
    // Chat adapters bind their own semantic/visual editor evidence. The initial
    // PID/window-directed focus notification necessarily precedes editor focus.
    var chatAdapter = false
}

struct ScopedInputContext {
    let startedAt: Double
    let completedAt: Double
    let target: ScopedTargetEvidence
    let userFocus: ScopedWindowFocus?
    let layout: ScopedDisplayLayout
    // Public CG ordering is sampled outside the event tap. It is used only to
    // identify a pointer's actual window, never to assign keyboard ownership.
    var pointerWindows: [ScopedPointerWindow] = []
    var userControlToken: UUID? = nil
    var userControlVerifiedAbsent = false
    var userFocusSource = "system_AX_and_NSWorkspace_CG"
}

struct ScopedPointerWindow: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    var requiresAXHitTest = false
}

struct ScopedPointerHit {
    let point: CGPoint
    let occludingWindowID: CGWindowID
    let window: ScopedPointerWindow
}

// Pointer contention and keyboard ownership are independent observations. A
// fresh public CG window stack can identify a foreign scroll while AX is busy;
// this proof never authorizes a keyboard or synthesized input event.
struct ScopedPointerContext {
    let startedAt: Double
    let completedAt: Double
    let target: ScopedBackgroundTarget
    let layout: ScopedDisplayLayout
    let windows: [ScopedPointerWindow]
    var hitTest: ScopedPointerHit? = nil
}

enum ScopedInputPolicy {
    static let maxContextAge: Double = 0.25

    static func contextFailure(_ context: ScopedInputContext?, target: ScopedBackgroundTarget,
                               at now: Double, requireEditable: Bool = true) -> String? {
        guard let context else { return "input_focus_unknown" }
        guard now.isFinite, context.startedAt.isFinite, context.completedAt.isFinite,
              context.startedAt <= context.completedAt, context.completedAt <= now,
              now - context.startedAt <= maxContextAge else { return "input_focus_stale" }
        guard context.layout.signature == target.topologySignature,
              context.target.target == target else { return "input_target_changed" }
        let evidence = context.target
        guard !evidence.protected else { return "secure_field_denied" }
        if requireEditable && !evidence.chatAdapter { guard evidence.internalFocusedWindowID == target.window.windowID,
              evidence.focusedControlID == target.controlID, evidence.controlPID == target.window.pid,
              evidence.controlWindowID == target.window.windowID,
              ["AXTextArea", "AXTextField", "AXComboBox"].contains(evidence.controlRole),
              (evidence.enabled == true || (evidence.enabled == nil && evidence.textEditWritableValue)),
              !evidence.protected else { return "background_internal_focus_unverified" } }
        guard let actualTargetScreens = context.layout.screens(for: target.window.frame, requireFullCoverage: requireEditable),
              actualTargetScreens == target.window.screenIDs, !actualTargetScreens.isEmpty else { return "input_target_changed" }
        // Reading target-owned pixels does not consume or claim the user's focus.
        if !requireEditable { return nil }
        guard let user = context.userFocus, user.pid > 0, user.windowID != 0,
              let actualUserScreens = context.layout.screens(for: user.frame, requireFullCoverage: false),
              actualUserScreens == user.screenIDs, !actualUserScreens.isEmpty else { return "input_focus_unknown" }
        guard user.pid != target.window.pid else { return "target_application_has_user_focus" }
        // postToPid addresses an application, not a display. A separately
        // verified foreign focused app/window may share the same screen.
        return nil
    }

    static func decide(mode: ScopedInputMode, event: ScopedInputEvent,
                       target: ScopedBackgroundTarget?, context: ScopedInputContext?,
                       pointerContext: ScopedPointerContext? = nil) -> ScopedInputDecision {
        if event.ownMarker { return .allow }
        // Read-only operations validate their target/coverage on the read path;
        // unrelated human events and global focus never grant or revoke pixels.
        if mode == .readOnly { return .allow }
        if mode == .sharedHID {
            if event.kind == .monitorDisabled { return .interrupt("input_monitor_disabled") }
            if [.pointerMove, .pointerDrag].contains(event.kind), event.sustainedMovement { return .interrupt("sustained_mouse_movement") }
            if event.kind == .keyDown, event.sustainedKeyboard { return .interrupt("sustained_keyboard_input") }
            return .allow
        }
        func refuse(_ reason: String) -> ScopedInputDecision {
            mode == .readOnly ? .invalidateRead(reason) : .interrupt(reason)
        }
        if event.kind == .monitorDisabled { return refuse("input_monitor_disabled") }
        if event.kind == .pointerMove && !event.sustainedMovement { return .allow }
        guard let target else { return refuse("input_target_unknown") }
        // A PID/window-local edit neither moves nor consumes the shared cursor.
        // Pure motion cannot take keyboard focus, even over the target or an
        // AX-transparent system overlay. A recent complete foreign-focus read
        // classifies this motion only; every post still takes fresh full proof.
        // Keep this bounded to the same two-second read interval as chat proof,
        // without making the 250 ms posting lease any longer.
        if event.kind == .pointerMove, let context, event.observedAt.isFinite,
           event.observedAt >= context.completedAt, event.observedAt - context.startedAt <= 2,
           contextFailure(context, target: target, at: context.completedAt) == nil {
            return .allow
        }
        if event.targetPID == target.window.pid { return refuse("manual_input_targeted_application") }
        switch event.kind {
        case .keyDown, .keyUp, .modifiers:
            // The event itself identifies an explicit foreign delivery owner.
            // This only classifies that external event; actual background
            // posting still requires a new complete scope/focus verification.
            if event.targetPID > 0 { return .allow }
            if let failure = contextFailure(context, target: target, at: event.observedAt) { return refuse(failure) }
            guard context?.userFocus != nil else { return refuse("input_focus_unknown") }
            // A zero CG target PID is common. Real system-wide AX focus is the
            // authority; pointer position must never assign a key to a screen.
            // Both the sampled actual owner and an explicit different event
            // PID are foreign. Switching between foreign apps never grants
            // ownership of the background target.
            return .allow
        case .pointerButton, .pointerDrag, .pointerMove, .scroll:
            guard let point = event.pointer, point.x.isFinite, point.y.isFinite else { return refuse("pointer_location_unknown") }
            guard let proof = pointerContext else { return refuse("pointer_context_unknown") }
            guard event.observedAt.isFinite, proof.startedAt.isFinite, proof.completedAt.isFinite,
                  proof.startedAt <= proof.completedAt, proof.completedAt <= event.observedAt,
                  event.observedAt - proof.startedAt <= maxContextAge else { return refuse("pointer_context_stale") }
            guard proof.target == target, proof.layout.signature == target.topologySignature,
                  proof.layout.screens(for: target.window.frame) == target.window.screenIDs else { return refuse("input_target_changed") }
            let screens = proof.layout.screens(at: point)
            guard !screens.isEmpty else { return refuse("pointer_display_unknown") }
            if var owner = proof.windows.first(where: { $0.frame.contains(point) }) {
                // Dock/Notification Center can advertise a whole-screen CG
                // rectangle even where its input surface is transparent.
                // Only an exact-point public AX hit, corroborated by this
                // same stack, can establish which window receives the input.
                if owner.requiresAXHitTest {
                    guard let hit = proof.hitTest, hit.point == point,
                          hit.occludingWindowID == owner.windowID,
                          hit.window.frame.contains(point), proof.windows.contains(hit.window) else {
                        return refuse("pointer_hit_test_unavailable")
                    }
                    owner = hit.window
                }
                if owner.pid == target.window.pid { return refuse("pointer_on_target_window") }
                guard owner.pid > 0, owner.windowID != 0 else { return refuse("pointer_window_owner_unknown") }
                // mouseMoved is delivered to the foreground app even while the
                // pointer crosses another app's window. Its delivery PID does
                // not override the fresh physical hit for motion contention.
                if event.kind == .pointerMove {
                    guard event.targetPID > 0 else { return refuse("pointer_event_owner_unknown") }
                    return .allow
                }
                // A nonzero event PID and the fresh topmost window under this
                // event's point must independently agree on the foreign owner.
                guard event.targetPID > 0 else { return refuse("pointer_event_owner_unknown") }
                guard event.targetPID == owner.pid else { return refuse("pointer_owner_conflict") }
                return .allow
            }
            if target.window.frame.contains(point) { return refuse("pointer_on_target_window") }
            // A desktop gap has no application hit. Only motion may use its
            // actual delivery owner, established independently by fresh full
            // system/app/window focus evidence. An unknown overlay never
            // reaches this branch, and clicks/drags/scrolls never use it.
            if event.kind == .pointerMove, event.targetPID > 0,
               proof.windows.contains(where: { $0.pid == target.window.pid && $0.windowID == target.window.windowID && $0.frame == target.window.frame }),
               contextFailure(context, target: target, at: event.observedAt) == nil,
               context?.userFocus?.pid == event.targetPID {
                return .allow
            }
            return refuse("pointer_window_owner_unknown")
        case .monitorDisabled, .unknown:
            return refuse("input_owner_unknown")
        }
    }
}

func scopedPointerOwnershipSelfTests() -> [String: Any] {
    var tests: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { tests.append(["name": name, "passed": passed]) }
    let layout = ScopedDisplayLayout(displays: [ScopedDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1792, height: 1120)),
        ScopedDisplay(id: 2, bounds: CGRect(x: 1792, y: 0, width: 1920, height: 1200))], signature: "mixed2x1x")
    let window = ScopedWindowFocus(pid: 60682, windowID: 33789, frame: CGRect(x: 329, y: 41, width: 855, height: 1079), screenIDs: [1])
    let target = ScopedBackgroundTarget(window: window, processLaunchTime: 1, controlID: UUID(), topologySignature: layout.signature)
    let foreign = ScopedPointerWindow(pid: 97986, windowID: 71, frame: CGRect(x: 0, y: 25, width: 1200, height: 1000))
    let targetWindow = ScopedPointerWindow(pid: window.pid, windowID: window.windowID, frame: window.frame)
    let evidence = ScopedTargetEvidence(target: target, internalFocusedWindowID: window.windowID, focusedControlID: target.controlID,
        controlPID: window.pid, controlWindowID: window.windowID, controlRole: "AXWindow", enabled: true, protected: false, chatAdapter: true)
    let staleKeyboard = ScopedInputContext(startedAt: 8, completedAt: 8.1, target: evidence, userFocus: nil, layout: layout)
    func pointer(_ start: Double = 9.95, _ complete: Double = 9.97,
                 windows: [ScopedPointerWindow] = [foreign, targetWindow], signature: String? = nil) -> ScopedPointerContext {
        ScopedPointerContext(startedAt: start, completedAt: complete, target: target,
            layout: ScopedDisplayLayout(displays: layout.displays, signature: signature ?? layout.signature), windows: windows)
    }
    func decision(_ event: ScopedInputEvent, _ proof: ScopedPointerContext? = pointer(), keyboard: ScopedInputContext? = nil,
                  mode: ScopedInputMode = .targetedBackground) -> ScopedInputDecision {
        ScopedInputPolicy.decide(mode: mode, event: event, target: target, context: keyboard, pointerContext: proof)
    }
    let point = CGPoint(x: 474, y: 619)
    for kind in [ScopedInputKind.pointerButton, .pointerDrag, .pointerMove, .scroll] {
        let event = ScopedInputEvent(kind: kind, observedAt: 10, targetPID: 97986, pointer: point, sustainedMovement: true)
        check("foreign_\(kind)_works_without_keyboard_cache", decision(event) == .allow)
        check("foreign_\(kind)_works_with_stale_keyboard_cache", decision(event, keyboard: staleKeyboard) == .allow)
    }
    var scroll = ScopedInputEvent(kind: .scroll, observedAt: 10, targetPID: 97986, pointer: point)
    check("fresh_foreign_overlay_is_actual_pointer_owner", decision(scroll) == .allow)
    check("event_pid_alone_is_never_proof", decision(scroll, nil) == .interrupt("pointer_context_unknown"))
    check("missing_pointer_sample_cannot_fall_back_to_keyboard_cache", decision(scroll, nil, keyboard: staleKeyboard) == .interrupt("pointer_context_unknown"))
    check("stale_pointer_proof_denied", decision(scroll, pointer(9, 9.1)) == .interrupt("pointer_context_stale"))
    check("future_pointer_proof_denied", decision(scroll, pointer(10.01, 10.02)) == .interrupt("pointer_context_stale"))
    check("reversed_pointer_times_denied", decision(scroll, pointer(9.99, 9.97)) == .interrupt("pointer_context_stale"))
    check("hotplug_pointer_proof_denied", decision(scroll, pointer(signature: "other")) == .interrupt("input_target_changed"))
    check("target_on_top_denied_despite_foreign_event_pid", decision(scroll, pointer(windows: [targetWindow, foreign])) == .interrupt("pointer_on_target_window"))
    check("missing_pointer_window_denied", decision(scroll, pointer(windows: [])) == .interrupt("pointer_on_target_window"))
    check("unknown_owner_overlay_denied", decision(scroll, pointer(windows: [ScopedPointerWindow(pid: 0, windowID: 5, frame: foreign.frame)])) == .interrupt("pointer_window_owner_unknown"))
    check("shared_HID_isolated_scroll_does_not_yield", decision(scroll, mode: .sharedHID) == .allow)
    scroll.targetPID = 0
    check("zero_event_pid_never_assumed_foreign", decision(scroll) == .interrupt("pointer_event_owner_unknown"))
    scroll.targetPID = 123
    check("event_and_hit_window_conflict_denied", decision(scroll) == .interrupt("pointer_owner_conflict"))
    scroll.targetPID = window.pid
    check("explicit_target_event_always_denied", decision(scroll) == .interrupt("manual_input_targeted_application"))
    scroll.targetPID = 97986; scroll.pointer = CGPoint(x: 1700, y: 1100)
    check("outside_target_is_not_foreign_ownership_proof", decision(scroll) == .interrupt("pointer_window_owner_unknown"))
    let userWindow = ScopedWindowFocus(pid: 98363, windowID: 72,
        frame: CGRect(x: 1857, y: 161, width: 855, height: 1079), screenIDs: [2])
    let freshKeyboard = ScopedInputContext(startedAt: 9.95, completedAt: 9.97, target: evidence, userFocus: userWindow, layout: layout)
    var move = ScopedInputEvent(kind: .pointerMove, observedAt: 10, targetPID: 98363, pointer: point, sustainedMovement: true)
    check("motion_foreground_delivery_pid_does_not_override_foreign_hit", decision(move) == .allow)
    check("motion_foreign_hit_independent_of_stale_keyboard", decision(move, keyboard: staleKeyboard) == .allow)
    check("motion_over_target_still_stops_foreign_delivery", decision(move, pointer(windows: [targetWindow])) == .interrupt("pointer_on_target_window"))
    move.pointer = CGPoint(x: 2748, y: 1169)
    check("desktop_motion_fresh_actual_delivery_owner_allowed", decision(move, keyboard: freshKeyboard) == .allow)
    check("desktop_motion_unknown_focus_denied", decision(move) == .interrupt("pointer_window_owner_unknown"))
    check("desktop_motion_stale_focus_denied", decision(move, keyboard: staleKeyboard) == .interrupt("pointer_window_owner_unknown"))
    check("pure_motion_complete_foreign_focus_independent_of_pointer_stack", decision(move, pointer(windows: []), keyboard: freshKeyboard) == .allow)
    let unknown = ScopedPointerWindow(pid: 0, windowID: 99, frame: CGRect(x: 2700, y: 1100, width: 200, height: 100))
    check("pure_motion_over_unknown_overlay_does_not_claim_its_input", decision(move, pointer(windows: [unknown, targetWindow]), keyboard: freshKeyboard) == .allow)
    move.targetPID = 97986
    check("pure_motion_route_does_not_override_actual_foreign_focus", decision(move, keyboard: freshKeyboard) == .allow)
    move.targetPID = 0
    check("pure_motion_zero_delivery_owner_with_complete_foreign_focus", decision(move, keyboard: freshKeyboard) == .allow)
    var hover = ScopedInputEvent(kind: .pointerMove, observedAt: 10, targetPID: target.window.pid, pointer: point, sustainedMovement: true)
    check("pure_hover_target_delivery_does_not_claim_keyboard_focus", decision(hover, nil, keyboard: freshKeyboard) == .allow)
    hover = ScopedInputEvent(kind: .pointerMove, observedAt: 10.3, targetPID: target.window.pid, pointer: point, sustainedMovement: true)
    check("pure_motion_late_sample_is_not_input_authorization", decision(hover, nil, keyboard: freshKeyboard) == .allow && ScopedInputPolicy.contextFailure(freshKeyboard, target: target, at: hover.observedAt) == "input_focus_stale")
    hover = ScopedInputEvent(kind: .pointerMove, observedAt: 12.1, targetPID: target.window.pid, pointer: point, sustainedMovement: true)
    check("pure_motion_last_good_foreign_focus_is_bounded", decision(hover, nil, keyboard: freshKeyboard) == .interrupt("manual_input_targeted_application"))
    for kind in [ScopedInputKind.pointerButton, .pointerDrag, .scroll, .keyDown, .keyUp, .modifiers] {
        let contention = ScopedInputEvent(kind: kind, observedAt: 10, targetPID: target.window.pid, pointer: point, sustainedMovement: true)
        check("target_\(kind)_never_uses_pure_motion_exception", decision(contention, nil, keyboard: freshKeyboard) == .interrupt("manual_input_targeted_application"))
    }
    for kind in [ScopedInputKind.pointerButton, .pointerDrag, .scroll] {
        let gapEvent = ScopedInputEvent(kind: kind, observedAt: 10, targetPID: 98363, pointer: move.pointer, sustainedMovement: true)
        check("desktop_\(kind)_never_uses_foreground_motion_exception", decision(gapEvent, keyboard: freshKeyboard) == .interrupt("pointer_window_owner_unknown"))
        let conflict = ScopedInputEvent(kind: kind, observedAt: 10, targetPID: 98363, pointer: point, sustainedMovement: true)
        check("foreign_\(kind)_still_requires_matching_hit_pid", decision(conflict, keyboard: freshKeyboard) == .interrupt("pointer_owner_conflict"))
    }
    let key = ScopedInputEvent(kind: .keyDown, observedAt: 10, targetPID: 0, pointer: point)
    check("pointer_proof_cannot_authorize_unknown_keyboard_owner", decision(key) == .interrupt("input_focus_unknown"))
    check("pointer_proof_cannot_authorize_stale_keyboard_owner", decision(key, keyboard: staleKeyboard) == .interrupt("input_focus_stale"))
    check("posting_guard_still_requires_keyboard_evidence", ScopedInputPolicy.contextFailure(nil, target: target, at: 10) == "input_focus_unknown")
    check("posting_guard_still_rejects_stale_keyboard_evidence", ScopedInputPolicy.contextFailure(staleKeyboard, target: target, at: 10) == "input_focus_stale")
    for kind in [ScopedInputKind.keyDown, .keyUp, .modifiers] {
        let foreignKey = ScopedInputEvent(kind: kind, observedAt: 10, targetPID: 98363)
        check("explicit_foreign_\(kind)_delivery_does_not_need_keyboard_cache", decision(foreignKey) == .allow)
        check("explicit_foreign_\(kind)_delivery_survives_stale_cache", decision(foreignKey, keyboard: staleKeyboard) == .allow)
        let targetedKey = ScopedInputEvent(kind: kind, observedAt: 10, targetPID: window.pid)
        check("explicit_target_\(kind)_still_interrupts", decision(targetedKey, keyboard: freshKeyboard) == .interrupt("manual_input_targeted_application"))
    }
    let dock = ScopedPointerWindow(pid: 766, windowID: 23,
        frame: CGRect(x: 0, y: 0, width: 1792, height: 1120), requiresAXHitTest: true)
    func dockProof(_ hit: ScopedPointerWindow?, hitPoint: CGPoint = point, overlayID: CGWindowID = 23) -> ScopedPointerContext {
        var proof = pointer(windows: [dock, foreign, targetWindow])
        if let hit { proof.hitTest = ScopedPointerHit(point: hitPoint, occludingWindowID: overlayID, window: hit) }
        return proof
    }
    let dockScroll = ScopedInputEvent(kind: .scroll, observedAt: 10, targetPID: foreign.pid, pointer: point)
    check("transparent_Dock_AX_hit_resolves_foreign_window", decision(dockScroll, dockProof(foreign)) == .allow)
    check("Dock_rectangle_alone_never_claims_hit", decision(dockScroll, dockProof(nil)) == .interrupt("pointer_hit_test_unavailable"))
    check("Dock_AX_hit_must_be_same_exact_point", decision(dockScroll, dockProof(foreign, hitPoint: CGPoint(x: 475, y: 619))) == .interrupt("pointer_hit_test_unavailable"))
    check("Dock_AX_hit_must_bind_same_overlay", decision(dockScroll, dockProof(foreign, overlayID: 24)) == .interrupt("pointer_hit_test_unavailable"))
    check("Dock_true_hit_not_treated_transparent", decision(dockScroll, dockProof(dock)) == .interrupt("pointer_owner_conflict"))
    check("Dock_AX_target_hit_interrupts", decision(dockScroll, dockProof(targetWindow)) == .interrupt("pointer_on_target_window"))
    let invented = ScopedPointerWindow(pid: 555, windowID: 888, frame: foreign.frame)
    check("Dock_AX_hit_without_stack_witness_denied", decision(dockScroll, dockProof(invented)) == .interrupt("pointer_hit_test_unavailable"))
    let notificationCenter = ScopedPointerWindow(pid: 864, windowID: 46, frame: dock.frame, requiresAXHitTest: true)
    var notificationProof = pointer(windows: [notificationCenter, foreign, targetWindow])
    check("NotificationCenter_rectangle_alone_not_input_hit", decision(dockScroll, notificationProof) == .interrupt("pointer_hit_test_unavailable"))
    notificationProof.hitTest = ScopedPointerHit(point: point, occludingWindowID: 46, window: foreign)
    check("NotificationCenter_transparent_area_public_AX_hit_allowed", decision(dockScroll, notificationProof) == .allow)
    notificationProof.hitTest = ScopedPointerHit(point: point, occludingWindowID: 46, window: notificationCenter)
    check("NotificationCenter_real_panel_hit_not_skipped", decision(dockScroll, notificationProof) == .interrupt("pointer_owner_conflict"))
    notificationProof.hitTest = ScopedPointerHit(point: point, occludingWindowID: 46, window: targetWindow)
    check("NotificationCenter_AX_target_hit_interrupts", decision(dockScroll, notificationProof) == .interrupt("pointer_on_target_window"))
    let cache = ScopedInputContextCache(), ticket = UInt64(0)
    check("pointer_cache_publishes_current_generation", cache.publishPointer(pointer(), ticket: ticket) && cache.currentPointer() != nil)
    cache.publish(nil, ticket: ticket)
    check("failed_keyboard_sample_keeps_independent_pointer_proof", cache.current() == nil && cache.currentPointer() != nil)
    check("older_pointer_sample_cannot_replace_newer", !cache.publishPointer(pointer(9.5, 9.6), ticket: ticket) && cache.currentPointer()?.completedAt == 9.97)
    cache.invalidate()
    check("command_end_discards_both_proofs", cache.current() == nil && cache.currentPointer() == nil)
    check("late_pointer_sample_cannot_revive_ended_command", !cache.publishPointer(pointer(), ticket: ticket) && cache.currentPointer() == nil)
    var attempts = 0, settles = 0
    do {
        let observed: Int = try scopedCompleteFocusRead({
            attempts += 1
            if attempts == 1 { throw ScopedContextError.unavailable("system_AX_AXFocusedApplication_-25204") }
            return attempts
        }, settle: { settles += 1 })
        check("transient_system_AX_recollects_once_and_returns_only_new_result", observed == 2 && attempts == 2 && settles == 1)
    } catch { check("transient_system_AX_recollects_once_and_returns_only_new_result", false) }
    for reason in ["system_AX_AXFocusedApplication_-25204", "system_AX_AXFocusedUIElement_-25204", "focus_collection_timeout", "secure_field_denied", "system_and_actual_foreground_conflict"] {
        attempts = 0; settles = 0
        do {
            let _: Int = try scopedCompleteFocusRead({ attempts += 1; throw ScopedContextError.unavailable(reason) }, settle: { settles += 1 })
            check("focus_retry_bounded_" + reason, false)
        } catch {
            let retry = reason.hasSuffix("_-25204")
            check("focus_retry_bounded_" + reason, attempts == (retry ? 2 : 1) && settles == (retry ? 1 : 0))
        }
    }
    return ["ok": tests.allSatisfy { $0["passed"] as? Bool == true }, "count": tests.count, "tests": tests,
        "events_posted": 0, "live_AX_reads": 0, "live_CG_reads": 0]
}

// Event-tap callbacks may only take this short lock and run the pure policy.
// They must not call the AX reader. Failed/obsolete refreshes clear the proof.
final class ScopedInputContextCache {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var value: ScopedInputContext?
    private var pointerValue: ScopedPointerContext?
    private var inFlight = false
    private var pointerInFlight = false
    private let worker = DispatchQueue(label: "IntelDesktopHelper.FocusContext")
    private let pointerWorker = DispatchQueue(label: "IntelDesktopHelper.PointerContext")
    func ticket() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func current() -> ScopedInputContext? { lock.lock(); defer { lock.unlock() }; return value }
    func currentPointer() -> ScopedPointerContext? { lock.lock(); defer { lock.unlock() }; return pointerValue }
    func invalidate() {
        lock.lock(); generation &+= 1; value = nil; pointerValue = nil; lock.unlock()
    }
    @discardableResult func publish(_ context: ScopedInputContext?, ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == ticket else { return false }
        if let context, let existing = value, context.completedAt < existing.completedAt { return false }
        value = context; return true
    }
    @discardableResult func publishPointer(_ context: ScopedPointerContext?, ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == ticket else { return false }
        if let context, let existing = pointerValue, context.completedAt < existing.completedAt { return false }
        pointerValue = context; return true
    }
    func requestPointerRefresh(_ reader: @escaping () throws -> ScopedPointerContext) {
        lock.lock()
        guard !pointerInFlight else { lock.unlock(); return }
        pointerInFlight = true; let ticket = generation
        lock.unlock()
        pointerWorker.async { [self] in
            let refreshed = try? reader()
            lock.lock()
            if generation == ticket {
                if let refreshed, let existing = pointerValue, refreshed.completedAt < existing.completedAt { /* Superseded sample. */ }
                else { pointerValue = refreshed }
            }
            pointerInFlight = false
            lock.unlock()
        }
    }
    // Bounded to one in-flight read; no periodic polling or unbounded job queue.
    // Integration calls this outside the event tap (e.g. before an operation or
    // after a public focus notification), then requires a fresh current proof.
    func requestRefresh(_ reader: @escaping () throws -> ScopedInputContext) {
        lock.lock()
        guard !inFlight else { lock.unlock(); return }
        inFlight = true; let ticket = generation
        lock.unlock()
        worker.async { [self] in
            let refreshed = try? reader()
            lock.lock()
            if generation == ticket {
                if let refreshed, let existing = value, refreshed.completedAt < existing.completedAt { /* Obsolete async sample. */ }
                else { value = refreshed }
            }
            inFlight = false
            lock.unlock()
        }
    }
}

struct PublicBackgroundBinding {
    let target: ScopedBackgroundTarget
    let window: AXUIElement
    let control: AXUIElement?
    var chatAdapter = false
}

enum ScopedContextError: Error { case unavailable(String) }

// A transient system AX transport failure discards the entire partial sample.
// Retry once from new process, target, focus, window and control observations;
// neither its old timestamp nor any partial identity survives the retry.
func scopedCompleteFocusRead<Value>(_ read: () throws -> Value, settle: () -> Void) throws -> Value {
    do { return try read() }
    catch ScopedContextError.unavailable(let reason) where reason.hasPrefix("system_AX_") && reason.hasSuffix("_\(AXError.cannotComplete.rawValue)") {
        settle()
        return try read()
    }
}

func scopedSameControl(_ left: AXUIElement?, _ right: AXUIElement?) -> Bool {
    if let left, let right { return CFEqual(left, right) }
    return left == nil && right == nil
}

func scopedSystemFocusCompatible(systemPID: pid_t?, systemFrontmost: Bool?, actualPID: pid_t) -> Bool {
    guard actualPID > 0 else { return false }
    guard let systemPID else { return true }
    return systemPID == actualPID || systemFrontmost == false
}

// Only the observed TextEdit AXTextArea may substitute positive AXValue
// writability for an unsupported AXEnabled. Missing/error/false are distinct.
func scopedEditability(bundle: String, role: String, enabledResult: AXError, enabled: Bool?,
                       settableResult: AXError, valueSettable: Bool?) throws -> (enabled: Bool?, textEditWritableValue: Bool) {
    let textEditArea = bundle == "com.apple.TextEdit" && role == "AXTextArea"
    if enabledResult == .success {
        guard let enabled else { throw ScopedContextError.unavailable("AXEnabled_invalid_boolean") }
        guard enabled else { throw ScopedContextError.unavailable("editable_control_disabled") }
    } else {
        guard enabledResult == .attributeUnsupported, textEditArea else {
            throw ScopedContextError.unavailable("AX_AXEnabled_\(enabledResult.rawValue)")
        }
    }
    if textEditArea {
        guard settableResult == .success, valueSettable == true else {
            throw ScopedContextError.unavailable("TextEdit_AXValue_not_writable_\(settableResult.rawValue)")
        }
    }
    return (enabledResult == .success ? enabled : nil, enabledResult == .attributeUnsupported && textEditArea)
}


// Missing advertised metadata is absence, not a failed mandatory read. Once an
// attribute is advertised, noValue/attributeUnsupported are genuine absence;
// transport and permission failures remain explicit failures.
func scopedOptionalMetadata<Value>(_ attribute: String, advertised: [String],
                                  read: () throws -> (AXError, Value?)) throws -> Value? {
    guard advertised.contains(attribute) else { return nil }
    let (result, value) = try read()
    if result == .attributeUnsupported || result == .noValue { return nil }
    guard result == .success, let value else {
        throw ScopedContextError.unavailable("AX_\(attribute)_\(result.rawValue)")
    }
    return value
}

func scopedSecureMetadata(role: String, subrole: String?, protected: Bool?) throws {
    guard !role.isEmpty else { throw ScopedContextError.unavailable("AXRole_invalid") }
    guard role != "AXSecureTextField", subrole != "AXSecureTextField", protected != true else {
        throw ScopedContextError.unavailable("secure_field_denied")
    }
}

struct ScopedWindowIDCandidate {
    let id: CGWindowID?
    let title: String?
}

// Candidates have already passed the exact PID, layer and frame checks. Only
// an ambiguous frame needs another AX IPC. Unknown titles cannot disambiguate
// a possibly identical document, and string comparison never normalizes text.
func scopedMatchedWindowID(_ candidates: [ScopedWindowIDCandidate],
                           readAXTitle: () throws -> String?) rethrows -> CGWindowID? {
    if candidates.count == 1 { return candidates[0].id.flatMap { $0 == 0 ? nil : $0 } }
    guard candidates.count > 1,
          candidates.allSatisfy({ $0.title.map { !$0.isEmpty } ?? false }),
          let title = try readAXTitle(), !title.isEmpty else { return nil }
    let matches = candidates.filter { $0.title!.utf16.elementsEqual(title.utf16) }
    guard matches.count == 1, let id = matches[0].id, id != 0 else { return nil }
    return id
}

func scopedWindowIDMatchSelfTests() -> [[String: Any]] {
    var rows: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { rows.append(["name": name, "passed": value]) }
    func c(_ id: CGWindowID?, _ title: String?) -> ScopedWindowIDCandidate { ScopedWindowIDCandidate(id: id, title: title) }
    var titleReads = 0
    let unique = scopedMatchedWindowID([c(42, nil)], readAXTitle: { titleReads += 1; return nil })
    check("unique_frame_no_title_IPC", unique == 42 && titleReads == 0)
    check("no_frame_no_title_IPC", scopedMatchedWindowID([], readAXTitle: { titleReads += 1; return "doc" }) == nil && titleReads == 0)
    check("unique_missing_ID_denied", scopedMatchedWindowID([c(nil, "doc")], readAXTitle: { titleReads += 1; return "doc" }) == nil && titleReads == 0)
    check("unique_zero_ID_denied", scopedMatchedWindowID([c(0, "doc")], readAXTitle: { titleReads += 1; return "doc" }) == nil && titleReads == 0)
    let actual = [c(40832, "OfflineFixture-final.txt"), c(40796, "OfflineFixture.txt")]
    let selected = scopedMatchedWindowID(actual, readAXTitle: { titleReads += 1; return "OfflineFixture.txt" })
    check("actual_second_stacked_document_selected", selected == 40796 && titleReads == 1)
    check("actual_first_stacked_document_selected", scopedMatchedWindowID(actual, readAXTitle: { "OfflineFixture-final.txt" }) == 40832)
    check("stack_order_not_authority", scopedMatchedWindowID(Array(actual.reversed()), readAXTitle: { "OfflineFixture-final.txt" }) == 40832)
    for (name, candidates, title) in [
        ("missing_AX_title", actual, nil as String?), ("empty_AX_title", actual, ""),
        ("missing_one_CG_title", [c(1, "doc"), c(2, nil)], "doc"),
        ("empty_one_CG_title", [c(1, "doc"), c(2, "")], "doc"),
        ("same_titles_ambiguous", [c(1, "doc"), c(2, "doc")], "doc"),
        ("no_title_match", actual, "another document"),
        ("matching_missing_ID", [c(nil, "doc"), c(2, "other")], "doc"),
        ("matching_zero_ID", [c(0, "doc"), c(2, "other")], "doc"),
        ("no_title_trimming", [c(1, "doc "), c(2, "other")], "doc"),
        ("no_case_folding", [c(1, "Doc"), c(2, "other")], "doc"),
        ("no_unicode_normalization", [c(1, "\u{00e9}"), c(2, "other")], "e\u{0301}")
    ] { check(name, scopedMatchedWindowID(candidates, readAXTitle: { title }) == nil) }
    check("exact_unicode_form_selected", scopedMatchedWindowID([c(1, "\u{00e9}"), c(2, "e\u{0301}")], readAXTitle: { "e\u{0301}" }) == 2)
    enum Fixture: Error { case unavailable }
    do {
        _ = try scopedMatchedWindowID(actual, readAXTitle: { throw Fixture.unavailable })
        check("title_read_error_propagates", false)
    } catch { check("title_read_error_propagates", error is Fixture) }
    return rows
}

// Explicit, read-only sampler. Call on the focus worker, never the event tap.
// No AXValue, keystroke text, clipboard, user preferences, or protected content
// is collected. The same app/window/control is checked at both ends of the read.
final class PublicInputContextReader {
    private let duration: Double = 0.20
    private var previousUserControl: AXUIElement?
    private var previousUserControlToken: UUID?
    func capture(_ binding: PublicBackgroundBinding, layout: () throws -> ScopedDisplayLayout) throws -> ScopedInputContext {
        try scopedCompleteFocusRead({ try self.captureOnce(binding, layout: layout) }, settle: {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
        })
    }
    private func captureOnce(_ binding: PublicBackgroundBinding, layout: () throws -> ScopedDisplayLayout) throws -> ScopedInputContext {
        let start = ProcessInfo.processInfo.systemUptime
        func reject(_ reason: String) -> ScopedContextError { .unavailable(reason) }
        func deadline() throws {
            guard ProcessInfo.processInfo.systemUptime - start <= duration else { throw reject("focus_collection_timeout") }
        }
        func value(_ element: AXUIElement, _ name: String, optional: Bool = false) throws -> CFTypeRef? {
            // Background AppKit IPC can exceed 25 ms even for supported bounds.
            // Keep each wait bounded inside the unchanged 200 ms collection
            // deadline; only <=250 ms evidence may authorize a posted event.
            try deadline(); AXUIElementSetMessagingTimeout(element, 0.12)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if optional && [.noValue, .attributeUnsupported].contains(error) { return nil }
            guard error == .success else { throw reject("AX_\(name)_\(error.rawValue)") }
            return value
        }
        func element(_ parent: AXUIElement, _ name: String) throws -> AXUIElement {
            guard let raw = try value(parent, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw reject("AX_element_missing") }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
        func pid(_ element: AXUIElement) throws -> pid_t {
            try deadline(); var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { throw reject("AX_PID_missing") }; return pid
        }
        func bounds(_ element: AXUIElement) throws -> CGRect {
            guard let p = try value(element, kAXPositionAttribute), let s = try value(element, kAXSizeAttribute),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw reject("AX_bounds_missing") }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { throw reject("AX_bounds_invalid") }
            return CGRect(origin: point, size: size)
        }
        func secureAncestry(_ control: AXUIElement, advertisedMetadata: Bool) throws {
            var current = control
            for _ in 0..<64 {
                guard let role = try value(current, kAXRoleAttribute) as? String, !role.isEmpty else { throw reject("AXRole_invalid") }
                try scopedSecureMetadata(role: role, subrole: nil, protected: nil)
                let subrole: String?, protected: Bool?
                if advertisedMetadata {
                    try deadline()
                    var rawNames: CFArray?
                    let namesResult = AXUIElementCopyAttributeNames(current, &rawNames)
                    guard namesResult == .success, let names = rawNames as? [String], names.count <= 512 else {
                        throw reject("AX_attribute_names_\(namesResult.rawValue)")
                    }
                    func optional(_ name: String) throws -> CFTypeRef? {
                        try scopedOptionalMetadata(name, advertised: names) {
                            try deadline()
                            var raw: CFTypeRef?
                            let result = AXUIElementCopyAttributeValue(current, name as CFString, &raw)
                            return (result, raw)
                        }
                    }
                    let rawSubrole = try optional(kAXSubroleAttribute)
                    guard rawSubrole == nil || rawSubrole as? String != nil else { throw reject("AXSubrole_invalid") }
                    subrole = rawSubrole as? String
                    let rawProtected = try optional("AXProtectedContent")
                    guard rawProtected == nil || CFGetTypeID(rawProtected!) == CFBooleanGetTypeID() else { throw reject("AXProtectedContent_invalid") }
                    protected = rawProtected as? Bool
                } else {
                    // Preserve the already verified Qt read path; this correction
                    // is for TextEdit's observed AppKit metadata declaration.
                    subrole = try value(current, kAXSubroleAttribute, optional: true) as? String
                    protected = try value(current, "AXProtectedContent", optional: true) as? Bool
                }
                try scopedSecureMetadata(role: role, subrole: subrole, protected: protected)
                if CFEqual(current, binding.window) { return }
                current = try element(current, kAXParentAttribute)
            }
            throw reject("control_window_ancestry_unverified")
        }
        guard AXIsProcessTrusted(), let application = NSRunningApplication(processIdentifier: binding.target.window.pid),
              !application.isTerminated, application.launchDate?.timeIntervalSince1970 == binding.target.processLaunchTime else { throw reject("target_process_changed") }
        let displays = try layout()
        guard displays.signature == binding.target.topologySignature else { throw reject("display_topology_changed") }
        let root = AXUIElementCreateApplication(binding.target.window.pid)
        var role = ""
        var editability: (enabled: Bool?, textEditWritableValue: Bool) = (nil, false)
        func validateTarget() throws {
            guard try pid(binding.window) == binding.target.window.pid,
                  try bounds(binding.window) == binding.target.window.frame else { throw reject("target_window_changed") }
            guard let control = binding.control else { try secureAncestry(binding.window, advertisedMetadata: application.bundleIdentifier == "com.apple.TextEdit"); return }
            let internalWindow = try element(root, kAXFocusedWindowAttribute)
            let mainWindow = try element(root, kAXMainWindowAttribute)
            let internalControl = try element(root, kAXFocusedUIElementAttribute)
            guard CFEqual(internalWindow, binding.window), CFEqual(mainWindow, binding.window),
                  CFEqual(internalControl, control), try pid(internalControl) == binding.target.window.pid,
                  try value(internalControl, kAXFocusedAttribute) as? Bool == true,
                  CFEqual(try element(internalControl, kAXWindowAttribute), binding.window) else {
                throw reject("background_internal_focus_changed")
            }
            try secureAncestry(internalControl, advertisedMetadata: application.bundleIdentifier == "com.apple.TextEdit")
            role = try value(internalControl, kAXRoleAttribute) as? String ?? ""
            guard ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) else { throw reject("editable_control_unverified") }
            try deadline()
            var rawEnabled: CFTypeRef?
            let enabledResult = AXUIElementCopyAttributeValue(internalControl, kAXEnabledAttribute as CFString, &rawEnabled)
            let enabled: Bool? = rawEnabled.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? ($0 as? Bool) : nil }
            var writable: Bool? = nil, writableResult = AXError.attributeUnsupported
            if application.bundleIdentifier == "com.apple.TextEdit", role == "AXTextArea",
               (enabledResult == .attributeUnsupported || (enabledResult == .success && enabled == true)) {
                try deadline()
                (writable, writableResult) = axSettableResult(internalControl, kAXValueAttribute)
            }
            editability = try scopedEditability(bundle: application.bundleIdentifier ?? "", role: role,
                enabledResult: enabledResult, enabled: enabled, settableResult: writableResult, valueSettable: writable)
        }
        try validateTarget()
        if binding.control == nil && !binding.chatAdapter {
            let id = try scopedWindowID(pid: binding.target.window.pid, frame: binding.target.window.frame)
            guard id == binding.target.window.windowID, try layout().signature == displays.signature else {
                throw reject("readonly_target_changed_during_collection")
            }
            try validateTarget(); try deadline()
            let evidence = ScopedTargetEvidence(target: binding.target, internalFocusedWindowID: 0,
                focusedControlID: binding.target.controlID, controlPID: 0, controlWindowID: 0,
                controlRole: "", enabled: nil, protected: false)
            return ScopedInputContext(startedAt: start, completedAt: ProcessInfo.processInfo.systemUptime,
                target: evidence, userFocus: nil, layout: displays)
        }

        let system = AXUIElementCreateSystemWide()
        func systemElement(_ name: String) throws -> AXUIElement? {
            try deadline(); AXUIElementSetMessagingTimeout(system, 0.12)
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(system, name as CFString, &raw)
            if result == .noValue { return nil }
            guard result == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw reject("system_AX_\(name)_\(result.rawValue)")
            }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
        // The persistent helper must settle workspace activation notifications
        // before retaining its PID; settling only after this read keeps an old
        // application object even when the run loop has learned the new owner.
        _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
        guard let workspaceApp = NSWorkspace.shared.frontmostApplication, !workspaceApp.isTerminated else { throw reject("NSWorkspace_frontmost_unknown") }
        var systemApp = try systemElement(kAXFocusedApplicationAttribute)
        let firstSystemPID = try systemApp.map { try pid($0) }
        if firstSystemPID != workspaceApp.processIdentifier {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            systemApp = try systemElement(kAXFocusedApplicationAttribute)
        }
        func systemCompatible(_ app: AXUIElement?) throws -> Bool {
            guard let app else { return true }
            let appPID = try pid(app)
            let frontmost = appPID == workspaceApp.processIdentifier ? nil : try value(app, kAXFrontmostAttribute) as? Bool
            return scopedSystemFocusCompatible(systemPID: appPID, systemFrontmost: frontmost, actualPID: workspaceApp.processIdentifier)
        }
        guard try systemCompatible(systemApp) else { throw reject("system_and_actual_foreground_conflict") }
        // A stale system AX application whose own AXFrontmost is false is not
        // the keyboard owner. Require the real workspace PID's direct AX app,
        // frontmost flag, unique CG window and exact control at both endpoints.
        let focusedApp = AXUIElementCreateApplication(workspaceApp.processIdentifier)
        let userPID = try pid(focusedApp)
        let userWindow = try element(focusedApp, kAXFocusedWindowAttribute)
        func appControl() throws -> AXUIElement? {
            try deadline()
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(focusedApp, kAXFocusedUIElementAttribute as CFString, &raw)
            if result == .noValue { return nil }
            guard result == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw reject("foreground_control_\(result.rawValue)")
            }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
        let directControl = try appControl()
        var userControl = directControl
        if let systemControl = try systemElement(kAXFocusedUIElementAttribute) {
            let systemControlPID = try pid(systemControl)
            if systemControlPID == userPID {
                guard scopedSameControl(systemControl, directControl) else { throw reject("system_and_direct_control_conflict") }
                userControl = systemControl
            } else {
                guard let systemApp, try pid(systemApp) == systemControlPID,
                      try value(systemApp, kAXFrontmostAttribute) as? Bool == false else {
                    throw reject("system_and_actual_control_conflict")
                }
            }
        }
        guard userPID == workspaceApp.processIdentifier, userPID != binding.target.window.pid,
              try value(focusedApp, kAXFrontmostAttribute) as? Bool == true else { throw reject("foreground_state_unverified") }
        if let userControl {
            guard try pid(userControl) == userPID, let userRole = try value(userControl, kAXRoleAttribute) as? String else {
                throw reject("user_focused_control_secure_or_unknown")
            }
            try scopedSecureMetadata(role: userRole,
                subrole: try value(userControl, kAXSubroleAttribute, optional: true) as? String,
                protected: try value(userControl, "AXProtectedContent", optional: true) as? Bool)
        }
        let userRect = try bounds(userWindow)
        // Keyboard ownership is still real when a user's window extends past
        // a screen edge. Only the target editor requires full pixel coverage.
        guard try pid(userWindow) == userPID, let userScreens = displays.screens(for: userRect, requireFullCoverage: false) else { throw reject("user_focused_window_unknown") }
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        func matchingID(_ pid: pid_t, _ rect: CGRect, window: AXUIElement) throws -> CGWindowID {
            let matching = rows.filter { row in
                guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                      (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let raw = row[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
                return frame == rect
            }
            let candidates = matching.map { row in
                ScopedWindowIDCandidate(id: (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                                        title: row[kCGWindowName as String] as? String)
            }
            guard let id = try scopedMatchedWindowID(candidates, readAXTitle: {
                try value(window, kAXTitleAttribute) as? String
            }) else { throw reject("window_ID_ambiguous") }
            return id
        }
        let targetID = try matchingID(binding.target.window.pid, binding.target.window.frame, window: binding.window)
        let userID = try matchingID(userPID, userRect, window: userWindow)
        let finalSystemApp = try systemElement(kAXFocusedApplicationAttribute)
        guard targetID == binding.target.window.windowID,
              try systemCompatible(finalSystemApp),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == userPID,
              CFEqual(try element(focusedApp, kAXFocusedWindowAttribute), userWindow), try bounds(userWindow) == userRect,
              scopedSameControl(try appControl(), userControl),
              try value(focusedApp, kAXFrontmostAttribute) as? Bool == true,
              try layout().signature == displays.signature else { throw reject("focus_changed_during_collection") }
        try validateTarget()
        try deadline()
        let token: UUID
        if scopedSameControl(previousUserControl, userControl), let previousToken = previousUserControlToken { token = previousToken }
        else { token = UUID(); previousUserControl = userControl; previousUserControlToken = token }
        let pointerWindows: [ScopedPointerWindow] = rows.prefix(2048).compactMap { row in
            if visualSystemCursorWindow(row) { return nil }
            guard let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner > 0,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value, id > 0,
                  let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 0,
                  let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha > 0,
                  let raw = row[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return ScopedPointerWindow(pid: owner, windowID: id, frame: rect)
        }
        let evidence = ScopedTargetEvidence(target: binding.target, internalFocusedWindowID: targetID,
            focusedControlID: binding.target.controlID, controlPID: binding.target.window.pid, controlWindowID: targetID,
            controlRole: role, enabled: editability.enabled, protected: false, textEditWritableValue: editability.textEditWritableValue,
            chatAdapter: binding.chatAdapter)
        return ScopedInputContext(startedAt: start, completedAt: ProcessInfo.processInfo.systemUptime, target: evidence,
            userFocus: ScopedWindowFocus(pid: userPID, windowID: userID, frame: userRect, screenIDs: userScreens), layout: displays,
            pointerWindows: pointerWindows, userControlToken: token, userControlVerifiedAbsent: userControl == nil,
            userFocusSource: systemApp == nil ? "NSWorkspace_direct_app_AX_CG" :
                ((try pid(systemApp!)) == userPID ? "system_AX_and_NSWorkspace_CG" : "NSWorkspace_direct_app_AX_CG_stale_system_focus"))
    }
}

func scopedLayout() throws -> ScopedDisplayLayout {
    let displays = try activeDisplays()
    return ScopedDisplayLayout(displays: displays.displays.map { ScopedDisplay(id: $0.id, bounds: $0.bounds) }, signature: displays.signature)
}

func scopedPointerContext(_ target: ScopedBackgroundTarget) throws -> ScopedPointerContext {
    let started = ProcessInfo.processInfo.systemUptime
    let layout = try scopedLayout()
    guard layout.signature == target.topologySignature,
          let application = NSRunningApplication(processIdentifier: target.window.pid), !application.isTerminated,
          application.launchDate?.timeIntervalSince1970 == target.processLaunchTime,
          let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]], rows.count <= 2048 else {
        throw ScopedContextError.unavailable("pointer_target_unverified")
    }
    let systemOverlayPIDs = Set(["com.apple.dock", "com.apple.notificationcenterui"].flatMap {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).filter { !$0.isTerminated }.map { $0.processIdentifier }
    })
    func pointerWindows(_ rows: [[String: Any]]) throws -> [ScopedPointerWindow] {
        guard rows.count <= 2048 else { throw ScopedContextError.unavailable("pointer_window_limit") }
        var result: [ScopedPointerWindow] = []
        for row in rows {
            if visualSystemCursorWindow(row) { continue }
            guard let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha.isFinite else {
                throw ScopedContextError.unavailable("pointer_window_visibility_unknown")
            }
            if layer < 0 || alpha <= 0 { continue }
            guard let raw = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else {
                throw ScopedContextError.unavailable("pointer_window_geometry_unknown")
            }
            if frame.width <= 0 || frame.height <= 0 { continue }
            let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            result.append(ScopedPointerWindow(pid: pid,
                windowID: (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                frame: frame, requiresAXHitTest: pid > 0 && systemOverlayPIDs.contains(pid)))
        }
        return result
    }
    let windows = try pointerWindows(rows)
    var hitTest: ScopedPointerHit?
    if let point = CGEvent(source: nil)?.location,
       let top = windows.first(where: { $0.frame.contains(point) }), top.requiresAXHitTest {
        let system = AXUIElementCreateSystemWide()
        // A system-wide timeout is process-global (AXUIElement.h). Keep the
        // same 120 ms budget as the focus reader, never change it underneath it.
        AXUIElementSetMessagingTimeout(system, 0.12)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit {
            var hitPID: pid_t = 0
            if AXUIElementGetPid(hit, &hitPID) == .success, hitPID > 0,
               let owner = windows.first(where: { $0.pid == hitPID && $0.windowID != 0 && $0.frame.contains(point) }),
               let afterRows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
               let afterWindows = try? pointerWindows(afterRows),
               windows.filter({ $0.frame.contains(point) }) == afterWindows.filter({ $0.frame.contains(point) }),
               CGEvent(source: nil)?.location == point {
                hitTest = ScopedPointerHit(point: point, occludingWindowID: top.windowID, window: owner)
            }
        }
    }
    guard windows.contains(where: { $0.pid == target.window.pid && $0.windowID == target.window.windowID && $0.frame == target.window.frame }),
          try scopedLayout().signature == layout.signature else {
        throw ScopedContextError.unavailable("pointer_target_changed")
    }
    return ScopedPointerContext(startedAt: started, completedAt: ProcessInfo.processInfo.systemUptime,
        target: target, layout: layout, windows: windows, hitTest: hitTest)
}

func scopedWindowID(pid: pid_t, frame: CGRect) throws -> CGWindowID {
    let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = rows.filter { row in
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let raw = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
        return bounds == frame
    }
    guard matches.count == 1, let id = (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
        throw fail("background_window_ambiguous", "Exactly one onscreen public CGWindow must match the selected AX PID and geometry")
    }
    return id
}

// One short-lived sampler per explicit command. Its queue only reads public
// focus/window metadata; the event tap consumes an immutable bounded-age copy.
final class BackgroundCommandScope {
    let binding: PublicBackgroundBinding
    let cache = ScopedInputContextCache()
    let mode: ScopedInputMode
    let firstUserFocus: ScopedWindowFocus?
    let firstUserControlToken: UUID?
    private let reader = PublicInputContextReader()
    private let readOnlyReader = PublicInputContextReader()
    private let sampleLock = NSLock()
    private let metricsLock = NSLock()
    private var fullFocusReadMS = 0.0, targetOnlyReadMS = 0.0
    private let timerQueue = DispatchQueue(label: "IntelDesktopHelper.ScopedFocusRefresh")
    private var timer: DispatchSourceTimer?
    init(target: Target, control: AXUIElement?, mode: ScopedInputMode, chatAdapter: Bool = false) throws {
        guard let title = target.expectedTitle, !title.isEmpty,
              axString(target.window, kAXTitleAttribute) == title,
              let frame = axBounds(target.window), let launch = target.application.launchDate?.timeIntervalSince1970 else {
            throw fail("background_target_unverified", "Background commands require an exact window title, geometry and process launch identity")
        }
        let layout = try scopedLayout()
        guard layout.signature == target.displaySignature, let screenIDs = layout.screens(for: frame, requireFullCoverage: mode != .readOnly) else {
            throw fail("background_display_unverified", "The target must have a verified display intersection; input requires complete display coverage")
        }
        let id = try scopedWindowID(pid: target.pid, frame: frame)
        let identity = ScopedBackgroundTarget(window: ScopedWindowFocus(pid: target.pid, windowID: id, frame: frame, screenIDs: screenIDs),
            processLaunchTime: launch, controlID: UUID(), topologySignature: layout.signature)
        binding = PublicBackgroundBinding(target: identity, window: target.window, control: control, chatAdapter: chatAdapter)
        self.mode = mode
        let context: ScopedInputContext
        do { context = try reader.capture(binding, layout: scopedLayout) }
        catch let error as HelperError { throw error }
        catch ScopedContextError.unavailable(let reason) { throw fail("background_context_unavailable", reason) }
        catch { throw fail("background_context_unavailable", String(describing: error)) }
        if let reason = ScopedInputPolicy.contextFailure(context, target: identity, at: ProcessInfo.processInfo.systemUptime, requireEditable: mode != .readOnly) {
            throw fail(reason, "Background target and a separately focused user application could not be verified")
        }
        guard mode == .readOnly || context.userFocus != nil else { throw fail("input_focus_unknown", "The current user's focused window is unavailable") }
        firstUserFocus = context.userFocus
        firstUserControlToken = context.userControlToken
        cache.publish(context, ticket: cache.ticket())
        if mode == .targetedBackground {
            cache.publishPointer(try scopedPointerContext(identity), ticket: cache.ticket())
        }
    }
    func refresh() throws -> ScopedInputContext {
        sampleLock.lock(); defer { sampleLock.unlock() }
        let started = ProcessInfo.processInfo.systemUptime
        defer { metricsLock.lock(); fullFocusReadMS += (ProcessInfo.processInfo.systemUptime - started) * 1000; metricsLock.unlock() }
        do {
            let context = try reader.capture(binding, layout: scopedLayout)
            if let reason = ScopedInputPolicy.contextFailure(context, target: binding.target, at: ProcessInfo.processInfo.systemUptime, requireEditable: mode != .readOnly) {
                throw fail(reason, "Background operation lost its exact target or independent user-focus evidence")
            }
            // A new verified foreign owner is allowed. We neither reclaim nor
            // restore focus; the result reports the observed external change.
            return context
        } catch let error as HelperError { throw error }
        catch { throw fail("background_context_unavailable", "Public AX focus evidence is unavailable: \(error)") }
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + .milliseconds(70), repeating: .milliseconds(70), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.mode == .targetedBackground {
                self.cache.requestPointerRefresh { [weak self] in
                    guard let self else { throw ScopedContextError.unavailable("scope_ended") }
                    return try scopedPointerContext(self.binding.target)
                }
            }
            self.cache.requestRefresh { [weak self] in
                guard let self else { throw ScopedContextError.unavailable("scope_ended") }
                return try self.refresh()
            }
        }
        self.timer = timer; timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil; cache.invalidate() }
    deinit { stop() }
    var readTiming: [String: Double] {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return ["full_focus_reads": fullFocusReadMS, "read_only_target_reads": targetOnlyReadMS]
    }
    // Fresh target-only evidence for an internal capture/OCR subphase. The
    // independently armed takeover monitor and full input cache stay intact.
    // This result is never published to that cache and cannot authorize input.
    func verifyReadTarget(_ target: Target) throws {
        let started = ProcessInfo.processInfo.systemUptime
        defer { metricsLock.lock(); targetOnlyReadMS += (ProcessInfo.processInfo.systemUptime - started) * 1000; metricsLock.unlock() }
        guard target.pid == binding.target.window.pid, CFEqual(target.window, binding.window),
              !target.application.isTerminated,
              target.application.launchDate?.timeIntervalSince1970 == binding.target.processLaunchTime,
              target.expectedTitle == axString(target.window, kAXTitleAttribute) else {
            throw fail("background_target_changed", "The selected target changed during its read-only subphase")
        }
        let readBinding = PublicBackgroundBinding(target: binding.target, window: binding.window, control: nil, chatAdapter: false)
        let context: ScopedInputContext
        do { context = try readOnlyReader.capture(readBinding, layout: scopedLayout) }
        catch { throw fail("background_context_unavailable", "Read-only target evidence is unavailable: \(error)") }
        if let reason = ScopedInputPolicy.contextFailure(context, target: binding.target,
                at: ProcessInfo.processInfo.systemUptime, requireEditable: false) {
            throw fail(reason, "Complete target identity/security/topology proof is required for reading")
        }
    }
    func verify(_ target: Target, forceFresh: Bool = false) throws {
        func changed(_ field: String) -> HelperError {
            fail("background_target_changed", "Background target identity changed: \(field)", ["failed_guard": field])
        }
        guard target.pid == binding.target.window.pid else { throw changed("pid") }
        guard CFEqual(target.window, binding.window) else { throw changed("selected_window") }
        guard !target.application.isTerminated else { throw changed("process_terminated") }
        guard target.application.launchDate?.timeIntervalSince1970 == binding.target.processLaunchTime else { throw changed("process_launch_time") }
        var rawTitle: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(target.window, kAXTitleAttribute as CFString, &rawTitle)
        guard titleResult == .success else {
            throw fail("background_context_unavailable", "AX_AXTitle_\(titleResult.rawValue)", ["failed_guard": "window_title_read", "ax_result": titleResult.rawValue])
        }
        guard let title = rawTitle as? String, target.expectedTitle == title else { throw changed("window_title") }
        var context = cache.current()
        if forceFresh || context == nil || ProcessInfo.processInfo.systemUptime - (context?.startedAt ?? 0) > 0.1 {
            let ticket = cache.ticket()
            do { context = try refresh(); cache.publish(context, ticket: ticket) }
            catch { cache.invalidate(); throw error }
        }
        if let reason = ScopedInputPolicy.contextFailure(context, target: binding.target, at: ProcessInfo.processInfo.systemUptime, requireEditable: mode != .readOnly) {
            throw fail(reason, "Fresh actual focus in an independently verified application is required")
        }
    }
}

struct BackgroundTextPlan {
    let before: String
    let after: String
    let parts: [[UniChar]]
    init(text: String, before: String, after: String) throws {
        let units = Array(text.utf16)
        guard !units.isEmpty, units.count <= 4096, before.utf16.count <= 65536, after.utf16.count <= 65536,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
            throw fail("background_text_denied", "Background typing accepts 1...4096 UTF-16 units of single-line text; Return, tabs and control characters are forbidden")
        }
        guard after == before + text, after != before else {
            throw fail("background_expected_after_mismatch", "expected_after must exactly equal expected_before + text for the verified append backend")
        }
        self.before = before; self.after = after
        var result: [[UniChar]] = [], index = 0
        while index < units.count {
            var end = min(index + 20, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            result.append(Array(units[index..<end])); index = end
        }
        parts = result
    }
}

struct BackgroundTextState: Equatable { let value: String; let caret: Int; let selectionLength: Int }
func validateBackgroundTextState(_ state: BackgroundTextState, allowed: [String]) throws {
    guard allowed.contains(state.value), state.caret == state.value.utf16.count, state.selectionLength == 0 else {
        throw fail("background_value_or_selection_changed", "Full AX value and end caret must match an exact already-posted append state")
    }
}

// Injection points make every guard/event boundary independently testable with
// zero live events. Up is posted only after the same complete guard as Down.
func performBackgroundText(plan: BackgroundTextPlan, observe: () throws -> BackgroundTextState,
                           guardTarget: () throws -> Void, post: ([UniChar], Bool) throws -> Void,
                           pause: () -> Void, now: () -> Double,
                           events: inout Int) throws {
    var allowed = [plan.before], typed: [UniChar] = []
    try guardTarget(); try validateBackgroundTextState(observe(), allowed: allowed)
    for part in plan.parts {
        for down in [true, false] {
            try guardTarget()
            try validateBackgroundTextState(observe(), allowed: allowed)
            try guardTarget()
            try validateBackgroundTextState(observe(), allowed: allowed)
            try post(part, down); events += 1
            if down {
                typed += part
                allowed.append(plan.before + String(decoding: typed, as: UTF16.self))
            }
        }
    }
    let deadline = now() + 2
    repeat {
        try guardTarget()
        let state = try observe()
        try validateBackgroundTextState(state, allowed: allowed)
        if state.value == plan.after { return }
        pause()
    } while now() < deadline
    throw fail("background_postcondition_unknown", "Targeted events were posted but exact expected_after was not verified; do not replay")
}

// Native construction shared by both chat adapters. The process notification
// and window-bound mouse sequence are recovered from the ARM event builder;
// the exported local coordinate setter is independently round-trip checked.
func backgroundFocusNotification() throws -> CGEvent {
    // The ARM initial-state transition (0x10073f430..0x10073f448) uses
    // NSAppKitDefined / applicationActivated. Type 21 is only its subsequent
    // "key focus returned" path and cannot establish a deactivated Qt editor.
    guard let type = NSEvent.EventType(rawValue: 13),
          let event = NSEvent.otherEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
              windowNumber: 0, context: nil, subtype: 1, data1: 0, data2: 0)?.cgEvent else {
        throw fail("event_creation_failed", "Could not construct the process focus notification")
    }
    event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    return event
}

func backgroundWindowMouse(down: Bool, point: CGPoint, window: ScopedWindowFocus) throws -> CGEvent {
    guard window.frame.contains(point),
          let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else {
        throw fail("background_mouse_unavailable", "Window-local event coordinates are unavailable")
    }
    defer { dlclose(handle) }
    guard let setter = dlsym(handle, "CGEventSetWindowLocation"), let getter = dlsym(handle, "CGEventGetWindowLocation"),
          let event = NSEvent.mouseEvent(with: down ? .leftMouseDown : .leftMouseUp, location: point,
              modifierFlags: [], timestamp: 0, windowNumber: Int(window.windowID), context: nil,
              eventNumber: 1, clickCount: 1, pressure: 1)?.cgEvent else {
        throw fail("background_mouse_unavailable", "Window-bound mouse construction is unavailable")
    }
    event.flags = []; event.location = point; event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    event.setIntegerValueField(CGEventField(rawValue: 3)!, value: 0)
    event.setIntegerValueField(CGEventField(rawValue: 7)!, value: 3)
    event.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(window.windowID))
    event.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(window.windowID))
    // CGEvent's window location is top-left relative, unlike AppKit's
    // locationInWindow. The ARM CGWindow target path writes false to
    // windowUsesFlippedCoordinates (0x100704574); its event builder then
    // subtracts the window origin without the optional Y reflection.
    // Both locations are Quartz points; the display backing scale is irrelevant.
    let local = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
    unsafeBitCast(setter, to: (@convention(c)(CGEvent, CGPoint) -> Void).self)(event, local)
    guard unsafeBitCast(getter, to: (@convention(c)(CGEvent) -> CGPoint).self)(event) == local,
          event.location == point, NSEvent(cgEvent: event)?.windowNumber == Int(window.windowID) else {
        throw fail("background_mouse_unavailable", "Global and window-local coordinates did not round-trip independently")
    }
    return event
}

// Preserve the target window in the event itself. An app's internal AX key
// window may survive deactivation by real keys delivered to another app;
// an unbound CG key then has no explicit destination inside this process.
// The public AppKit key factory's window number survives CG serialization.
func backgroundWindowKey(source: CGEventSource, code: CGKeyCode, flags: CGEventFlags,
                         down: Bool, units: [UniChar] = [], windowID: CGWindowID) throws -> CGEvent {
    guard windowID != 0, (code == 0 || code == 51),
          flags.isEmpty || (code == 0 && flags == .maskCommand) else {
        throw fail("background_key_unavailable", "Only window-bound text, select-all and delete keys are supported")
    }
    let characters = units.isEmpty ? (code == 51 ? "\u{7f}" : "a") : String(decoding: units, as: UTF16.self)
    guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)), timestamp: 0,
        windowNumber: Int(windowID), context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)?.cgEvent else {
        throw fail("background_key_unavailable", "Could not construct a window-bound keyboard event")
    }
    event.setSource(source)
    event.flags = flags
    if !units.isEmpty {
        units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
    }
    guard NSEvent(cgEvent: event)?.windowNumber == Int(windowID),
          event.type == (down ? .keyDown : .keyUp), event.flags == flags,
          event.getIntegerValueField(.keyboardEventKeycode) == Int64(code),
          event.getIntegerValueField(.eventSourceStateID) == Int64(source.sourceStateID.rawValue) else {
        throw fail("background_key_unavailable", "Window-bound key metadata did not round-trip with its private source")
    }
    return event
}

func backgroundWindowKeySelfTests() -> [String: Any] {
    var tests: [[String: Any]] = []
    func check(_ name: String, _ pass: Bool) { tests.append(["name": name, "passed": pass]) }
    guard let source = CGEventSource(stateID: .privateState) else {
        return ["ok": false, "tests": [["name": "private_source_creation", "passed": false]]]
    }
    for (name, code, flags, units) in [
        ("unicode", CGKeyCode(0), CGEventFlags(), Array("中文🙂".utf16)),
        ("select_all", CGKeyCode(0), CGEventFlags.maskCommand, [UniChar]()),
        ("delete", CGKeyCode(51), CGEventFlags(), [UniChar]())
    ] {
        for down in [true, false] {
            do {
                let event = try backgroundWindowKey(source: source, code: code, flags: flags, down: down, units: units, windowID: 42)
                let restored = event.data.flatMap { CGEvent(withDataAllocator: nil, data: $0) }
                check("\(name)_\(down)_serialized_exact_window", restored.flatMap { NSEvent(cgEvent: $0) }?.windowNumber == 42)
                check("\(name)_\(down)_serialized_type_code_flags", restored?.type == (down ? .keyDown : .keyUp) && restored?.flags == flags && restored?.getIntegerValueField(.keyboardEventKeycode) == Int64(code))
                // CGEventCreateFromData drops source ownership for both the
                // AppKit and plain-CG factory. We post the original event.
                check("\(name)_\(down)_original_keeps_private_source", event.getIntegerValueField(.eventSourceStateID) == Int64(source.sourceStateID.rawValue) && source.sourceStateID != .combinedSessionState && source.sourceStateID != .hidSystemState)
                if !units.isEmpty {
                    var count = 0, recovered = [UniChar](repeating: 0, count: units.count + 1)
                    recovered.withUnsafeMutableBufferPointer { restored?.keyboardGetUnicodeString(maxStringLength: $0.count, actualStringLength: &count, unicodeString: $0.baseAddress) }
                    check("\(name)_\(down)_complete_utf16", Array(recovered.prefix(count)) == units)
                }
            } catch { check("\(name)_\(down)_construction", false) }
        }
    }
    for (name, code, flags, windowID) in [
        ("no_window", CGKeyCode(0), CGEventFlags(), CGWindowID(0)),
        ("submit", CGKeyCode(36), CGEventFlags(), CGWindowID(42)),
        ("unapproved_modifier", CGKeyCode(0), CGEventFlags.maskAlternate, CGWindowID(42))
    ] {
        do { _ = try backgroundWindowKey(source: source, code: code, flags: flags, down: true, windowID: windowID); check(name, false) }
        catch { check(name, (error as? HelperError)?.code == "background_key_unavailable") }
    }
    return ["ok": tests.allSatisfy { $0["passed"] as? Bool == true }, "tests": tests,
        "case_count": tests.count, "events_posted": 0, "live_reads": 0]
}

struct BackgroundChatPlan {
    let operation: String
    let before: String
    let after: String
    let afterValues: [String]
    let recipient: String
    let parts: [[UniChar]]
    let suffix: String
    init(_ request: [String: Any], bundle: String) throws {
        guard ["com.bytedance.macos.feishu", "com.tencent.xinWeChat"].contains(bundle),
              let operation = try string(request, "operation", required: false), ["type", "clear"].contains(operation),
              let before = try string(request, "expected_before", required: false),
              let after = try string(request, "expected_after", required: false),
              before.utf16.count <= 65536, after.utf16.count <= 65536 else {
            throw fail("invalid_request", "Chat background input requires operation=type|clear and complete expected_before/expected_after strings")
        }
        guard request["allow_submit"] == nil, request["key"] == nil, request["modifiers"] == nil else {
            throw fail("background_submit_denied", "Background chat input never accepts submit keys or caller modifiers")
        }
        let feishu = bundle == "com.bytedance.macos.feishu"
        let recipient = try string(request, feishu ? "expected_recipient" : "chat_title")!
        guard recipient.utf16.count <= 1024 else { throw fail("invalid_request", "Recipient is too long") }
        let suffix = feishu ? "\u{200b}\n\u{200b}\n\u{200b}" : ""
        let empty = feishu ? "发送给 " + recipient + "\n" + suffix : ""
        let emptyValues = feishu ? [empty, "按住 \nfn \n说话\n" + empty] : [""]
        var parts: [[UniChar]] = []
        if operation == "type" {
            let text = try string(request, "text")!
            let plan = try BackgroundTextPlan(text: text, before: "", after: text)
            guard emptyValues.contains(before), after == text + suffix else {
                throw fail("background_expected_after_mismatch", "Typing requires a verified empty composer and the exact application serialization of text")
            }
            parts = plan.parts
        } else {
            guard request["text"] == nil, !before.isEmpty, !emptyValues.contains(before), emptyValues.contains(after),
                  !feishu || (before.hasSuffix(suffix) && before.utf16.count > suffix.utf16.count) else {
                throw fail("background_clear_values_unverified", "Clear requires the complete existing draft and exact known empty composer serialization")
            }
        }
        self.operation = operation; self.before = before; self.after = after
        // Feishu may switch its voice-hint presentation after deletion. Both
        // exact complete empty serializations prove the same cleared draft.
        afterValues = operation == "clear" ? emptyValues : [after]
        self.recipient = recipient; self.parts = parts; self.suffix = suffix
    }
    func typedValue(_ units: [UniChar]) -> String { String(decoding: units, as: UTF16.self) + suffix }
}

// A fresh complete composer/header read leases one bounded, PID-directed key
// burst. The matching key-up never starts another capture. Every event still
// checks current owner/target/takeover; an expired lease stops without replay.
func renewBackgroundVisualEvidence(previousTime: Double, previousSerial: Int, attempts: inout Int,
                                   read: () throws -> [String: Any], now: () -> Double) throws -> [String: Any] {
    guard attempts == 0, previousTime.isFinite, previousSerial > 0 else {
        throw fail("background_evidence_expired", "The bounded read-only evidence refresh is unavailable; no input replay")
    }
    attempts += 1
    let result = try read(), completed = now()
    guard let stamp = result["background_evidence_frame_time"] as? Double,
          let serial = result["frame_complete_serial"] as? Int,
          stamp.isFinite, completed.isFinite, stamp > previousTime, serial > previousSerial,
          completed >= stamp, completed - stamp <= 2 else {
        throw fail("background_evidence_expired", "A genuinely newer complete frame did not satisfy the original two-second lease")
    }
    return result
}

func backgroundEvidenceRenewalSelfTests() -> [String: Any] {
    var tests: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { tests.append(["name": name, "passed": passed]) }
    for (name, stamp, serial, now, accepted) in [
        ("new_complete_frame_original_lease", 12.1, 2, 12.2, true),
        ("old_frame_new_clock_rejected", 10.0, 2, 12.2, false),
        ("old_serial_new_clock_rejected", 12.1, 1, 12.2, false),
        ("new_frame_still_expired_rejected", 10.1, 2, 12.2, false),
        ("future_frame_rejected", 12.3, 2, 12.2, false),
        ("invalid_frame_clock_rejected", Double.nan, 2, 12.2, false),
        ("unchanged_two_second_bound", 12.0, 2, 14.0, true)] {
        var attempts = 0, reads = 0
        do {
            _ = try renewBackgroundVisualEvidence(previousTime: 10, previousSerial: 1, attempts: &attempts, read: {
                reads += 1; return ["background_evidence_frame_time": stamp, "frame_complete_serial": serial]
            }, now: { now })
            check(name, accepted && attempts == 1 && reads == 1)
        } catch { check(name, !accepted && (error as? HelperError)?.code == "background_evidence_expired" && attempts == 1 && reads == 1) }
    }
    var attempts = 1, reads = 0
    do {
        _ = try renewBackgroundVisualEvidence(previousTime: 10, previousSerial: 1, attempts: &attempts,
            read: { reads += 1; return [:] }, now: { 12.2 })
        check("second_refresh_does_not_read_or_replay", false)
    } catch { check("second_refresh_does_not_read_or_replay", attempts == 1 && reads == 0) }
    attempts = 0
    do {
        _ = try renewBackgroundVisualEvidence(previousTime: 10, previousSerial: 1, attempts: &attempts,
            read: { throw fail("background_draft_changed", "fixture") }, now: { 12.2 })
        check("changed_draft_failure_propagated_without_retry", false)
    } catch { check("changed_draft_failure_propagated_without_retry", attempts == 1 && (error as? HelperError)?.code == "background_draft_changed") }
    return ["ok": tests.allSatisfy { $0["passed"] as? Bool == true }, "count": tests.count, "tests": tests, "events_posted": 0]
}

func performBackgroundVisualBurst(plan: BackgroundChatPlan, evidenceTime: Double,
                                  guardTarget: () throws -> Void,
                                  post: (CGKeyCode, CGEventFlags, Bool, [UniChar]) throws -> Void,
                                  now: () -> Double) throws {
    func guardedPost(_ code: CGKeyCode, _ flags: CGEventFlags, _ down: Bool, _ units: [UniChar] = []) throws {
        try guardTarget()
        let time = now()
        guard time.isFinite, evidenceTime.isFinite, time >= evidenceTime, time - evidenceTime <= 2 else {
            throw fail("background_evidence_expired", "Complete composer and recipient evidence expired before the next event; do not replay")
        }
        try post(code, flags, down, units)
    }
    if plan.operation == "type" {
        for part in plan.parts {
            try guardedPost(0, [], true, part)
            try guardedPost(0, [], false, part)
        }
    } else {
        try guardedPost(0, .maskCommand, true)
        try guardedPost(0, .maskCommand, false)
        try guardedPost(51, [], true)
        try guardedPost(51, [], false)
    }
}

// A complete fresh AX/scope read leases exactly one notification and its keys.
// No AX IPC or run-loop wait is inserted between activation and the key pair.
// The caller must verify the complete result before preparing another chunk.
func performBackgroundFeishuBurst(part: [UniChar]?, selectingAll: Bool = false, prepare: () throws -> Double,
                                  guardEvent: () throws -> Void, notify: () throws -> Void,
                                  post: (CGKeyCode, CGEventFlags, Bool, [UniChar]) throws -> Void,
                                  now: () -> Double) throws {
    if let part, part.isEmpty || part.count > 128 || selectingAll {
        throw fail("background_text_denied", "A Feishu burst requires one nonempty bounded Unicode chunk")
    }
    let proofTime = try prepare()
    func check() throws {
        try guardEvent()
        let time = now()
        guard proofTime.isFinite, time.isFinite, time >= proofTime,
              time - proofTime <= ScopedInputPolicy.maxContextAge else {
            throw fail("background_evidence_expired", "The complete Feishu scope/composer proof expired within the burst; do not replay")
        }
    }
    try check(); try notify()
    if let part {
        for down in [true, false] { try check(); try post(0, [], down, part) }
    } else {
        for down in [true, false] { try check(); try post(selectingAll ? 0 : 51, selectingAll ? .maskCommand : [], down, []) }
    }
}

// Once input is posted, an intermediate complete value grants no further
// input. Only the exact endpoint completes this bounded read-only wait. All
// identity/recipient/security/focus failures from read propagate immediately.
func waitBackgroundFeishuValue(expected: [String], read: () throws -> String,
                               pause: () -> Void, now: () -> Double) throws -> String {
    let deadline = now() + 2
    repeat {
        // Give the application event/renderer loop actual time before AX IPC,
        // including the first read after posting. A run-loop callback alone is
        // not a settle interval and can otherwise create continuous AX traffic.
        pause()
        let value = try read()
        if expected.contains(value) { return value }
    } while now() < deadline
    throw fail("background_postcondition_unknown", "Posted Feishu input did not reach its complete expected value; do not replay")
}

// Construct the initial app-defined notification and mouse pair before posting.
// Only the caller's fresh full composer/scope proof can authorize each
// PID-directed event; there is no global cursor move or recovery input here.
func performBackgroundFeishuComposerClick(source: CGEventSource, window: ScopedWindowFocus,
                                         composer: CGRect, verifyBefore: () throws -> Void,
                                         post: (CGEvent) -> Void) throws {
    // A newly created private source receives its own state ID, rather than
    // retaining the .privateState creation sentinel (-1).
    guard source.sourceStateID != .combinedSessionState, source.sourceStateID != .hidSystemState,
          window.pid > 0, window.windowID != 0,
          composer.minX.isFinite, composer.minY.isFinite, composer.width.isFinite, composer.height.isFinite,
          composer.width > 2, composer.height > 2, window.frame.contains(composer) else {
        throw fail("background_composer_unverified", "A private source and exact contained composer are required")
    }
    let point = CGPoint(x: composer.minX + min(12, composer.width / 2), y: composer.midY)
    let pair = try [true, false].map { down -> CGEvent in
        let event = try backgroundWindowMouse(down: down, point: point, window: window)
        event.setSource(source)
        guard event.getIntegerValueField(.eventSourceStateID) == Int64(source.sourceStateID.rawValue),
              event.getIntegerValueField(CGEventField(rawValue: 91)!) == Int64(window.windowID),
              event.getIntegerValueField(CGEventField(rawValue: 92)!) == Int64(window.windowID),
              event.location == point else {
            throw fail("background_mouse_unavailable", "Private composer mouse metadata did not retain its exact window")
        }
        return event
    }
    for event in [try backgroundFocusNotification()] + pair {
        try verifyBefore()
        post(event)
    }
}

func backgroundFeishuComposerClickSelfTests() -> [[String: Any]] {
    var tests: [[String: Any]] = []
    func check(_ name: String, _ pass: Bool) { tests.append(["name": name, "passed": pass]) }
    guard let source = CGEventSource(stateID: .privateState) else {
        return [["name": "private_source_creation", "passed": false]]
    }
    for (name, origin) in [("left_2x_points", CGPoint(x: 220, y: 90)),
                            ("right_1x_points", CGPoint(x: 2000, y: 120)),
                            ("negative_origin_points", CGPoint(x: -900, y: -150))] {
        let window = ScopedWindowFocus(pid: 7, windowID: 42,
            frame: CGRect(origin: origin, size: CGSize(width: 1000, height: 900)), screenIDs: [1])
        let composer = CGRect(x: origin.x + 600, y: origin.y + 700, width: 353, height: 22)
        var trace: [String] = [], posted: [CGEvent] = []
        do {
            try performBackgroundFeishuComposerClick(source: source, window: window, composer: composer,
                verifyBefore: { trace.append("full_before_and_fresh_scope") }, post: {
                    trace.append($0.type == .leftMouseDown ? "down" : $0.type == .leftMouseUp ? "up" : "notification")
                    posted.append($0)
                })
            check(name + "_three_independently_guarded_posts", trace == ["full_before_and_fresh_scope", "notification", "full_before_and_fresh_scope", "down", "full_before_and_fresh_scope", "up"])
            check(name + "_one_initial_13_1_notification", posted.count == 3 &&
                  posted.first.flatMap { NSEvent(cgEvent: $0) }?.type.rawValue == 13 &&
                  posted.first.flatMap { NSEvent(cgEvent: $0) }?.subtype.rawValue == 1 &&
                  posted.filter { $0.type == .leftMouseDown || $0.type == .leftMouseUp }.count == 2)
            check(name + "_exact_window_and_private_source", posted.count == 3 && posted.dropFirst().allSatisfy {
                $0.getIntegerValueField(.eventSourceStateID) == Int64(source.sourceStateID.rawValue) &&
                $0.getIntegerValueField(CGEventField(rawValue: 91)!) == 42 &&
                $0.getIntegerValueField(CGEventField(rawValue: 92)!) == 42 &&
                NSEvent(cgEvent: $0)?.windowNumber == 42
            })
            check(name + "_safe_point_no_scale_conversion", posted.dropFirst().allSatisfy {
                $0.location == CGPoint(x: composer.minX + 12, y: composer.midY) && composer.contains($0.location)
            })
        } catch { check(name + "_construction", false) }
    }
    let window = ScopedWindowFocus(pid: 7, windowID: 42, frame: CGRect(x: 0, y: 0, width: 1000, height: 900), screenIDs: [1])
    let composer = CGRect(x: 600, y: 700, width: 353, height: 22)
    for (code, failAt) in [("secure_field_denied", 1), ("background_draft_changed", 1),
                           ("background_recipient_unverified", 1), ("input_focus_changed", 1),
                           ("input_focus_changed", 2), ("background_draft_changed", 2),
                           ("input_focus_changed", 3), ("background_draft_changed", 3)] {
        var guards = 0, posts = 0
        do {
            try performBackgroundFeishuComposerClick(source: source, window: window, composer: composer,
                verifyBefore: { guards += 1; if guards == failAt { throw fail(code, "fixture") } },
                post: { _ in posts += 1 })
            check("\(code)_at_\(failAt)_stops_without_replay", false)
        } catch {
            check("\(code)_at_\(failAt)_stops_without_replay", (error as? HelperError)?.code == code &&
                  guards == failAt && posts == failAt - 1)
        }
    }
    for (name, rect) in [("outside_window", CGRect(x: 950, y: 700, width: 353, height: 22)),
                         ("empty_composer", CGRect(x: 600, y: 700, width: 0, height: 22)),
                         ("unsafe_narrow_composer", CGRect(x: 600, y: 700, width: 2, height: 22))] {
        var posts = 0, guards = 0
        do {
            try performBackgroundFeishuComposerClick(source: source, window: window, composer: rect,
                verifyBefore: { guards += 1 }, post: { _ in posts += 1 })
            check(name + "_zero_events", false)
        } catch { check(name + "_zero_events", posts == 0 && guards == 0 && (error as? HelperError)?.code == "background_composer_unverified") }
    }
    return tests
}

// Unlike a text area's default AXPress action, explicit AXFocused asks
// Chromium to establish its native view responder before focusing the DOM node.
// The setter is one attempt, never evidence that focus or editing succeeded.
func performBackgroundFeishuComposerFocus(writability: () -> (AXError, Bool),
                                         verifyBefore: () throws -> Void,
                                         setFocused: () -> AXError) throws {
    let (result, writable) = writability()
    guard result == .success, writable else {
        throw fail("background_composer_unverified", "The exact Feishu composer does not expose writable AXFocused",
                   ["ax_result": result.rawValue, "ax_focused_settable": writable])
    }
    try verifyBefore()
    let focusResult = setFocused()
    guard focusResult == .success else {
        throw fail("background_composer_focus_failed", "AXFocused failed on the exact composer; do not replay",
                   ["ax_result": focusResult.rawValue])
    }
}

func backgroundFeishuComposerFocusSelfTests() -> [[String: Any]] {
    var tests: [[String: Any]] = []
    func check(_ name: String, _ pass: Bool) { tests.append(["name": name, "passed": pass]) }
    func run(writableResult: AXError = .success, writable: Bool = true,
             guardFailure: String? = nil, setterResult: AXError = .success)
        -> (calls: [String], attempts: Int, error: HelperError?) {
        var calls: [String] = [], attempts = 0
        do {
            try performBackgroundFeishuComposerFocus(writability: {
                calls.append("writability")
                return (writableResult, writable)
            }, verifyBefore: {
                calls.append("full_before_and_fresh_scope")
                if let guardFailure { throw fail(guardFailure, "fixture") }
            }, setFocused: {
                calls.append("AXFocused_true"); attempts += 1
                return setterResult
            })
            return (calls, attempts, nil)
        } catch {
            return (calls, attempts, error as? HelperError)
        }
    }
    let success = run()
    check("single_explicit_focus_after_full_guard", success.error == nil && success.attempts == 1 &&
          success.calls == ["writability", "full_before_and_fresh_scope", "AXFocused_true"])
    let readonly = run(writable: false)
    check("not_settable_no_focus_attempt", readonly.error?.code == "background_composer_unverified" &&
          readonly.attempts == 0 && readonly.calls == ["writability"])
    for result in [AXError.attributeUnsupported, .cannotComplete, .invalidUIElement, .apiDisabled] {
        // A stale true out-parameter must never override the real AX error.
        let probe = run(writableResult: result, writable: true)
        check("writability_error_\(result.rawValue)_preserved", probe.error?.code == "background_composer_unverified" &&
              probe.error?.details["ax_result"] as? Int32 == result.rawValue && probe.attempts == 0 &&
              probe.calls == ["writability"])
    }
    for code in ["secure_field_denied", "background_draft_changed", "background_recipient_unverified", "input_focus_changed"] {
        let probe = run(guardFailure: code)
        check("\(code)_prevents_focus", probe.error?.code == code && probe.attempts == 0 &&
              probe.calls == ["writability", "full_before_and_fresh_scope"])
    }
    for result in [AXError.cannotComplete, .attributeUnsupported, .invalidUIElement] {
        let probe = run(setterResult: result)
        check("setter_error_\(result.rawValue)_one_attempt_no_replay", probe.error?.code == "background_composer_focus_failed" &&
              probe.error?.details["ax_result"] as? Int32 == result.rawValue && probe.attempts == 1 &&
              probe.calls == ["writability", "full_before_and_fresh_scope", "AXFocused_true"])
    }
    return tests
}

// Cached Feishu semantic identities are refetched around each bounded edit.
// Their original messenger-chat/header geometry remains part of the binding.
final class BackgroundFeishuComposer {
    let target: Target
    let composer: AXUIElement
    let recipient: AXUIElement
    let chat: AXUIElement
    let composerID: String?
    let recipientID: String?
    let composerRect: CGRect
    let recipientRect: CGRect
    let chatRect: CGRect
    let title: String
    convenience init(request: [String: Any], helper: DesktopHelper, target: Target, title: String) throws {
        let composerID = try string(request, "element_id")!
        let recipientID = try string(request, "recipient_element_id")!
        guard composerID != recipientID else { throw fail("background_composer_unverified", "Composer and recipient must be distinct cached elements") }
        let composer = try helper.cached(["element_id": composerID], target: target)
        let recipient = try helper.cached(["element_id": recipientID], target: target)
        try self.init(target: target, composer: composer, recipient: recipient, title: title, composerID: composerID, recipientID: recipientID)
    }
    init(target: Target, composer: AXUIElement, recipient: AXUIElement, title: String,
         composerID: String? = nil, recipientID: String? = nil) throws {
        guard target.bundleID == "com.bytedance.macos.feishu", target.expectedTitle == "飞书" else {
            throw fail("background_target_unverified", "Feishu background input requires its exact main chat window")
        }
        self.target = target; self.title = title
        self.composerID = composerID; self.recipientID = recipientID
        self.composer = composer; self.recipient = recipient
        guard !CFEqual(composer, recipient) else { throw fail("background_composer_unverified", "Composer and recipient identities overlap") }
        let composerChat = try Self.chatAncestor(composer, target: target)
        let recipientChat = try Self.chatAncestor(recipient, target: target)
        guard CFEqual(composerChat, recipientChat), let c = axBounds(composer), let r = axBounds(recipient),
              let area = axBounds(composerChat), let window = axBounds(target.window),
              visualContains(window, area), visualContains(area, c), c.minY > area.midY,
              r.height > 2, visualContains(CGRect(x: area.minX, y: area.minY, width: area.width * 0.67, height: min(56, area.height)), r) else {
            throw fail("background_recipient_unverified", "Composer and header must belong to the same exact current messenger-chat")
        }
        chat = composerChat; composerRect = c; recipientRect = r; chatRect = area
    }
    static func chatAncestor(_ element: AXUIElement, target: Target) throws -> AXUIElement {
        var item: AXUIElement? = element, chat: AXUIElement?
        for _ in 0..<64 {
            guard let node = item else { break }
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid == target.pid else {
                throw fail("background_composer_unverified", "Ancestry left the bound process")
            }
            if axString(node, kAXRoleAttribute) == "AXWebArea", axString(node, kAXTitleAttribute) == "messenger-chat" { chat = node }
            if CFEqual(node, target.window), let chat { return chat }
            item = axElement(node, kAXParentAttribute)
        }
        throw fail("background_composer_unverified", "Cached control no longer belongs to the selected chat window")
    }
    func observe(helper: DesktopHelper, allowed: [String], requireFocus: Bool) throws -> String {
        let value = try readValue(helper: helper, requireFocus: requireFocus)
        guard allowed.contains(value) else { throw fail("background_draft_changed", "Complete Feishu composer value changed; no replay") }
        return value
    }
    func readValue(helper: DesktopHelper, requireFocus: Bool) throws -> String {
        let c = try composerID.map { try helper.cached(["element_id": $0], target: target) } ?? composer
        let r = try recipientID.map { try helper.cached(["element_id": $0], target: target) } ?? recipient
        try helper.denySecure(c); try helper.denySecure(r)
        guard CFEqual(c, composer), CFEqual(r, recipient),
              CFEqual(try Self.chatAncestor(c, target: target), chat), CFEqual(try Self.chatAncestor(r, target: target), chat),
              axBounds(c) == composerRect, axBounds(r) == recipientRect, axBounds(chat) == chatRect,
              axString(c, kAXRoleAttribute) == "AXTextArea", axString(r, kAXRoleAttribute) == "AXStaticText",
              axBool(c, kAXEnabledAttribute) == true,
              [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap({ axString(r, $0) }).first(where: { !$0.isEmpty }) == title,
              let value = axString(c, kAXValueAttribute), value.utf16.count <= 65536 else {
            throw fail("background_draft_changed", "Complete Feishu composer, exact recipient, or cached geometry changed; no replay")
        }
        if requireFocus {
            guard axElement(target.axApplication, kAXFocusedWindowAttribute).map({ CFEqual($0, target.window) }) == true,
                  axElement(target.axApplication, kAXFocusedUIElementAttribute).map({ CFEqual($0, c) }) == true,
                  axBool(c, kAXFocusedAttribute) == true else {
                throw fail("background_internal_focus_unverified", "The bound Feishu composer did not acquire internal keyboard focus")
            }
        }
        return value
    }
}

extension DesktopHelper {
    func withBackgroundTargetRead<Value>(enabled: Bool = true, _ read: () throws -> Value) rethrows -> Value {
        guard enabled else { return try read() }
        backgroundTargetReadDepth += 1
        defer { backgroundTargetReadDepth -= 1 }
        return try read()
    }
    func backgroundChatInput(_ originalRequest: [String: Any], bundle: String, atomic: Bool = false) throws -> [String: Any] {
        var events = 0, notifications = 0, mouseEvents = 0, keyEvents = 0, axActionCount = 0
        var menuActionCount = 0, composerFocusCount = 0, menuEditAttempted = false
        var clipboard: BackgroundClipboardLease?
        defer { clipboard?.restore() }
        var visualEvidenceRefreshes = 0
        let route = bundle == "com.bytedance.macos.feishu" ? "appKitDefined13_windowLocal_mouse_AXFocused_AXPress_exact_edit_menu" : "appKitDefined13_subtype1_windowNumber91_92_windowLocal_postToPid"
        var lastEvidence: [String: Any] = [:]
        var stages: [String: Double] = [:]
        let commandStarted = ProcessInfo.processInfo.systemUptime
        var phaseStarted = commandStarted
        do {
            var request = originalRequest
            let atomicRequest = atomic ? try AtomicBackgroundChatEdit(request) : nil
            if let atomicRequest { request["window_title"] = atomicRequest.windowTitle }
            let legacyPlan = atomic ? nil : try BackgroundChatPlan(request, bundle: bundle)
            _ = try string(request, "window_title")!
            let chosen = try target(request)
            stages["target"] = (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1000
            phaseStarted = ProcessInfo.processInfo.systemUptime
            let scope = try BackgroundCommandScope(target: chosen, control: nil, mode: .targetedBackground, chatAdapter: true)
            let source: CGEventSource?
            if bundle == "com.bytedance.macos.feishu" { source = nil }
            else {
                guard CGPreflightPostEventAccess(), let eventSource = CGEventSource(stateID: .privateState) else {
                    throw fail("post_event_unavailable", "Existing post-event permission and private event source are required")
                }
                source = eventSource
            }
            let pointerBefore = CGEvent(source: nil)?.location
            try monitor.beginScoped(mode: .targetedBackground, target: scope.binding.target, cache: scope.cache)
            backgroundScope = scope; scope.start()
            defer { scope.stop(); backgroundScope = nil; monitor.end() }
            func guarded() throws {
                try monitor.check(); try verifyDisplayTopology(chosen)
                try scope.verify(chosen); try monitor.check()
            }
            stages["scope"] = (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1000
            phaseStarted = ProcessInfo.processInfo.systemUptime
            let feishu: BackgroundFeishuComposer?
            if bundle == "com.bytedance.macos.feishu" {
                feishu = atomic ? try BackgroundFeishuComposer.discover(helper: self, target: chosen, expectedTitle: atomicRequest!.title,
                    beforeRebuild: {
                        try monitor.check(); try verifyDisplayTopology(chosen)
                        try scope.verify(chosen, forceFresh: true); try monitor.check()
                    }) :
                    try BackgroundFeishuComposer(request: request, helper: self, target: chosen, title: legacyPlan!.recipient)
            } else { feishu = nil }
            stages["binding"] = (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1000
            phaseStarted = ProcessInfo.processInfo.systemUptime
            var initialValue: String?, initialTitle: String?, alreadyEmpty = false
            if let atomicRequest {
                try guarded()
                if let feishu {
                    initialTitle = feishu.title
                    initialValue = try feishu.readValue(helper: self, requireFocus: false)
                } else {
                    lastEvidence = try withBackgroundTargetRead {
                        try visual.backgroundComposerState(target: chosen, helper: self, title: atomicRequest.title)
                    }
                    initialValue = lastEvidence["background_composer_value"] as? String
                    initialTitle = lastEvidence["background_recipient"] as? String
                }
                guard let initialValue, let initialTitle else { throw fail("background_composer_unverified", "Complete initial chat state is unavailable") }
                let prepared = try atomicRequest.planRequest(request, recipient: initialTitle, before: initialValue)
                request = prepared.request; alreadyEmpty = prepared.alreadyEmpty
                try guarded()
                stages["initial_read"] = (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1000
                if let evidence = lastEvidence["background_evidence_stage_ms"] as? [String: Double] {
                    for (name, value) in evidence { stages["initial_" + name] = value }
                }
            }
            func receipt(operation: String, recipient: String, value: String, empty: Bool, alreadyEmpty: Bool = false) throws -> [String: Any] {
                try scope.verify(chosen, forceFresh: true); try monitor.check()
                for (name, elapsed) in scope.readTiming { stages[name] = elapsed }
                let foregroundPreserved = scope.cache.current()?.userFocus == scope.firstUserFocus && scope.cache.current()?.userControlToken == scope.firstUserControlToken
                stages["total"] = (ProcessInfo.processInfo.systemUptime - commandStarted) * 1000
                var result: [String: Any] = ["app": bundle, "operation": operation, "target_pid": chosen.pid,
                    "window_title": chosen.expectedTitle ?? "", "chat_title": recipient,
                    "window_id": scope.binding.target.window.windowID, "events_posted": events,
                    "notification_events_posted": notifications, "mouse_events_posted": mouseEvents, "key_events_posted": keyEvents,
                    "ax_actions_attempted": axActionCount, "ax_menu_actions_attempted": menuActionCount,
                    "ax_composer_focus_actions_attempted": composerFocusCount,
                    "value_verified": true, "draft_value": value,
                    "read_only_evidence_refreshes": visualEvidenceRefreshes,
                    "recipient_verified": true, "composer_complete": true,
                    "draft_empty": empty, "already_empty": alreadyEmpty, "atomic_chat_edit": atomic,
                    "foreground_preserved": foregroundPreserved, "foreground_app_window_control_preserved": foregroundPreserved,
                    "focus_isolated": scope.cache.current()?.userFocus.map { $0.pid != chosen.pid } ?? false,
                    "external_focus_change_detected": !foregroundPreserved,
                    "foreign_pointer_events_allowed": monitor.foreignPointerEventsAllowed,
                    "pointer_preserved": pointerBefore == CGEvent(source: nil)?.location,
                    "input_route": route, "input_scope": "target_application_background", "activated_foreground": false,
                    "verification_source": feishu != nil ? "complete_AX_composer_and_exact_recipient" : "new_complete_target_window_frame_composer_and_exact_recipient",
                    "automatic_replay_allowed": false, "send_verified": false, "native_stage_ms": stages,
                    "user_focused_pid": scope.firstUserFocus?.pid ?? 0, "user_focused_window_id": scope.firstUserFocus?.windowID ?? 0,
                    "user_control_verified_absent": scope.cache.current()?.userControlVerifiedAbsent ?? false,
                    "user_focus_source": scope.cache.current()?.userFocusSource ?? "unavailable"]
                if let atomicRequest {
                    let draft = try atomicRequest.plainValue(value, recipient: recipient)
                    result["draft"] = draft; result["draft_text"] = draft
                }
                result.merge(clipboard?.receipt ?? ["temporary_clipboard_used": false, "clipboard_restored": false,
                    "clipboard_external_change": false, "clipboard_isolated": true]) { _, new in new }
                if let evidence = lastEvidence["background_evidence_stage_ms"] { result["last_evidence_stage_ms"] = evidence }
                return result
            }
            if alreadyEmpty {
                return try receipt(operation: "clear", recipient: initialTitle!, value: initialValue!, empty: true, alreadyEmpty: true)
            }
            let plan = try legacyPlan ?? BackgroundChatPlan(request, bundle: bundle)
            var controlRect: CGRect
            var bindingSnapshot: String? = nil
            if let feishu {
                controlRect = feishu.composerRect
            }
            else if atomic {
                controlRect = try visualRect(lastEvidence["background_control_rect"])
            } else {
                guard try string(request, "control_kind") == "chat_composer", try boolean(request, "confirm_control") else {
                    throw fail("background_composer_unverified", "WeChat requires a confirmed chat_composer rectangle")
                }
                controlRect = try visualRect(request["control_rect"], name: "control_rect")
                bindingSnapshot = try string(request, "snapshot_id")!
            }
            guard visualContains(scope.binding.target.window.frame, controlRect) else { throw fail("background_composer_unverified", "Composer lies outside the selected window") }
            func renewReadOnlyEvidence(_ read: () throws -> [String: Any]) throws {
                try guarded()
                guard let oldTime = lastEvidence["background_evidence_frame_time"] as? Double,
                      let oldSerial = lastEvidence["frame_complete_serial"] as? Int else {
                    throw fail("background_evidence_expired", "Complete original frame identity is unavailable")
                }
                let started = ProcessInfo.processInfo.systemUptime
                defer {
                    stages["evidence_refresh_count"] = Double(visualEvidenceRefreshes)
                    stages["evidence_refresh"] = (stages["evidence_refresh"] ?? 0) + (ProcessInfo.processInfo.systemUptime - started) * 1000
                }
                lastEvidence = try renewBackgroundVisualEvidence(previousTime: oldTime, previousSerial: oldSerial,
                    attempts: &visualEvidenceRefreshes, read: read, now: { ProcessInfo.processInfo.systemUptime })
                try guarded()
            }
            func validateVisualEvidence(_ values: [String], focused: Bool) throws -> String {
                guard lastEvidence["background_composer_verified"] as? Bool == true,
                      lastEvidence["background_recipient_verified"] as? Bool == true,
                      let value = lastEvidence["background_composer_value"] as? String, values.contains(value),
                      let stamp = lastEvidence["background_evidence_frame_time"] as? Double,
                      ProcessInfo.processInfo.systemUptime >= stamp, ProcessInfo.processInfo.systemUptime - stamp <= 2,
                      let measured = try? visualRect(lastEvidence["background_control_rect"]),
                      visualContains(measured, controlRect) else {
                    throw fail("background_composer_unverified", "Fresh complete WeChat composer and recipient proof is unavailable")
                }
                if focused {
                    guard axElement(chosen.axApplication, kAXFocusedWindowAttribute).map({ CFEqual($0, chosen.window) }) == true else {
                        throw fail("background_internal_focus_unverified", "The selected WeChat window lost internal key focus")
                    }
                }
                try guarded()
                return value
            }
            func observe(_ values: [String], focused: Bool) throws -> String {
                try guarded()
                if let feishu { return try feishu.observe(helper: self, allowed: values, requireFocus: focused) }
                // A fresh target-owned frame is authoritative. When checking a
                // pending asynchronous edit, only its two exact endpoint values
                // are accepted; a failed capture is never input evidence.
                let candidate = values.last!
                func readVisual() throws -> [String: Any] {
                    do {
                        return try self.withBackgroundTargetRead(enabled: atomic) {
                            try self.visual.backgroundComposerEvidence(target: chosen, helper: self,
                                title: plan.recipient, expected: candidate, bindingSnapshotID: bindingSnapshot)
                        }
                    } catch let error as HelperError where error.code == "background_draft_changed" && values.count > 1 {
                        bindingSnapshot = nil
                        return try self.withBackgroundTargetRead(enabled: atomic) {
                            try self.visual.backgroundComposerEvidence(target: chosen, helper: self,
                                title: plan.recipient, expected: values[0])
                        }
                    }
                }
                lastEvidence = try readVisual()
                bindingSnapshot = nil
                if let stamp = lastEvidence["background_evidence_frame_time"] as? Double,
                   stamp.isFinite, ProcessInfo.processInfo.systemUptime - stamp > 2 {
                    try renewReadOnlyEvidence(readVisual)
                }
                return try validateVisualEvidence(values, focused: focused)
            }
            func emit(_ event: CGEvent, kind: String) {
                event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                event.setIntegerValueField(.eventSourceUserData, value: self.monitor.marker)
                event.postToPid(chosen.pid)
                events += 1
                if kind == "notification" { notifications += 1 }
                else if kind == "mouse" { mouseEvents += 1 }
                else { keyEvents += 1 }
            }
            func post(_ event: CGEvent, kind: String) throws {
                try guarded(); emit(event, kind: kind)
            }
            func key(_ code: CGKeyCode, _ flags: CGEventFlags, _ down: Bool, _ units: [UniChar] = []) throws -> CGEvent {
                guard feishu == nil, let source,
                      let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                    throw fail("event_creation_failed", "Could not construct targeted keyboard event")
                }
                event.flags = flags
                if !units.isEmpty { units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) } }
                return event
            }
            func guardVisualEvidence() throws {
                try guarded()
                if let stamp = lastEvidence["background_evidence_frame_time"] as? Double,
                   stamp.isFinite, ProcessInfo.processInfo.systemUptime - stamp > 2 {
                    // Only a new read, bound to the same complete draft/title.
                    // A notification or mouse event already posted is never replayed.
                    try renewReadOnlyEvidence {
                        try self.withBackgroundTargetRead(enabled: atomic) {
                            try self.visual.backgroundComposerEvidence(target: chosen, helper: self,
                                title: plan.recipient, expected: plan.before)
                        }
                    }
                    _ = try validateVisualEvidence([plan.before], focused: mouseEvents > 0)
                }
                guard let stamp = lastEvidence["background_evidence_frame_time"] as? Double,
                      ProcessInfo.processInfo.systemUptime >= stamp, ProcessInfo.processInfo.systemUptime - stamp <= 2 else {
                    throw fail("background_evidence_expired", "Complete composer/recipient proof expired before input; do not replay")
                }
            }
            if !atomic { _ = try observe([plan.before], focused: false) }
            if feishu == nil { try guardVisualEvidence() }
            phaseStarted = ProcessInfo.processInfo.systemUptime
            if let feishu {
                guard CGPreflightPostEventAccess(), let mouseSource = CGEventSource(stateID: .privateState) else {
                    throw fail("post_event_unavailable", "Existing post-event permission and private mouse source are required")
                }
                try performBackgroundFeishuComposerClick(source: mouseSource, window: scope.binding.target.window,
                    composer: controlRect, verifyBefore: {
                        _ = try observe([plan.before], focused: false)
                        try scope.verify(chosen, forceFresh: true); try monitor.check()
                    }, post: { emit($0, kind: $0.type.rawValue == 13 ? "notification" : "mouse") })
                try performBackgroundFeishuComposerFocus(writability: {
                    var writable = DarwinBoolean(false)
                    let result = AXUIElementIsAttributeSettable(feishu.composer, kAXFocusedAttribute as CFString, &writable)
                    return (result, writable.boolValue)
                }, verifyBefore: {
                    _ = try observe([plan.before], focused: false)
                    try scope.verify(chosen, forceFresh: true); try monitor.check()
                }, setFocused: {
                    axActionCount += 1; composerFocusCount += 1
                    return AXUIElementSetAttributeValue(feishu.composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                })
            } else {
                try post(backgroundFocusNotification(), kind: "notification")
                _ = CFRunLoopRunInMode(.defaultMode, 0.08, true)
                let point = CGPoint(x: controlRect.minX + min(12, controlRect.width / 2), y: controlRect.midY)
                for down in [true, false] {
                    try guardVisualEvidence()
                    try post(backgroundWindowMouse(down: down, point: point, window: scope.binding.target.window), kind: "mouse")
                }
            }
            if feishu == nil { _ = CFRunLoopRunInMode(.defaultMode, 0.08, true) }
            _ = try observe([plan.before], focused: true)
            stages["establish_focus_and_read"] = (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1000
            phaseStarted = ProcessInfo.processInfo.systemUptime
            func menuAction(_ action: BackgroundFeishuMenuAction) throws {
                guard feishu != nil else { throw fail("background_target_unsupported", "Menu editing requires Feishu") }
                _ = try observe([plan.before], focused: true)
                let item = try backgroundFeishuMenuElement(target: chosen, action: action)
                try verifyDisplayTopology(chosen)
                try scope.verify(chosen, forceFresh: true); try monitor.check()
                if action == .paste {
                    guard let clipboard else { throw fail("background_clipboard_unavailable", "Paste requires this command's temporary clipboard lease") }
                    try clipboard.verifyOwnership()
                }
                // Count attempted AX actions even when the application returns
                // failure: dispatch may have happened and must not be replayed.
                menuActionCount += 1; axActionCount += 1
                if action != .selectAll { menuEditAttempted = true }
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                guard result == .success else {
                    throw fail("background_menu_action_failed", "The exact Edit menu action failed; do not replay", ["ax_result": result.rawValue])
                }
            }
            func waitFeishuValue(_ expected: [String]) throws -> String {
                guard let feishu, menuEditAttempted else {
                    throw fail("background_postcondition_unknown", "Read-only settling requires an already posted Feishu edit")
                }
                return try waitBackgroundFeishuValue(expected: expected, read: {
                    try guarded()
                    return try feishu.readValue(helper: self, requireFocus: true)
                }, pause: {
                    let started = ProcessInfo.processInfo.systemUptime
                    _ = CFRunLoopRunInMode(.defaultMode, 0.04, false)
                    stages["post_input_read_settle"] = (stages["post_input_read_settle"] ?? 0) + (ProcessInfo.processInfo.systemUptime - started) * 1000
                }, now: { ProcessInfo.processInfo.systemUptime })
            }
            if feishu == nil {
                try guardVisualEvidence()
                guard let stamp = lastEvidence["background_evidence_frame_time"] as? Double else {
                    throw fail("background_evidence_expired", "Missing complete post-click composer proof")
                }
                try performBackgroundVisualBurst(plan: plan, evidenceTime: stamp, guardTarget: guarded,
                    post: { code, flags, down, units in try emit(key(code, flags, down, units), kind: "key") },
                    now: { ProcessInfo.processInfo.systemUptime })
            } else {
                if plan.operation == "type" {
                    let lease = BackgroundClipboardLease(BackgroundSystemPasteboard())
                    clipboard = lease
                    try lease.stage(String(decoding: plan.parts.flatMap { $0 }, as: UTF16.self))
                }
                try performBackgroundFeishuMenuEdit(operation: plan.operation, action: menuAction, selectionPause: {
                    _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
                })
            }
            stages["input"] = (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1000
            phaseStarted = ProcessInfo.processInfo.systemUptime
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var final = plan.before
            if feishu != nil {
                final = try waitFeishuValue(plan.afterValues)
                // Release the temporary shared clipboard immediately after the
                // complete editor postcondition, before receipt-only reads.
                try clipboard?.finish()
            } else {
                repeat {
                    _ = CFRunLoopRunInMode(.defaultMode, 0.02, true)
                    final = try observe(plan.afterValues, focused: true)
                    if plan.afterValues.contains(final) { break }
                } while ProcessInfo.processInfo.systemUptime < deadline
            }
            guard plan.afterValues.contains(final) else { throw fail("background_postcondition_unknown", "Complete final composer value was not verified; do not replay") }
            stages["final_read"] = (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1000
            return try receipt(operation: plan.operation, recipient: plan.recipient, value: final, empty: plan.operation == "clear")
        } catch {
            clipboard?.restore()
            let error = error as? HelperError ?? fail("background_context_unavailable", String(describing: error))
            var details = error.details
            details.merge(clipboard?.receipt ?? ["temporary_clipboard_used": false, "clipboard_restored": false,
                "clipboard_external_change": false, "clipboard_isolated": true]) { _, new in new }
            details.merge(["events_posted": events, "notification_events_posted": notifications,
                "mouse_events_posted": mouseEvents, "key_events_posted": keyEvents, "value_verified": false,
                "ax_actions_attempted": axActionCount, "ax_menu_actions_attempted": menuActionCount,
                "ax_composer_focus_actions_attempted": composerFocusCount,
                "read_only_evidence_refreshes": visualEvidenceRefreshes,
                "input_may_be_partial": keyEvents > 0 || menuEditAttempted || (bundle == "com.bytedance.macos.feishu" && mouseEvents > 0), "automatic_replay_allowed": false,
                "input_route": route, "send_verified": false, "native_stage_ms": stages,
                "atomic_chat_edit": atomic]) { _, new in new }
            throw fail(error.code, error.message, details)
        }
    }
}


extension DesktopHelper {
    func backgroundTypeText(_ request: [String: Any]) throws -> [String: Any] {
        let app = try string(request, "app")!
        if ["com.bytedance.macos.feishu", "com.tencent.xinWeChat"].contains(app) {
            // Preserve the chat adapter's exact notification/mouse/key counts.
            return try backgroundChatInput(request, bundle: app)
        }
        var events = 0
        do {
            guard app == "com.apple.TextEdit" else {
                throw fail("background_backend_unverified", "Background input supports the exact TextEdit, Feishu and WeChat adapters")
            }
            _ = try string(request, "window_title")!
            let text = try string(request, "text")!
            guard let before = try string(request, "expected_before", required: false),
                  let after = try string(request, "expected_after", required: false) else {
                throw fail("invalid_request", "Full expected_before and expected_after strings are required, including empty values")
            }
            let plan = try BackgroundTextPlan(text: text, before: before, after: after)
            let chosen = try target(request)
            let control = try cached(request, target: chosen)
            let scope = try BackgroundCommandScope(target: chosen, control: control, mode: .targetedBackground)
            guard let userFocus = scope.firstUserFocus else { throw fail("input_focus_unknown", "The current user's focused window is unavailable") }
            guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState) else {
                throw fail("post_event_unavailable", "Existing post-event permission and a private event source are required")
            }
            try monitor.beginScoped(mode: .targetedBackground, target: scope.binding.target, cache: scope.cache)
            backgroundScope = scope; scope.start()
            defer { scope.stop(); backgroundScope = nil; monitor.end() }
            func guarded() throws {
                try monitor.check(); try verifyDisplayTopology(chosen)
                try scope.verify(chosen, forceFresh: true); try monitor.check()
            }
            func observe() throws -> BackgroundTextState {
                guard let value = axString(control, kAXValueAttribute), value.utf16.count <= 65536,
                      let range = axSelectedRange(control) else {
                    throw fail("background_value_unavailable", "The complete bounded AX value and UTF-16 selection are required")
                }
                return BackgroundTextState(value: value, caret: range.location, selectionLength: range.length)
            }
            try performBackgroundText(plan: plan, observe: observe, guardTarget: guarded, post: { part, down in
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
                    throw fail("event_creation_failed", "Could not construct a targeted Unicode event")
                }
                event.flags = []
                part.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
                event.setIntegerValueField(.eventSourceUserData, value: self.monitor.marker)
                try self.monitor.check()
                event.postToPid(chosen.pid)
            }, pause: { _ = CFRunLoopRunInMode(.defaultMode, 0.02, true) },
                now: { ProcessInfo.processInfo.systemUptime }, events: &events)
            try guarded()
            guard try observe().value == after else { throw fail("background_postcondition_unknown", "Final complete AX value changed after posting; do not replay") }
            return ["app": chosen.bundleID, "target_pid": chosen.pid, "window_id": scope.binding.target.window.windowID,
                "events_posted": events, "value_verified": true, "foreground_preserved": scope.cache.current()?.userFocus == scope.firstUserFocus,
                "activated_foreground": false,
                "input_route": "CGEvent.postToPid_privateState", "input_scope": "target_application_background",
                "automatic_replay_allowed": false, "send_verified": false,
                "target_display_ids": scope.binding.target.window.screenIDs.sorted(),
                "user_focused_pid": userFocus.pid, "user_focused_window_id": userFocus.windowID,
                "user_display_ids": userFocus.screenIDs.sorted()]
        } catch {
            let underlying = error as? HelperError ?? fail("background_context_unavailable", String(describing: error))
            var details = underlying.details
            details["events_posted"] = events; details["value_verified"] = false
            details["input_may_be_partial"] = events > 0; details["automatic_replay_allowed"] = false
            details["input_route"] = "CGEvent.postToPid_privateState"
            throw fail(underlying.code, underlying.message, details)
        }
    }
}

func backgroundInputSelfTests() -> [String: Any] {
    var tests: [[String: Any]] = []
    func check(_ name: String, _ pass: Bool) { tests.append(["name": name, "passed": pass]) }
    for item in backgroundEvidenceRenewalSelfTests()["tests"] as? [[String: Any]] ?? [] {
        check("visual_evidence_renewal_" + (item["name"] as? String ?? "unknown"), item["passed"] as? Bool == true)
    }
    for item in backgroundWindowKeySelfTests()["tests"] as? [[String: Any]] ?? [] {
        check("window_key_" + (item["name"] as? String ?? "unknown"), item["passed"] as? Bool == true)
    }
    for item in backgroundFeishuBurstSelfTests()["tests"] as? [[String: Any]] ?? [] {
        check("feishu_burst_" + (item["name"] as? String ?? "unknown"), item["passed"] as? Bool == true)
    }
    for item in scopedWindowIDMatchSelfTests() {
        check("window_ID_" + (item["name"] as? String ?? "unknown"), item["passed"] as? Bool == true)
    }
    for item in backgroundFeishuComposerFocusSelfTests() {
        check("feishu_composer_focus_" + (item["name"] as? String ?? "unknown"), item["passed"] as? Bool == true)
    }
    for item in backgroundFeishuComposerClickSelfTests() {
        check("feishu_composer_click_" + (item["name"] as? String ?? "unknown"), item["passed"] as? Bool == true)
    }
    func errorCode(_ body: () throws -> Void) -> String { do { try body(); return "none" } catch { return (error as? HelperError)?.code ?? "other" } }
    func editabilityOK(_ result: AXError, _ enabled: Bool?, _ settable: AXError = .success, _ writable: Bool? = true,
                       _ bundle: String = "com.apple.TextEdit", _ role: String = "AXTextArea") -> Bool {
        (try? scopedEditability(bundle: bundle, role: role, enabledResult: result, enabled: enabled,
            settableResult: settable, valueSettable: writable)) != nil
    }
    let actualUnsupported = try? scopedEditability(bundle: "com.apple.TextEdit", role: "AXTextArea",
        enabledResult: .attributeUnsupported, enabled: nil, settableResult: .success, valueSettable: true)
    check("actual_TextEdit_unsupported_enabled_positive_writability", actualUnsupported != nil && actualUnsupported?.enabled == nil && actualUnsupported?.textEditWritableValue == true)
    check("explicit_enabled_false_always_denied", !editabilityOK(.success, false))
    check("enabled_success_missing_boolean_denied", !editabilityOK(.success, nil))
    check("unsupported_enabled_readonly_value_denied", !editabilityOK(.attributeUnsupported, nil, .success, false))
    check("supported_enabled_readonly_TextEdit_value_denied", !editabilityOK(.success, true, .success, false))
    check("unsupported_value_settable_attribute_denied", !editabilityOK(.attributeUnsupported, nil, .attributeUnsupported, nil))
    check("settable_AX_error_denied", !editabilityOK(.attributeUnsupported, nil, .cannotComplete, nil))
    check("enabled_noValue_not_treated_as_unsupported", !editabilityOK(.noValue, nil))
    check("enabled_cannotComplete_not_treated_as_unsupported", !editabilityOK(.cannotComplete, nil))
    check("enabled_notImplemented_not_treated_as_unsupported", !editabilityOK(.notImplemented, nil))
    check("unsupported_enabled_other_app_not_extrapolated", !editabilityOK(.attributeUnsupported, nil, .success, true, "com.bytedance.macos.feishu"))
    check("unsupported_enabled_other_role_not_extrapolated", !editabilityOK(.attributeUnsupported, nil, .success, true, "com.apple.TextEdit", "AXTextField"))
    check("supported_enabled_writable_TextEdit_preserved", editabilityOK(.success, true))
    check("absent_system_focus_accepts_direct_owner", scopedSystemFocusCompatible(systemPID: nil, systemFrontmost: nil, actualPID: 200))
    check("stale_nonfrontmost_AX_app_accepts_direct_owner", scopedSystemFocusCompatible(systemPID: 100, systemFrontmost: false, actualPID: 200))
    check("contradictory_active_AX_app_rejected", !scopedSystemFocusCompatible(systemPID: 100, systemFrontmost: true, actualPID: 200))
    check("unknown_AX_frontmost_conflict_rejected", !scopedSystemFocusCompatible(systemPID: 100, systemFrontmost: nil, actualPID: 200))
    check("missing_actual_owner_always_rejected", !scopedSystemFocusCompatible(systemPID: nil, systemFrontmost: nil, actualPID: 0))
    var optionalReads = 0
    func metadataCode(_ body: () throws -> Void) -> String {
        do { try body(); return "none" }
        catch ScopedContextError.unavailable(let reason) { return reason }
        catch { return "other" }
    }
    check("actual_TextEdit_TextArea_missing_Subrole_not_queried", metadataCode {
        let value: String? = try scopedOptionalMetadata("AXSubrole", advertised: ["AXRole", "AXValue"]) { optionalReads += 1; return (.cannotComplete, nil) }
        if value != nil { throw ScopedContextError.unavailable("unexpected") }
    } == "none" && optionalReads == 0)
    check("actual_TextEdit_ScrollArea_missing_protected_not_queried", metadataCode {
        let value: Bool? = try scopedOptionalMetadata("AXProtectedContent", advertised: ["AXRole", "AXParent"]) { optionalReads += 1; return (.cannotComplete, nil) }
        if value != nil { throw ScopedContextError.unavailable("unexpected") }
    } == "none" && optionalReads == 0)
    check("actual_TextEdit_Window_advertised_subrole_read", (try? scopedOptionalMetadata("AXSubrole", advertised: ["AXSubrole"]) { (.success, "AXStandardWindow") }) == "AXStandardWindow")
    check("advertised_optional_attributeUnsupported_allowed", metadataCode {
        let _: String? = try scopedOptionalMetadata("AXSubrole", advertised: ["AXSubrole"]) { (.attributeUnsupported, nil) }
    } == "none")
    check("advertised_optional_noValue_is_absence", metadataCode {
        let _: String? = try scopedOptionalMetadata("AXSubrole", advertised: ["AXSubrole"]) { (.noValue, nil) }
    } == "none")
    for result in [AXError.cannotComplete, .notImplemented, .apiDisabled] {
        check("advertised_optional_error_\(result.rawValue)_not_ignored", metadataCode {
            let _: String? = try scopedOptionalMetadata("AXSubrole", advertised: ["AXSubrole"]) { (result, nil) }
        } == "AX_AXSubrole_\(result.rawValue)")
    }
    check("advertised_optional_success_nil_not_proof", metadataCode {
        let _: String? = try scopedOptionalMetadata("AXSubrole", advertised: ["AXSubrole"]) { (.success, nil) }
    } != "none")
    for item in [("AXSecureTextField", nil as String?, nil as Bool?), ("AXTextArea", "AXSecureTextField", nil), ("AXTextArea", nil, true)] {
        check("secure_metadata_denied_\(tests.count)", metadataCode { try scopedSecureMetadata(role: item.0, subrole: item.1, protected: item.2) } == "secure_field_denied")
    }
    check("ordinary_TextArea_absent_optional_metadata_allowed", metadataCode { try scopedSecureMetadata(role: "AXTextArea", subrole: nil, protected: nil) } == "none")
    check("missing_role_not_proof", metadataCode { try scopedSecureMetadata(role: "", subrole: nil, protected: nil) } == "AXRole_invalid")
    do {
        let recipient = "验收人", suffix = "\u{200b}\n\u{200b}\n\u{200b}"
        let empty = "发送给 " + recipient + "\n" + suffix
        let request: [String: Any] = ["operation": "type", "expected_recipient": recipient,
            "expected_before": empty, "expected_after": "后台中文" + suffix, "text": "后台中文"]
        let plan = try BackgroundChatPlan(request, bundle: "com.bytedance.macos.feishu")
        check("Feishu_complete_serialization_plan", plan.parts.count == 1 && plan.typedValue(plan.parts[0]) == "后台中文" + suffix)
        for field in ["operation", "expected_recipient", "expected_before", "expected_after", "text"] {
            var missing = request; missing.removeValue(forKey: field)
            check("chat_missing_" + field + "_rejected", errorCode { _ = try BackgroundChatPlan(missing, bundle: "com.bytedance.macos.feishu") } != "none")
        }
        var changed = request; changed["expected_before"] = "用户草稿" + suffix
        check("chat_preserves_existing_draft", errorCode { _ = try BackgroundChatPlan(changed, bundle: "com.bytedance.macos.feishu") } == "background_expected_after_mismatch")
        for (field, value) in [("allow_submit", true as Any), ("key", "return" as Any), ("modifiers", ["cmd"] as Any)] {
            var denied = request; denied[field] = value
            check("chat_" + field + "_denied", errorCode { _ = try BackgroundChatPlan(denied, bundle: "com.bytedance.macos.feishu") } == "background_submit_denied")
        }
        let clear: [String: Any] = ["operation": "clear", "expected_recipient": recipient,
            "expected_before": "后台中文" + suffix, "expected_after": empty]
        check("Feishu_clear_complete_before_and_empty", try BackgroundChatPlan(clear, bundle: "com.bytedance.macos.feishu").parts.isEmpty)
        let wx: [String: Any] = ["operation": "type", "chat_title": recipient, "expected_before": "", "expected_after": "中文", "text": "中文"]
        check("WeChat_type_complete_value", try BackgroundChatPlan(wx, bundle: "com.tencent.xinWeChat").after == "中文")
        let wxClear: [String: Any] = ["operation": "clear", "chat_title": recipient, "expected_before": "中文", "expected_after": ""]
        check("WeChat_clear_exact_empty", try BackgroundChatPlan(wxClear, bundle: "com.tencent.xinWeChat").after.isEmpty)
        let burstPlan = try BackgroundChatPlan(wx, bundle: "com.tencent.xinWeChat")
        var posted: [(CGKeyCode, CGEventFlags, Bool, [UniChar])] = []
        try performBackgroundVisualBurst(plan: burstPlan, evidenceTime: 10, guardTarget: {},
            post: { posted.append(($0, $1, $2, $3)) }, now: { 10.1 })
        check("visual_burst_one_unicode_pair_no_capture_callback", posted.count == 2 && posted.allSatisfy { $0.0 == 0 && $0.1.isEmpty && String(decoding: $0.3, as: UTF16.self) == "中文" })
        let clearPlan = try BackgroundChatPlan(wxClear, bundle: "com.tencent.xinWeChat")
        posted = []
        try performBackgroundVisualBurst(plan: clearPlan, evidenceTime: 10, guardTarget: {},
            post: { posted.append(($0, $1, $2, $3)) }, now: { 10.1 })
        check("visual_clear_burst_four_events_no_Return", posted.map { $0.0 } == [0, 0, 51, 51] && posted.prefix(2).allSatisfy { $0.1 == .maskCommand } && posted.suffix(2).allSatisfy { $0.1.isEmpty } && posted.allSatisfy { $0.3.isEmpty })
        for stopping in 1...4 {
            var guards = 0, count = 0
            let result = errorCode {
                try performBackgroundVisualBurst(plan: clearPlan, evidenceTime: 10, guardTarget: {
                    guards += 1
                    if guards == stopping { throw fail("user_interrupted", "fixture") }
                }, post: { _, _, _, _ in count += 1 }, now: { 10.1 })
            }
            check("visual_burst_takeover_boundary_\(stopping)", result == "user_interrupted" && count == stopping - 1)
        }
        var expiryPosts = 0, tick = 10.1
        let expired = errorCode {
            try performBackgroundVisualBurst(plan: burstPlan, evidenceTime: 10, guardTarget: {},
                post: { _, _, _, _ in expiryPosts += 1; tick = 12.01 }, now: { tick })
        }
        check("visual_burst_expiry_stops_no_replay", expired == "background_evidence_expired" && expiryPosts == 1)
        for invalid in [Double.nan, 9, 12.01] {
            var count = 0
            let result = errorCode {
                try performBackgroundVisualBurst(plan: burstPlan, evidenceTime: 10, guardTarget: {},
                    post: { _, _, _, _ in count += 1 }, now: { invalid })
            }
            check("visual_burst_invalid_lease_zero_events_\(tests.count)", result == "background_evidence_expired" && count == 0)
        }
        let notification = try backgroundFocusNotification()
        check("notification_unposted_exact_type_subtype", NSEvent(cgEvent: notification)?.type.rawValue == 13 && NSEvent(cgEvent: notification)?.subtype.rawValue == 1)
        let fakeWindow = ScopedWindowFocus(pid: 7, windowID: 42, frame: CGRect(x: -1200, y: 50, width: 900, height: 800), screenIDs: [2])
        let mouse = try backgroundWindowMouse(down: true, point: CGPoint(x: -700, y: 740), window: fakeWindow)
        check("window_bound_mouse_unposted_roundtrip", mouse.location == CGPoint(x: -700, y: 740) && NSEvent(cgEvent: mouse)?.windowNumber == 42 && mouse.getIntegerValueField(CGEventField(rawValue: 91)!) == 42 && mouse.getIntegerValueField(CGEventField(rawValue: 92)!) == 42)
        if let library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) {
            defer { dlclose(library) }
            if let symbol = dlsym(library, "CGEventGetWindowLocation") {
                let local = unsafeBitCast(symbol, to: (@convention(c)(CGEvent) -> CGPoint).self)
                check("window_bound_mouse_negative_origin_top_left_local", local(mouse) == CGPoint(x: 500, y: 690))
                let rightWindow = ScopedWindowFocus(pid: 7, windowID: 43, frame: CGRect(x: 1857, y: 161, width: 855, height: 1079), screenIDs: [3])
                let rightMouse = try backgroundWindowMouse(down: false, point: CGPoint(x: 2203, y: 1130), window: rightWindow)
                check("window_bound_mouse_right_display_points_unscaled", local(rightMouse) == CGPoint(x: 346, y: 969) && rightMouse.location == CGPoint(x: 2203, y: 1130))
            } else { check("window_bound_mouse_local_getter_available", false) }
        } else { check("window_bound_mouse_local_library_available", false) }
    } catch { check("chat_plan_or_event_construction", false) }
    let layout = ScopedDisplayLayout(displays: [ScopedDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1792, height: 1120)),
        ScopedDisplay(id: 2, bounds: CGRect(x: 1792, y: 0, width: 1920, height: 1200))], signature: "mixed2x1x")
    let targetWindow = ScopedWindowFocus(pid: 100, windowID: 9, frame: CGRect(x: 1900, y: 100, width: 646, height: 418), screenIDs: [2])
    let target = ScopedBackgroundTarget(window: targetWindow, processLaunchTime: 1, controlID: UUID(), topologySignature: layout.signature)
    let foreign = ScopedWindowFocus(pid: 200, windowID: 8, frame: CGRect(x: 66, y: 25, width: 1714, height: 1095), screenIDs: [1])
    func context(_ variant: String = "") -> ScopedInputContext {
        let user: ScopedWindowFocus?
        switch variant {
        case "unknown": user = nil
        case "targetpid": user = ScopedWindowFocus(pid: 100, windowID: 8, frame: foreign.frame, screenIDs: [1])
        case "same": user = ScopedWindowFocus(pid: 200, windowID: 8, frame: CGRect(x: 2000, y: 20, width: 200, height: 200), screenIDs: [2])
        case "seam": user = ScopedWindowFocus(pid: 200, windowID: 8, frame: CGRect(x: 1700, y: 20, width: 200, height: 200), screenIDs: [1, 2])
        case "lyingScreens": user = ScopedWindowFocus(pid: 200, windowID: 8, frame: foreign.frame, screenIDs: [2])
        case "gap": user = ScopedWindowFocus(pid: 200, windowID: 8, frame: CGRect(x: -20, y: 10, width: 100, height: 100), screenIDs: [1])
        case "zeroid": user = ScopedWindowFocus(pid: 200, windowID: 0, frame: foreign.frame, screenIDs: [1])
        case "foreignSwitch": user = ScopedWindowFocus(pid: 300, windowID: 7, frame: CGRect(x: 50, y: 50, width: 1000, height: 1000), screenIDs: [1])
        default: user = foreign
        }
        let evidence = ScopedTargetEvidence(target: target, internalFocusedWindowID: variant == "wrongWindow" ? 10 : 9,
            focusedControlID: variant == "wrongControl" ? UUID() : target.controlID,
            controlPID: variant == "wrongControlPID" ? 300 : 100, controlWindowID: variant == "wrongControlWindow" ? 10 : 9,
            controlRole: variant == "shell" ? "AXWindow" : "AXTextArea", enabled: variant != "disabled", protected: variant == "secure")
        return ScopedInputContext(startedAt: variant == "stale" ? 9 : 9.9,
            completedAt: variant == "future" ? 10.1 : (variant == "reversed" ? 9.8 : 9.95), target: evidence, userFocus: user,
            layout: variant == "hotplug" ? ScopedDisplayLayout(displays: layout.displays, signature: "changed") : layout,
            pointerWindows: [ScopedPointerWindow(pid: foreign.pid, windowID: foreign.windowID, frame: foreign.frame),
                ScopedPointerWindow(pid: targetWindow.pid, windowID: targetWindow.windowID, frame: targetWindow.frame)])
    }
    func decide(_ mode: ScopedInputMode = .targetedBackground, _ event: ScopedInputEvent, _ variant: String = "") -> ScopedInputDecision {
        let sample = context(variant)
        return ScopedInputPolicy.decide(mode: mode, event: event, target: target, context: sample,
            pointerContext: ScopedPointerContext(startedAt: sample.startedAt, completedAt: sample.completedAt,
                target: sample.target.target, layout: sample.layout, windows: sample.pointerWindows))
    }
    let key = ScopedInputEvent(kind: .keyDown, observedAt: 10, keyCode: 53, targetPID: 0, pointer: CGPoint(x: 2200, y: 100))
    check("foreign_keyboard_owner_uses_AX_not_pointer", decide(.targetedBackground, key) == .allow)
    check("foreign_escape_does_not_claim_target", decide(.targetedBackground, key) == .allow)
    check("shared_isolated_escape_does_not_yield", decide(.sharedHID, key) == .allow)
    for kind in [ScopedInputKind.keyDown, .keyUp, .modifiers] {
        check("keyboard_\(kind)_targetPIDzero_foreign_focus_allowed", decide(.targetedBackground, ScopedInputEvent(kind: kind, observedAt: 10)) == .allow)
        check("keyboard_\(kind)_targetPIDforeign_corrob_allowed", decide(.targetedBackground, ScopedInputEvent(kind: kind, observedAt: 10, targetPID: 200)) == .allow)
        check("keyboard_\(kind)_targetPIDtarget_denied", decide(.targetedBackground, ScopedInputEvent(kind: kind, observedAt: 10, targetPID: 100)) == .interrupt("manual_input_targeted_application"))
        check("keyboard_\(kind)_other_foreign_PID_does_not_claim_target", decide(.targetedBackground, ScopedInputEvent(kind: kind, observedAt: 10, targetPID: 300)) == .allow)
    }
    for variant in ["unknown", "targetpid", "lyingScreens", "zeroid", "wrongWindow", "wrongControl", "wrongControlPID", "wrongControlWindow", "shell", "disabled", "secure", "stale", "future", "reversed", "hotplug"] {
        check("background_\(variant)_denied", decide(.targetedBackground, key, variant) != .allow)
    }
    for variant in ["same", "seam", "gap"] {
        check("different_application_keyboard_\(variant)_display_allowed",decide(.targetedBackground,key,variant) == .allow)
    }
    check("fresh_foreign_window_switch_other_screen_allowed", decide(.targetedBackground, ScopedInputEvent(kind: .keyDown, observedAt: 10, targetPID: 300), "foreignSwitch") == .allow)
    check("readonly_secure_target_denied_by_target_guard", ScopedInputPolicy.contextFailure(context("secure"), target: target, at: 10, requireEditable: false) == "secure_field_denied")
    check("readonly_Qt_shell_no_editable_focus_requirement", decide(.readOnly, key, "shell") == .allow)
    check("readonly_target_evidence_cannot_be_input_authority", ScopedInputPolicy.contextFailure(context("shell"), target: target, at: 10, requireEditable: true) == "background_internal_focus_unverified")
    check("readonly_foreign_focus_absence_still_denies_actual_input", ScopedInputPolicy.contextFailure(context("unknown"), target: target, at: 10, requireEditable: true) == "input_focus_unknown")
    check("readonly_unknown_user_focus_does_not_interrupt", decide(.readOnly, key, "unknown") == .allow)
    for variant in ["unknown", "targetpid", "same", "seam", "foreignSwitch", "shell", "disabled"] {
        check("readonly_\(variant)_does_not_require_user_focus_or_editability",
            ScopedInputPolicy.contextFailure(context(variant), target: target, at: 10, requireEditable: false) == nil)
    }
    check("readonly_hotplug_still_denied", ScopedInputPolicy.contextFailure(context("hotplug"), target: target, at: 10, requireEditable: false) == "input_target_changed")
    check("readonly_no_monitor_dependency", decide(.readOnly, ScopedInputEvent(kind: .monitorDisabled, observedAt: 10)) == .allow)
    for kind in [ScopedInputKind.pointerButton, .pointerDrag, .scroll, .pointerMove] {
        check("pointer_\(kind)_foreign_screen_allowed", decide(.targetedBackground, ScopedInputEvent(kind: kind, observedAt: 10, targetPID: 200, pointer: CGPoint(x: 100, y: 100), sustainedMovement: true)) == .allow)
        let targetHover = kind == .pointerMove
        check("pointer_\(kind)_target_window_" + (targetHover ? "hover_allowed" : "denied"),
            decide(.targetedBackground, ScopedInputEvent(kind: kind, observedAt: 10, pointer: CGPoint(x: 1900, y: 100), sustainedMovement: true)) == (targetHover ? .allow : .interrupt("pointer_on_target_window")))
    }
    var overlapped=context("same")
    overlapped.pointerWindows=[ScopedPointerWindow(pid:200,windowID:8,frame:overlapped.userFocus!.frame),ScopedPointerWindow(pid:100,windowID:9,frame:targetWindow.frame)]
    var overlapClick=ScopedInputEvent(kind:.pointerButton,observedAt:10,targetPID:200,pointer:CGPoint(x:2050,y:150))
    func overlapDecision() -> ScopedInputDecision {
        ScopedInputPolicy.decide(mode: .targetedBackground, event: overlapClick, target: target, context: overlapped,
            pointerContext: ScopedPointerContext(startedAt: overlapped.startedAt, completedAt: overlapped.completedAt,
                target: target, layout: overlapped.layout, windows: overlapped.pointerWindows))
    }
    check("same_screen_actual_foreground_window_pointer_allowed", overlapDecision() == .allow)
    overlapped.pointerWindows.reverse()
    check("same_screen_target_window_pointer_stops", overlapDecision() == .interrupt("pointer_on_target_window"))
    overlapped.pointerWindows=[ScopedPointerWindow(pid:300,windowID:77,frame:targetWindow.frame)]
    overlapClick.targetPID = 300
    check("verified_foreign_overlay_pointer_does_not_claim_target", overlapDecision() == .allow)
    check("single_mouse_movement_not_takeover", decide(.targetedBackground, ScopedInputEvent(kind: .pointerMove, observedAt: 10, pointer: CGPoint(x: 1900, y: 100))) == .allow)
    check("pointer_unknown_denied", decide(.targetedBackground, ScopedInputEvent(kind: .scroll, observedAt: 10)) == .interrupt("pointer_location_unknown"))
    check("pointer_offscreen_denied", decide(.targetedBackground, ScopedInputEvent(kind: .scroll, observedAt: 10, pointer: CGPoint(x: -100, y: 1))) == .interrupt("pointer_display_unknown"))
    check("shared_foreign_key_up_does_not_yield", decide(.sharedHID, ScopedInputEvent(kind: .keyUp, observedAt: 10)) == .allow)
    check("shared_foreign_isolated_scroll_does_not_yield", decide(.sharedHID, ScopedInputEvent(kind: .scroll, observedAt: 10, pointer: CGPoint(x: 100, y: 100))) == .allow)
    check("monitor_disabled_stops", decide(.targetedBackground, ScopedInputEvent(kind: .monitorDisabled, observedAt: 10)) == .interrupt("input_monitor_disabled"))
    check("own_marker_ignored", decide(.targetedBackground, ScopedInputEvent(kind: .keyDown, observedAt: 10, ownMarker: true, targetPID: 100), "unknown") == .allow)
    check("display_boundary_halfopen", layout.screens(at: CGPoint(x: 1792, y: 100)) == [2])
    check("mixedscale_union_seam", layout.screens(for: CGRect(x: 1350, y: 33, width: 855, height: 1079)) == [1, 2])
    let negative = ScopedDisplayLayout(displays: [ScopedDisplay(id: 1, bounds: CGRect(x: -1920, y: -300, width: 1920, height: 1200)), ScopedDisplay(id: 2, bounds: CGRect(x: 0, y: 0, width: 1792, height: 1120))], signature: "negative")
    check("negative_display_coordinates", negative.screens(for: CGRect(x: -1800, y: -250, width: 600, height: 400)) == [1])
    check("topology_gap_denied", negative.screens(for: CGRect(x: -100, y: -200, width: 200, height: 400)) == nil)
    check("readonly_partial_display_coverage_allowed", negative.screens(for: CGRect(x: -100, y: -200, width: 200, height: 400), requireFullCoverage: false) == [1, 2])
    check("readonly_fully_offscreen_still_denied", negative.screens(for: CGRect(x: 100, y: -400, width: 100, height: 100), requireFullCoverage: false) == nil)
    let mirrored = ScopedDisplayLayout(displays: [ScopedDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)), ScopedDisplay(id: 2, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))], signature: "mirror")
    check("mirror_union_not_doublecounted", mirrored.screens(for: CGRect(x: 0, y: 0, width: 100, height: 100)) == [1, 2])
    let cache = ScopedInputContextCache(); let ticket = cache.ticket()
    check("cache_publish_current_generation", cache.publish(context(), ticket: ticket) && cache.current() != nil)
    cache.invalidate()
    check("cache_old_async_cannot_restore_invalidated_focus", !cache.publish(context(), ticket: ticket) && cache.current() == nil)
    check("background_visual_read_wire_schema_accepted", errorCode { try VisualDesktop().validate(["command": "background_visual_read", "confirm_target": false]) } == "none")
    do {
        let text = String(repeating: "中", count: 19) + "😀" + "文"
        let plan = try BackgroundTextPlan(text: text, before: "前", after: "前" + text)
        check("unicode_surrogate_boundary_not_split", plan.parts.map { $0.count } == [19, 3])
        check("unicode_exact_roundtrip", plan.parts.flatMap { $0 } == Array(text.utf16))
        for bad in ["", "\n", "\r", "\t", "a\u{0000}", "\u{001b}", String(repeating: "中", count: 4097)] {
            check("text_reject_\(bad.utf16.count)_\(tests.count)", errorCode { _ = try BackgroundTextPlan(text: bad, before: "", after: bad) } == "background_text_denied")
        }
        check("after_must_be_exact_append", errorCode { _ = try BackgroundTextPlan(text: "中", before: "前", after: "中") } == "background_expected_after_mismatch")
        for state in [BackgroundTextState(value: "wrong", caret: 5, selectionLength: 0), BackgroundTextState(value: "前", caret: 0, selectionLength: 0), BackgroundTextState(value: "前", caret: 1, selectionLength: 1)] {
            var events = 0, posts = 0
            check("wrong_value_or_selection_zeroevents_\(tests.count)", errorCode { try performBackgroundText(plan: plan, observe: { state }, guardTarget: {}, post: { _, _ in posts += 1 }, pause: {}, now: { 0 }, events: &events) } == "background_value_or_selection_changed" && events == 0 && posts == 0)
        }
        let short = try BackgroundTextPlan(text: "中文😀", before: "", after: "中文😀")
        for boundary in 1...6 {
            var events = 0, posted = 0, guardCount = 0, value = ""
            let code = errorCode { try performBackgroundText(plan: short, observe: { BackgroundTextState(value: value, caret: value.utf16.count, selectionLength: 0) }, guardTarget: {
                guardCount += 1; if guardCount == boundary { throw fail("synthetic_takeover", "stop") }
            }, post: { part, down in posted += 1; if down { value += String(decoding: part, as: UTF16.self) } }, pause: {}, now: { 0 }, events: &events) }
            check("takeover_guard_\(boundary)_bounded_no_replay", code == "synthetic_takeover" && events == posted && posted <= 2 && (boundary <= 3 ? posted == 0 : true))
        }
        var events = 0, sequence: [Bool] = [], value = ""
        try performBackgroundText(plan: short, observe: { BackgroundTextState(value: value, caret: value.utf16.count, selectionLength: 0) }, guardTarget: {}, post: { part, down in sequence.append(down); if down { value += String(decoding: part, as: UTF16.self) } }, pause: {}, now: { 0 }, events: &events)
        check("post_exactly_one_pair_and_verify_full_after", events == 2 && sequence == [true, false] && value == short.after)
        events = 0; var clock: Double = 0; var postCount = 0
        let unknown = errorCode { try performBackgroundText(plan: short, observe: { BackgroundTextState(value: "", caret: 0, selectionLength: 0) }, guardTarget: {}, post: { _, _ in postCount += 1 }, pause: { clock += 0.5 }, now: { clock }, events: &events) }
        check("no_effect_unknown_never_replays", unknown == "background_postcondition_unknown" && events == 2 && postCount == 2)
        events = 0; postCount = 0
        let failure = errorCode { try performBackgroundText(plan: short, observe: { BackgroundTextState(value: "", caret: 0, selectionLength: 0) }, guardTarget: {}, post: { _, _ in postCount += 1; throw fail("synthetic_post_failure", "failed before API") }, pause: {}, now: { 0 }, events: &events) }
        check("post_error_no_retry_no_unposted_release", failure == "synthetic_post_failure" && events == 0 && postCount == 1)
    } catch { tests.append(["name": "unexpected_error", "passed": false, "error": String(describing: error)]) }
    return ["ok": tests.allSatisfy { $0["passed"] as? Bool == true }, "case_count": tests.count, "cases": tests,
        "events_posted": 0, "capture_executed": false, "live_AX_read_executed": false]
}
