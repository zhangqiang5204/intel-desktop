import Foundation
import AppKit
import ApplicationServices

func nativeSelectionEqual(_ actual: String, _ expected: String) -> Bool {
    actual.utf8.elementsEqual(expected.utf8)
}

func nativeSelectionBoundaryValid(_ source: NSString, _ offset: Int) -> Bool {
    guard offset >= 0, offset <= source.length else { return false }
    if offset == 0 || offset == source.length { return true }
    return !((0xD800...0xDBFF).contains(source.character(at: offset - 1))
             && (0xDC00...0xDFFF).contains(source.character(at: offset)))
}

func nativeSelectionRange(_ value: String, text: String, occurrence: Int?) throws -> NSRange {
    guard !text.isEmpty else { throw fail("invalid_request", "Selection text must be nonempty") }
    let source = value as NSString
    var matches: [NSRange] = [], start = 0
    while start < source.length {
        let found = source.range(of: text, options: .literal, range: NSRange(location: start, length: source.length - start))
        if found.location == NSNotFound { break }
        matches.append(found)
        start = found.location + 1 // Include overlapping exact occurrences.
    }
    guard !matches.isEmpty else { throw fail("selection_text_not_found", "Exact selection text is absent") }
    if let occurrence {
        guard occurrence > 0, occurrence <= matches.count else {
            throw fail("selection_occurrence_out_of_range", "Requested exact occurrence is absent", ["matching_count": matches.count])
        }
        return matches[occurrence - 1]
    }
    guard matches.count == 1 else { throw fail("selection_text_ambiguous", "Specify an occurrence for repeated exact text", ["matching_count": matches.count]) }
    return matches[0]
}

func nativeSelectionExplicitRange(_ request: [String: Any], field: String, value: String) throws -> NSRange? {
    guard let raw = request[field] else { return nil }
    guard let object = raw as? [String: Any], Set(object.keys) == Set(["location", "length"]) else {
        throw fail("invalid_request", "Selection ranges require location and length only")
    }
    let location = try integer(object, "location", default: 0, range: 0...131072)
    let length = try integer(object, "length", default: 0, range: 0...131072)
    let limit = (value as NSString).length
    guard location <= limit, length <= limit - location else { throw fail("selection_range_out_of_bounds", "UTF-16 selection range exceeds the complete value") }
    let range = NSRange(location: location, length: length)
    // Never split a surrogate pair at either boundary.
    let source = value as NSString
    guard nativeSelectionBoundaryValid(source, location), nativeSelectionBoundaryValid(source, location + length) else {
        throw fail("selection_range_invalid_boundary", "Selection boundaries are invalid Unicode positions")
    }
    return range
}

func nativeSelectionFromCFRange(_ raw: CFRange?, value: String) -> NSRange? {
    guard let raw, raw.location >= 0, raw.length >= 0 else { return nil }
    let limit = (value as NSString).length
    guard raw.location <= limit, raw.length <= limit - raw.location else { return nil }
    let range = NSRange(location: raw.location, length: raw.length)
    let source = value as NSString
    return nativeSelectionBoundaryValid(source, raw.location) && nativeSelectionBoundaryValid(source, raw.location + raw.length) ? range : nil
}

func nativeSelectionSystemFocusBinding() -> (pid: pid_t, window: AXUIElement)? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.12)
    guard let application = axElement(system, kAXFocusedApplicationAttribute) else { return nil }
    AXUIElementSetMessagingTimeout(application, 0.12)
    var pid: pid_t = 0
    guard AXUIElementGetPid(application, &pid) == .success, pid > 0 else { return nil }
    let focused = axElement(system, kAXFocusedUIElementAttribute) ?? axElement(application, kAXFocusedUIElementAttribute)
    guard let window = axElement(application, kAXFocusedWindowAttribute)
        ?? focused.flatMap({ axElement($0, kAXWindowAttribute) }) else { return nil }
    var windowPID: pid_t = 0
    guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid else { return nil }
    return (pid, window)
}

