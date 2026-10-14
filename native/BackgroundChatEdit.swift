import AppKit
import ApplicationServices

// The observed official-assistant decoration is a small, separately grouped
// label beside the complete title. The word alone never identifies a badge.
func backgroundFeishuOfficialHeaderBadge(value: String, bounds: CGRect,
                                        parentGroup: CGRect?, inButton: Bool,
                                        primaryBounds: CGRect) -> Bool {
    guard value == "官方", !inButton, let group = parentGroup,
          bounds.width > 2, bounds.width <= 32, bounds.height > 2, bounds.height <= 14,
          bounds.height <= primaryBounds.height * 0.8,
          group.width > 0, group.width <= 40, group.height > 0, group.height <= 20,
          group.contains(bounds), group.minX >= primaryBounds.maxX,
          bounds.minX >= primaryBounds.maxX + 2, bounds.minX - primaryBounds.maxX <= 128,
          bounds.minY >= primaryBounds.minY, bounds.maxY <= primaryBounds.maxY,
          abs(bounds.midY - primaryBounds.midY) <= 2 else { return false }
    return true
}

enum BackgroundFeishuMenuAction: String {
    case paste = "粘贴", selectAll = "全选", delete = "删除"
}

// The only allowed menu edits. A failed or unknown action is never replayed.
func performBackgroundFeishuMenuEdit(operation: String,
                                    action: (BackgroundFeishuMenuAction) throws -> Void,
                                    selectionPause: () -> Void) throws {
    if operation == "type" { try action(.paste) }
    else if operation == "clear" {
        try action(.selectAll)
        selectionPause()
        try action(.delete)
    } else { throw fail("invalid_request", "Only type or clear is a menu edit") }
}

struct BackgroundFeishuMenuRow {
    let pid: pid_t
    let role: String?
    let title: String?
    let secure: Bool
}

func backgroundFeishuMenuIndex(_ rows: [BackgroundFeishuMenuRow], pid: pid_t,
                              role: String, title: String?) throws -> Int {
    guard rows.count <= 128,
          rows.allSatisfy({ $0.pid == pid && $0.role != nil && !$0.secure }) else {
        throw fail("background_menu_unverified", "Menu ancestry has an unknown or protected owner")
    }
    let matches = rows.indices.filter { rows[$0].role == role && (title == nil || rows[$0].title == title) }
    guard matches.count == 1 else { throw fail("background_menu_unverified", "Exactly one bound Edit menu action is required") }
    return matches[0]
}

func backgroundFeishuMenuElement(target: Target, action: BackgroundFeishuMenuAction) throws -> AXUIElement {
    guard target.bundleID == "com.bytedance.macos.feishu",
          let menuBar = axElement(target.axApplication, kAXMenuBarAttribute) else {
        throw fail("background_menu_unverified", "The bound Feishu menu bar is unavailable")
    }
    func row(_ element: AXUIElement) throws -> BackgroundFeishuMenuRow {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            throw fail("background_menu_unverified", "Menu owner is unavailable")
        }
        let metadata = axMetadataAttributes(element)
        return BackgroundFeishuMenuRow(pid: pid, role: metadata.string("AXRole"),
                                      title: metadata.string("AXTitle"), secure: metadata.isSecure)
    }
    let root = try row(menuBar)
    _ = try backgroundFeishuMenuIndex([root], pid: target.pid, role: "AXMenuBar", title: nil)
    func child(_ parent: AXUIElement, role: String, title: String?) throws -> AXUIElement {
        let list = axNavigationChildren(parent, limit: 128, counts: axChildCounts(parent))
        guard !list.truncated else { throw fail("background_menu_unverified", "Menu children are incomplete") }
        let index = try backgroundFeishuMenuIndex(list.elements.map(row), pid: target.pid, role: role, title: title)
        let element = list.elements[index]
        guard axElement(element, kAXParentAttribute).map({ CFEqual($0, parent) }) == true else {
            throw fail("background_menu_unverified", "Menu action left its exact ancestry")
        }
        return element
    }
    let edit = try child(menuBar, role: "AXMenuBarItem", title: "编辑")
    let submenu = try child(edit, role: "AXMenu", title: nil)
    let item = try child(submenu, role: "AXMenuItem", title: action.rawValue)
    let (enabledValue, enabledResult) = axBooleanResult(item, kAXEnabledAttribute)
    let enabled = enabledResult == .success ? enabledValue : nil
    var actionNames: CFArray?
    let actionsResult = AXUIElementCopyActionNames(item, &actionNames)
    let allActions = actionsResult == .success ? actionNames as? [String] : nil
    let actions = Array((allActions ?? []).prefix(32))
    guard enabled == true, actions.contains(kAXPressAction) else {
        // Only fixed menu structure and AX results are exposed, never composer
        // text. Unknown enabled/actions remain distinct from false/empty.
        throw fail("background_menu_unverified", "The exact Edit menu action is disabled or cannot be pressed", [
            "menu_ancestry": ["编辑", action.rawValue], "menu_owner_pid": target.pid,
            "menu_enabled": enabled.map { $0 as Any } ?? NSNull(),
            "menu_enabled_ax_result": enabledResult.rawValue,
            "menu_actions": allActions.map { Array($0.prefix(32)) as Any } ?? NSNull(),
            "menu_actions_count": allActions.map { $0.count as Any } ?? NSNull(),
            "menu_actions_truncated": (allActions?.count ?? 0) > 32,
            "menu_actions_ax_result": actionsResult.rawValue])
    }
    return item
}

// Opaque clipboard bytes are held only for this command, never in receipts,
// diagnostic strings, persistent storage, or text logs.
typealias BackgroundPasteboardSnapshot = [[String: Data]]
protocol BackgroundPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func snapshot(maxBytes: Int) throws -> BackgroundPasteboardSnapshot
    func declareText() -> Int
    func writeText(_ text: String) -> Bool
    func clear() -> Int
    func writeSnapshot(_ items: BackgroundPasteboardSnapshot) -> Bool
}