extension DesktopHelper {
    func selectText(_ request: [String: Any], target: Target) throws -> [String: Any] {
        guard target.expectedTitle != nil else { throw fail("window_title_required", "Text selection requires an exact window title") }
        let expected = try string(request, "expected_value")!
        guard expected.count <= 65536 else { throw fail("text_too_large", "Selection value exceeds 65536 characters") }
        let background = try boolean(request, "background")
        let literal = try string(request, "text", required: false)
        guard (literal != nil) != (request["range"] != nil) else { throw fail("invalid_request", "Choose exact text or one explicit UTF-16 range") }
        guard (literal?.count ?? 0) <= 65536 else { throw fail("text_too_large", "Selection text exceeds 65536 characters") }
        let occurrence = request["occurrence"] == nil ? nil : try integer(request, "occurrence", default: 1, range: 1...65536)
        guard literal != nil || occurrence == nil else { throw fail("invalid_request", "Occurrence requires exact text") }
        let range = try literal.map { try nativeSelectionRange(expected, text: $0, occurrence: occurrence) }
            ?? nativeSelectionExplicitRange(request, field: "range", value: expected)!
        let expectedSelection = try nativeSelectionExplicitRange(request, field: "expected_selection", value: expected)
        let element = try cached(request, target: target)
        let originalFrame = axBounds(target.window)
        let launch = target.application.launchDate?.timeIntervalSince1970
        let focusBefore = observationSystemFocus()
        let focusWindowBefore = background ? nativeSelectionSystemFocusBinding() : nil
        var writes = 0
        func selectedRange() -> NSRange? { nativeSelectionFromCFRange(axSelectedRange(element), value: expected) }
        func checkTarget() throws {
            if background {
                guard focusBefore["available"] as? Bool == true,
                      let origin = focusWindowBefore,
                      (focusBefore["pid"] as? NSNumber)?.int32Value == origin.pid,
                      axBool(target.axApplication, kAXFrontmostAttribute) == false else {
                    throw fail("selection_background_focus_unavailable", "Background selection requires complete foreign-app focus proof")
                }
                guard let current = nativeSelectionSystemFocusBinding(), current.pid == origin.pid,
                      CFEqual(current.window, origin.window),
                      NSDictionary(dictionary: observationSystemFocus()).isEqual(to: focusBefore) else {
                    throw fail("selection_focus_changed", "System focus changed; no focus recovery or replay")
                }
            } else { try self.verify(target) }
            guard !target.application.isTerminated, target.application.launchDate?.timeIntervalSince1970 == launch,
                  axString(target.window, kAXTitleAttribute) == target.expectedTitle,
                  originalFrame != nil, axBounds(target.window) == originalFrame,
                  self.windows(target.axApplication).contains(where: { CFEqual($0, target.window) }),
                  try self.currentDisplays().signature == target.displaySignature else {
                throw fail("selection_target_changed", "Selection target identity, geometry or topology changed")
            }
            try self.denySecure(target.window); try self.denySecure(element)
            let metadata = axMetadataAttributes(element)
            let dialog = background ? nil : try self.currentInspectedDialog(target)
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success,
                  dialog.map({ nativeElementInDialog(element, dialog: $0.dialog) }) ?? (pid == target.pid),
                  metadata.observationSecurityKnown, !metadata.isSecure,
                  ["AXTextArea", "AXTextField"].contains(metadata.string("AXRole") ?? ""),
                  metadata.boolean("AXEnabled") != false else {
                throw fail("selection_control_unavailable", "Selection requires the current enabled text control")
            }
            var parent: AXUIElement? = element, belongs = dialog.map { nativeElementInDialog(element, dialog: $0.dialog) } ?? false
            for _ in 0..<64 {
                guard let current = parent else { break }
                if CFEqual(current, target.window) { belongs = true; break }
                parent = axElement(current, kAXParentAttribute)
            }
            guard belongs else { throw fail("selection_target_changed", "Text control is no longer within the selected window") }
            guard let current = axString(element, kAXValueAttribute), nativeSelectionEqual(current, expected) else {
                throw fail("selection_value_changed", "Complete text value changed; no text or selection replay")
            }
        }
        do {
            try checkTarget()
            guard let before = selectedRange() else { throw fail("selection_unavailable", "Current text selection is unavailable") }
            if let expectedSelection, before != expectedSelection { throw fail("selection_changed", "Current selection changed; preserve it") }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
                  settable.boolValue else { throw fail("selection_not_settable", "Native text selection is not writable") }
            if before != range {
                try checkTarget()
                if let expectedSelection, selectedRange() != expectedSelection { throw fail("selection_changed", "Selection changed before write; preserve it") }
                var nativeRange = CFRange(location: range.location, length: range.length)
                guard let wrapped = AXValueCreate(.cfRange, &nativeRange) else { throw fail("selection_range_unavailable", "Cannot construct native selection range") }
                writes = 1
                let code = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, wrapped)
                guard code == .success else { throw fail("selection_write_failed", "Native selection write did not confirm success", ["ax_result": code.rawValue]) }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            repeat {
                try checkTarget()
                if selectedRange() == range {
                    return ["method": "AXSelectedTextRange", "element_id": request["element_id"]!,
                            "target_pid": target.pid, "window_title": target.expectedTitle!,
                            "selection_verified": true, "value_verified": true, "text_unchanged": true,
                            "selection": ["location": range.location, "length": range.length],
                            "previous_selection": ["location": before.location, "length": before.length],
                            "selection_coordinate_system": "UTF-16", "ax_selection_writes_attempted": writes,
                            "background": background, "system_focus_preserved": background,
                            "system_focus_window_verified": background,
                            "foreground_verified": !background,
                            "focus_attempted": false, "events_posted": 0, "automatic_replay_allowed": false]
                }
                Thread.sleep(forTimeInterval: 0.02)
            } while ProcessInfo.processInfo.systemUptime < deadline
            throw fail("selection_postcondition_failed", "Native selected range did not settle; no replay")
        } catch {
            let error = error as? HelperError ?? fail("selection_failed", "Native text selection failed")
            var details = error.details
            details["events_posted"] = 0; details["ax_selection_writes_attempted"] = writes
            details["selection_may_have_changed"] = writes > 0
            details["automatic_replay_allowed"] = false
            throw fail(error.code, error.message, details)
        }
    }
}