final class BackgroundSystemPasteboard: BackgroundPasteboardAccess {
    private let pasteboard = NSPasteboard.general
    var changeCount: Int { pasteboard.changeCount }
    func snapshot(maxBytes: Int) throws -> BackgroundPasteboardSnapshot {
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= 256 else { throw fail("background_clipboard_unavailable", "Clipboard snapshot exceeds its bound") }
        var bytes = 0, formats = 0
        return try items.map { item in
            var copy: [String: Data] = [:]
            for type in item.types {
                formats += 1
                guard formats <= 4096, let data = item.data(forType: type), data.count <= maxBytes - bytes else {
                    throw fail("background_clipboard_unavailable", "A complete bounded clipboard snapshot is unavailable")
                }
                bytes += data.count; copy[type.rawValue] = data
            }
            return copy
        }
    }
    func declareText() -> Int { pasteboard.declareTypes([.string], owner: nil) }
    func writeText(_ text: String) -> Bool { pasteboard.setString(text, forType: .string) }
    func clear() -> Int { pasteboard.clearContents() }
    func writeSnapshot(_ items: BackgroundPasteboardSnapshot) -> Bool {
        if items.isEmpty { return true }
        var copies: [NSPasteboardItem] = []
        for values in items {
            let item = NSPasteboardItem()
            for (name, data) in values {
                guard item.setData(data, forType: NSPasteboard.PasteboardType(name)) else { return false }
            }
            copies.append(item)
        }
        return pasteboard.writeObjects(copies)
    }
}

final class BackgroundClipboardLease {
    private let pasteboard: BackgroundPasteboardAccess
    private var saved: BackgroundPasteboardSnapshot = []
    private var ownedCount: Int?
    private var restoreAttempts = 0
    private(set) var used = false
    private(set) var restored = false
    private(set) var externalChange = false
    init(_ pasteboard: BackgroundPasteboardAccess) { self.pasteboard = pasteboard }
    deinit { restore() }
    func stage(_ text: String) throws {
        guard !used else { throw fail("background_clipboard_unavailable", "A clipboard stage cannot be replayed") }
        let count = pasteboard.changeCount
        saved = try pasteboard.snapshot(maxBytes: 16 * 1024 * 1024)
        guard pasteboard.changeCount == count else {
            saved = []; externalChange = true
            throw fail("background_clipboard_changed", "Clipboard changed during the opaque snapshot; no paste")
        }
        used = true
        ownedCount = pasteboard.declareText()
        let success = pasteboard.writeText(text)
        try verifyOwnership()
        guard success else { throw fail("background_clipboard_unavailable", "Temporary clipboard text could not be staged") }
    }
    func verifyOwnership() throws {
        guard let ownedCount, pasteboard.changeCount == ownedCount else {
            externalChange = true; self.ownedCount = nil; saved = []
            throw fail("background_clipboard_changed", "Clipboard ownership changed; no paste or overwrite")
        }
    }
    // Retry only restoration of this command's own still-owned clipboard,
    // never an editor action. A foreign change revokes restoration authority.
    func restore() {
        while let count = ownedCount, restoreAttempts < 2 {
            guard pasteboard.changeCount == count else {
                externalChange = true; ownedCount = nil; saved = []; return
            }
            restoreAttempts += 1
            let restoringCount = pasteboard.clear()
            ownedCount = restoringCount
            let success = pasteboard.writeSnapshot(saved)
            guard pasteboard.changeCount == restoringCount else {
                externalChange = true; ownedCount = nil; saved = []; return
            }
            if success { restored = true; ownedCount = nil; saved = []; return }
        }
    }
    func finish() throws {
        restore()
        guard !used || restored || externalChange else {
            throw fail("background_clipboard_restore_failed", "The owned clipboard could not be restored; do not replay the edit")
        }
    }
    var receipt: [String: Any] {
        ["temporary_clipboard_used": used, "clipboard_restored": restored,
         "clipboard_external_change": externalChange, "clipboard_isolated": false]
    }
}

private func backgroundFeishuMenuSelfTests() -> [[String: Any]] {
    var rows: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { rows.append(["name": "menu_" + name, "passed": value]) }
    func refuses(_ code: String, _ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return (error as? HelperError)?.code == code }
    }
    func row(_ title: String, pid: pid_t = 7, role: String? = "AXMenuItem", secure: Bool = false) -> BackgroundFeishuMenuRow {
        BackgroundFeishuMenuRow(pid: pid, role: role, title: title, secure: secure)
    }
    check("exact_title_only", (try? backgroundFeishuMenuIndex([row("粘贴并匹配样式"), row("粘贴")], pid: 7, role: "AXMenuItem", title: "粘贴")) == 1)
    for (name, values) in [("duplicate", [row("粘贴"), row("粘贴")]), ("wrong_owner", [row("粘贴", pid: 8)]),
                           ("unknown_role", [row("粘贴", role: nil)]), ("wrong_role", [row("粘贴", role: "AXButton")]),
                           ("protected", [row("粘贴", secure: true)]), ("wrong_title", [row("粘贴并匹配样式")])] {
        check(name, refuses("background_menu_unverified") { _ = try backgroundFeishuMenuIndex(values, pid: 7, role: "AXMenuItem", title: "粘贴") })
    }
    check("oversized_tree", refuses("background_menu_unverified") {
        _ = try backgroundFeishuMenuIndex(Array(repeating: row("粘贴"), count: 129), pid: 7, role: "AXMenuItem", title: "粘贴")
    })
    var trace: [String] = []
    try? performBackgroundFeishuMenuEdit(operation: "type", action: { trace.append("fresh_before_scope_" + $0.rawValue) }, selectionPause: { trace.append("pause") })
    check("one_whole_paste", trace == ["fresh_before_scope_粘贴"])
    trace = []
    try? performBackgroundFeishuMenuEdit(operation: "clear", action: { trace.append("fresh_before_scope_" + $0.rawValue) }, selectionPause: { trace.append("selection_settle") })
    check("clear_two_independent_guards", trace == ["fresh_before_scope_全选", "selection_settle", "fresh_before_scope_删除"])
    for failure in ["background_draft_changed", "user_interrupted", "background_target_changed", "background_menu_action_failed"] {
        var actions = 0
        let denied = refuses(failure) {
            try performBackgroundFeishuMenuEdit(operation: "clear", action: { _ in actions += 1; throw fail(failure, "fixture") }, selectionPause: {})
        }
        check("no_replay_" + failure, denied && actions == 1)
    }
    var deletes = 0
    check("changed_before_delete", refuses("background_draft_changed") {
        try performBackgroundFeishuMenuEdit(operation: "clear", action: { action in
            if action == .delete { throw fail("background_draft_changed", "fixture") }
            deletes += 1
        }, selectionPause: {})
    } && deletes == 1)
    check("unknown_operation_no_action", refuses("invalid_request") {
        try performBackgroundFeishuMenuEdit(operation: "send", action: { _ in deletes += 1 }, selectionPause: {})
    } && deletes == 1)

    final class FakePasteboard: BackgroundPasteboardAccess {
        var changeCount = 1
        var values: BackgroundPasteboardSnapshot = [["binary": Data([0, 255]), "text": Data([65])], ["other": Data([9])]]
        var snapshotFails = false, changeOnSnapshot = false, writeFails = false, changeOnStage = false
        var restoreFailures = 0, changeOnRestore = false, clears = 0, writes = 0
        func snapshot(maxBytes: Int) throws -> BackgroundPasteboardSnapshot {
            if snapshotFails { throw fail("background_clipboard_unavailable", "fixture") }
            if changeOnSnapshot { changeCount += 1 }
            guard values.flatMap({ $0.values }).reduce(0, { $0 + $1.count }) <= maxBytes else { throw fail("background_clipboard_unavailable", "fixture") }
            return values
        }
        func declareText() -> Int { changeCount += 1; values = []; return changeCount }
        func writeText(_ text: String) -> Bool {
            writes += 1; values = [["text": Data(text.utf8)]]
            if changeOnStage { changeCount += 1; values = [["foreign": Data([8])]] }
            return !writeFails
        }
        func clear() -> Int { clears += 1; changeCount += 1; values = []; return changeCount }
        func writeSnapshot(_ items: BackgroundPasteboardSnapshot) -> Bool {
            if changeOnRestore { changeCount += 1; values = [["foreign": Data([8])]]; return false }
            if restoreFailures > 0 { restoreFailures -= 1; return false }
            values = items; return true
        }
    }
    do {
        let p = FakePasteboard(), original = p.values, lease = BackgroundClipboardLease(p)
        try? lease.stage("后台🙂"); try? lease.finish(); lease.restore()
        check("opaque_all_formats_restored_once", lease.used && lease.restored && !lease.externalChange && p.values == original && p.clears == 1)
        check("stage_not_replayed", refuses("background_clipboard_unavailable") { try lease.stage("再次") } && p.writes == 1)
        check("receipt_has_no_clipboard_data", Set(lease.receipt.keys) == Set(["temporary_clipboard_used", "clipboard_restored", "clipboard_external_change", "clipboard_isolated"]))
    }
    for snapshotFailure in [true, false] {
        let p = FakePasteboard(); p.snapshotFails = snapshotFailure; p.changeOnSnapshot = !snapshotFailure
        let lease = BackgroundClipboardLease(p)
        let denied = refuses(snapshotFailure ? "background_clipboard_unavailable" : "background_clipboard_changed") { try lease.stage("文字") }
        lease.restore()
        check(snapshotFailure ? "incomplete_snapshot_no_write" : "changed_snapshot_no_write", denied && !lease.used && p.writes == 0 && p.clears == 0)
    }
    do {
        let p = FakePasteboard(); p.values = [["oversized": Data(count: 16 * 1024 * 1024 + 1)]]
        let lease = BackgroundClipboardLease(p)
        check("snapshot_byte_limit", refuses("background_clipboard_unavailable") { try lease.stage("文字") } && p.writes == 0)
    }
    do {
        let p = FakePasteboard(), original = p.values; p.writeFails = true
        let lease = BackgroundClipboardLease(p)
        let denied = refuses("background_clipboard_unavailable") { try lease.stage("文字") }
        lease.restore(); check("stage_failure_restores_owned_clipboard", denied && lease.restored && p.values == original)
    }
    for duringStage in [true, false] {
        let p = FakePasteboard(); p.changeOnStage = duringStage
        let lease = BackgroundClipboardLease(p)
        try? lease.stage("文字")
        if !duringStage { p.changeCount += 1; p.values = [["foreign": Data([8])]] }
        let foreign = p.values
        lease.restore()
        check(duringStage ? "changed_during_stage_no_overwrite" : "foreign_copy_no_overwrite", lease.externalChange && !lease.restored && p.clears == 0 && p.values == foreign)
    }
    do {
        let p = FakePasteboard(), original = p.values, lease = BackgroundClipboardLease(p)
        try? lease.stage("文字"); p.restoreFailures = 1; try? lease.finish()
        check("failed_restore_one_owned_retry", lease.restored && p.clears == 2 && p.values == original)
    }
    do {
        let p = FakePasteboard(), lease = BackgroundClipboardLease(p)
        try? lease.stage("文字"); p.restoreFailures = 5
        let denied = refuses("background_clipboard_restore_failed") { try lease.finish() }; lease.restore()
        check("restore_failure_bounded", denied && !lease.restored && p.clears == 2)
    }
    do {
        let p = FakePasteboard(), lease = BackgroundClipboardLease(p)
        try? lease.stage("文字"); p.changeOnRestore = true; lease.restore()
        check("foreign_change_during_restore_stops_retry", lease.externalChange && !lease.restored && p.clears == 1 && p.values == [["foreign": Data([8])]])
    }
    do {
        let p = FakePasteboard(), original = p.values
        var lease: BackgroundClipboardLease? = BackgroundClipboardLease(p)
        try? lease?.stage("文字"); lease = nil
        check("failure_exit_fallback_restore", p.values == original && p.clears == 1)
    }
    for failure in ["user_interrupted", "background_target_changed", "background_draft_changed", "background_postcondition_unknown"] {
        let p = FakePasteboard(), original = p.values, lease = BackgroundClipboardLease(p)
        var actions = 0, clock: Double = 0
        let denied = refuses(failure) {
            defer { lease.restore() }
            try lease.stage("授权完整正文")
            try performBackgroundFeishuMenuEdit(operation: "type", action: { _ in
                try lease.verifyOwnership(); actions += 1
            }, selectionPause: {})
            _ = try waitBackgroundFeishuValue(expected: ["complete"], read: {
                if failure != "background_postcondition_unknown" { throw fail(failure, "fixture") }
                return "transitional"
            }, pause: { clock += 0.75 }, now: { clock })
        }
        check("postcondition_failure_restores_without_replay_" + failure, denied && actions == 1 && lease.restored && p.values == original)
    }
    do {
        let p = FakePasteboard(), lease = BackgroundClipboardLease(p)
        var actions = 0
        try? lease.stage("文字"); p.changeCount += 1; p.values = [["foreign": Data([7])]]
        let foreign = p.values
        let denied = refuses("background_clipboard_changed") {
            try performBackgroundFeishuMenuEdit(operation: "type", action: { _ in
                try lease.verifyOwnership(); actions += 1
            }, selectionPause: {})
        }
        lease.restore()
        check("foreign_copy_before_paste_zero_action", denied && actions == 0 && p.values == foreign && p.clears == 0)
    }
    return rows
}