func nativeTextSelectionSelfTests() -> [String: Any] {
    var checks: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
    func denied(_ name: String, _ body: () throws -> NSRange?) {
        do { _ = try body(); check(name, false) } catch { check(name, true) }
    }
    check("Chinese_exact_UTF16", (try? nativeSelectionRange("甲乙丙", text: "乙", occurrence: nil)) == NSRange(location: 1, length: 1))
    check("emoji_UTF16_offset", (try? nativeSelectionRange("🙂中文", text: "中文", occurrence: nil)) == NSRange(location: 2, length: 2))
    check("emoji_complete_pair", (try? nativeSelectionRange("甲🙂乙", text: "🙂", occurrence: nil)) == NSRange(location: 1, length: 2))
    check("literal_case", (try? nativeSelectionRange("aA", text: "A", occurrence: nil)) == NSRange(location: 1, length: 1))
    check("overlapping_occurrence", (try? nativeSelectionRange("aaa", text: "aa", occurrence: 2)) == NSRange(location: 1, length: 2))
    denied("repeated_text_requires_occurrence") { try nativeSelectionRange("甲甲", text: "甲", occurrence: nil) }
    denied("empty_text_denied") { try nativeSelectionRange("甲", text: "", occurrence: nil) }
    denied("missing_text_denied") { try nativeSelectionRange("甲", text: "乙", occurrence: nil) }
    denied("missing_occurrence_denied") { try nativeSelectionRange("甲", text: "甲", occurrence: 2) }
    check("byte_exact_value", !nativeSelectionEqual("é", "e\u{301}"))
    check("same_value_exact", nativeSelectionEqual("🙂甲", "🙂甲"))
    check("restore_empty_caret", (try? nativeSelectionExplicitRange(["range": ["location": 0, "length": 0]], field: "range", value: "🙂")) == NSRange(location: 0, length: 0))
    denied("range_out_of_bounds") { try nativeSelectionExplicitRange(["range": ["location": 2, "length": 2]], field: "range", value: "甲") }
    denied("range_unknown_field") { try nativeSelectionExplicitRange(["range": ["location": 0, "length": 1, "extra": true]], field: "range", value: "甲") }
    denied("surrogate_split_denied") { try nativeSelectionExplicitRange(["range": ["location": 1, "length": 1]], field: "range", value: "🙂") }
    check("native_CFRange_conversion", nativeSelectionFromCFRange(CFRange(location: 2, length: 1), value: "🙂甲") == NSRange(location: 2, length: 1))
    check("invalid_negative_native_range", nativeSelectionFromCFRange(CFRange(location: -1, length: 0), value: "甲") == nil)
    check("invalid_native_surrogate_boundary", nativeSelectionFromCFRange(CFRange(location: 1, length: 1), value: "🙂") == nil)
    return ["ok": checks.allSatisfy { $0["passed"] as? Bool == true }, "suite": "native_text_selection", "count": checks.count, "checks": checks, "events_posted": 0]
}