private struct BackgroundFeishuDiscoveryRoleUnavailable: Error {
    let result: AXError
}

private func backgroundFeishuDiscoveryRole(_ metadata: AXMetadataAttributes) throws -> String {
    guard !metadata.isSecure else { throw fail("secure_field_denied", "Protected semantic node") }
    guard let role = metadata.string("AXRole") else {
        throw BackgroundFeishuDiscoveryRoleUnavailable(result: metadata.attributes["AXRole"]?.result ?? .failure)
    }
    return role
}

// Only pre-input discovery may rebuild, once, after a role-less AX node. A
// failed traversal contributes no candidates to the fresh traversal. Security,
// identity, ownership and all other errors propagate without retry.
private func backgroundFeishuDiscovery<Value>(read: (TimeInterval) throws -> Value,
        beforeRebuild: () throws -> Void, pause: () -> Void,
        now: () -> TimeInterval) throws -> Value {
    let deadline = now() + 1.5
    var firstRoleResult: AXError?
    func checkDeadline() throws {
        guard now() < deadline else { throw fail("background_composer_unverified", "Bounded Feishu semantic discovery timed out") }
    }
    for attempt in 0..<2 {
        try checkDeadline()
        do {
            let value = try read(deadline)
            try checkDeadline()
            return value
        } catch let missing as BackgroundFeishuDiscoveryRoleUnavailable {
            guard attempt == 0 else {
                throw fail("background_composer_unverified", "Feishu semantic node role remains unavailable after a complete read-only rebuild",
                    ["failed_guard": "semantic_node_role", "ax_result": missing.result.rawValue,
                     "initial_ax_result": firstRoleResult?.rawValue ?? missing.result.rawValue, "discovery_attempts": 2])
            }
            firstRoleResult = missing.result
            pause()
            try checkDeadline()
            try beforeRebuild()
        }
    }
    throw fail("background_composer_unverified", "Complete Feishu semantic discovery is unavailable")
}

private func backgroundFeishuDiscoverySelfTests() -> [[String: Any]] {
    var tests: [[String: Any]] = []
    func check(_ name: String, _ pass: Bool) { tests.append(["name": "discovery_" + name, "passed": pass]) }
    func failure(_ body: () throws -> Void) -> HelperError? {
        do { try body(); return nil } catch { return error as? HelperError }
    }
    func metadata(_ role: String?, _ result: AXError, secure: Bool = false) -> AXMetadataAttributes {
        AXMetadataAttributes(attributes: [
            "AXRole": AXMetadataAttributeResult(result: result, value: role as CFString?),
            "AXProtectedContent": AXMetadataAttributeResult(result: .success, value: NSNumber(value: secure))
        ], usedBatch: true)
    }
    var reads = 0, pauses = 0, guards = 0
    let complete = try? backgroundFeishuDiscovery(read: { deadline in
        reads += 1; return deadline
    }, beforeRebuild: { guards += 1 }, pause: { pauses += 1 }, now: { 10 })
    check("complete_first_tree_has_no_retry_or_delay", complete == 11.5 && reads == 1 && pauses == 0 && guards == 0)
    var trace: [String] = [], deadlines: [Double] = []
    let fresh = try? backgroundFeishuDiscovery(read: { deadline -> [String] in
        deadlines.append(deadline)
        // A traversal's candidates are local and cannot survive a failed read.
        var candidates: [String] = []
        trace.append("root")
        if deadlines.count == 1 {
            candidates.append("stale_partial")
            _ = try backgroundFeishuDiscoveryRole(metadata(nil, .invalidUIElement))
        }
        _ = try backgroundFeishuDiscoveryRole(metadata("AXTextArea", .success))
        candidates.append("new_complete")
        return candidates
    }, beforeRebuild: { trace.append("fresh_scope_target") }, pause: { trace.append("settle") }, now: { 10 })
    check("rebuild_discards_partial_tree_and_restarts_from_root", fresh == ["new_complete"] && trace == ["root", "settle", "fresh_scope_target", "root"])
    check("both_traversals_share_original_deadline", deadlines == [11.5, 11.5])
    reads = 0; pauses = 0; guards = 0
    let missing = failure {
        _ = try backgroundFeishuDiscovery(read: { _ -> String in
            reads += 1
            return try backgroundFeishuDiscoveryRole(metadata(nil, reads == 1 ? .invalidUIElement : .cannotComplete))
        }, beforeRebuild: { guards += 1 }, pause: { pauses += 1 }, now: { 10 })
    }
    check("second_unknown_stops_without_third_tree", missing?.code == "background_composer_unverified" && reads == 2 && pauses == 1 && guards == 1)
    check("unknown_preserves_actual_initial_and_final_AX_errors", missing?.details["ax_result"] as? Int32 == AXError.cannotComplete.rawValue && missing?.details["initial_ax_result"] as? Int32 == AXError.invalidUIElement.rawValue)
    for role in [nil, "AXTextArea"] as [String?] {
        reads = 0; pauses = 0; guards = 0
        let protected = failure {
            _ = try backgroundFeishuDiscovery(read: { _ -> String in
                reads += 1; return try backgroundFeishuDiscoveryRole(metadata(role, .success, secure: true))
            }, beforeRebuild: { guards += 1 }, pause: { pauses += 1 }, now: { 10 })
        }
        check("secure_\(role == nil ? "unknown_role" : "known_role")_never_retried", protected?.code == "secure_field_denied" && reads == 1 && pauses == 0 && guards == 0)
    }
    for reason in ["background_target_changed", "background_recipient_unverified", "user_interrupted"] {
        reads = 0; pauses = 0
        let stopped = failure {
            _ = try backgroundFeishuDiscovery(read: { _ -> String in
                reads += 1; throw fail(reason, "fixture")
            }, beforeRebuild: {}, pause: { pauses += 1 }, now: { 10 })
        }
        check("\(reason)_does_not_rebuild", stopped?.code == reason && reads == 1 && pauses == 0)
    }
    reads = 0
    let changed = failure {
        _ = try backgroundFeishuDiscovery(read: { _ -> String in
            reads += 1; return try backgroundFeishuDiscoveryRole(metadata(nil, .noValue))
        }, beforeRebuild: { throw fail("background_target_changed", "fixture") }, pause: {}, now: { 10 })
    }
    check("failed_fresh_target_guard_prevents_second_traversal", changed?.code == "background_target_changed" && reads == 1)
    for expiredAt in ["pause", "guard", "read"] {
        var time = 10.0
        reads = 0; guards = 0
        let expired = failure {
            _ = try backgroundFeishuDiscovery(read: { _ -> String in
                reads += 1
                if expiredAt == "read" { time = 11.5; return "late_complete" }
                return try backgroundFeishuDiscoveryRole(metadata(nil, .cannotComplete))
            }, beforeRebuild: { guards += 1; if expiredAt == "guard" { time = 11.5 } },
                pause: { if expiredAt == "pause" { time = 11.5 } }, now: { time })
        }
        check("\(expiredAt)_cannot_extend_shared_budget", expired?.code == "background_composer_unverified" && reads == 1 && guards == (expiredAt == "guard" ? 1 : 0))
    }
    return tests
}

func backgroundFeishuBurstSelfTests() -> [String: Any] {
    var tests = backgroundFeishuDiscoverySelfTests() + backgroundFeishuMenuSelfTests()
    func check(_ name: String, _ pass: Bool) { tests.append(["name": name, "passed": pass]) }
    func code(_ action: () throws -> Void) -> String {
        do { try action(); return "none" } catch { return (error as? HelperError)?.code ?? "other" }
    }
    for mode in ["type", "select_all", "delete"] {
        var trace: [String] = [], keys: [(CGKeyCode, CGEventFlags, Bool, [UniChar])] = []
        let part = mode == "type" ? Array("中文🙂".utf16) : nil
        let selectingAll = mode == "select_all"
        let keyCode: CGKeyCode = mode == "delete" ? 51 : 0
        let flags: CGEventFlags = selectingAll ? .maskCommand : []
        let result = code {
            try performBackgroundFeishuBurst(part: part, selectingAll: selectingAll, prepare: { trace.append("complete_before_and_scope"); return 10 },
                guardEvent: { trace.append("guard") }, notify: { trace.append("notification") },
                post: { keys.append(($0, $1, $2, $3)); trace.append("key") }, now: { 10.1 })
        }
        let count = 2
        check("\(mode)_single_full_preflight_before_tight_events", result == "none" && trace == ["complete_before_and_scope", "guard", "notification"] + Array(repeating: ["guard", "key"], count: count).flatMap { $0 })
        check("\(mode)_matching_down_up_no_submit", keys.map { $0.0 } == [keyCode, keyCode] && keys.map { $0.2 } == [true, false])
        check("\(mode)_exact_unicode_or_clear_modifiers", keys.allSatisfy { $0.1 == flags && $0.3 == (part ?? []) })
        for boundary in 1...(count + 1) {
            var checks = 0, posted = 0
            let result = code {
                try performBackgroundFeishuBurst(part: part, selectingAll: selectingAll, prepare: { 10 }, guardEvent: {
                    checks += 1
                    if checks == boundary { throw fail("user_interrupted", "fixture") }
                }, notify: { posted += 1 }, post: { _, _, _, _ in posted += 1 }, now: { 10.1 })
            }
            check("\(mode)_takeover_stops_at_event_\(boundary)_without_replay", result == "user_interrupted" && posted == boundary - 1)
        }
    }
    for draftChanged in [false, true] {
        var trace: [String] = []
        let result = code {
            for selectingAll in [true, false] {
                try performBackgroundFeishuBurst(part: nil, selectingAll: selectingAll, prepare: {
                    trace.append(selectingAll ? "verify_before_select" : "verify_before_delete")
                    if !selectingAll && draftChanged { throw fail("background_draft_changed", "fixture") }
                    return 10
                }, guardEvent: {}, notify: { trace.append("notification") },
                    post: { key, _, down, _ in trace.append("\(key)_\(down)") }, now: { 10.1 })
                if selectingAll { trace.append("settle_readonly") }
            }
        }
        let selection = ["verify_before_select", "notification", "0_true", "0_false", "settle_readonly", "verify_before_delete"]
        check("clear_\(draftChanged)_separate_lease_and_no_replay", draftChanged ? (result == "background_draft_changed" && trace == selection) : (result == "none" && trace == selection + ["notification", "51_true", "51_false"]))
    }
    for time in [Double.nan, 9.9, 10.251] {
        var posted = 0
        let result = code {
            try performBackgroundFeishuBurst(part: [65], prepare: { 10 }, guardEvent: {}, notify: { posted += 1 }, post: { _, _, _, _ in posted += 1 }, now: { time })
        }
        check("invalid_lease_\(tests.count)_zero_events", result == "background_evidence_expired" && posted == 0)
    }
    var time = 10.1, posted = 0
    let expired = code {
        try performBackgroundFeishuBurst(part: [65], prepare: { 10 }, guardEvent: {}, notify: { posted += 1; time = 10.251 }, post: { _, _, _, _ in posted += 1 }, now: { time })
    }
    check("expiry_after_notification_never_posts_or_replays_keys", expired == "background_evidence_expired" && posted == 1)
    for part in [[UniChar](), [UniChar](repeating: 65, count: 129)] {
        var prepared = 0
        let result = code {
            try performBackgroundFeishuBurst(part: part, prepare: { prepared += 1; return 10 }, guardEvent: {}, notify: {}, post: { _, _, _, _ in }, now: { 10.1 })
        }
        check("invalid_chunk_\(part.count)_no_preparation_or_events", result == "background_text_denied" && prepared == 0)
    }
    posted = 0
    let changed = code {
        try performBackgroundFeishuBurst(part: [65], prepare: { throw fail("background_draft_changed", "fixture") }, guardEvent: {}, notify: { posted += 1 }, post: { _, _, _, _ in posted += 1 }, now: { 10.1 })
    }
    check("before_mismatch_never_activates_or_posts", changed == "background_draft_changed" && posted == 0)
    var reads = 0, pauses = 0
    let settled = try? waitBackgroundFeishuValue(expected: ["complete"], read: { reads += 1; return reads == 1 ? "transitional" : "complete" }, pause: { pauses += 1 }, now: { 10 })
    check("post_read_transient_value_only_waits_for_exact_endpoint", settled == "complete" && reads == 2 && pauses == 2)
    var postTrace: [String] = []
    _ = try? waitBackgroundFeishuValue(expected: ["complete"], read: { postTrace.append("full_AX_read"); return "complete" },
        pause: { postTrace.append("actual_settle") }, now: { 10 })
    check("first_posted_read_has_settle_before_AX_IPC", postTrace == ["actual_settle", "full_AX_read"])
    for failure in ["secure_field_denied", "background_draft_changed", "background_internal_focus_unverified", "user_interrupted"] {
        reads = 0; pauses = 0
        let result = code {
            _ = try waitBackgroundFeishuValue(expected: ["complete"], read: { reads += 1; throw fail(failure, "fixture") }, pause: { pauses += 1 }, now: { 10 })
        }
        check("post_read_\(failure)_never_swallowed", result == failure && reads == 1 && pauses == 1)
    }
    reads = 0; time = 10
    let unknown = code {
        _ = try waitBackgroundFeishuValue(expected: ["complete"], read: { reads += 1; return "other" }, pause: { time += 0.75 }, now: { time })
    }
    check("post_read_never_exact_bounded_unknown", unknown == "background_postcondition_unknown" && reads == 3)
    let clear = try? waitBackgroundFeishuValue(expected: ["standard_empty", "voice_empty"], read: { "voice_empty" }, pause: {}, now: { 10 })
    check("clear_accepts_only_supplied_exact_empty_endpoints", clear == "voice_empty")
    return ["ok": tests.allSatisfy { $0["passed"] as? Bool == true }, "count": tests.count,
        "tests": tests, "events_posted": 0, "live_reads": 0]
}

// The atomic command is an editing request, never authority inherited from a
// read-only snapshot. Clear is bound to the caller's complete authorized text.
struct AtomicBackgroundChatEdit {
    let bundle: String
    let operation: String
    let title: String?
    let text: String?
    let expectedBefore: String?
    let expectedDraft: String?
    let windowTitle: String
    static let feishuSuffix = "\u{200b}\n\u{200b}\n\u{200b}"

    init(_ request: [String: Any]) throws {
        bundle = try string(request, "app")!
        guard ["com.tencent.xinWeChat", "com.bytedance.macos.feishu"].contains(bundle) else {
            throw fail("background_target_unsupported", "Atomic chat editing supports only WeChat and Feishu")
        }
        operation = try string(request, "operation")!
        guard ["type", "clear"].contains(operation) else { throw fail("invalid_request", "operation must be type or clear") }
        for forbidden in ["allow_submit", "key", "modifiers", "snapshot_id", "element_id", "recipient_element_id", "expected_recipient", "control_rect", "control_kind", "confirm_control", "expected_after"] {
            guard request[forbidden] == nil else { throw fail("invalid_request", "Atomic chat editing does not accept \(forbidden)") }
        }
        for field in ["kind", "chat_kind"] {
            if let kind = try string(request, field, required: false), kind != "any" {
                throw fail("background_chat_kind_unverified", "Atomic current-chat editing does not infer group/person type from a title")
            }
        }
        title = try string(request, "chat_title", required: false)
        text = try string(request, "text", required: false)
        expectedBefore = try string(request, "expected_before", required: false)
        expectedDraft = try string(request, "expected_draft", required: false)
        windowTitle = try string(request, "window_title", required: false) ?? (bundle == "com.tencent.xinWeChat" ? "微信" : "飞书")
        guard (title?.utf16.count ?? 0) <= 1024,
              title.map({ !$0.isEmpty }) ?? true,
              (expectedBefore?.utf16.count ?? 0) <= 65536,
              (expectedDraft?.utf16.count ?? 0) <= 65536 else { throw fail("invalid_request", "Chat text exceeds its complete-value limit") }
        if operation == "type" {
            guard let text else { throw fail("invalid_request", "Typing requires text") }
            _ = try BackgroundTextPlan(text: text, before: "", after: text)
        } else {
            guard text == nil, expectedBefore != nil || expectedDraft != nil else {
                throw fail("background_clear_values_unverified", "Clear requires an explicit complete expected_draft or expected_before")
            }
        }
    }

    func emptyValues(_ recipient: String) -> [String] {
        if bundle == "com.tencent.xinWeChat" { return [""] }
        let empty = "发送给 " + recipient + "\n" + Self.feishuSuffix
        return [empty, "按住 \nfn \n说话\n" + empty]
    }

    func plainValue(_ raw: String, recipient: String) throws -> String {
        if emptyValues(recipient).contains(raw) { return "" }
        if bundle == "com.tencent.xinWeChat" { return raw }
        guard raw.hasSuffix(Self.feishuSuffix), raw.utf16.count > Self.feishuSuffix.utf16.count else {
            throw fail("background_draft_serialization_unverified", "Feishu draft lacks its exact known composer suffix")
        }
        return String(raw.dropLast(Self.feishuSuffix.count))
    }

    func planRequest(_ request: [String: Any], recipient: String, before: String) throws -> (request: [String: Any], alreadyEmpty: Bool) {
        guard before.utf16.count <= 65536 else { throw fail("background_draft_changed", "Composer value exceeds its complete-value limit") }
        let empty = emptyValues(recipient).contains(before)
        // Empty clear is an observed no-op; a changed nonempty draft is never
        // promoted into the user's authorized value.
        if operation == "clear" && empty { return (request, true) }
        guard expectedBefore.map({ before == $0 }) ?? true else {
            throw fail("background_draft_changed", "The complete current draft differs from expected_before; no input")
        }
        if let expectedDraft {
            guard try plainValue(before, recipient: recipient) == expectedDraft else {
                throw fail("background_draft_changed", "The complete current draft differs from expected_draft; no input")
            }
        }
        if operation == "type" && !empty { throw fail("background_draft_not_empty", "Typing requires a verified empty current composer") }
        var normalized = request
        normalized["expected_before"] = before
        normalized["expected_after"] = operation == "type" ? text! + (bundle == "com.bytedance.macos.feishu" ? Self.feishuSuffix : "") : emptyValues(recipient)[0]
        normalized[bundle == "com.tencent.xinWeChat" ? "chat_title" : "expected_recipient"] = recipient
        return (normalized, false)
    }
}

func atomicBackgroundChatEditSelfTests() -> [String: Any] {
    var rows: [[String: Any]] = []
    func check(_ name: String, _ body: () throws -> Bool) {
        do { rows.append(["name": name, "passed": try body()]) }
        catch { rows.append(["name": name, "passed": false, "error": (error as? HelperError)?.code ?? "unexpected_error"]) }
    }
    func refuses(_ body: () throws -> Void, _ code: String) -> Bool {
        do { try body(); return false } catch { return (error as? HelperError)?.code == code }
    }
    let we = "com.tencent.xinWeChat", fe = "com.bytedance.macos.feishu"
    let typing: [String: Any] = ["app": we, "operation": "type", "text": "后台中文🙂"]
    check("atomic_type_current_recipient_without_snapshot") {
        let a = try AtomicBackgroundChatEdit(typing)
        let q = try a.planRequest(typing, recipient: "当前聊天（5）", before: "").request
        let p = try BackgroundChatPlan(q, bundle: we)
        return p.recipient == "当前聊天（5）" && p.after == "后台中文🙂" && p.before == ""
    }
    check("atomic_type_nonempty_zero_authority") {
        refuses({ _ = try AtomicBackgroundChatEdit(typing).planRequest(typing, recipient: "当前", before: "已有内容") }, "background_draft_not_empty")
    }
    for field in ["snapshot_id", "element_id", "recipient_element_id", "control_rect", "allow_submit", "key", "modifiers", "expected_after"] {
        check("atomic_rejects_" + field) {
            var q = typing; q[field] = "untrusted"
            return refuses({ _ = try AtomicBackgroundChatEdit(q) }, "invalid_request")
        }
    }
    for value in ["line\nbreak", "\t", "\r", ""] {
        check("atomic_submit_control_text_rejected_\(rows.count)") {
            var q = typing; q["text"] = value
            return refuses({ _ = try AtomicBackgroundChatEdit(q) }, "background_text_denied")
        }
    }
    check("clear_requires_explicit_authorized_draft") {
        refuses({ _ = try AtomicBackgroundChatEdit(["app": we, "operation": "clear"]) }, "background_clear_values_unverified")
    }
    check("wechat_clear_whole_exact_draft") {
        let q: [String: Any] = ["app": we, "operation": "clear", "expected_draft": "保留空格 \n完整末行"]
        let a = try AtomicBackgroundChatEdit(q), prepared = try a.planRequest(q, recipient: "当前", before: "保留空格 \n完整末行")
        let p = try BackgroundChatPlan(prepared.request, bundle: we)
        return p.before == "保留空格 \n完整末行" && p.after == "" && !prepared.alreadyEmpty
    }
    check("wechat_clear_unknown_draft_rejected") {
        let q: [String: Any] = ["app": we, "operation": "clear", "expected_draft": "授权草稿"]
        return refuses({ _ = try AtomicBackgroundChatEdit(q).planRequest(q, recipient: "当前", before: "另一份草稿") }, "background_draft_changed")
    }
    check("clear_preserves_business_whitespace") {
        let q: [String: Any] = ["app": we, "operation": "clear", "expected_draft": "文字"]
        return refuses({ _ = try AtomicBackgroundChatEdit(q).planRequest(q, recipient: "当前", before: "文字 ") }, "background_draft_changed")
    }
    check("empty_clear_is_observed_noop") {
        let q: [String: Any] = ["app": we, "operation": "clear", "expected_draft": "已消失的授权草稿"]
        return try AtomicBackgroundChatEdit(q).planRequest(q, recipient: "当前", before: "").alreadyEmpty
    }
    check("feishu_clear_only_known_exact_suffix_removed") {
        let q: [String: Any] = ["app": fe, "operation": "clear", "expected_draft": "正文\u{200b} \n"]
        let raw = "正文\u{200b} \n" + AtomicBackgroundChatEdit.feishuSuffix
        let a = try AtomicBackgroundChatEdit(q), p = try a.planRequest(q, recipient: "当前", before: raw)
        return try BackgroundChatPlan(p.request, bundle: fe).before == raw && a.plainValue(raw, recipient: "当前") == "正文\u{200b} \n"
    }
    check("feishu_unknown_serialization_rejected") {
        let q: [String: Any] = ["app": fe, "operation": "clear", "expected_draft": "正文"]
        return refuses({ _ = try AtomicBackgroundChatEdit(q).planRequest(q, recipient: "当前", before: "正文\u{200b}") }, "background_draft_serialization_unverified")
    }
    check("feishu_type_accepts_exact_voice_placeholder") {
        var q = typing; q["app"] = fe
        let a = try AtomicBackgroundChatEdit(q), p = try a.planRequest(q, recipient: "当前", before: a.emptyValues("当前")[1])
        return try BackgroundChatPlan(p.request, bundle: fe).after == "后台中文🙂" + AtomicBackgroundChatEdit.feishuSuffix
    }
    check("feishu_clear_verifies_both_complete_empty_presentations") {
        let q: [String: Any] = ["app": fe, "operation": "clear", "expected_draft": "待清空"]
        let a = try AtomicBackgroundChatEdit(q)
        let p = try BackgroundChatPlan(a.planRequest(q, recipient: "何越·运维", before: "待清空" + AtomicBackgroundChatEdit.feishuSuffix).request, bundle: fe)
        return p.afterValues == a.emptyValues("何越·运维") && p.afterValues.count == 2 &&
            p.afterValues.allSatisfy { (try? a.plainValue($0, recipient: "何越·运维")) == "" }
    }
    check("feishu_clear_never_accepts_unknown_hint_or_business_text") {
        let q: [String: Any] = ["app": fe, "operation": "clear", "expected_draft": "待清空"]
        let a = try AtomicBackgroundChatEdit(q)
        let p = try BackgroundChatPlan(a.planRequest(q, recipient: "当前", before: "待清空" + AtomicBackgroundChatEdit.feishuSuffix).request, bundle: fe)
        return !p.afterValues.contains("按住说话\n" + p.after) && !p.afterValues.contains("正文" + AtomicBackgroundChatEdit.feishuSuffix) &&
            !p.afterValues.contains(p.after + " ") && !p.afterValues.contains(p.after.replacingOccurrences(of: "当前", with: "另一人"))
    }
    check("typing_keeps_one_exact_final_value") {
        var q = typing; q["app"] = fe
        let a = try AtomicBackgroundChatEdit(q)
        let p = try BackgroundChatPlan(a.planRequest(q, recipient: "当前", before: a.emptyValues("当前")[1]).request, bundle: fe)
        return p.afterValues == ["后台中文🙂" + AtomicBackgroundChatEdit.feishuSuffix]
    }
    check("both_authorizations_must_match") {
        let q: [String: Any] = ["app": we, "operation": "clear", "expected_draft": "正文", "expected_before": "另一份"]
        return refuses({ _ = try AtomicBackgroundChatEdit(q).planRequest(q, recipient: "当前", before: "正文") }, "background_draft_changed")
    }
    check("explicit_recipient_kind_requires_actual_evidence") {
        var q = typing; q["kind"] = "person"
        return refuses({ _ = try AtomicBackgroundChatEdit(q) }, "background_chat_kind_unverified")
    }
    return ["ok": rows.allSatisfy { $0["passed"] as? Bool == true }, "tests": rows, "count": rows.count, "events_posted": 0, "live_AX_reads": 0]
}

extension BackgroundFeishuComposer {
    // Per-command identities only: discovery never caches values or transfers a
    // previous command's authority. Every event still rereads value, ancestry,
    // PID, role, geometry, recipient and required internal focus.
    static func discover(helper: DesktopHelper, target: Target, expectedTitle: String?,
                         beforeRebuild: () throws -> Void) throws -> BackgroundFeishuComposer {
        try backgroundFeishuDiscovery(read: { deadline in
            try discoverOnce(helper: helper, target: target, expectedTitle: expectedTitle, deadline: deadline)
        }, beforeRebuild: beforeRebuild, pause: {
            _ = CFRunLoopRunInMode(.defaultMode, 0.04, false)
        }, now: { ProcessInfo.processInfo.systemUptime })
    }

    private static func discoverOnce(helper: DesktopHelper, target: Target, expectedTitle: String?,
                                     deadline: TimeInterval) throws -> BackgroundFeishuComposer {
        guard let windowRect = axBounds(target.window) else { throw fail("background_target_unverified", "Missing Feishu window geometry") }
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var chats: [(AXUIElement, CGRect)] = []
        func fresh(_ node: AXUIElement) throws -> AXMetadataAttributes {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw fail("background_composer_unverified", "Bounded Feishu semantic discovery timed out") }
            var owner: pid_t = 0
            guard AXUIElementGetPid(node, &owner) == .success, owner == target.pid else {
                throw fail("background_composer_unverified", "Feishu discovery encountered an unknown process owner")
            }
            AXUIElementSetMessagingTimeout(node, 0.15)
            let metadata = axMetadataAttributes(node)
            _ = try backgroundFeishuDiscoveryRole(metadata)
            return metadata
        }
        func children(_ node: AXUIElement) throws -> [AXUIElement] {
            let values = axNavigationChildren(node, limit: 512, counts: axChildCounts(node))
            guard !values.truncated else { throw fail("background_composer_unverified", "Feishu semantic child list was truncated") }
            return values.elements
        }
        var queue: [(AXUIElement, Int)] = [(target.window, 0)], index = 0
        while index < queue.count {
            guard index < 512 else { throw fail("background_composer_unverified", "Feishu semantic discovery exceeded its node bound") }
            let (node, depth) = queue[index]; index += 1
            let hash = CFHash(node)
            if seen[hash]?.contains(where: { CFEqual($0, node) }) == true { continue }
            seen[hash, default: []].append(node)
            let metadata = try fresh(node), role = metadata.string("AXRole")!
            if role == "AXWebArea" {
                if metadata.string("AXTitle") == "messenger-chat", let rect = metadata.bounds, visualContains(windowRect, rect) { chats.append((node, rect)) }
                continue // Other web areas are history/sidebar, not chat owners.
            }
            if ["AXStaticText", "AXButton", "AXRadioButton", "AXToolbar", "AXMenuBar", "AXMenu"].contains(role) { continue }
            let next = try children(node)
            guard depth < 40 || next.isEmpty else { throw fail("background_composer_unverified", "Feishu semantic ancestry was truncated") }
            queue += next.map { ($0, depth + 1) }
        }
        guard chats.count == 1 else { throw fail("background_recipient_unverified", "Exactly one current messenger-chat is required") }
        let (chat, area) = chats[0]
        let header = CGRect(x: area.minX, y: area.minY, width: area.width * 0.67, height: min(56, area.height))
        let lower = CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        var composers: [AXUIElement] = [], titles: [(AXUIElement, String, CGRect, Bool, CGRect?)] = []
        var localQueue: [(AXUIElement, Int, Bool, CGRect?)] = [(chat, 0, false, nil)], localIndex = 0
        seen = [:]
        while localIndex < localQueue.count {
            guard localIndex < 512 else { throw fail("background_composer_unverified", "Feishu chat discovery exceeded its node bound") }
            let (node, depth, inButton, parentGroup) = localQueue[localIndex]; localIndex += 1
            let hash = CFHash(node)
            if seen[hash]?.contains(where: { CFEqual($0, node) }) == true { continue }
            seen[hash, default: []].append(node)
            let metadata = try fresh(node), role = metadata.string("AXRole")!
            if let rect = metadata.bounds, rect.intersection(header).isNull && rect.intersection(lower).isNull { continue }
            if role == "AXTextArea" {
                if let rect = metadata.bounds, visualContains(lower, rect), metadata.boolean("AXEnabled") == true { composers.append(node) }
                continue
            }
            if role == "AXStaticText" {
                if let rect = metadata.bounds, rect.width > 2, rect.height > 2, visualContains(header, rect) {
                    let value = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { axString(node, $0) }.first(where: { !$0.isEmpty }) ?? ""
                    if !value.isEmpty, !["智能体", "AI", "聊天", "消息", "搜索", "发送"].contains(value) { titles.append((node, value, rect, inButton, parentGroup)) }
                }
                continue
            }
            let next = try children(node)
            guard depth < 40 || next.isEmpty else { throw fail("background_composer_unverified", "Feishu chat ancestry was truncated") }
            localQueue += next.map { ($0, depth + 1, inButton || role == "AXButton", role == "AXGroup" ? metadata.bounds : nil) }
        }
        // A numeric member counter may share the title baseline inside a
        // distinct button. Numeric recipient names themselves remain titles.
        if let first = titles.min(by: { $0.2.minX < $1.2.minX }) {
            titles.removeAll { item in
                !CFEqual(item.0, first.0) && item.3 && item.1.allSatisfy({ $0.isNumber }) &&
                item.2.minX >= first.2.maxX - 2 && abs(item.2.midY - first.2.midY) <= max(item.2.height, first.2.height)
            }
            let officialBadges = titles.filter { item in
                !CFEqual(item.0, first.0) && backgroundFeishuOfficialHeaderBadge(value: item.1, bounds: item.2,
                    parentGroup: item.4, inButton: item.3, primaryBounds: first.2)
            }
            if officialBadges.count == 1 {
                titles.removeAll { CFEqual($0.0, officialBadges[0].0) }
            }
        }
        guard composers.count == 1, titles.count == 1,
              expectedTitle.map({ $0 == titles[0].1 }) ?? true else {
            throw fail("background_recipient_unverified", "Exactly one complete current Feishu header and composer are required")
        }
        try helper.denySecure(composers[0]); try helper.denySecure(titles[0].0)
        return try BackgroundFeishuComposer(target: target, composer: composers[0], recipient: titles[0].0, title: titles[0].1)
    }
}
