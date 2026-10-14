import Foundation
import AppKit
import ApplicationServices
import Carbon

// Persistent, bounded JSONL service. No launch or permission prompts.
// Feishu paste temporarily leases the general clipboard with guarded restoration.
struct HelperError: Error {
    let code: String
    let message: String
    var details: [String: Any] = [:]
}

func fail(_ code: String, _ message: String, _ details: [String: Any] = [:]) -> HelperError {
    HelperError(code: code, message: message, details: details)
}

func string(_ request: [String: Any], _ name: String, required: Bool = true) throws -> String? {
    guard let value = request[name] else {
        if required { throw fail("invalid_request", "Missing string field: \(name)") }
        return nil
    }
    guard let result = value as? String else { throw fail("invalid_request", "\(name) must be a string") }
    if required && result.isEmpty { throw fail("invalid_request", "\(name) must not be empty") }
    return result
}

func integer(_ request: [String: Any], _ name: String, default defaultValue: Int,
             range: ClosedRange<Int>) throws -> Int {
    guard let value = request[name] else { return defaultValue }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
          number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound)
    else { throw fail("invalid_request", "\(name) must be an integer in \(range)") }
    return number.intValue
}

func boolean(_ request: [String: Any], _ name: String, default defaultValue: Bool = false) throws -> Bool {
    guard let value = request[name] else { return defaultValue }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw fail("invalid_request", "\(name) must be a boolean")
    }
    return number.boolValue
}

func axResult(_ result: AXError) -> [String: Any] {
    let name: String
    switch result {
    case .success: name = "success"
    case .failure: name = "failure"
    case .illegalArgument: name = "illegal_argument"
    case .invalidUIElement: name = "invalid_ui_element"
    case .cannotComplete: name = "cannot_complete"
    case .attributeUnsupported: name = "attribute_unsupported"
    case .actionUnsupported: name = "action_unsupported"
    case .notImplemented: name = "not_implemented"
    case .noValue: name = "no_value"
    case .apiDisabled: name = "api_disabled"
    default: name = "ax_error"
    }
    return ["code": result.rawValue, "name": name]
}

func axBooleanResult(_ element: AXUIElement, _ name: String) -> (Bool?, AXError) {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return ((value as? NSNumber)?.boolValue, result)
}

func axSettableResult(_ element: AXUIElement, _ name: String) -> (Bool?, AXError) {
    var settable = DarwinBoolean(false)
    let result = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
    return (result == .success ? settable.boolValue : nil, result)
}

let navigationChildAttributes = [kAXChildrenAttribute, "AXChildrenInNavigationOrder"]

func axChildCounts(_ element: AXUIElement) -> [(name: String, count: Int, result: AXError)] {
    navigationChildAttributes.map { name in
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
        return (name, result == .success ? max(0, count) : 0, result)
    }
}

func axChildCountReasons(_ counts: [(name: String, count: Int, result: AXError)]) -> Set<String> {
    // Unsupported/absent optional child orders are normal on leaves. A failed
    // read has unknown cardinality, even though its diagnostic count is zero.
    counts.contains { ![.success, .attributeUnsupported, .noValue].contains($0.result) } ? ["child_count_failed"] : []
}

func axNavigationChildren(_ element: AXUIElement, limit: Int,
                          counts: [(name: String, count: Int, result: AXError)]) -> (elements: [AXUIElement], truncated: Bool, reasons: Set<String>) {
    var reasons = axChildCountReasons(counts)
    if counts.contains(where: { $0.count > max(0, limit) }) { reasons.insert("node_limit") }
    guard limit > 0 else { return ([], !reasons.isEmpty, reasons) }
    var children: [AXUIElement] = []
    var buckets: [CFHashCode: [AXUIElement]] = [:]
    for source in counts where source.result == .success && source.count > 0 {
        let requested = min(source.count, limit)
        var raw: CFArray?
        let copied = AXUIElementCopyAttributeValues(element, source.name as CFString, 0, requested, &raw)
        guard copied == .success, let values = raw as? [AnyObject] else {
            reasons.insert("child_read_failed"); continue
        }
        // A shorter/malformed prefix after a positive count is not a proven
        // empty subtree. Keep usable children, but never claim a complete tree.
        if values.count != requested { reasons.insert("child_read_failed") }
        // Read a bounded prefix from both orders. CFEqual prevents duplicate nodes
        // while preserving distinct elements whose CFHash happens to collide.
        for value in values.prefix(requested) {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                reasons.insert("child_read_failed"); continue
            }
            let child = unsafeBitCast(value, to: AXUIElement.self)
            let hash = CFHash(child)
            if buckets[hash]?.contains(where: { CFEqual($0, child) }) == true { continue }
            guard children.count < limit else {
                reasons.insert("node_limit"); return (children, true, reasons)
            }
            buckets[hash, default: []].append(child)
            children.append(child)
        }
    }
    return (children, !reasons.isEmpty, reasons)
}

func number(_ request: [String: Any], _ name: String) throws -> Double {
    guard let value = request[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite else { throw fail("invalid_request", "\(name) must be a finite number") }
    return value.doubleValue
}

let quartzCoordinateSystem: [String: Any] = [
    "name": "quartz_global_points", "units": "points", "origin": "main_display_top_left",
    "x_axis": "right", "y_axis": "down", "negative_coordinates_supported": true,
    "bounds_edges": "min_inclusive_max_exclusive", "apply_display_scale_to_click": false]

func rectJSON(_ rect: CGRect) -> [String: Double] {
    ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
}

func pointIsInsideRect(_ point: CGPoint, _ rect: CGRect) -> Bool {
    point.x.isFinite && point.y.isFinite && point.x >= rect.minX && point.x < rect.maxX &&
    point.y >= rect.minY && point.y < rect.maxY
}

struct DisplayGeometry {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let modePointSize: CGSize
    let main: Bool
    let builtin: Bool
    let rotation: Double
    let backingScaleFactor: Double?

    init(id: CGDirectDisplayID, bounds: CGRect, pixelWidth: Int, pixelHeight: Int,
         modePointSize: CGSize? = nil, main: Bool = false, builtin: Bool = false, rotation: Double = 0,
         backingScaleFactor: Double? = nil) {
        self.id = id; self.bounds = bounds
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.modePointSize = modePointSize ?? bounds.size
        self.main = main; self.builtin = builtin; self.rotation = rotation
        self.backingScaleFactor = backingScaleFactor
    }

    var scaleX: Double { Double(pixelWidth) / Double(modePointSize.width) }
    var scaleY: Double { Double(pixelHeight) / Double(modePointSize.height) }
    var json: [String: Any] {
        ["display_id": id, "bounds": rectJSON(bounds), "pixel_size": ["width": pixelWidth, "height": pixelHeight],
         "mode_point_size": ["width": modePointSize.width, "height": modePointSize.height],
         "scale": backingScaleFactor.map { $0 as Any } ?? NSNull(),
         "backing_scale_factor": backingScaleFactor.map { $0 as Any } ?? NSNull(),
         "mode_pixel_scale_x": scaleX, "mode_pixel_scale_y": scaleY, "is_main": main, "is_builtin": builtin,
         "rotation_degrees": rotation, "coordinate_system": "quartz_global_points"]
    }

    func contains(_ point: CGPoint) -> Bool {
        pointIsInsideRect(point, bounds)
    }

    var signature: String {
        "\(id):\(bounds.minX),\(bounds.minY),\(bounds.width),\(bounds.height):\(pixelWidth),\(pixelHeight):\(modePointSize.width),\(modePointSize.height):\(main):\(builtin):\(rotation):\(backingScaleFactor.map { String($0) } ?? "unknown")"
    }
}

struct DisplaySnapshot {
    let displays: [DisplayGeometry]
    var signature: String { displays.sorted { $0.id < $1.id }.map { $0.signature }.joined(separator: "|") }

    func display(at point: CGPoint) -> DisplayGeometry? {
        displays.filter { $0.contains(point) }.sorted {
            if $0.main != $1.main { return $0.main }
            return $0.id < $1.id
        }.first
    }

    func associations(for rect: CGRect) -> [String: Any] {
        let overlaps = displays.compactMap { display -> (DisplayGeometry, CGRect, CGFloat)? in
            let overlap = rect.intersection(display.bounds)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            return (display, overlap, overlap.width * overlap.height)
        }.sorted {
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            if $0.0.main != $1.0.main { return $0.0.main }
            return $0.0.id < $1.0.id
        }
        return ["display_ids": overlaps.map { $0.0.id },
            "primary_display_id": overlaps.first.map { $0.0.id as Any } ?? NSNull(),
            "display_intersections": overlaps.map {
                ["display_id": $0.0.id, "bounds": rectJSON($0.1), "area_points_squared": $0.2] as [String: Any]
            }]
    }
}

func activeDisplays() throws -> DisplaySnapshot {
    var ids = [CGDirectDisplayID](repeating: 0, count: 64)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(64, &ids, &count) == .success, count > 0, count < 64 else {
        throw fail("display_state_unavailable", "Could not enumerate a bounded active-display topology")
    }
    let displays = ids.prefix(Int(count)).map { id -> DisplayGeometry in
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        // The SDK distinguishes display-mode points from backing pixels. Clicks use
        // CGDisplayBounds/AX points directly, including on Retina screens.
        let pointSize = mode.map { CGSize(width: $0.width, height: $0.height) } ?? bounds.size
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return DisplayGeometry(id: id, bounds: bounds,
            pixelWidth: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
            pixelHeight: mode?.pixelHeight ?? CGDisplayPixelsHigh(id), modePointSize: pointSize,
            main: CGDisplayIsMain(id) != 0, builtin: CGDisplayIsBuiltin(id) != 0, rotation: CGDisplayRotation(id),
            backingScaleFactor: screen.map { Double($0.backingScaleFactor) })
    }
    guard displays.allSatisfy({ $0.bounds.width > 0 && $0.bounds.height > 0 &&
        $0.bounds.minX.isFinite && $0.bounds.minY.isFinite && $0.modePointSize.width > 0 && $0.modePointSize.height > 0 }) else {
        throw fail("display_state_unavailable", "Active display geometry is invalid")
    }
    return DisplaySnapshot(displays: displays.sorted { $0.id < $1.id })
}

func geometrySelfTests() -> [String: Any] {
    let main = DisplayGeometry(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), pixelWidth: 3840, pixelHeight: 2160, main: true, builtin: true)
    let left = DisplayGeometry(id: 2, bounds: CGRect(x: -1280, y: 0, width: 1280, height: 1024), pixelWidth: 1280, pixelHeight: 1024)
    let right = DisplayGeometry(id: 3, bounds: CGRect(x: 1920, y: 0, width: 1280, height: 720), pixelWidth: 1280, pixelHeight: 720)
    let above = DisplayGeometry(id: 4, bounds: CGRect(x: 0, y: -900, width: 1600, height: 900), pixelWidth: 3200, pixelHeight: 1800)
    let below = DisplayGeometry(id: 5, bounds: CGRect(x: 0, y: 1080, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080)
    let desktop = DisplaySnapshot(displays: [main, left, right, above, below])
    let gapScreen = DisplayGeometry(id: 6, bounds: CGRect(x: 2100, y: 0, width: 1000, height: 800), pixelWidth: 1000, pixelHeight: 800)
    let gap = DisplaySnapshot(displays: [main, gapScreen])
    var cases: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]) }
    func ids(_ rect: CGRect, snapshot: DisplaySnapshot = desktop) -> [CGDirectDisplayID] {
        snapshot.associations(for: rect)["display_ids"] as? [CGDirectDisplayID] ?? []
    }
    check("left_negative_x", desktop.display(at: CGPoint(x: -640, y: 500))?.id == 2)
    check("above_negative_y", desktop.display(at: CGPoint(x: 500, y: -450))?.id == 4)
    check("right_display", desktop.display(at: CGPoint(x: 2500, y: 500))?.id == 3)
    check("below_display", desktop.display(at: CGPoint(x: 500, y: 1500))?.id == 5)
    check("mixed_retina_scales", main.scaleX == 2 && above.scaleY == 2 && left.scaleX == 1 && below.scaleY == 1)
    check("points_not_multiplied_by_scale", DisplaySnapshot(displays: [main]).display(at: CGPoint(x: 3000, y: 500)) == nil)
    check("gap_is_not_a_display", gap.display(at: CGPoint(x: 2000, y: 100)) == nil)
    check("gap_display_min_edge_included", gap.display(at: CGPoint(x: 2100, y: 100))?.id == 6)
    check("negative_outer_min_edge_included", desktop.display(at: CGPoint(x: -1280, y: 0))?.id == 2)
    check("negative_outer_edge_excluded", desktop.display(at: CGPoint(x: -1280.01, y: 0)) == nil)
    check("main_origin_and_left_seam", desktop.display(at: .zero)?.id == 1)
    check("right_seam_belongs_to_right_display", desktop.display(at: CGPoint(x: 1920, y: 0))?.id == 3)
    check("below_seam_belongs_to_below_display", desktop.display(at: CGPoint(x: 0, y: 1080))?.id == 5)
    check("outer_max_edge_excluded", desktop.display(at: CGPoint(x: 3200, y: 500)) == nil)
    check("nonfinite_coordinate_rejected", desktop.display(at: CGPoint(x: Double.nan, y: 1)) == nil)
    let spanning = CGRect(x: -100, y: 100, width: 200, height: 300)
    check("cross_screen_window_associates_both", Set(ids(spanning)) == Set([1, 2]))
    check("equal_area_prefers_main", desktop.associations(for: spanning)["primary_display_id"] as? CGDirectDisplayID == 1)
    check("primary_display_uses_largest_overlap", desktop.associations(for: CGRect(x: -150, y: 100, width: 200, height: 300))["primary_display_id"] as? CGDirectDisplayID == 2)
    check("vertical_cross_screen_window", Set(ids(CGRect(x: 100, y: -100, width: 100, height: 200))) == Set([1, 4]))
    check("window_wholly_in_gap_has_no_display", ids(CGRect(x: 1950, y: 20, width: 100, height: 50), snapshot: gap).isEmpty)
    check("edge_touch_is_not_rectangle_overlap", ids(CGRect(x: 1920, y: 20, width: 100, height: 50), snapshot: DisplaySnapshot(displays: [main])).isEmpty)
    check("topology_order_is_irrelevant", desktop.signature == DisplaySnapshot(displays: desktop.displays.reversed()).signature)
    check("adding_or_removing_display_changes_topology", desktop.signature != DisplaySnapshot(displays: [main]).signature)
    let moved = DisplayGeometry(id: 2, bounds: CGRect(x: -1280, y: -50, width: 1280, height: 1024), pixelWidth: 1280, pixelHeight: 1024)
    check("display_movement_changes_topology", DisplaySnapshot(displays: [left]).signature != DisplaySnapshot(displays: [moved]).signature)
    let changedScale = DisplayGeometry(id: 1, bounds: main.bounds, pixelWidth: 1920, pixelHeight: 1080, main: true, builtin: true)
    check("pixel_scale_change_changes_topology", DisplaySnapshot(displays: [main]).signature != DisplaySnapshot(displays: [changedScale]).signature)
    let changedMain = DisplayGeometry(id: 1, bounds: main.bounds, pixelWidth: 3840, pixelHeight: 2160, main: false, builtin: true)
    check("main_display_change_changes_topology", DisplaySnapshot(displays: [main]).signature != DisplaySnapshot(displays: [changedMain]).signature)
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "command": "geometry_self_test",
        "case_count": cases.count, "cases": cases, "coordinate_system": quartzCoordinateSystem,
        "physical_displays_examined": false]
}

func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func axString(_ element: AXUIElement, _ name: String) -> String? {
    axValue(element, name) as? String
}

func axBool(_ element: AXUIElement, _ name: String) -> Bool? {
    (axValue(element, name) as? NSNumber)?.boolValue
}

func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

func axElements(_ element: AXUIElement, _ name: String, limit: Int = 2000) -> [AXUIElement] {
    // Ask for only the allowed prefix, rather than fetching an unbounded child array.
    var count: CFIndex = 0
    guard AXUIElementGetAttributeValueCount(element, name as CFString, &count) == .success, count > 0 else { return [] }
    var result: CFArray?
    guard AXUIElementCopyAttributeValues(element, name as CFString, 0, min(count, limit), &result) == .success,
          let values = result as? [AnyObject] else { return [] }
    return values.compactMap { value in
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}

func inspectionWindowList(_ root: AXUIElement) -> (windows: [AXUIElement], metadata: [String: Any]) {
    var count: CFIndex = 0
    let counted = AXUIElementGetAttributeValueCount(root, kAXWindowsAttribute as CFString, &count)
    var metadata: [String: Any] = ["window_list_count_result": axResult(counted),
        "window_list_available": counted == .success, "window_list_complete": counted == .success,
        "window_list_reported_count": counted == .success ? max(0, count) : 0]
    guard counted == .success, count > 0 else { return ([], metadata) }
    var raw: CFArray?
    let copied = AXUIElementCopyAttributeValues(root, kAXWindowsAttribute as CFString, 0, min(count, 128), &raw)
    metadata["window_list_copy_result"] = axResult(copied)
    let values = raw as? [AnyObject]
    let rows = (values ?? []).compactMap { value -> AXUIElement? in
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    metadata["window_list_available"] = copied == .success && values != nil
    metadata["window_list_complete"] = copied == .success && count <= 128 && rows.count == count
    return (rows, metadata)
}

// Menu enumeration is optional during a title-free window-list observation.
// Bind only to that observation's focused/unique root, without a second window
// read or choosing an arbitrary window when Feishu is opening its search modal.
func inspectionMenuWindowIndex(windowCount: Int, focusedIndex: Int?) -> Int? {
    if let focusedIndex, focusedIndex >= 0 && focusedIndex < windowCount { return focusedIndex }
    return windowCount == 1 ? 0 : nil
}

func axActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return Array((names as? [String] ?? []).prefix(32))
}

func axBounds(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute), let size = axValue(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    let p: AXValue = unsafeBitCast(position, to: AXValue.self)
    let s: AXValue = unsafeBitCast(size, to: AXValue.self)
    guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions),
          point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
          dimensions.width > 0, dimensions.height > 0 else { return nil }
    return CGRect(origin: point, size: dimensions)
}

func axSelectedRange(_ element: AXUIElement) -> CFRange? {
    guard let value = axValue(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let rangeValue: AXValue = unsafeBitCast(value, to: AXValue.self)
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
    return range
}

func foregroundMetadata() -> (pid: pid_t?, source: String) {
    // Keep workspace notifications current in a stdin-driven service. Metadata is never
    // used to authorize input: verify() queries AXFrontmost on the selected target itself.
    for _ in 0..<8 {
        if CFRunLoopRunInMode(.defaultMode, 0, true) != .handledSource { break }
    }
    return (NSWorkspace.shared.frontmostApplication?.processIdentifier, "NSWorkspaceAfterRunLoop")
}

func isSecure(_ element: AXUIElement) -> Bool {
    axString(element, kAXSubroleAttribute) == "AXSecureTextField" ||
    axString(element, kAXRoleAttribute) == "AXSecureTextField" ||
    axBool(element, "AXProtectedContent") == true
}

func readableValue(_ element: AXUIElement, maxCharacters: Int = 4000) -> String? {
    guard !isSecure(element), let value = axValue(element, kAXValueAttribute) else { return nil }
    if let text = value as? String { return String(text.prefix(maxCharacters)) }
    if let numeric = value as? NSNumber { return numeric.stringValue }
    return nil
}

func readableValueProof(_ element: AXUIElement, maxCharacters: Int = 4000) -> (value: String, complete: Bool)? {
    guard !isSecure(element), let value = axValue(element, kAXValueAttribute) else { return nil }
    if let text = value as? String { return (String(text.prefix(maxCharacters)), text.count <= maxCharacters) }
    if let numeric = value as? NSNumber { return (numeric.stringValue, true) }
    return nil
}

func excludedMenuBranch(role: String, title: String) -> String? {
    guard ["AXMenuBarItem", "AXMenuItem"].contains(role) else { return nil }
    let label = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if role == "AXMenuBarItem" && ["apple", "", "苹果", "蘋果"].contains(label) { return "apple_menu" }
    if ["services", "服务", "服務", "サービス"].contains(label) { return "services" }
    if ["recent items", "open recent", "recent documents", "最近使用的项目", "最近使用的項目",
        "最近项目", "最近項目", "最近打开", "最近打開", "打开最近", "打開最近",
        "最近使用した項目", "最近使った項目", "最近使用した書類"].contains(label) { return "recent_items" }
    return nil
}

// Retain only the event that actually trips the monitor. This reads CG fields
// and an already sampled focus value; no AX, key text, or per-event history.
func inputInterruptionEvent(_ type: CGEventType, _ event: CGEvent, marker: Int64,
                            mode: ScopedInputMode, reason: String, cached: ScopedInputContext?,
                            claimTimestamp: CGEventTimestamp?, pointerContext: ScopedPointerContext? = nil) -> [String: Any] {
    let observedRaw = inputClaimTimestamp()
    let now = ProcessInfo.processInfo.systemUptime
    let keyboard = [.keyDown, .keyUp, .flagsChanged].contains(type)
    let pointer = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
        .otherMouseDragged, .mouseMoved, .scrollWheel].contains(type)
    var focus: [String: Any] = ["state": "unknown"]
    if let cached, let value = cached.userFocus {
        focus = ["state": "cached", "pid": value.pid, "window_id": value.windowID,
            "window_frame": rectJSON(value.frame), "screen_ids": value.screenIDs.sorted(),
            "sample_age_ms": max(0, now - cached.startedAt) * 1000,
            "fresh": now >= cached.completedAt && now - cached.startedAt <= ScopedInputPolicy.maxContextAge]
    }
    var pointerOwner: [String: Any] = ["state": "unavailable"]
    if pointer, let sample = pointerContext {
        pointerOwner = ["state": "no_application_window", "sample_age_ms": max(0, now - sample.startedAt) * 1000,
            "fresh": now >= sample.completedAt && now - sample.startedAt <= ScopedInputPolicy.maxContextAge,
            "inside_target_frame": sample.target.window.frame.contains(event.location), "sampled_windows": sample.windows.count]
        if let hit = sample.windows.first(where: { $0.frame.contains(event.location) }) {
            pointerOwner["state"] = "hit"; pointerOwner["pid"] = hit.pid
            pointerOwner["window_id"] = hit.windowID; pointerOwner["window_frame"] = rectJSON(hit.frame)
            pointerOwner["requires_AX_hit_test"] = hit.requiresAXHitTest
        }
        if let hit = sample.hitTest {
            pointerOwner["AX_hit_test"] = ["point": ["x": hit.point.x, "y": hit.point.y],
                "pid": hit.window.pid, "window_id": hit.window.windowID,
                "occluding_window_id": hit.occludingWindowID, "matches_event_point": hit.point == event.location] as [String: Any]
        }
    }
    let modeName: String
    switch mode { case .sharedHID: modeName = "sharedHID"; case .targetedBackground: modeName = "targetedBackground"; case .readOnly: modeName = "readOnly" }
    return ["reason": reason, "mode": modeName, "observed_at_uptime": now,
        "event_timestamp_ns": event.timestamp,
        "claim_event_timestamp_ns": claimTimestamp.map { $0 as Any } ?? NSNull(),
        "observed_raw_uptime_ns": observedRaw,
        "event_after_claim": inputEventAfterClaim(event.timestamp, baseline: claimTimestamp),
        "event_type": type.rawValue,
        "keycode": keyboard ? event.getIntegerValueField(.keyboardEventKeycode) as Any : NSNull(),
        "source_unix_process_id": event.getIntegerValueField(.eventSourceUnixProcessID),
        "target_unix_process_id": event.getIntegerValueField(.eventTargetUnixProcessID),
        "source_user_data_matches_own": event.getIntegerValueField(.eventSourceUserData) == marker,
        "keyboard_focus": focus,
        "pointer_owner": pointerOwner,
        "point": pointer ? ["x": event.location.x, "y": event.location.y] as Any : NSNull()]
}

// CGEventTimestamp is nanoseconds since startup (CGEventTypes.h). Darwin's
// CLOCK_UPTIME_RAW is mach_absolute_time converted through mach_timebase_info,
// unlike continuous/monotonic clocks that advance during system sleep.
func inputClaimTimestamp() -> CGEventTimestamp {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func inputEventAfterClaim(_ timestamp: CGEventTimestamp, baseline: CGEventTimestamp?) -> Bool {
    guard let baseline else{return true}
    return timestamp==0 || timestamp>=baseline // Unknown timestamps are never ignored.
}
func inputInvalidatesRetainedFocus(_ type: CGEventType, timestamp: CGEventTimestamp,
                                  baseline: CGEventTimestamp?, own: Bool) -> Bool {
    !own && inputEventAfterClaim(timestamp, baseline: baseline) &&
        [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
         .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
         .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel].contains(type)
}

func focusOriginAppMatches(pid: pid_t, bundle: String, actualPID: pid_t?, actualBundle: String?) -> Bool {
    pid > 0 && !bundle.isEmpty && actualPID == pid && actualBundle == bundle
}

// Transport metadata binds a retained focus claim to its logical runtime task.
// It is stripped before command validation and grants no application authority.
func nativeRuntimeRequest(_ original: [String: Any], legacyTaskID: String) throws -> (request: [String: Any], taskID: String, operationID: String?) {
    var request = original
    let rawTask = request.removeValue(forKey: "_runtime_task_id")
    let rawOperation = request.removeValue(forKey: "_runtime_operation_id")
    let taskID: String
    if let rawTask {
        guard let value = rawTask as? String, !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) }) else {
            throw fail("invalid_runtime_task_id", "Internal runtime task ID must be 1...128 printable ASCII characters")
        }
        taskID = value
    } else { taskID = legacyTaskID }
    var operationID: String?
    if let rawOperation {
        guard let value = rawOperation as? String, !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) }) else {
            throw fail("invalid_runtime_operation_id", "Internal runtime operation ID must be 1...128 printable ASCII characters")
        }
        operationID = value
    }
    return (request, taskID, operationID)
}

func focusRecordTaskMatches(_ recorded: String, _ current: String) -> Bool { recorded == current }

func focusRestoreKeepsWindow(hasRecordedWindow: Bool, identityVerified: Bool) -> Bool {
    hasRecordedWindow && identityVerified
}

func focusRestoreShouldRaise(originFrontmost: Bool, originalWindowFocused: Bool, raiseAttempted: Bool) -> Bool {
    originFrontmost && !originalWindowFocused && !raiseAttempted
}

func focusRestoreSuppression(hasRecord:Bool,claimComplete:Bool,interrupted:Bool,taskStillFocused:Bool,originExists:Bool,topologyMatches:Bool) -> String? {
    if !hasRecord{return "no_previous_focus"}
    if !claimComplete{return "focus_claim_unconfirmed"}
    if interrupted{return "user_takeover"}
    if !taskStillFocused{return "task_focus_changed"}
    if !originExists{return "previous_window_unavailable"}
    if !topologyMatches{return "display_topology_changed"}
    return nil
}
let feishuSearchWindowTitle = "ModalWebViewWidget - search:search-command-bar:default"

// Only a successfully posted navigation in the owned search modal can create
// this candidate. Restoring later still requires the same actual main/focus,
// absent modal, stable AX/CG identity, topology and uninterrupted stage claim.
struct OwnedFeishuMainReturn {
    let target: Target
    let frame: CGRect
    let windowID: CGWindowID
    let taskID: String
    let operationID: String
    let activityRevision: UInt64
    let until: Double
}
struct OwnedFeishuSearchOpen {
    let main: OwnedFeishuMainReturn
}
func feishuOwnedScopeMatches(task: String, operation: String, pid: pid_t, revision: UInt64, until: Double,
                            currentTask: String, currentOperation: String?, currentPID: pid_t,
                            currentRevision: UInt64, now: Double) -> Bool {
    !operation.isEmpty && task == currentTask && operation == currentOperation && pid == currentPID &&
        revision == currentRevision && now.isFinite && until.isFinite && now >= 0 && now <= until
}
func implicitFocusClaimDisposition(sameTask: Bool, sameOperation: Bool, complete: Bool,
                                   monitorAvailable: Bool, interrupted: Bool,
                                   sameProcess: Bool, stillFocused: Bool) -> String {
    if sameTask && complete && monitorAvailable && !interrupted && sameProcess && stillFocused { return "reuse" }
    return sameTask && sameOperation ? "stop" : "new_claim"
}
func feishuSearchOpenControlAllowed(role: String, title: String?, description: String?) -> Bool {
    if role == "AXMenuItem" { return title == "搜索" }
    guard role == "AXButton" else { return false }
    return [title, description].compactMap { $0 }.contains { label in
        let normalized = label.filter { !$0.isWhitespace }.replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
        return normalized == "搜索" || normalized == "搜索(⌘K)" || normalized == "搜索(⌘＋K)"
    }
}
func feishuAXMainWindowKind(available: Bool, matchesSavedMain: Bool, matchesUniqueSearchModal: Bool) -> String {
    if !available { return "missing" }
    if matchesSavedMain { return "saved_main" }
    return matchesUniqueSearchModal ? "known_search_modal" : "other"
}
func ownedFeishuReturnAllowed(claimComplete: Bool, interrupted: Bool, actionAccepted: Bool,
                             sameIdentity: Bool, modalAbsent: Bool, actualMainFocused: Bool,
                             topologyMatches: Bool) -> Bool {
    claimComplete && !interrupted && actionAccepted && sameIdentity && modalAbsent && actualMainFocused && topologyMatches
}

let feishuSearchStructure = "\u{200B}\n"
let feishuSearchEnterHint = "\n回车查看答案"

func feishuSearchOrdinaryQuery(_ value: String) -> Bool {
    !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x200B || $0.value == 0x2028 || $0.value == 0x2029 }
}
// Only the two complete AX serializations observed in this exact search editor.
// The query is preserved literally; arbitrary lines/labels are never trimmed.
func feishuSearchValue(_ value: String) -> (query: String, serialization: String)? {
    let suffix: String, name: String
    if value.hasSuffix(feishuSearchStructure + feishuSearchEnterHint) {
        suffix = feishuSearchStructure + feishuSearchEnterHint; name = "query_ZW_LF_enter_hint"
    } else if value.hasSuffix(feishuSearchStructure) {
        suffix = feishuSearchStructure; name = "query_ZW_LF"
    } else { return nil }
    let query = String(value.dropLast(suffix.count))
    guard query.count <= 65536, feishuSearchOrdinaryQuery(query) else { return nil }
    return (query, name)
}
func feishuSearchVerifiedAfter(_ value: String?, query: String) -> (value: String, serialization: String)? {
    guard let value, let parsed = feishuSearchValue(value), parsed.query == query else { return nil }
    return (value, parsed.serialization)
}

struct FeishuSearchReplacement {
    let text: String
    let beforeQuery: String
    let before: String
    let after: String
    let elementID: String
    init(_ request: [String: Any]) throws {
        text = try string(request, "text")!
        before = try string(request, "expected_before")!
        after = try string(request, "expected_value")!
        elementID = try string(request, "element_id")!
        guard text.count <= 65536, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              feishuSearchOrdinaryQuery(text), let parsedBefore = feishuSearchValue(before),
              after == text + feishuSearchStructure else {
            throw fail("invalid_search_replacement", "Search replacement requires one nonempty query and exact complete before/after AX serializations")
        }
        beforeQuery = parsedBefore.query
    }
}
func feishuSearchReplacementTargetAllowed(bundle: String, title: String, role: String,
                                         focused: Bool, secure: Bool, actualBefore: String?, expectedBefore: String) -> Bool {
    bundle == "com.bytedance.macos.feishu" && title == feishuSearchWindowTitle && role == "AXTextArea" &&
        focused && !secure && actualBefore == expectedBefore
}

struct PreviousFocusRecord {
    let runtimeTaskID:String
    let runtimeOperationID:String?
    let application:NSRunningApplication
    let root:AXUIElement
    let window:AXUIElement?
    let frame:CGRect?
    let originBundleID:String
    let topology:String
    var task:Target
    var claimComplete=false
    var ownedFeishuReturn: OwnedFeishuMainReturn?
    var ownedFeishuOpen: OwnedFeishuSearchOpen?
    var ownedFeishuFocusUpdated = false
    var ownedFeishuReturnDiagnostic: [String: Any]?
}

// Activity must span real event time, not merely a burst of tap callbacks.
// Separate pointer/key streams allow key-up and isolated clicks without extending
// a gesture. Own events and pre-arm/stale/reordered timestamps never count.
struct SustainedInputActivity {
    static let pointerDuration = 0.5
    static let pointerIdle = 0.25
    static let keyboardDuration = 0.6
    static let keyboardIdle = 0.6
    static let maxDeliveryAge = 0.25
    private var baseline: CGEventTimestamp = 0
    private var latest: CGEventTimestamp = 0
    private var pointerStart: Double?
    private var pointerLast: Double?
    private var point: CGPoint?
    private var distance = 0.0
    private var moves = 0
    private var keyStart: Double?
    private var keyLast: Double?
    private var keys = 0

    mutating func reset(at timestamp: CGEventTimestamp) {
        self = SustainedInputActivity(); baseline = timestamp
    }
    mutating func observe(type: CGEventType, timestamp: CGEventTimestamp,
                          observed: CGEventTimestamp, location: CGPoint, own: Bool) -> String? {
        guard !own, timestamp > 0, timestamp >= baseline else { return nil }
        guard timestamp <= observed, observed - timestamp <= UInt64(Self.maxDeliveryAge * 1e9),
              timestamp >= latest else { reset(at: observed); return nil }
        latest = timestamp
        let time = Double(timestamp) / 1e9
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard location.x.isFinite, location.y.isFinite else { reset(at: observed); return nil }
            if pointerLast == nil || time - pointerLast! > Self.pointerIdle {
                pointerStart = time; moves = 0; distance = 0; point = nil
            }
            if let point { distance += hypot(location.x - point.x, location.y - point.y) }
            point = location; pointerLast = time; moves += 1
            if let start = pointerStart, time - start >= Self.pointerDuration, moves >= 4, distance >= 24 {
                return "sustained_mouse_movement"
            }
        case .keyDown:
            if keyLast == nil || time - keyLast! > Self.keyboardIdle {
                keyStart = time; keys = 0
            }
            keyLast = time; keys += 1 // auto-repeat is real ongoing keyboard input too.
            if let start = keyStart, time - start >= Self.keyboardDuration, keys >= 3 {
                return "sustained_keyboard_input"
            }
        default: break // key-up, modifiers, clicks and scroll do not establish a takeover.
        }
        return nil
    }
}

// A dedicated runloop prevents stdin/AX calls from starving takeover detection.
final class InputMonitor {
    let marker: Int64 = Int64.random(in: 1...Int64.max)
    private let lock = NSLock()
    private var armed = false
    private var sharedClaimActive = false
    private var claimEventTimestamp: CGEventTimestamp?
    private var interruption: String?
    private var lastInterruptionEvent: [String: Any]?
    private var scopedInterruption: String?
    private var scopedMode: ScopedInputMode = .sharedHID
    private var scopedTarget: ScopedBackgroundTarget?
    private var scopedCache: ScopedInputContextCache?
    private var foreignPointerAllowCount = 0
    private var externalInteractionRevision: UInt64 = 0
    private var focusQuietState = NativeFocusQuietState()
    private var focusHandoffPending = false
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var ready = false
    private var sharedActivity = SustainedInputActivity()
    private var scopedActivity = SustainedInputActivity()
    private let startup = DispatchSemaphore(value: 0)

    init() {
        let thread = Thread { [self] in
            let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                .otherMouseDragged, .mouseMoved, .scrollWheel]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                    if let context {
                        Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue().observe(type, event)
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: pointer)
            guard let created else { startup.signal(); return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
            lock.lock()
            tap = created
            loop = CFRunLoopGetCurrent()
            ready = true
            lock.unlock()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            startup.signal()
            CFRunLoopRun()
            CFMachPortInvalidate(created)
        }
        thread.name = "IntelDesktopHelper.Takeover"
        thread.start()
        _ = startup.wait(timeout: .now() + 1)
    }

    var available: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready && tap.map { CGEvent.tapIsEnabled(tap: $0) } == true
    }

    var reason: String? {
        lock.lock(); defer { lock.unlock() }
        return interruption
    }

    var lastInterruption: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return lastInterruptionEvent
    }
    var interactionRevision: UInt64 {
        lock.lock(); defer { lock.unlock() }; return externalInteractionRevision
    }
    var foreignPointerEventsAllowed: Int {
        lock.lock(); defer { lock.unlock() }; return foreignPointerAllowCount
    }

    var focusQuietObservation: NativeFocusQuietState {
        lock.lock(); defer { lock.unlock() }; return focusQuietState
    }

    func prepareExplicitFocus(quietRevision: UInt64?, continuing: Bool) throws {
        guard available else { throw fail("input_monitoring_unavailable", "Input monitoring is required before explicit focus") }
        lock.lock(); defer { lock.unlock() }
        if continuing {
            guard sharedClaimActive, interruption == nil else { throw fail("user_interrupted", "The existing focus claim is no longer continuous") }
            return
        }
        guard quietRevision == focusQuietState.revision, focusQuietState.quiet(at: ProcessInfo.processInfo.systemUptime) else {
            throw fail("user_interrupted", "User input continued after the handoff notice; original focus was retained")
        }
        let timestamp = inputClaimTimestamp()
        guard timestamp > 0 else { throw fail("input_monitoring_unavailable", "A current input baseline is unavailable") }
        // Arm before activation. A key arriving while activation settles must
        // stop the claim, not be erased by a new post-activation baseline.
        armed = true; sharedClaimActive = false; claimEventTimestamp = timestamp
        interruption = nil; focusHandoffPending = true
        scopedMode = .sharedHID; scopedTarget = nil; scopedCache = nil; scopedInterruption = nil
        sharedActivity.reset(at: timestamp); scopedActivity.reset(at: timestamp)
    }

    func completeExplicitFocus(retainClaim: Bool) throws {
        guard available else { throw fail("input_monitoring_unavailable", "Input monitoring is unavailable at focus claim") }
        lock.lock(); defer { lock.unlock() }
        guard interruption == nil, claimEventTimestamp != nil else {
            throw fail("user_interrupted", "User input interrupted focus acquisition; no editor input is allowed")
        }
        sharedClaimActive = retainClaim; armed = true; focusHandoffPending = false
    }

    func discardClaim() {
        lock.lock();defer{lock.unlock()}
        sharedClaimActive=false;claimEventTimestamp=nil;armed=false;focusHandoffPending=false
    }

    func begin(resume: Bool = false) throws {
        guard available else { throw fail("input_monitoring_unavailable", "Listen-only input monitoring is unavailable; grant Input Monitoring to this helper before desktop actions") }
        lock.lock(); defer { lock.unlock() }
        if resume { interruption = nil }
        if let reason = interruption { throw fail("user_interrupted", "User input interrupted control (\(reason)); send an explicit focus or resume request to continue") }
        armed = true
        if !sharedClaimActive { sharedActivity.reset(at: inputClaimTimestamp()) }
    }

    func beginScoped(mode: ScopedInputMode, target: ScopedBackgroundTarget, cache: ScopedInputContextCache) throws {
        guard available else { throw fail("input_monitoring_unavailable", "Background commands require the existing listen-only input monitor") }
        lock.lock(); defer { lock.unlock() }
        scopedMode = mode; scopedTarget = target; scopedCache = cache; scopedInterruption = nil
        foreignPointerAllowCount = 0
        armed = true; scopedActivity.reset(at: inputClaimTimestamp())
    }

    func end() {
        lock.lock(); armed = sharedClaimActive; scopedMode = .sharedHID; scopedTarget = nil; scopedCache = nil; scopedInterruption = nil; lock.unlock()
    }

    func check() throws {
        guard available else { throw fail("input_monitoring_unavailable", "Input monitoring became unavailable") }
        lock.lock(); let failure = scopedMode == .sharedHID ? interruption : scopedInterruption; lock.unlock()
        if let failure { throw fail("user_interrupted", "User input interrupted control (\(failure)); no further events were sent") }
    }

    func observe(_ type: CGEventType, _ event: CGEvent) {
        lock.lock(); defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            ready = false
            if armed {
                if scopedMode == .sharedHID { interruption = "input_monitor_disabled" } else { scopedInterruption = "input_monitor_disabled" }
                lastInterruptionEvent = inputInterruptionEvent(type, event, marker: marker, mode: scopedMode,
                    reason: "input_monitor_disabled", cached: scopedCache?.current(), claimTimestamp: claimEventTimestamp)
            }
            return
        }
        let ownEvent = event.getIntegerValueField(.eventSourceUserData) == marker
        focusQuietState.observe(type: type, key: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags, timestamp: event.timestamp, observed: inputClaimTimestamp(), point: event.location, own: ownEvent)
        if focusHandoffPending, !ownEvent, [.keyDown, .keyUp, .flagsChanged].contains(type), inputEventAfterClaim(event.timestamp, baseline: claimEventTimestamp) {
            interruption = "keyboard_input_during_handoff"
            lastInterruptionEvent = inputInterruptionEvent(type, event, marker: marker, mode: .sharedHID,
                reason: "keyboard_input_during_handoff", cached: nil, claimTimestamp: claimEventTimestamp)
        }
        // Isolated input is not a takeover, but it can invalidate a retained
        // editor focus proof. No input is consumed and no interruption is latched.
        if inputInvalidatesRetainedFocus(type, timestamp: event.timestamp, baseline: claimEventTimestamp,
                own: event.getIntegerValueField(.eventSourceUserData) == marker) {
            externalInteractionRevision &+= 1
        }
        guard armed, (scopedMode == .sharedHID ? interruption : scopedInterruption) == nil,
              event.getIntegerValueField(.eventSourceUserData) != marker else { return }
        if scopedMode == .sharedHID, !inputEventAfterClaim(event.timestamp,baseline:claimEventTimestamp) {return}
        if scopedMode != .sharedHID {
            let kind: ScopedInputKind
            switch type {
            case .keyDown: kind = .keyDown
            case .keyUp: kind = .keyUp
            case .flagsChanged: kind = .modifiers
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: kind = .pointerButton
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .pointerDrag
            case .mouseMoved: kind = .pointerMove
            case .scrollWheel: kind = .scroll
            default: kind = .unknown
            }
            let rawNow = inputClaimTimestamp()
            let activity = scopedActivity.observe(type: type, timestamp: event.timestamp,
                observed: rawNow, location: event.location, own: false)
            let cachedContext = scopedCache?.current()
            let pointerContext = scopedCache?.currentPointer()
            let input = ScopedInputEvent(kind: kind, observedAt: ProcessInfo.processInfo.systemUptime,
                keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                targetPID: pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID)),
                pointer: [.keyDown, .keyUp, .modifiers].contains(kind) ? nil : event.location,
                sustainedMovement: activity == "sustained_mouse_movement",
                sustainedKeyboard: activity == "sustained_keyboard_input")
            // A background command retains its own scoped decision. Separately
            // remember real post-claim user activity so a later foreground
            // restore cannot steal focus after the user took over in between.
            if sharedClaimActive, interruption == nil,
               let reason = sharedActivity.observe(type: type, timestamp: event.timestamp,
                    observed: rawNow, location: event.location, own: false) {
                interruption = reason
                lastInterruptionEvent = inputInterruptionEvent(type, event, marker: marker,
                    mode: .sharedHID, reason: reason, cached: cachedContext, claimTimestamp: claimEventTimestamp)
            }
            switch ScopedInputPolicy.decide(mode: scopedMode, event: input, target: scopedTarget, context: cachedContext,
                                           pointerContext: pointerContext) {
            case .allow:
                if [.pointerButton, .pointerDrag, .scroll].contains(kind) || kind == .pointerMove && input.sustainedMovement {
                    foreignPointerAllowCount += 1
                }
            case .interrupt(let why), .invalidateRead(let why):
                scopedInterruption = why
                lastInterruptionEvent = inputInterruptionEvent(type, event, marker: marker, mode: scopedMode, reason: why, cached: cachedContext, claimTimestamp: claimEventTimestamp, pointerContext: pointerContext)
            }
            return
        }
        interruption = sharedActivity.observe(type: type, timestamp: event.timestamp,
            observed: inputClaimTimestamp(), location: event.location, own: false)
        if let interruption {
            lastInterruptionEvent = inputInterruptionEvent(type, event, marker: marker, mode: scopedMode, reason: interruption, cached: nil, claimTimestamp: claimEventTimestamp)
        }
    }

    func stop() {
        lock.lock(); let current = loop; lock.unlock()
        if let current { CFRunLoopStop(current) }
    }
}

func actualMainCGWindowID(pid: pid_t, bounds: CGRect, rows: [[String: Any]]) -> CGWindowID? {
    let matches = rows.filter { row in
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let raw = row[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
        return rect == bounds
    }
    guard matches.count == 1 else { return nil }
    return (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
}

// Feishu's search modal and main window can have identical frames and layers.
// Only the exact current AX main title disambiguates this observed pair.
func feishuReturnMainCGWindowID(pid: pid_t, bounds: CGRect, actualAXTitle: String, rows: [[String: Any]]) -> CGWindowID? {
    guard actualAXTitle == "飞书" else { return nil }
    let named = rows.filter { row in
        guard row[kCGWindowName as String] as? String == actualAXTitle,
              let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
              alpha.isFinite, alpha > 0, alpha <= 1 else { return false }
        return true
    }
    guard let id = actualMainCGWindowID(pid: pid, bounds: bounds, rows: named), id != kCGNullWindowID else { return nil }
    return id
}

func feishuSearchEscapeReturnEligible(bundle: String, title: String?, key: String, flags: CGEventFlags) -> Bool {
    bundle == "com.bytedance.macos.feishu" && title == feishuSearchWindowTitle && key == "escape" && flags.isEmpty
}

// The actual WeChat main window can expose AXWindow without a focused child.
// That absence is not permission to edit: only its observed recent-chat sidebar
// supports a coordinate navigation click with all downstream AX hit guards.
func wechatSidebarNavigationWithoutFocusedElement(bundle: String, expectedTitle: String?,
    currentTitle: String?, windowRole: String?, frame: CGRect?, point: CGPoint,
    focusRead: AXError, hasRawFocus: Bool, foregroundScope: Bool,
    secureEventInput: Bool?) -> Bool {
    guard bundle == "com.tencent.xinWeChat", expectedTitle == "微信", currentTitle == "微信",
          windowRole == kAXWindowRole, foregroundScope, secureEventInput == false, !hasRawFocus,
          focusRead == .noValue || focusRead == .attributeUnsupported || focusRead == .success,
          let frame, frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
          frame.width > 317, frame.height > 80, point.x.isFinite, point.y.isFinite else { return false }
    return point.x > frame.minX + 56 && point.x < frame.minX + 317 &&
           point.y > frame.minY + 50 && point.y < frame.maxY - 30
}

struct Target {
    let bundleID: String
    let application: NSRunningApplication
    let axApplication: AXUIElement
    let window: AXUIElement
    let expectedTitle: String?
    let displaySignature: String
    var pid: pid_t { application.processIdentifier }
}

struct CachedElement {
    let element: AXUIElement
    let window: AXUIElement
    let bundleID: String
    let pid: pid_t
    var dialog: AXUIElement? = nil
}

struct NativeSubmitExpected {
    let composerID: String
    let recipientID: String
    let recipient: String
    let value: String
    let empty: String
    init(_ request: [String: Any]) throws {
        guard try boolean(request, "allow_submit") else { throw fail("submit_not_authorized", "submit_text requires allow_submit=true under the caller's exact current authorization") }
        composerID = try string(request, "element_id")!
        recipientID = try string(request, "recipient_element_id")!
        recipient = try string(request, "expected_recipient")!
        value = try string(request, "expected_value")!
        guard let empty = try string(request, "expected_empty_value", required: false),
              value.count <= 65536, empty.count <= 65536, recipient.count <= 1024,
              value != empty, composerID != recipientID else { throw fail("invalid_request", "Distinct cached composer/header and nonempty draft differing from expected_empty_value are required") }
        self.empty = empty
        let visible = visualNormalizedText(value)
        let placeholder = "发送给" + visualNormalizedText(recipient)
        guard !visible.isEmpty, visible != placeholder, visible != "按住fn说话" + placeholder else {
            throw fail("submit_empty_draft", "The complete AX value is an empty Feishu placeholder, including its voice-hint variant")
        }
    }
}

struct NativeSubmitObservation: Equatable {
    let bundle: String
    let title: String
    let topology: String
    let window: CGRect
    let chat: CGRect
    let composer: CGRect
    let recipient: CGRect
    let composerRole: String
    let recipientRole: String
    let recipientText: String
    let value: String
    let sameChatAndWindow: Bool
    let focused: Bool
    let enabled: Bool
}

func validateNativeSubmit(_ observed: NativeSubmitObservation, expected: NativeSubmitExpected) throws {
    guard observed.bundle == "com.bytedance.macos.feishu", observed.title == "飞书" else {
        throw fail("submit_target_unsupported", "submit_text supports only the exact Feishu main window")
    }
    guard observed.sameChatAndWindow, observed.composerRole == "AXTextArea", observed.recipientRole == "AXStaticText",
          visualContains(observed.window, observed.chat), visualContains(observed.chat, observed.composer),
          observed.recipient.height > 2,
          visualContains(CGRect(x: observed.chat.minX, y: observed.chat.minY,
            width: observed.chat.width * 0.67, height: min(56, observed.chat.height)), observed.recipient) else {
        throw fail("submit_recipient_unverified", "Composer and actual top-left messenger-chat header must belong to the same current chat window")
    }
    guard observed.recipientText == expected.recipient else { throw fail("submit_recipient_mismatch", "Current chat header does not exactly match expected_recipient") }
    guard observed.focused, observed.enabled else { throw fail("submit_composer_not_focused", "The exact enabled composer must already be focused") }
    guard observed.value == expected.value else { throw fail("submit_value_mismatch", "Complete current AX composer value differs from expected_value") }
}

// Public AX cannot lock another process. Keep both observations and the final
// guard within this native command, then emit exactly one Return pair. Callers
// must still verify fresh post-submit chat evidence; events are not delivery.
func performNativeSubmit(expected: NativeSubmitExpected, observe: () throws -> NativeSubmitObservation,
                         guardTarget: () throws -> Void, down: () throws -> Void, up: () -> Void,
                         events: inout Int) throws {
    try guardTarget()
    let first = try observe()
    try validateNativeSubmit(first, expected: expected)
    try guardTarget()
    let last = try observe()
    try validateNativeSubmit(last, expected: expected)
    guard last == first else { throw fail("submit_target_changed", "Submit target geometry or observed state changed within the command") }
    try guardTarget()
    try down(); events += 1
    up(); events += 1 // Always release the single posted Return, without replay.
}

final class DesktopHelper {
    let monitor = InputMonitor()
    let visual = VisualDesktop()
    let observation = NativeObservation()
    var backgroundScope: BackgroundCommandScope?
    // Internal synchronous pixel-read phase only; never a request field or an
    // input capability. Actual posts call scope.verify directly.
    var backgroundTargetReadDepth = 0
    private var previousFocus: PreviousFocusRecord?
    private let legacyRuntimeTaskID = "legacy-native-session-" + UUID().uuidString
    private var runtimeTaskID: String?
    private var runtimeOperationID: String?
    private var currentRuntimeTaskID: String { runtimeTaskID ?? legacyRuntimeTaskID }
    private var cache: [String: CachedElement] = [:]
    private var inspectedDialogs: [NativeInspectedDialog] = []
    private var acceptedAXWindowTransition: (task: String, operation: String, pid: pid_t, bundle: String, revision: UInt64, until: Double)?
    private var generation = 0
    private var displaySignature: String?
    private var displayTopologyGeneration = 0
    private var displayChangeNeedsInspect = false
    private var accessibilityWriteResults: [String: AXError] = [:]
    var source: CGEventSource? = CGEventSource(stateID: .privateState)
    let commands: Set<String> = ["status", "ping", "inspect", "focus", "resume", "press", "click", "scroll", "set_text", "select_text", "type_text", "clear_text", "submit_text", "key", "batch", "wait_text", "background_observe", "background_type_text", "background_chat_edit", "background_visual_read", "visual_read", "visual_click", "visual_type_text", "visual_key", "visual_scroll"]
    let mutationCommands: Set<String> = ["focus", "resume", "press", "click", "scroll", "set_text", "type_text", "clear_text", "submit_text", "key", "batch", "visual_click", "visual_type_text", "visual_key", "visual_scroll"]

    func currentDisplays() throws -> DisplaySnapshot {
        let current = try activeDisplays()
        if displaySignature != current.signature {
            if displaySignature != nil { displayChangeNeedsInspect = true }
            cache.removeAll(keepingCapacity: true)
            inspectedDialogs.removeAll(keepingCapacity: true)
            displaySignature = current.signature
            displayTopologyGeneration += 1
        }
        return current
    }

    func verifyDisplayTopology(_ target: Target) throws {
        guard try currentDisplays().signature == target.displaySignature else {
            throw fail("display_topology_changed", "Display topology changed; inspect and focus the target again before further actions")
        }
    }

    func checkAfterAcceptedAction(_ method: String) throws {
        do { try monitor.check() }
        catch {
            let underlying = error as? HelperError ?? fail("internal_error", error.localizedDescription)
            var details = underlying.details
            details["action_accepted"] = true; details["method"] = method
            throw fail(underlying.code, underlying.message, details)
        }
    }

    func accessibilityAttributeProbe(_ element: AXUIElement, name: String) -> [String: Any] {
        let (original, readResult) = axBooleanResult(element, name)
        let (settable, settableResult) = axSettableResult(element, name)
        return ["attribute": name, "original_value": original.map { $0 as Any } ?? NSNull(),
            "read_result": axResult(readResult), "settable": settable.map { $0 as Any } ?? NSNull(),
            "settable_result": axResult(settableResult)]
    }

    func accessibilityEnablement(_ root: AXUIElement, application: NSRunningApplication,
                                bundle: String, requested: Bool) -> [String: Any] {
        let identity = "\(bundle):\(application.processIdentifier):\(application.launchDate?.timeIntervalSince1970 ?? 0)"
        var attributes: [[String: Any]] = []
        var manualEnabled = false
        var anyEnabled = false
        var anyAccepted = false
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            var record = accessibilityAttributeProbe(root, name: name)
            let original = record["original_value"] as? Bool
            let readCode = (record["read_result"] as? [String: Any])?["code"] as? Int32
            let settableCode = (record["settable_result"] as? [String: Any])?["code"] as? Int32
            let supported = readCode == AXError.success.rawValue || settableCode == AXError.success.rawValue
            let key = "\(identity):\(name)"
            record["supported"] = supported
            record["attempted"] = false
            record["write_result"] = NSNull()
            record["verified_enabled"] = original == true
            var enabled = original == true
            if original == true { record["status"] = "already_enabled" }
            else if !requested { record["status"] = "not_requested" }
            else if name == "AXEnhancedUserInterface" && manualEnabled { record["status"] = "fallback_not_needed" }
            else if !supported { record["status"] = "unsupported" }
            else if let previous = accessibilityWriteResults[key] {
                record["status"] = "previous_attempt_not_repeated"
                record["previous_write_result"] = axResult(previous)
            } else {
                let writeResult = AXUIElementSetAttributeValue(root, name as CFString, kCFBooleanTrue)
                record["attempted"] = true
                record["write_result"] = axResult(writeResult)
                if [.success, .attributeUnsupported, .actionUnsupported, .notImplemented].contains(writeResult) {
                    accessibilityWriteResults[key] = writeResult
                }
                let (after, afterResult) = axBooleanResult(root, name)
                enabled = after == true
                record["value_after"] = after.map { $0 as Any } ?? NSNull()
                record["read_after_result"] = axResult(afterResult)
                record["verified_enabled"] = enabled
                record["status"] = writeResult == .success ? (enabled ? "enabled_verified" : "write_accepted_unverified") : "write_failed"
                if writeResult == .success { anyAccepted = true }
            }
            if name == "AXManualAccessibility" { manualEnabled = enabled }
            anyEnabled = anyEnabled || enabled
            attributes.append(record)
        }
        return ["requested": requested, "attributes": attributes, "enabled": anyEnabled,
            "any_write_accepted": anyAccepted, "target": "AXApplication",
            "unsupported_is_success": false]
    }

    func accessibilityTreeProbe(_ windows: [AXUIElement], deadline: Double) -> [String: Any] {
        var queue = windows.map { ($0, 0) }
        var visited: [AXUIElement] = []
        var index = 0
        var webArea = false
        var editable = false
        while index < queue.count && visited.count < 32 && ProcessInfo.processInfo.systemUptime < deadline {
            let (element, level) = queue[index]; index += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.12)
            let role = axString(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { webArea = true }
            if ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) && !isSecure(element) { editable = true }
            if webArea || editable { break }
            if level < 6 && !isSecure(element) {
                let counts = axChildCounts(element)
                queue.append(contentsOf: axNavigationChildren(element, limit: max(0, 32 - queue.count + index), counts: counts).elements.map { ($0, level + 1) })
            }
        }
        return ["nodes_seen": visited.count, "web_area_found": webArea, "editable_role_found": editable,
            "max_nodes": 32, "max_depth": 6]
    }

    func focusedElementDiagnostic(_ root: AXUIElement, application: NSRunningApplication,
                                  bundle: String, selected: [AXUIElement], displays: DisplaySnapshot) -> [String: Any] {
        var value: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
        var observed: AXUIElement?
        if readResult == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() { observed = unsafeBitCast(value, to: AXUIElement.self) }
        let dialogs = inspectedDialogs.filter { record in record.runtimeTaskID == currentRuntimeTaskID && record.ownerPID == application.processIdentifier &&
            record.bundleID == bundle && selected.contains(where: { CFEqual($0, record.ownerWindow) }) }
        if observed == nil, !dialogs.isEmpty {
            let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.12)
            if let candidate = axElement(system, kAXFocusedUIElementAttribute), dialogs.contains(where: { nativeElementInDialog(candidate, dialog: $0.dialog) }) { observed = candidate }
        }
        guard let element = observed else { return ["available": false, "read_result": axResult(readResult)] }
        AXUIElementSetMessagingTimeout(element, 0.15)
        let associated = dialogs.first { nativeElementInDialog(element, dialog: $0.dialog) }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == application.processIdentifier || associated != nil else {
            return ["available": false, "error": "focused_element_pid_mismatch"]
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var current: AXUIElement? = element
        var matchedWindow: AXUIElement?
        for _ in 0..<64 {
            guard let item = current, ProcessInfo.processInfo.systemUptime < deadline else { break }
            AXUIElementSetMessagingTimeout(item, 0.12)
            if isSecure(item) { return ["available": true, "secure": true, "readback_redacted": true] }
            if let matched = selected.first(where: { CFEqual($0, item) }) { matchedWindow = matched; break }
            if let window = axElement(item, kAXWindowAttribute), let matched = selected.first(where: { CFEqual($0, window) }) {
                matchedWindow = matched; break
            }
            current = axElement(item, kAXParentAttribute)
        }
        guard let window = matchedWindow ?? associated?.ownerWindow else { return ["available": true, "within_selected_window": false, "readback_redacted": true] }
        do { try denySecure(element) }
        catch { return ["available": true, "secure": true, "readback_redacted": true] }
        AXUIElementSetMessagingTimeout(element, 0.15)
        let existing = cache.first { CFEqual($0.value.element, element) && CFEqual($0.value.window, window) }?.key
        let id = existing ?? "g\(generation)-focused"
        cache[id] = CachedElement(element: element, window: window, bundleID: bundle, pid: pid, dialog: associated?.dialog)
        let role = axString(element, kAXRoleAttribute) ?? "AXUnknown"
        let (valueSettable, valueSetResult) = axSettableResult(element, kAXValueAttribute)
        let (focusSettable, focusSetResult) = axSettableResult(element, kAXFocusedAttribute)
        let range = axSelectedRange(element)
        let readable = readableValue(element)
        var result: [String: Any] = ["available": true, "within_selected_window": true, "secure": false,
            "element_id": id, "element_pid": pid, "associated_dialog": associated != nil,
            "role": role, "title": axString(element, kAXTitleAttribute) ?? "",
            "description": axString(element, kAXDescriptionAttribute) ?? "", "actions": axActions(element),
            "value_readable": readable != nil, "value_settable": valueSettable.map { $0 as Any } ?? NSNull(),
            "value_settable_result": axResult(valueSetResult), "focused_settable": focusSettable.map { $0 as Any } ?? NSNull(),
            "focused_settable_result": axResult(focusSetResult),
            "selected_text_range": range.map { ["location": $0.location, "length": $0.length] as Any } ?? NSNull(),
            "input_candidate": ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) && readable != nil && (valueSettable == true || range != nil)]
        if let readable { result["value"] = readable }
        if let bounds = axBounds(element) {
            result["position"] = ["x": bounds.minX, "y": bounds.minY]
            result["size"] = ["width": bounds.width, "height": bounds.height]
            result.merge(displays.associations(for: bounds)) { _, new in new }
        }
        return result
    }

    func running(_ bundleID: String) throws -> (NSRunningApplication, AXUIElement) {
        var found = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        if found.isEmpty {
            // A just-moved/restored application can momentarily disappear from
            // AppKit's main-thread cache. Refresh discovery once, before any
            // target or event is created; never replay an action.
            _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
            found = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        }
        guard !found.isEmpty else { throw fail("app_not_running", "Application is not running: \(bundleID)") }
        guard found.count == 1 else { throw fail("ambiguous_app", "More than one running process has bundle ID \(bundleID)") }
        let app = found[0]
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.8)
        return (app, root)
    }

    func windows(_ root: AXUIElement) -> [AXUIElement] {
        axElements(root, kAXWindowsAttribute, limit: 128)
    }

    func actualMainWindow(_ root: AXUIElement) -> (AXUIElement, CGWindowID)? {
        guard let main = axElement(root, kAXMainWindowAttribute), let bounds = axBounds(main) else { return nil }
        var pid: pid_t = 0, owner: pid_t = 0
        guard AXUIElementGetPid(root, &pid) == .success, AXUIElementGetPid(main, &owner) == .success, pid == owner else { return nil }
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        guard let id = actualMainCGWindowID(pid: pid, bounds: bounds, rows: rows) else { return nil }
        return (main, id)
    }

    func selectWindow(_ root: AXUIElement, title: String?) throws -> AXUIElement {
        let all = windows(root)
        let selectionMetadata: [String: Any] = ["window_selection_scope": title == nil ? "focused_or_unique" : "exact_title",
            "window_list_count": all.count, "requested_window_kind": title == "飞书" ? "feishu_main" : title == feishuSearchWindowTitle ? "feishu_search" : "other"]
        guard !all.isEmpty else { throw fail("window_not_found", "No accessible windows found for the running application", selectionMetadata) }
        if let title {
            let matched = all.filter { axString($0, kAXTitleAttribute) == title }
            if matched.count > 1, let actual = actualMainWindow(root),
               matched.contains(where: { CFEqual($0, actual.0) }) {
                var pid: pid_t = 0
                if AXUIElementGetPid(root, &pid) == .success {
                    let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                    // These observed apps expose duplicate shell titles. The current
                    // AX main window must independently match one actual CG window;
                    // no ordering, largest-window or title-only guess selects it.
                    if (bundle == "com.tencent.xinWeChat" && title == "微信") || bundle == "com.openai.codex" {
                        return actual.0
                    }
                }
            }
            guard matched.count == 1 else {
                throw fail(matched.isEmpty ? "window_not_found" : "ambiguous_window", "Expected exactly one window with title: \(title)", selectionMetadata)
            }
            return matched[0]
        }
        if let focused = axElement(root, kAXFocusedWindowAttribute), all.contains(where: { CFEqual($0, focused) }) { return focused }
        if all.count == 1 { return all[0] }
        throw fail("window_title_required", "Multiple windows exist; provide an exact window_title")
    }

    func target(_ request: [String: Any]) throws -> Target {
        let bundle = try string(request, "app")!
        let title = try string(request, "window_title", required: false)
        let displays = try currentDisplays()
        guard !displayChangeNeedsInspect else {
            throw fail("display_topology_changed", "Display topology changed; inspect the target again before focusing or sending further actions")
        }
        let (app, root) = try running(bundle)
        let window = try selectWindow(root, title: title)
        AXUIElementSetMessagingTimeout(window, 0.8)
        return Target(bundleID: bundle, application: app, axApplication: root, window: window,
            expectedTitle: title, displaySignature: displays.signature)
    }

    func requireAX() throws {
        guard AXIsProcessTrusted() else { throw fail("accessibility_unavailable", "Accessibility permission is unavailable; this helper never prompts for it") }
    }

    func dialogFocusMatches(_ dialog: AXUIElement, ownerWindow: AXUIElement, root: AXUIElement) -> Bool {
        // AXFocusedWindow is remembered while an app is backgrounded. Require
        // current foreground ownership before accepting that remembered edge.
        if axBool(root, kAXFrontmostAttribute) == true {
            if let focused = axElement(root, kAXFocusedWindowAttribute), CFEqual(focused, dialog) { return true }
            if let element = axElement(root, kAXFocusedUIElementAttribute), nativeElementInDialog(element, dialog: dialog) { return true }
        }
        // System focus may be represented by the app's remote Open/Save service.
        // Only an element in this exact app-published dialog is admissible.
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.12)
        guard let element = axElement(system, kAXFocusedUIElementAttribute) else { return false }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && foregroundMetadata().pid == pid &&
            nativeElementInDialog(element, dialog: dialog)
    }

    func currentInspectedDialog(_ target: Target) throws -> NativeInspectedDialog? {
        let records = inspectedDialogs.filter {
            $0.runtimeTaskID == currentRuntimeTaskID && $0.bundleID == target.bundleID &&
                $0.ownerPID == target.pid && CFEqual($0.ownerWindow, target.window)
        }
        guard records.count <= 1 else { throw fail("dialog_identity_ambiguous", "Inspect one active associated dialog before input") }
        guard let record = records.first else { return nil }
        guard nativeDialogAttached(record.dialog, to: target.window, applicationRoot: target.axApplication, ownerPID: target.pid),
              axBounds(record.dialog) == record.frame,
              dialogFocusMatches(record.dialog, ownerWindow: target.window, root: target.axApplication) else {
            throw fail("dialog_identity_changed", "The inspected dialog closed, moved, or changed association/focus; inspect the authorized app again")
        }
        try denySecure(target.window); try denySecure(record.dialog)
        return record
    }

    func dialogFocusedElement(_ target: Target, dialog: AXUIElement) -> AXUIElement? {
        if let focused = axElement(target.axApplication, kAXFocusedUIElementAttribute), nativeElementInDialog(focused, dialog: dialog) { return focused }
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.12)
        guard let focused = axElement(system, kAXFocusedUIElementAttribute), nativeElementInDialog(focused, dialog: dialog) else { return nil }
        return focused
    }

    func verify(_ target: Target, foreground: Bool = true, focusedWindow: Bool = true) throws {
        if let scope = backgroundScope {
            if scope.mode != .readOnly { try monitor.check() }
            try verifyDisplayTopology(target)
            if backgroundTargetReadDepth > 0, scope.binding.chatAdapter {
                try scope.verifyReadTarget(target)
            } else { try scope.verify(target) }
            return
        }
        try monitor.check()
        try verifyDisplayTopology(target)
        guard !target.application.isTerminated else { throw fail("app_not_running", "Target application terminated") }
        let dialog = focusedWindow ? try currentInspectedDialog(target) : nil
        if foreground {
            let associatedForeground: Bool = dialog.map { bound in
                guard let focused = dialogFocusedElement(target, dialog: bound.dialog) else { return false }
                var focusedPID: pid_t = 0
                return AXUIElementGetPid(focused, &focusedPID) == .success && foregroundMetadata().pid == focusedPID
            } ?? false
            guard let direct = axBool(target.axApplication, kAXFrontmostAttribute) else {
                throw fail("foreground_state_unavailable", "Target application's AXFrontmost state is unavailable")
            }
            guard direct || associatedForeground else {
                let actual = foregroundMetadata()
                throw fail("foreground_mismatch", "Target application is not in the foreground; send focus explicitly",
                    ["expected_pid": target.pid, "actual_pid": actual.pid ?? 0,
                     "source": "AXFrontmost", "actual_pid_source": actual.source])
            }
        }
        if let expected = target.expectedTitle, axString(target.window, kAXTitleAttribute) != expected {
            throw fail("window_mismatch", "Target window title changed")
        }
        if focusedWindow {
            if dialog != nil { return }
            let liveSheets = axElements(target.window, nativeAXSheetsAttribute, limit: 16)
            if liveSheets.contains(where: { nativeDialogRole(axString($0, kAXRoleAttribute), subrole: axString($0, kAXSubroleAttribute), modal: axBool($0, kAXModalAttribute)) }) {
                throw fail("dialog_requires_inspect", "An attached dialog is active; inspect the authorized app before using its new controls")
            }
            guard let focused = axElement(target.axApplication, kAXFocusedWindowAttribute), CFEqual(focused, target.window) else {
                throw fail("window_mismatch", "The focused window does not match the selected target window")
            }
        }
    }

    func cached(_ request: [String: Any], target: Target) throws -> AXUIElement {
        let id = try string(request, "element_id")!
        guard let saved = cache[id] else { throw fail("stale_element", "Unknown element_id; inspect the target again") }
        guard saved.bundleID == target.bundleID, CFEqual(saved.window, target.window) else {
            throw fail("element_target_mismatch", "element_id is bound to a different application, process or window")
        }
        var currentPID: pid_t = 0
        guard AXUIElementGetPid(saved.element, &currentPID) == .success, currentPID == saved.pid else {
            throw fail("stale_element", "Cached element process identity changed")
        }
        if let bound = try currentInspectedDialog(target) {
            guard saved.dialog.map({ CFEqual($0, bound.dialog) }) == true,
                  nativeElementInDialog(saved.element, dialog: bound.dialog) else {
                throw fail("element_target_mismatch", "Element is not in the freshly inspected active dialog")
            }
        } else if saved.dialog != nil || saved.pid != target.pid {
            throw fail("element_target_mismatch", "Remote/dialog elements require a current inspected app association")
        }
        AXUIElementSetMessagingTimeout(saved.element, 0.8)
        try denySecure(saved.element)
        return saved.element
    }

    func denySecure(_ element: AXUIElement) throws {
        var current: AXUIElement? = element
        for _ in 0..<64 {
            guard let item = current else { return }
            if isSecure(item) { throw fail("secure_field_denied", "Secure/protected fields cannot be inspected or modified") }
            current = axElement(item, kAXParentAttribute)
        }
        if current != nil { throw fail("ancestry_limit", "Element ancestry exceeds the secure-field verification limit") }
    }

    func focused(_ target: Target) throws -> AXUIElement {
        let bound = try currentInspectedDialog(target)
        guard let element = bound.map({ dialogFocusedElement(target, dialog: $0.dialog) }) ?? axElement(target.axApplication, kAXFocusedUIElementAttribute) else {
            throw fail("focused_element_unavailable", "No accessible focused element in the selected window/dialog")
        }
        try denySecure(element)
        return element
    }

    func keyFocusedElement(_ target: Target, name: String, flags: CGEventFlags) throws -> AXUIElement? {
        if try currentInspectedDialog(target) != nil { return try focused(target) }
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(target.axApplication, kAXFocusedUIElementAttribute as CFString, &raw)
        if result == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let element = unsafeBitCast(raw, to: AXUIElement.self)
            try denySecure(element)
            return element
        }
        guard name == "escape", flags.isEmpty,
              result == .noValue || result == .attributeUnsupported || (result == .success && raw == nil) else {
            throw fail("focused_element_unavailable", "No accessible focused element", ["read_result": axResult(result)])
        }
        guard target.expectedTitle != nil else {
            throw fail("window_title_required", "Escape without a focused element requires an exact window_title")
        }
        try denySecure(target.window)
        return nil
    }

    func inspectMenus(_ root: AXUIElement, application: NSRunningApplication, bundle: String,
                      window: AXUIElement, displays: DisplaySnapshot, depth: Int, limit: Int,
                      deadline: Double) -> (elements: [[String: Any]], metadata: [String: Any], reasons: Set<String>) {
        var raw: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &raw)
        var metadata: [String: Any] = ["menus_read_result": axResult(readResult),
            "menu_window_title": axString(window, kAXTitleAttribute) ?? "",
            "menus_excluded_policy": ["apple_menu", "services", "recent_items"]]
        guard readResult == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            metadata["menus_available"] = false
            metadata["menus_excluded_subtrees"] = [] as [[String: Any]]
            let reasons: Set<String> = [.attributeUnsupported, .noValue].contains(readResult) ? [] : ["menu_read_failed"]
            return ([], metadata, reasons)
        }
        let menuBar = unsafeBitCast(raw, to: AXUIElement.self)
        metadata["menus_available"] = true
        var queue: [(AXUIElement, Int, String?, [String])] = [(menuBar, 0, nil, [])]
        var index = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var elements: [[String: Any]] = []
        var excluded: [[String: Any]] = []
        var reasons: Set<String> = []
        var roleCounts: [String: Int] = [:]
        while index < queue.count && elements.count < limit {
            if ProcessInfo.processInfo.systemUptime >= deadline { reasons.insert("time_limit"); break }
            let (item, level, parentID, parentPath) = queue[index]; index += 1
            let hash = CFHash(item)
            if seen[hash]?.contains(where: { CFEqual($0, item) }) == true { continue }
            seen[hash, default: []].append(item)
            AXUIElementSetMessagingTimeout(item, 0.8)
            var pid: pid_t = 0
            guard AXUIElementGetPid(item, &pid) == .success, pid == application.processIdentifier else {
                reasons.insert("menu_process_mismatch"); continue
            }
            let role = axString(item, kAXRoleAttribute) ?? "AXUnknown"
            let title = axString(item, kAXTitleAttribute) ?? ""
            let path = ["AXMenuBarItem", "AXMenuItem"].contains(role) && !title.isEmpty ? parentPath + [title] : parentPath
            if let reason = excludedMenuBranch(role: role, title: title) {
                excluded.append(["menu_path": path, "reason": reason])
                continue // Do not read actions, values or children of excluded branches.
            }
            let id = "g\(generation)-m\(elements.count + 1)"
            let secure = isSecure(item)
            cache[id] = CachedElement(element: item, window: window, bundleID: bundle, pid: pid)
            roleCounts[role, default: 0] += 1
            var row: [String: Any] = ["element_id": id, "role": role, "depth": level,
                "title": title, "description": axString(item, kAXDescriptionAttribute) ?? "",
                "menu_path": path, "enabled": axBool(item, kAXEnabledAttribute) ?? true,
                "focused": axBool(item, kAXFocusedAttribute) ?? false, "actions": axActions(item),
                "secure": secure]
            if let parentID { row["parent_id"] = parentID }
            if let subrole = axString(item, kAXSubroleAttribute) { row["subrole"] = subrole }
            if let identifier = axString(item, "AXIdentifier") { row["identifier"] = identifier }
            if !secure {
                if let shortcut = axString(item, "AXMenuItemCmdChar") { row["shortcut_char"] = shortcut }
                if let modifiers = axValue(item, "AXMenuItemCmdModifiers") as? NSNumber { row["shortcut_modifiers"] = modifiers.intValue }
                if let glyph = axValue(item, "AXMenuItemCmdGlyph") as? NSNumber { row["shortcut_glyph"] = glyph.intValue }
            }
            let counts = secure ? [] : axChildCounts(item)
            reasons.formUnion(axChildCountReasons(counts))
            if !secure { row["child_sources"] = counts.map { ["attribute": $0.name, "count": $0.count, "result": axResult($0.result)] as [String: Any] } }
            if let bounds = axBounds(item) {
                row["position"] = ["x": bounds.minX, "y": bounds.minY]
                row["size"] = ["width": bounds.width, "height": bounds.height]
                row.merge(displays.associations(for: bounds)) { _, new in new }
            }
            elements.append(row)
            if level < depth && !secure {
                let available = max(0, limit - elements.count - (queue.count - index))
                let children = axNavigationChildren(item, limit: available, counts: counts)
                reasons.formUnion(children.reasons)
                queue.append(contentsOf: children.elements.map { ($0, level + 1, id, path) })
            } else if !secure && counts.contains(where: { $0.count > 0 }) { reasons.insert("depth_limit") }
        }
        if index < queue.count && elements.count >= limit { reasons.insert("node_limit") }
        metadata["menus_excluded_subtrees"] = excluded
        metadata["menu_role_counts"] = roleCounts
        return (elements, metadata, reasons)
    }

    func inspect(_ request: [String: Any]) throws -> [String: Any] {
        let depth = try integer(request, "max_depth", default: 8, range: 0...40)
        let limit = try integer(request, "max_nodes", default: 500, range: 1...2000)
        let enable = try boolean(request, "enable_accessibility")
        let includeMenus = try boolean(request, "include_menus")
        let includeImage = try boolean(request, "include_image")
        let title = try string(request, "window_title", required: false)
        if includeImage && title == nil { throw fail("invalid_request", "include_image requires an explicit exact window_title") }
        let bundle = try string(request, "app")!
        let displays = try currentDisplays()
        let (app, root) = try running(bundle)
        generation += 1
        cache.removeAll(keepingCapacity: true)
        inspectedDialogs.removeAll(keepingCapacity: true)
        var enablement = accessibilityEnablement(root, application: app, bundle: bundle, requested: enable)
        let windowRead = inspectionWindowList(root)
        let all = windowRead.windows
        // Consume only this operation's accepted exact search navigation while
        // reading the new state. This also handles read-only stages which may
        // wait for a reply long after closing their initial search modal.
        if bundle == "com.bytedance.macos.feishu", !all.isEmpty, previousFocus?.runtimeTaskID == currentRuntimeTaskID {
            let modalCount = all.filter { axString($0, kAXTitleAttribute) == feishuSearchWindowTitle }.count
            if modalCount == 0 && previousFocus?.ownedFeishuReturn != nil { _ = adoptOwnedFeishuMainReturn() }
            if modalCount == 1 && previousFocus?.ownedFeishuOpen != nil { _ = adoptOwnedFeishuSearchOpen() }
        }
        let verifiedMain = all.isEmpty ? nil : actualMainWindow(root)
        let selected: [AXUIElement]
        if title != nil {
            do { selected = [try selectWindow(root, title: title)] }
            catch let error as HelperError {
                var details = error.details.merging(windowRead.metadata) { _, new in new }
                details["inspection_stage"] = "exact_window_selection"
                throw fail(error.code, error.message, details)
            }
        } else { selected = all }
        // An accepted AX navigation may open or close an app-owned window.
        // Fresh inspection advances only the focus receipt; cached controls
        // remain window-bound and no new input or authorization is produced.
        if let accepted = acceptedAXWindowTransition {
            let quiet = monitor.focusQuietObservation
            if accepted.task != currentRuntimeTaskID || accepted.operation != runtimeOperationID ||
               accepted.revision != quiet.revision || ProcessInfo.processInfo.systemUptime > accepted.until {
                acceptedAXWindowTransition = nil
            } else if accepted.pid == app.processIdentifier, accepted.bundle == bundle,
                      monitor.reason == nil, axBool(root, kAXFrontmostAttribute) == true,
                      let active = axElement(root, kAXFocusedWindowAttribute),
                      all.contains(where: { CFEqual($0, active) }), selected.contains(where: { CFEqual($0, active) }),
                      let prior = previousFocus, prior.claimComplete, prior.runtimeTaskID == currentRuntimeTaskID,
                      prior.task.pid == app.processIdentifier, prior.task.bundleID == bundle,
                      prior.topology == displays.signature, !prior.task.application.isTerminated,
                      axBounds(active) != nil {
                previousFocus?.task = Target(bundleID: bundle, application: app, axApplication: root,
                    window: active, expectedTitle: axString(active, kAXTitleAttribute), displaySignature: displays.signature)
                acceptedAXWindowTransition = nil
            }
        }
        let observedFocus = all.isEmpty ? nil : axElement(root, kAXFocusedWindowAttribute)
        let focusedIndex = observedFocus.flatMap { focused in all.firstIndex(where: { CFEqual($0, focused) }) }
        let menuWindow: AXUIElement? = !includeMenus ? nil : title != nil ? selected.first :
            inspectionMenuWindowIndex(windowCount: all.count, focusedIndex: focusedIndex).map { all[$0] }
        if enablement["any_write_accepted"] as? Bool == true {
            let started = ProcessInfo.processInfo.systemUptime
            let waitDeadline = started + 0.6
            var probe: [String: Any]
            repeat {
                probe = accessibilityTreeProbe(selected, deadline: waitDeadline)
                if probe["web_area_found"] as? Bool == true || probe["editable_role_found"] as? Bool == true { break }
                if ProcessInfo.processInfo.systemUptime >= waitDeadline { break }
                _ = CFRunLoopRunInMode(.defaultMode, 0.02, true)
            } while true
            enablement["tree_probe"] = probe
            enablement["waited_ms"] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        } else { enablement["waited_ms"] = 0 }
        var elements: [[String: Any]] = []
        var metadata: [[String: Any]] = []
        let focusedInspectionWindow = title == nil ? observedFocus : nil
        let focusedSheets = focusedInspectionWindow.map { axElements($0, nativeAXSheetsAttribute, limit: 16) } ?? []
        var queue: [(AXUIElement, AXUIElement, Int, String?, AXUIElement?)] = selected.map { item in
            // Some apps publish the same sheet both in AXWindows and AXSheets.
            // Keep its cache bound to the exact focused owner selected by the
            // title-free input route, rather than the order of those arrays.
            let owner = focusedInspectionWindow.flatMap { focused in
                selected.contains(where: { CFEqual($0, focused) }) && focusedSheets.contains(where: { CFEqual($0, item) }) ? focused : nil
            } ?? item
            return (item, owner, 0, nil, nil)
        }
        var index = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var truncationReasons: Set<String> = windowRead.metadata["window_list_complete"] as? Bool == true ? [] : ["window_list_incomplete"]
        var roleCounts: [String: Int] = [:]
        var attributeProbes: [[String: Any]] = []
        var imagePrivacyNodes: [InspectionImagePrivacyNode] = []
        var imagePrivacyKnown = true
        while index < queue.count && elements.count < limit {
            if ProcessInfo.processInfo.systemUptime >= deadline { truncationReasons.insert("time_limit"); break }
            let (item, window, level, parentID, inheritedDialog) = queue[index]
            index += 1
            let hash = CFHash(item)
            if seen[hash]?.contains(where: { CFEqual($0, item) }) == true { continue }
            seen[hash, default: []].append(item)
            AXUIElementSetMessagingTimeout(item, 0.8)
            let attributes = axMetadataAttributes(item)
            let role = attributes.string("AXRole") ?? "AXUnknown"
            if ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"].contains(role) {
                if includeImage { imagePrivacyKnown = false }
                continue
            }
            var dialog = inheritedDialog
            if (nativeDialogRole(role, subrole: attributes.string("AXSubrole"), modal: axBool(item, kAXModalAttribute)) ||
                nativePublishedRemotePanel(item, root: root, ownerPID: app.processIdentifier)),
               nativeDialogAttached(item, to: window, applicationRoot: root, ownerPID: app.processIdentifier),
               let frame = attributes.bounds,
               dialogFocusMatches(item, ownerWindow: window, root: root) {
                dialog = item
                if !inspectedDialogs.contains(where: { CFEqual($0.dialog, item) }) {
                    inspectedDialogs.append(NativeInspectedDialog(runtimeTaskID: currentRuntimeTaskID, bundleID: bundle,
                        ownerPID: app.processIdentifier, ownerWindow: window, dialog: item, frame: frame))
                }
            }
            var elementPID: pid_t = 0
            guard AXUIElementGetPid(item, &elementPID) == .success,
                  elementPID == app.processIdentifier || dialog.map({ nativeElementInDialog(item, dialog: $0) }) == true else {
                truncationReasons.insert("unverified_element_process"); imagePrivacyKnown = false; continue
            }
            let id = "g\(generation)-e\(elements.count + 1)"
            let secure = attributes.isSecure
            roleCounts[role, default: 0] += 1
            cache[id] = CachedElement(element: item, window: window, bundleID: bundle, pid: elementPID, dialog: dialog)
            var row: [String: Any] = ["element_id": id, "role": role, "depth": level,
                "title": attributes.string("AXTitle") ?? "", "description": attributes.string("AXDescription") ?? "",
                "enabled": attributes.boolean("AXEnabled") ?? true, "focused": attributes.boolean("AXFocused") ?? false,
                "actions": axActions(item), "secure": secure]
            if let parentID { row["parent_id"] = parentID }
            row["element_pid"] = elementPID
            if dialog != nil { row["associated_dialog"] = true; row["authorized_owner_pid"] = app.processIdentifier }
            if let subrole = attributes.string("AXSubrole") { row["subrole"] = subrole }
            if let identifier = attributes.string("AXIdentifier") { row["identifier"] = identifier }
            if !secure, let proof = readableValueProof(item) {
                row["value"] = proof.value; row["value_complete"] = proof.complete; row["value_truncated"] = !proof.complete
            }
            if !secure, ["AXTextArea", "AXTextField"].contains(role), let range = axSelectedRange(item) { row["selected_range"] = ["location": range.location, "length": range.length] }
            let counts = secure ? [] : axChildCounts(item)
            truncationReasons.formUnion(axChildCountReasons(counts))
            if !secure {
                row["child_sources"] = counts.map { ["attribute": $0.name, "count": $0.count, "result": axResult($0.result)] as [String: Any] }
            }
            if enable && !secure && ["AXWindow", "AXGroup"].contains(role) && attributeProbes.count < 6 && ProcessInfo.processInfo.systemUptime < deadline {
                attributeProbes.append(["element_id": id, "role": role, "read_only": true,
                    "attributes": ["AXManualAccessibility", "AXEnhancedUserInterface"].map { accessibilityAttributeProbe(item, name: $0) }])
            }
            if let bounds = attributes.bounds {
                row["position"] = ["x": bounds.origin.x, "y": bounds.origin.y]
                row["size"] = ["width": bounds.width, "height": bounds.height]
                row.merge(displays.associations(for: bounds)) { _, new in new }
            }
            if level == 0 {
                let isMain = verifiedMain.map { CFEqual($0.0, item) } == true
                row["is_actual_main_window"] = isMain
                if isMain { row["actual_main_window_id"] = verifiedMain!.1 }
            }
            elements.append(row)
            if level == 0 { metadata.append(row) }
            var imageChildren: [AXUIElement] = []
            if level < depth && !secure {
                let available = max(0, limit - elements.count - (queue.count - index))
                let children = axNavigationChildren(item, limit: available, counts: counts)
                truncationReasons.formUnion(children.reasons)
                if includeImage { imageChildren = children.elements }
                queue.append(contentsOf: children.elements.map { ($0, window, level + 1, id, dialog) })
                // AppKit can publish AXSheets separately from AXChildren.
                if role == kAXWindowRole {
                    let sheets = axElements(item, nativeAXSheetsAttribute, limit: min(16, available))
                    queue.append(contentsOf: sheets.map { ($0, window, level + 1, id, dialog) })
                    if includeImage { imageChildren += sheets }
                }
            } else if !secure && counts.contains(where: { $0.count > 0 }) {
                truncationReasons.insert("depth_limit")
            }
            if includeImage {
                imagePrivacyKnown = imagePrivacyKnown && inspectionImagePrivacyKnown(attributes)
                    && (secure || counts.allSatisfy { [.success, .attributeUnsupported, .noValue].contains($0.result) })
                imagePrivacyNodes.append(InspectionImagePrivacyNode(element: item, role: role, secure: secure,
                    bounds: attributes.bounds, children: imageChildren))
            }
        }
        if index < queue.count && elements.count >= limit { truncationReasons.insert("node_limit") }
        var menuElements: [[String: Any]] = []
        var menuMetadata: [String: Any] = [:]
        if let menuWindow {
            let menus = inspectMenus(root, application: app, bundle: bundle, window: menuWindow,
                displays: displays, depth: depth, limit: max(0, limit - elements.count), deadline: deadline)
            menuElements = menus.elements
            menuMetadata = menus.metadata
            menuMetadata["menu_node_count"] = menuElements.count
            menuMetadata["menus_truncated"] = !menus.reasons.isEmpty
            menuMetadata["menus_truncation_reasons"] = menus.reasons.sorted()
            menuMetadata["window_node_count"] = elements.count
            truncationReasons.formUnion(menus.reasons)
        }
        let focusedDiagnostic = selected.isEmpty ? ["available": false, "within_selected_window": false] :
            focusedElementDiagnostic(root, application: app, bundle: bundle, selected: selected, displays: displays)
        var currentWindow: [String: Any] = ["available": false]
        if let focused = observedFocus,
           all.contains(where: { CFEqual($0, focused) }), let frame = axBounds(focused) {
            var elementPID: pid_t = 0
            if AXUIElementGetPid(focused, &elementPID) == .success {
                let focusedTitle = axString(focused, kAXTitleAttribute) ?? ""
                currentWindow = ["available": true, "authorized_owner_pid": app.processIdentifier,
                    "window_element_pid": elementPID, "title": String(focusedTitle.prefix(256)),
                    "title_complete": focusedTitle.count <= 256, "frame": rectJSON(frame),
                    "is_selected_window": selected.contains(where: { CFEqual($0, focused) }),
                    "app_frontmost": axBool(root, kAXFrontmostAttribute).map { $0 as Any } ?? NSNull(),
                    "identity_source": "authorized_app_AXWindows_and_AXFocusedWindow", "input_authorization": false]
            }
        }
        guard try currentDisplays().signature == displays.signature else {
            throw fail("display_topology_changed", "Display topology changed during inspection; inspect again")
        }
        displayChangeNeedsInspect = false
        var result: [String: Any] = ["app": bundle, "target_pid": app.processIdentifier, "generation": generation,
            "windows": metadata, "current_window": currentWindow, "elements": elements, "node_count": elements.count + menuElements.count,
            "max_depth": depth, "max_nodes": limit, "truncated": !truncationReasons.isEmpty,
            "truncation_reasons": truncationReasons.sorted(), "role_counts": roleCounts,
            "child_attributes": navigationChildAttributes, "focused_element": focusedDiagnostic,
            "accessibility_enablement": enablement, "embedded_accessibility_probes": attributeProbes,
            "associated_dialogs": inspectedDialogs.map { ["owner_pid": $0.ownerPID, "frame": rectJSON($0.frame),
                "relation": "fresh_app_AXWindow_AXSheet_or_parent_identity", "requires_reinspection_on_change": true] as [String: Any] },
            "values_max_characters": 4000, "menus_skipped": !includeMenus,
            "coordinate_system": quartzCoordinateSystem, "displays": displays.displays.map { $0.json },
            "display_topology_generation": displayTopologyGeneration]
        result["image_requested"] = includeImage
        result.merge(windowRead.metadata) { _, new in new }
        result["menu_window_available"] = menuWindow != nil
        result["menu_window_scope"] = !includeMenus ? "not_requested" : title != nil ? "exact_title" : menuWindow != nil ? "observed_focused_or_unique" : "unavailable"
        result["menus_skipped"] = !includeMenus || menuWindow == nil
        result["image_available"] = false
        result["image_unavailable_reason"] = "not_requested"
        if includeImage, let title, selected.count == 1 {
            do {
                guard let frame = axBounds(selected[0]) else { throw fail("inspection_image_window_unverified", "Selected AX window has no image geometry") }
                let image = try inspectionTargetImage(helper: self, application: app, root: root, window: selected[0],
                    bundle: bundle, title: title, frame: frame, topology: displays.signature, generation: generation,
                    privacyNodes: imagePrivacyNodes, truncated: !truncationReasons.isEmpty, privacyKnown: imagePrivacyKnown)
                result.merge(image) { _, new in new }
                result.removeValue(forKey: "image_unavailable_reason")
            } catch let error as HelperError {
                result["image_unavailable_reason"] = error.code
            } catch {
                result["image_unavailable_reason"] = "inspection_image_failed"
            }
            result["image_snapshot_is_input_authorization"] = false
            result["ax_image_atomic"] = false
        }
        if includeMenus {
            result["menu_elements"] = menuElements
            result.merge(menuMetadata) { _, new in new }
        }
        return result
    }

    // Qt can briefly return no AXFocusedWindow after opening its search popup.
    // Wait only for actual AX focus; never substitute AXMainWindow or activate.
    func settledFocusedWindow(_ target: Target) throws -> AXUIElement {
        guard let frame = axBounds(target.window) else { throw fail("window_mismatch", "Selected main-window geometry is unavailable") }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        var lastResult = AXError.noValue
        AXUIElementSetMessagingTimeout(target.axApplication, 0.12)
        defer { AXUIElementSetMessagingTimeout(target.axApplication, 0.8) }
        repeat {
            try monitor.check()
            try verifyDisplayTopology(target)
            guard !target.application.isTerminated, axBool(target.axApplication, kAXFrontmostAttribute) == true,
                  axBounds(target.window) == frame else { throw fail("foreground_mismatch", "Target lost foreground or geometry during focus observation") }
            var raw: CFTypeRef?
            lastResult = AXUIElementCopyAttributeValue(target.axApplication, kAXFocusedWindowAttribute as CFString, &raw)
            if lastResult == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let focused = unsafeBitCast(raw, to: AXUIElement.self)
                var pid: pid_t = 0
                guard AXUIElementGetPid(focused, &pid) == .success, pid == target.pid else { throw fail("window_mismatch", "Focused window PID changed") }
                try denySecure(focused)
                return focused
            }
            guard observationFocusMaySettle(bundle: target.bundleID, result: lastResult, hasValue: raw != nil) else { break }
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw fail("window_mismatch", "Actual AX focused window remained unavailable after bounded read-only settling",
            ["AXFocusedWindow_result": axResult(lastResult), "selected_main_frame": rectJSON(frame),
             "AXMainWindow_frame": axElement(target.axApplication, kAXMainWindowAttribute).flatMap { axBounds($0) }.map { rectJSON($0) as Any } ?? NSNull(),
             "system_focus": observationSystemFocus(), "settle_limit_ms": 400, "focus_substituted": false])
    }

    func taskStillFocused(_ target: Target) -> Bool {
        // Feishu's search panel is a separate concrete AXWindow. Only our
        // accepted search navigation may migrate that claim; arbitrary same-
        // app dialogs must not implicitly inherit it.
        if target.bundleID == "com.bytedance.macos.feishu" {
            return (try? settledFocusedWindow(target)).map { CFEqual($0, target.window) } == true
        }
        if (try? currentInspectedDialog(target)) != nil { return true }
        // A newly inspected app-modal panel may replace the document's focused
        // AXWindow. Its fresh app-root association preserves this task's claim.
        if inspectedDialogs.contains(where: { record in
            record.runtimeTaskID == currentRuntimeTaskID && record.bundleID == target.bundleID && record.ownerPID == target.pid &&
                nativeDialogAttached(record.dialog, to: record.ownerWindow, applicationRoot: target.axApplication, ownerPID: target.pid) &&
                axBounds(record.dialog) == record.frame && dialogFocusMatches(record.dialog, ownerWindow: record.ownerWindow, root: target.axApplication)
        }) { return true }
        guard let focused = try? settledFocusedWindow(target) else { return false }
        if CFEqual(focused, target.window) { return true }
        guard target.bundleID == "com.tencent.xinWeChat", let bounds = axBounds(focused),
              (axString(focused, kAXTitleAttribute) ?? "").isEmpty,
              let identity = try? visual.selectedIdentity(target),
              let popup = try? visualCurrentSearchOverlay(identity) else { return false }
        return popup.frame == bounds
    }

    func capturePreviousFocus(_ target:Target) throws {
        if let previous=previousFocus, !focusRecordTaskMatches(previous.runtimeTaskID, currentRuntimeTaskID) {
            // This is a new explicit focus claim, not restoration of the other
            // task's origin. Capture this task's actual foreground instead.
            previousFocus=nil;monitor.discardClaim()
        }
        if let previous=previousFocus,monitor.reason != nil || !previous.claimComplete || !taskStillFocused(previous.task) {
            if previous.runtimeOperationID != nil && previous.runtimeOperationID == runtimeOperationID {
                throw fail("focus_scope_changed", "The current operation lost its original focus claim; implicit origin replacement is forbidden", focusScopeChangedDetails(target))
            }
            previousFocus=nil
        }
        if previousFocus != nil {previousFocus!.task=target;previousFocus!.ownedFeishuReturn=nil;previousFocus!.ownedFeishuOpen=nil;previousFocus!.ownedFeishuReturnDiagnostic=nil;return}
        guard let pid=foregroundMetadata().pid,let app=NSRunningApplication(processIdentifier:pid),
              !app.isTerminated,let originBundle=app.bundleIdentifier,!originBundle.isEmpty else {
            throw fail("previous_focus_unavailable","Cannot record the current foreground application identity before claiming focus")
        }
        let root=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(root,0.2)
        var originalWindow:AXUIElement?,originalFrame:CGRect?
        if axBool(root,kAXFrontmostAttribute)==true,let window=axElement(root,kAXFocusedWindowAttribute),
           let frame=axBounds(window),windows(root).contains(where:{CFEqual($0,window)}) {
            var windowPID:pid_t=0
            if AXUIElementGetPid(window,&windowPID) == .success,windowPID==pid {
                originalWindow=window;originalFrame=frame
            }
        }
        // A missing AX window does not erase a reliably identified foreground
        // app. Record app-only scope; never substitute AXMainWindow or another UI.
        let finalPID=foregroundMetadata().pid
        let finalBundle=finalPID.flatMap{NSRunningApplication(processIdentifier:$0)?.bundleIdentifier}
        guard !app.isTerminated,focusOriginAppMatches(pid:pid,bundle:originBundle,actualPID:finalPID,actualBundle:finalBundle) else {
            throw fail("previous_focus_unavailable","Foreground application identity changed while recording the focus origin")
        }
        previousFocus=PreviousFocusRecord(runtimeTaskID:currentRuntimeTaskID,runtimeOperationID:runtimeOperationID,application:app,root:root,window:originalWindow,frame:originalFrame,
            originBundleID:originBundle,topology:target.displaySignature,task:target)

    }

    func feishuModalReturnCandidate(_ target: Target) -> OwnedFeishuMainReturn? {
        guard target.bundleID == "com.bytedance.macos.feishu", target.expectedTitle == feishuSearchWindowTitle else { return nil }
        var diagnostic: [String: Any] = ["navigation_kind": "search_to_main", "candidate_reason": "claim_unavailable", "candidate_available": false,
            "target_pid": target.pid, "action_accepted": false, "claim_available": previousFocus != nil,
            "claim_complete": previousFocus?.claimComplete == true, "monitor_available": monitor.available,
            "interrupted": monitor.reason != nil,
            "claimed_window_matches_selected": previousFocus.map { CFEqual($0.task.window, target.window) } == true,
            "claimed_PID_matches_selected": previousFocus?.task.pid == target.pid,
            "claimed_topology_matches": previousFocus?.topology == target.displaySignature]
        defer { previousFocus?.ownedFeishuReturnDiagnostic = diagnostic }
        guard let previous = previousFocus, let operation = runtimeOperationID,
              previous.runtimeTaskID == currentRuntimeTaskID, previous.runtimeOperationID == operation,
              previous.claimComplete, monitor.reason == nil, monitor.available,
              CFEqual(previous.task.window, target.window), previous.task.pid == target.pid,
              previous.topology == target.displaySignature else { return nil }
        diagnostic["claim_bound_to_modal"] = true
        let all = windows(target.axApplication)
        let mains = all.filter { axString($0, kAXTitleAttribute) == "飞书" }
        diagnostic["main_AX_match_count"] = mains.count
        diagnostic["candidate_reason"] = "main_AX_identity_unavailable"
        guard mains.count == 1, let frame = axBounds(mains[0]) else { return nil }
        diagnostic["main_frame"] = rectJSON(frame)
        diagnostic["modal_frame"] = axBounds(target.window).map { rectJSON($0) as Any } ?? NSNull()
        let modals = all.filter { axString($0, kAXTitleAttribute) == feishuSearchWindowTitle }
        let actualMain = axElement(target.axApplication, kAXMainWindowAttribute)
        let actualFocus = axElement(target.axApplication, kAXFocusedWindowAttribute)
        let matchesMain = actualMain.map { CFEqual($0, mains[0]) } == true
        let matchesModal = modals.count == 1 && CFEqual(modals[0], target.window) && actualMain.map { CFEqual($0, target.window) } == true
        diagnostic["main_matches_AXMainWindow"] = matchesMain
        diagnostic["search_modal_count"] = modals.count
        diagnostic["current_AXMainWindow_kind"] = feishuAXMainWindowKind(available: actualMain != nil,
            matchesSavedMain: matchesMain, matchesUniqueSearchModal: matchesModal)
        diagnostic["modal_matches_AXFocusedWindow"] = actualFocus.map { CFEqual($0, target.window) } == true
        diagnostic["current_AXFocusedWindow_kind"] = feishuAXMainWindowKind(available: actualFocus != nil,
            matchesSavedMain: actualFocus.map { CFEqual($0, mains[0]) } == true,
            matchesUniqueSearchModal: modals.count == 1 && CFEqual(modals[0], target.window) && actualFocus.map { CFEqual($0, target.window) } == true)
        var pid: pid_t = 0
        diagnostic["candidate_reason"] = "main_PID_mismatch"
        guard AXUIElementGetPid(mains[0], &pid) == .success, pid == target.pid else { return nil }
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let matching = rows.filter { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let raw = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
            return rect == frame
        }
        diagnostic["same_frame_CG_count"] = matching.count
        diagnostic["same_frame_CG_rows"] = matching.prefix(8).map { row -> [String: Any] in
            ["window_id": row[kCGWindowNumber as String] ?? NSNull(), "layer": row[kCGWindowLayer as String] ?? NSNull(),
             "onscreen": row[kCGWindowIsOnscreen as String] ?? NSNull(), "alpha": row[kCGWindowAlpha as String] ?? NSNull()]
        }
        diagnostic["same_frame_CG_rows_truncated"] = matching.count > 8
        diagnostic["candidate_reason"] = "main_or_modal_AX_window_mismatch"
        guard diagnostic["main_matches_AXMainWindow"] as? Bool == true,
              diagnostic["modal_matches_AXFocusedWindow"] as? Bool == true else { return nil }
        diagnostic["candidate_reason"] = "main_CG_identity_ambiguous_or_unavailable"
        guard let id = feishuReturnMainCGWindowID(pid: pid, bounds: frame,
                actualAXTitle: axString(mains[0], kAXTitleAttribute) ?? "", rows: rows) else { return nil }
        let main = Target(bundleID: target.bundleID, application: target.application, axApplication: target.axApplication,
                          window: mains[0], expectedTitle: "飞书", displaySignature: target.displaySignature)
        diagnostic["candidate_reason"] = "bound"
        diagnostic["candidate_available"] = true
        diagnostic["main_CG_window_id"] = id
        return OwnedFeishuMainReturn(target: main, frame: frame, windowID: id, taskID: currentRuntimeTaskID,
            operationID: operation, activityRevision: monitor.focusQuietObservation.revision,
            until: ProcessInfo.processInfo.systemUptime + 15)
    }

    func feishuMainIdentity(_ candidate: OwnedFeishuMainReturn, diagnostic: inout [String: Any]) -> Bool {
        let main = candidate.target
        let revision = monitor.focusQuietObservation.revision
        let now = ProcessInfo.processInfo.systemUptime
        diagnostic["claimed_task_matches"] = candidate.taskID == currentRuntimeTaskID && previousFocus?.runtimeTaskID == currentRuntimeTaskID
        diagnostic["claimed_operation_matches"] = candidate.operationID == runtimeOperationID && previousFocus?.runtimeOperationID == runtimeOperationID
        diagnostic["claimed_PID_matches_selected"] = main.pid == previousFocus?.task.pid
        diagnostic["activity_revision_matches"] = candidate.activityRevision == revision
        diagnostic["candidate_within_deadline"] = now.isFinite && candidate.until.isFinite && now >= 0 && now <= candidate.until
        diagnostic["monitor_available"] = monitor.available
        diagnostic["interrupted"] = monitor.reason != nil
        diagnostic["adoption_reason"] = "task_identity_mismatch"
        guard !main.application.isTerminated,
              feishuOwnedScopeMatches(task: candidate.taskID, operation: candidate.operationID, pid: main.pid,
                  revision: candidate.activityRevision, until: candidate.until, currentTask: currentRuntimeTaskID,
                  currentOperation: runtimeOperationID, currentPID: previousFocus?.task.pid ?? 0,
                  currentRevision: revision, now: now),
              previousFocus?.runtimeOperationID == runtimeOperationID,
              previousFocus?.runtimeTaskID == currentRuntimeTaskID, previousFocus?.claimComplete == true,
              monitor.reason == nil, monitor.available else { return false }
        let all = windows(main.axApplication)
        let modals = all.filter { axString($0, kAXTitleAttribute) == feishuSearchWindowTitle }
        let actualMain = axElement(main.axApplication, kAXMainWindowAttribute)
        let actualFocus = axElement(main.axApplication, kAXFocusedWindowAttribute)
        let matchesMain = actualMain.map { CFEqual($0, main.window) } == true
        let matchesModal = modals.count == 1 && actualMain.map { CFEqual($0, modals[0]) } == true
        let axIdentity = axBounds(main.window) == candidate.frame && axString(main.window, kAXTitleAttribute) == "飞书" &&
            all.contains(where: { CFEqual($0, main.window) })
        diagnostic["AX_main_identity_unchanged"] = axIdentity
        diagnostic["search_modal_count"] = modals.count
        diagnostic["current_AXMainWindow_kind"] = feishuAXMainWindowKind(available: actualMain != nil,
            matchesSavedMain: matchesMain, matchesUniqueSearchModal: matchesModal)
        diagnostic["current_AXFocusedWindow_kind"] = feishuAXMainWindowKind(available: actualFocus != nil,
            matchesSavedMain: actualFocus.map { CFEqual($0, main.window) } == true,
            matchesUniqueSearchModal: modals.count == 1 && actualFocus.map { CFEqual($0, modals[0]) } == true)
        diagnostic["main_matches_AXMainWindow"] = matchesMain
        diagnostic["modal_matches_AXFocusedWindow"] = modals.count == 1 && actualFocus.map { CFEqual($0, modals[0]) } == true
        diagnostic["adoption_reason"] = "main_AX_identity_unavailable"
        guard axIdentity else { return false }
        diagnostic["adoption_reason"] = "AX_main_window_mismatch"
        guard matchesMain else { return false }
        let frontmost = axBool(main.axApplication, kAXFrontmostAttribute) == true
        let topology = (try? currentDisplays().signature) == main.displaySignature
        diagnostic["target_frontmost"] = frontmost
        diagnostic["topology_matches"] = topology
        diagnostic["adoption_reason"] = "post_navigation_proof_incomplete"
        guard frontmost, topology else { return false }
        var pid: pid_t = 0
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let identity = AXUIElementGetPid(main.window, &pid) == .success && pid == main.pid &&
            feishuReturnMainCGWindowID(pid: pid, bounds: candidate.frame, actualAXTitle: "飞书", rows: rows) == candidate.windowID
        diagnostic["CG_main_identity_unchanged"] = identity
        diagnostic["adoption_reason"] = identity ? "main_identity_verified" : "main_CG_identity_ambiguous_or_unavailable"
        return identity
    }

    func feishuSearchOpenCandidate(_ target: Target, element: AXUIElement) -> OwnedFeishuSearchOpen? {
        guard target.bundleID == "com.bytedance.macos.feishu", target.expectedTitle == "飞书" else { return nil }
        var diagnostic: [String: Any] = ["navigation_kind": "main_to_search", "candidate_reason": "claim_unavailable",
            "candidate_available": false, "action_accepted": false, "claim_available": previousFocus != nil,
            "claim_complete": previousFocus?.claimComplete == true, "monitor_available": monitor.available,
            "interrupted": monitor.reason != nil,
            "claimed_window_matches_selected": previousFocus.map { CFEqual($0.task.window, target.window) } == true,
            "claimed_PID_matches_selected": previousFocus?.task.pid == target.pid,
            "claimed_topology_matches": previousFocus?.topology == target.displaySignature,
            "claimed_task_matches": previousFocus?.runtimeTaskID == currentRuntimeTaskID,
            "claimed_operation_matches": runtimeOperationID != nil && previousFocus?.runtimeOperationID == runtimeOperationID]
        defer { if previousFocus?.runtimeTaskID == currentRuntimeTaskID { previousFocus?.ownedFeishuReturnDiagnostic = diagnostic } }
        let role = axString(element, kAXRoleAttribute)
        diagnostic["search_control_role"] = role == "AXMenuItem" || role == "AXButton" ? role! : role == nil ? "missing" : "other"
        let stillFocused = taskStillFocused(target)
        diagnostic["claimed_window_still_focused"] = stillFocused
        guard target.bundleID == "com.bytedance.macos.feishu", target.expectedTitle == "飞书",
              let previous = previousFocus, let operation = runtimeOperationID,
              previous.runtimeTaskID == currentRuntimeTaskID, previous.runtimeOperationID == operation,
              previous.claimComplete, monitor.available, monitor.reason == nil,
              previous.task.pid == target.pid, CFEqual(previous.task.window, target.window),
              previous.topology == target.displaySignature, stillFocused else { return nil }
        let allowed = feishuSearchOpenControlAllowed(role: role ?? "",
            title: axString(element, kAXTitleAttribute), description: axString(element, kAXDescriptionAttribute))
        diagnostic["search_control_allowed"] = allowed
        diagnostic["candidate_reason"] = "search_control_not_exact"
        guard allowed else { return nil }
        let modalCount = windows(target.axApplication).filter { axString($0, kAXTitleAttribute) == feishuSearchWindowTitle }.count
        diagnostic["search_modal_count"] = modalCount
        diagnostic["candidate_reason"] = "existing_search_modal"
        guard modalCount == 0 else { return nil }
        diagnostic["candidate_reason"] = "main_AX_identity_unavailable"
        guard let frame = axBounds(target.window) else { return nil }
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        diagnostic["candidate_reason"] = "main_CG_identity_ambiguous_or_unavailable"
        guard let id = feishuReturnMainCGWindowID(pid: target.pid, bounds: frame,
            actualAXTitle: axString(target.window, kAXTitleAttribute) ?? "", rows: rows) else { return nil }
        diagnostic["candidate_reason"] = "bound"
        diagnostic["candidate_available"] = true
        return OwnedFeishuSearchOpen(main: OwnedFeishuMainReturn(target: target, frame: frame, windowID: id,
            taskID: currentRuntimeTaskID, operationID: operation, activityRevision: monitor.focusQuietObservation.revision,
            until: ProcessInfo.processInfo.systemUptime + 15))
    }

    func adoptOwnedFeishuSearchOpen(_ selected: Target? = nil) -> Bool {
        guard let candidate = previousFocus?.ownedFeishuOpen else { return false }
        var diagnostic = previousFocus?.ownedFeishuReturnDiagnostic ?? [:]
        diagnostic["navigation_kind"] = "main_to_search"
        defer { previousFocus?.ownedFeishuReturnDiagnostic = diagnostic }
        guard feishuMainIdentity(candidate.main, diagnostic: &diagnostic) else { return false }
        let main = candidate.main.target
        diagnostic["adoption_reason"] = "claimed_main_window_mismatch"
        guard previousFocus.map({ CFEqual($0.task.window, main.window) }) == true else { return false }
        let modals = windows(main.axApplication).filter { axString($0, kAXTitleAttribute) == feishuSearchWindowTitle }
        diagnostic["search_modal_count"] = modals.count
        diagnostic["adoption_reason"] = "unique_focused_modal_unavailable"
        guard modals.count == 1, let frame = axBounds(modals[0]), frame.width > 0, frame.height > 0,
              axElement(main.axApplication, kAXFocusedWindowAttribute).map({ CFEqual($0, modals[0]) }) == true else { return false }
        if let selected {
            diagnostic["adoption_reason"] = "selected_modal_mismatch"
            guard selected.pid == main.pid, selected.bundleID == main.bundleID,
                  selected.expectedTitle == feishuSearchWindowTitle, CFEqual(selected.window, modals[0]) else { return false }
        }
        var pid: pid_t = 0
        diagnostic["adoption_reason"] = "modal_PID_or_security_mismatch"
        guard AXUIElementGetPid(modals[0], &pid) == .success, pid == main.pid, !isSecure(modals[0]) else { return false }
        previousFocus?.task = Target(bundleID: main.bundleID, application: main.application, axApplication: main.axApplication,
            window: modals[0], expectedTitle: feishuSearchWindowTitle, displaySignature: main.displaySignature)
        previousFocus?.ownedFeishuOpen = nil
        previousFocus?.ownedFeishuFocusUpdated = true
        diagnostic["adoption_reason"] = "verified_owned_main_to_modal"
        return true // Preserve the foreign origin and the original input baseline.
    }

    func adoptOwnedFeishuMainReturn() -> Bool {
        guard let previous = previousFocus else { return false }
        var diagnostic = previous.ownedFeishuReturnDiagnostic ?? [:]
        defer { if !diagnostic.isEmpty { previousFocus?.ownedFeishuReturnDiagnostic = diagnostic } }
        guard let candidate = previous.ownedFeishuReturn else {
            if !diagnostic.isEmpty && diagnostic["navigation_kind"] as? String != "main_to_search" { diagnostic["adoption_reason"] = "candidate_unavailable" }
            return false
        }
        diagnostic["adoption_reason"] = "input_monitor_interrupted_or_unavailable"
        guard monitor.reason == nil, monitor.available else { return false }
        let main = candidate.target
        diagnostic["adoption_reason"] = "task_identity_mismatch"
        guard feishuOwnedScopeMatches(task: candidate.taskID, operation: candidate.operationID, pid: main.pid,
                  revision: candidate.activityRevision, until: candidate.until, currentTask: currentRuntimeTaskID,
                  currentOperation: runtimeOperationID, currentPID: previous.task.pid,
                  currentRevision: monitor.focusQuietObservation.revision, now: ProcessInfo.processInfo.systemUptime),
              previous.runtimeTaskID == currentRuntimeTaskID, previous.runtimeOperationID == runtimeOperationID,
              !main.application.isTerminated, previous.task.pid == main.pid,
              previous.task.bundleID == main.bundleID, main.bundleID == "com.bytedance.macos.feishu",
              previous.task.expectedTitle == feishuSearchWindowTitle else { return false }
        let all = windows(main.axApplication)
        var pid: pid_t = 0
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let axIdentity = AXUIElementGetPid(main.window, &pid) == .success && pid == main.pid &&
            axBounds(main.window) == candidate.frame && axString(main.window, kAXTitleAttribute) == "飞书" &&
            all.contains(where: { CFEqual($0, main.window) })
        let cgID = feishuReturnMainCGWindowID(pid: pid, bounds: candidate.frame,
            actualAXTitle: axString(main.window, kAXTitleAttribute) ?? "", rows: rows)
        let identity = axIdentity && cgID == candidate.windowID
        let modalAbsent = !all.contains(where: { CFEqual($0, previous.task.window) || axString($0, kAXTitleAttribute) == feishuSearchWindowTitle })
        let frontmost = axBool(main.axApplication, kAXFrontmostAttribute) == true
        let actualMain = axElement(main.axApplication, kAXMainWindowAttribute).map { CFEqual($0, main.window) } == true
        let actualFocus = axElement(main.axApplication, kAXFocusedWindowAttribute).map { CFEqual($0, main.window) } == true
        let topologyMatches = (try? currentDisplays().signature) == previous.topology
        diagnostic["AX_main_identity_unchanged"] = axIdentity
        diagnostic["CG_main_identity_unchanged"] = cgID == candidate.windowID
        diagnostic["current_main_CG_window_id"] = cgID.map { $0 as Any } ?? NSNull()
        diagnostic["modal_absent"] = modalAbsent
        diagnostic["target_frontmost"] = frontmost
        diagnostic["actual_AXMainWindow_matches"] = actualMain
        diagnostic["actual_AXFocusedWindow_matches"] = actualFocus
        diagnostic["topology_matches"] = topologyMatches
        diagnostic["adoption_reason"] = "post_navigation_proof_incomplete"
        guard ownedFeishuReturnAllowed(claimComplete: previous.claimComplete, interrupted: monitor.reason != nil || !monitor.available,
              actionAccepted: true, sameIdentity: identity, modalAbsent: modalAbsent, actualMainFocused: frontmost && actualMain && actualFocus,
              topologyMatches: topologyMatches) else { return false }
        previousFocus?.task = main
        previousFocus?.ownedFeishuReturn = nil
        previousFocus?.ownedFeishuOpen = nil
        previousFocus?.ownedFeishuFocusUpdated = true
        diagnostic["adoption_reason"] = "verified_owned_modal_to_main"
        return true // No activation, new claim, monitor reset or input.
    }

    func restorePreviousFocus(_ request:[String:Any]) throws -> [String:Any] {
        let bundle=try string(request,"app")!
        if let previous=previousFocus, !focusRecordTaskMatches(previous.runtimeTaskID, currentRuntimeTaskID) {
            // Before adoption, defer cleanup, or any UI access: the other
            // task's origin and active takeover claim must remain untouched.
            return ["focus_restored":false,"restore_reason":"task_id_mismatch",
                "focus_restore_attempted":false,"restore_raise_attempted":false,
                "owned_navigation_focus_updated":false,"events_posted":0]
        }
        var ownedNavigationUpdated = false
        if bundle == "com.bytedance.macos.feishu" && previousFocus?.task.bundleID == bundle {
            ownedNavigationUpdated = adoptOwnedFeishuMainReturn()
            ownedNavigationUpdated = adoptOwnedFeishuSearchOpen() || ownedNavigationUpdated
            ownedNavigationUpdated = previousFocus?.ownedFeishuFocusUpdated == true || ownedNavigationUpdated
        }
        let previous=previousFocus
        defer{previousFocus=nil;monitor.discardClaim()}
        var raiseResult: AXError?
        var restoreWindow=previous?.window,restoreFrame=previous?.frame
        var originalWindowUnavailable=false
        func result(_ restored:Bool,_ reason:String,_ attempted:Bool=false)->[String:Any]{
            var value: [String: Any] = ["focus_restored":restored,"restore_reason":reason,"focus_restore_attempted":attempted,"events_posted":0]
            value["owned_navigation_focus_updated"] = ownedNavigationUpdated
            value["owned_navigation_diagnostic"] = previous?.ownedFeishuReturnDiagnostic.map { $0 as Any } ?? NSNull()
            value["restore_raise_attempted"] = raiseResult != nil
            value["restore_raise_result"] = raiseResult.map { axResult($0) as Any } ?? NSNull()
            value["restore_verify_limit_ms"] = 400
            value["previous_focus_scope"] = previous.map { $0.window == nil ? "app_only" : "exact_window" } ?? "unavailable"
            value["restore_scope"] = restoreWindow == nil ? "app_only" : "exact_window"
            value["window_unknown"] = restoreWindow == nil
            value["original_window_reference_unavailable"] = originalWindowUnavailable
            value["focus_restored_app"] = restored
            value["window_verified"] = restored && restoreWindow != nil
            return value
        }
        guard let previous else{return result(false,"no_previous_focus")}
        guard previous.task.bundleID==bundle else{return result(false,"task_target_mismatch")}
        let topology=try? currentDisplays()
        let originAppExists = !previous.application.isTerminated && previous.application.bundleIdentifier==previous.originBundleID
        if let window=restoreWindow {
            let identityVerified=restoreFrame.map{axBounds(window)==$0} == true && windows(previous.root).contains(where:{CFEqual($0,window)})
            if !focusRestoreKeepsWindow(hasRecordedWindow:true,identityVerified:identityVerified) {
                restoreWindow=nil;restoreFrame=nil;originalWindowUnavailable=true
            }
        }
        // An invalidated AX wrapper does not prove its application disappeared.
        // App-only fallback never selects a replacement window or claims one.
        let suppression=focusRestoreSuppression(hasRecord:true,claimComplete:previous.claimComplete,
            interrupted:monitor.reason != nil || !monitor.available,taskStillFocused:taskStillFocused(previous.task),
            originExists:originAppExists,topologyMatches:topology?.signature==previous.topology)
        if let suppression{return result(false,suppression)}
        do {
            try monitor.check()
            guard taskStillFocused(previous.task) else{return result(false,"task_focus_changed")}
            if previous.application.processIdentifier==previous.task.pid,let window=restoreWindow,CFEqual(window,previous.task.window){return result(true,"already_previous_window")}
            guard previous.application.activate(options:[.activateIgnoringOtherApps]) else{return result(false,"previous_activation_failed",true)}
            let deadline=ProcessInfo.processInfo.systemUptime+0.4
            AXUIElementSetMessagingTimeout(previous.root,0.12)
            if let window=previous.window { AXUIElementSetMessagingTimeout(window,0.12) }
            defer { AXUIElementSetMessagingTimeout(previous.root,0.8); if let window=previous.window {AXUIElementSetMessagingTimeout(window,0.8)} }
            repeat {
                try monitor.check()
                guard try currentDisplays().signature==previous.topology else{return result(false,"display_topology_changed",true)}
                guard !previous.application.isTerminated,previous.application.bundleIdentifier==previous.originBundleID else{return result(false,"previous_app_unavailable",true)}
                if let window=restoreWindow,let frame=restoreFrame,axBounds(window) != frame {
                    restoreWindow=nil;restoreFrame=nil;originalWindowUnavailable=true
                }
                if restoreWindow == nil {
                    let actualPID=foregroundMetadata().pid
                    let actualBundle=actualPID.flatMap{NSRunningApplication(processIdentifier:$0)?.bundleIdentifier}
                    try monitor.check()
                    if focusOriginAppMatches(pid:previous.application.processIdentifier,bundle:previous.originBundleID,actualPID:actualPID,actualBundle:actualBundle) {
                        return result(true,originalWindowUnavailable ? "previous_window_unavailable_app_restored":"previous_app_verified_window_unknown",true)
                    }
                } else if let window=restoreWindow {
                    let originFrontmost=axBool(previous.root,kAXFrontmostAttribute)==true
                    let originalWindowFocused=originFrontmost && axElement(previous.root,kAXFocusedWindowAttribute).map({CFEqual($0,window)})==true
                    try monitor.check()
                    if originalWindowFocused { return result(true,"previous_window_verified",true) }
                    // One raise only after actual activation; an unknown AX
                    // result is verified without replaying activation or raise.
                    if focusRestoreShouldRaise(originFrontmost:originFrontmost,originalWindowFocused:originalWindowFocused,raiseAttempted:raiseResult != nil),
                       ProcessInfo.processInfo.systemUptime<deadline {
                        if windows(previous.root).contains(where:{CFEqual($0,window)}) {
                            try monitor.check()
                            if ProcessInfo.processInfo.systemUptime<deadline { raiseResult=AXUIElementPerformAction(window,kAXRaiseAction as CFString) }
                            try monitor.check()
                        } else {
                            restoreWindow=nil;restoreFrame=nil;originalWindowUnavailable=true
                        }
                    }
                }
                if ProcessInfo.processInfo.systemUptime<deadline { _ = CFRunLoopRunInMode(.defaultMode,0.01,true) }
            }while ProcessInfo.processInfo.systemUptime<deadline
            return result(false,raiseResult.map { $0 != .success && $0 != .actionUnsupported } == true ? "previous_window_raise_unverified":"previous_focus_unverified",true)
        }catch{return result(false,(error as? HelperError)?.code == "user_interrupted" ? "user_takeover":"restore_guard_failed",true)}
    }

    func ensureForegroundClaim(_ target: Target) throws {
        if previousFocus?.runtimeTaskID == currentRuntimeTaskID {
            _ = adoptOwnedFeishuMainReturn()
            _ = adoptOwnedFeishuSearchOpen(target)
        }
        let previous = previousFocus
        let disposition = implicitFocusClaimDisposition(sameTask: previous?.runtimeTaskID == currentRuntimeTaskID,
            sameOperation: runtimeOperationID != nil && previous?.runtimeOperationID == runtimeOperationID,
            complete: previous?.claimComplete == true, monitorAvailable: monitor.available, interrupted: monitor.reason != nil,
            sameProcess: previous?.task.pid == target.pid && previous?.task.bundleID == target.bundleID,
            stillFocused: previous.map { taskStillFocused($0.task) } == true)
        if disposition == "reuse" { return }
        if disposition == "stop" {
            try monitor.check()
            throw fail("focus_scope_changed", "This operation lost its foreground scope; no implicit focus claim or origin replacement", focusScopeChangedDetails(target))
        }
        // Direct input to an already foreground target also needs the notice.
        // An unfocused app still requires an explicit focus command.
        try verify(target)
        _ = try focus(target)
    }

    func focusScopeChangedDetails(_ target: Target) -> [String: Any] {
        ["events_posted": 0, "focus_claim_complete": previousFocus?.claimComplete == true,
         "focus_claim_same_task": previousFocus?.runtimeTaskID == currentRuntimeTaskID,
         "focus_claim_same_operation": runtimeOperationID != nil && previousFocus?.runtimeOperationID == runtimeOperationID,
         "focus_claim_same_process": previousFocus?.task.pid == target.pid && previousFocus?.task.bundleID == target.bundleID,
         "focus_monitor_available": monitor.available, "focus_monitor_interrupted": monitor.reason != nil,
         "pending_search_open": previousFocus?.ownedFeishuOpen != nil,
         "pending_search_return": previousFocus?.ownedFeishuReturn != nil,
         "owned_navigation_diagnostic": previousFocus?.ownedFeishuReturnDiagnostic.map { $0 as Any } ?? NSNull()]
    }

    func waitForFocusHandoff(_ target: Target) throws -> (revision: UInt64, elapsedMS: Double) {
        guard monitor.available else { throw fail("input_monitoring_unavailable", "Input monitoring is required before a handoff notice") }
        guard let origin = foregroundMetadata().pid else { throw fail("previous_focus_unavailable", "Current foreground identity is unavailable") }
        let originRoot = AXUIElementCreateApplication(origin)
        AXUIElementSetMessagingTimeout(originRoot, 0.12)
        let originWindow = axElement(originRoot, kAXFocusedWindowAttribute)
        let notice = try NativeFocusNotice()
        defer { notice.close() }
        let start = ProcessInfo.processInfo.systemUptime
        repeat {
            guard monitor.available, foregroundMetadata().pid == origin,
                  originWindow.map({ saved in axElement(originRoot, kAXFocusedWindowAttribute).map { CFEqual($0, saved) } == true }) != false else {
                throw fail("user_interrupted", "Original focus changed during the handoff notice; target was not activated")
            }
            try verifyDisplayTopology(target)
            let now = ProcessInfo.processInfo.systemUptime, quiet = monitor.focusQuietObservation
            if quiet.mayClaim(noticeStarted: start, now: now) { return (quiet.revision, (now - start) * 1000) }
            if now - start >= 2 { break }
            _ = CFRunLoopRunInMode(.defaultMode, 0.02, true)
        } while true
        throw fail("user_interrupted", "User input continued through the handoff notice; original focus was retained",
            ["handoff_notice_shown": true, "target_activated": false, "events_posted": 0])
    }

    func focus(_ target: Target) throws -> [String: Any] {
        // Every explicit native stage keeps its concrete origin process/window.
        // Restore uses that recorded process object, never a bundle-only lookup.
        if previousFocus?.runtimeTaskID == currentRuntimeTaskID {
            _ = adoptOwnedFeishuMainReturn()
            _ = adoptOwnedFeishuSearchOpen(target)
        }
        if let previous = previousFocus, previous.runtimeTaskID == currentRuntimeTaskID,
           runtimeOperationID != nil, previous.runtimeOperationID == runtimeOperationID,
           (!previous.claimComplete || monitor.reason != nil || !taskStillFocused(previous.task)) {
            try monitor.check()
            throw fail("focus_scope_changed", "An existing operation cannot replace its original focus record", focusScopeChangedDetails(target))
        }
        let continuing = previousFocus.map {
            focusRecordTaskMatches($0.runtimeTaskID, currentRuntimeTaskID) && $0.claimComplete &&
                monitor.reason == nil && taskStillFocused($0.task)
        } == true
        let handoff = continuing ? nil : try waitForFocusHandoff(target)
        try capturePreviousFocus(target)
        var completed=false
        defer{if !completed {previousFocus=nil;monitor.discardClaim()}}
        try monitor.prepareExplicitFocus(quietRevision: handoff?.revision, continuing: continuing)
        try verify(target, foreground: false, focusedWindow: false)
        guard target.application.activate(options: [.activateIgnoringOtherApps]) else {throw fail("activation_failed", "The running target application could not be activated")}
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var last: Error = fail("foreground_mismatch", "Focus did not settle")
        var selectionAttempted = false
        var selectionResults: [String: Any] = [:]
        repeat {
            try verify(target, foreground: false, focusedWindow: false)
            // Activation returns before the app has finished restoring its
            // previous key window. Select our exact window only after actual
            // AXFrontmost; otherwise that restoration can undo an early raise.
            if !selectionAttempted, try currentInspectedDialog(target) == nil,
               axBool(target.axApplication, kAXFrontmostAttribute) == true,
               axElement(target.axApplication, kAXFocusedWindowAttribute).map({ CFEqual($0, target.window) }) != true {
                selectionAttempted = true
                let mainResult = AXUIElementSetAttributeValue(target.window, kAXMainAttribute as CFString, kCFBooleanTrue)
                selectionResults["AXMain_result"] = axResult(mainResult)
                try monitor.check()
                let raiseResult = AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
                selectionResults["AXRaise_result"] = axResult(raiseResult)
                if raiseResult != .success && raiseResult != .actionUnsupported {
                    throw fail("ax_action_failed", "AXRaise failed: \(raiseResult.rawValue)", selectionResults)
                }
                try monitor.check()
                // AXMain is document selection, not proof of keyboard focus.
                // Use the public focused setter only when this exact window
                // advertises it as writable, then independently read focus.
                var writable = DarwinBoolean(false)
                let writableResult = AXUIElementIsAttributeSettable(target.window, kAXFocusedAttribute as CFString, &writable)
                selectionResults["AXFocused_settable_result"] = axResult(writableResult)
                selectionResults["AXFocused_settable"] = writable.boolValue
                if writableResult == .success, writable.boolValue {
                    try monitor.check()
                    selectionResults["AXFocused_set_result"] = axResult(AXUIElementSetAttributeValue(target.window, kAXFocusedAttribute as CFString, kCFBooleanTrue))
                }
            }
            do {try verify(target)}
            catch {last=error;try monitor.check();_ = CFRunLoopRunInMode(.defaultMode,0.02,true);continue}
            try monitor.completeExplicitFocus(retainClaim:true)
            try verify(target) // New post-baseline input or focus loss is never reset.
            previousFocus?.claimComplete=true;completed=true
            return ["app":target.bundleID,"target_pid":target.pid,"window_title":axString(target.window,kAXTitleAttribute) ?? "", "foreground_verified":true,"user_interruption_cleared":true,
                "takeover_baseline":"before_target_activation","handoff_notice_shown":handoff != nil,
                "handoff_wait_ms":handoff?.elapsedMS ?? 0,"continuous_task_focus_claim":continuing,
                "previous_focus_recorded":previousFocus != nil,
                "previous_focus_scope":previousFocus.map{$0.window == nil ? "app_only":"exact_window"} ?? "unavailable",
                "previous_window_known":previousFocus?.window != nil,
                "window_selection_attempted":selectionAttempted,"window_selection_results":selectionResults]
        }while ProcessInfo.processInfo.systemUptime<deadline
        if let failure = last as? HelperError {
            var details = failure.details
            details["window_selection_attempted"] = selectionAttempted
            details["window_selection_results"] = selectionResults
            details["actual_frontmost"] = axBool(target.axApplication, kAXFrontmostAttribute) as Any? ?? NSNull()
            details["selected_window_is_focused"] = axElement(target.axApplication, kAXFocusedWindowAttribute).map { CFEqual($0, target.window) } as Any? ?? NSNull()
            throw fail(failure.code, failure.message, details)
        }
        throw last
    }

    func requireEvents() throws {
        guard CGPreflightPostEventAccess(), source != nil else { throw fail("post_event_unavailable", "Permission to post keyboard/mouse events is unavailable") }
    }

    func post(_ event: CGEvent, target: Target) throws {
        try monitor.check()
        try verifyDisplayTopology(target)
        event.setIntegerValueField(.eventSourceUserData, value: monitor.marker)
        event.post(tap: .cghidEventTap)
    }

    func coordinateClick(_ point: CGPoint, target: Target) throws -> [String: Any] {
        try requireEvents()
        try verify(target)
        let activeDialog = try currentInspectedDialog(target)
        let inputWindow = activeDialog?.dialog ?? target.window
        let initialBounds = axBounds(inputWindow)
        func focusedClickGuard(_ frame: CGRect?) throws -> Bool {
            if activeDialog != nil { _ = try focused(target); return false }
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(target.axApplication, kAXFocusedUIElementAttribute as CFString, &raw)
            if result == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                try denySecure(unsafeBitCast(raw, to: AXUIElement.self))
                return false
            }
            guard wechatSidebarNavigationWithoutFocusedElement(bundle: target.bundleID, expectedTitle: target.expectedTitle,
                    currentTitle: axString(target.window, kAXTitleAttribute), windowRole: axString(target.window, kAXRoleAttribute),
                    frame: frame, point: point, focusRead: result, hasRawFocus: raw != nil,
                    foregroundScope: backgroundScope == nil, secureEventInput: IsSecureEventInputEnabled()) else {
                throw fail("focused_element_unavailable", "No safely verified focused element; use the confirmed visual_click route when supported",
                    ["read_result": axResult(result), "events_posted": 0, "supported_route": "visual_click"])
            }
            try denySecure(target.window)
            return true
        }
        let sidebarNavigation = try focusedClickGuard(initialBounds)
        let displays = try currentDisplays()
        guard displays.signature == target.displaySignature else {
            throw fail("display_topology_changed", "Display topology changed before the click; inspect again")
        }
        guard let display = displays.display(at: point) else {
            throw fail("coordinate_not_on_display", "Click point lies outside all active displays or in a gap between displays")
        }
        guard let bounds = axBounds(inputWindow), pointIsInsideRect(point, bounds) else {
            throw fail("coordinate_outside_window", "Click point must lie inside the selected target window bounds")
        }
        var hit: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.8)
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else {
            throw fail("coordinate_target_unavailable", "Could not verify the element at the click point")
        }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success,
              activeDialog.map({ nativeElementInDialog(hit, dialog: $0.dialog) }) ?? (hitPID == target.pid) else {
            throw fail("coordinate_target_mismatch", "Click point is covered by a different application")
        }
        try denySecure(hit)
        var ancestor: AXUIElement? = hit
        var belongs = false
        for _ in 0..<24 {
            guard let current = ancestor else { break }
            if CFEqual(current, inputWindow) || axElement(current, kAXWindowAttribute).map({ CFEqual($0, inputWindow) }) == true {
                belongs = true; break
            }
            ancestor = axElement(current, kAXParentAttribute)
        }
        guard belongs else { throw fail("coordinate_target_mismatch", "Click point does not belong to the selected target window") }
        if sidebarNavigation {
            try verify(target)
            guard axBounds(target.window) == initialBounds, try focusedClickGuard(initialBounds) else {
                throw fail("focused_element_changed", "The navigation-only focus/window evidence changed before the click", ["events_posted": 0])
            }
        }
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw fail("event_creation_failed", "Could not construct mouse events")
        }
        down.flags = []; up.flags = []
        try verify(target)
        guard axBounds(inputWindow) == initialBounds else { throw fail("window_geometry_changed", "The selected input window/dialog moved before the click") }
        try post(down, target: target)
        // Always balance an already-sent down, even if takeover occurs between the pair.
        up.setIntegerValueField(.eventSourceUserData, value: monitor.marker)
        up.post(tap: .cghidEventTap)
        try checkAfterAcceptedAction("CGEvent")
        var receipt: [String: Any] = ["method": "CGEvent", "x": point.x, "y": point.y, "display_id": display.id,
            "coordinate_system": "quartz_global_points", "action_accepted": true, "events_posted": 2,
            "foreground_verified_before_action": true]
        if sidebarNavigation {
            receipt["route"] = "wechat_sidebar_navigation_ax_hit_test"
            receipt["navigation_only"] = true; receipt["focused_element_missing"] = true
            receipt["secure_event_input_verified_disabled"] = true
            receipt["selected_chat_verified"] = false
        }
        return receipt
    }

    func validateScroll(_ request: [String: Any]) throws {
        let hasElement = request["element_id"] != nil
        let hasCoordinate = request["x"] != nil || request["y"] != nil
        guard hasElement != hasCoordinate else { throw fail("invalid_request", "scroll requires element_id or both x and y, exclusively") }
        if hasElement { _ = try string(request, "element_id") }
        else { _ = try number(request, "x"); _ = try number(request, "y") }
        let delta = try integer(request, "delta_y", default: 0, range: -100...100)
        guard delta != 0 else { throw fail("invalid_request", "scroll delta_y must be a nonzero integer between -100 and 100") }
    }

    func scroll(_ request: [String: Any], target: Target) throws -> [String: Any] {
        var count = 0
        do {
            try validateScroll(request)
            try requireEvents()
            try verify(target)
            let activeDialog = try currentInspectedDialog(target)
            let inputWindow = activeDialog?.dialog ?? target.window
            var inputPID: pid_t = 0
            guard AXUIElementGetPid(inputWindow, &inputPID) == .success else { throw fail("window_identity_unavailable", "Selected input window/dialog PID is unavailable") }
            try denySecure(inputWindow)
            if activeDialog != nil { _ = try focused(target) }
            else if let focused = axElement(target.axApplication, kAXFocusedUIElementAttribute) { try denySecure(focused) }
            guard let originalBounds = axBounds(inputWindow) else { throw fail("window_bounds_unavailable", "Selected window has no accessible geometry") }
            let element: AXUIElement?
            let elementBounds: CGRect?
            let point: CGPoint
            if request["element_id"] != nil {
                let selected = try cached(request, target: target)
                guard axBool(selected, kAXEnabledAttribute) != false else { throw fail("element_disabled", "Scroll target is disabled") }
                guard let bounds = axBounds(selected), !bounds.intersection(originalBounds).isNull else {
                    throw fail("element_bounds_unavailable", "Scroll target has no visible bounds within the selected window")
                }
                let visible = bounds.intersection(originalBounds)
                guard visible.width > 0, visible.height > 0 else { throw fail("coordinate_outside_window", "Scroll target has no visible area in the selected window") }
                element = selected; elementBounds = bounds
                point = CGPoint(x: visible.midX, y: visible.midY)
            } else {
                element = nil; elementBounds = nil
                point = try CGPoint(x: number(request, "x"), y: number(request, "y"))
            }
            guard pointIsInsideRect(point, originalBounds) else { throw fail("coordinate_outside_window", "Scroll point must lie within the selected target window") }
            let displays = try currentDisplays()
            guard displays.signature == target.displaySignature, let display = displays.display(at: point) else {
                throw fail("coordinate_not_on_display", "Scroll point is outside all active displays or in a gap")
            }
            let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let matched = rows.filter { row in
                guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == inputPID,
                      let raw = row[kCGWindowBounds as String] as? [String: Any],
                      let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
                return abs(bounds.minX-originalBounds.minX) < 0.5 && abs(bounds.minY-originalBounds.minY) < 0.5 &&
                    abs(bounds.width-originalBounds.width) < 0.5 && abs(bounds.height-originalBounds.height) < 0.5
            }
            guard matched.count == 1,
                  let windowID = (matched[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let raw = matched[0][kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else {
                throw fail("window_geometry_ambiguous", "Expected one onscreen CG window with the selected AX window PID and geometry")
            }
            let identity = VisualIdentity(pid: inputPID, windowID: windowID, frame: cgBounds, topology: target.displaySignature)
            func guardCurrentWindow() throws {
                try verify(target)
                try denySecure(inputWindow)
                if let focused = axElement(target.axApplication, kAXFocusedUIElementAttribute) { try denySecure(focused) }
                guard axBounds(inputWindow) == originalBounds else { throw fail("window_geometry_changed", "Window geometry changed during scroll") }
                if let element {
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(element, &pid) == .success,
                          activeDialog.map({ nativeElementInDialog(element, dialog: $0.dialog) }) ?? (pid == target.pid),
                          axBounds(element) == elementBounds else { throw fail("stale_element", "Scroll element geometry or process changed") }
                    try denySecure(element)
                }
                try guardDesktopPoint(point, identity: identity, selectedWindow: inputWindow)
            }
            try guardCurrentWindow()
            let delta = try integer(request, "delta_y", default: 0, range: -100...100)
            guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
                  let wheel = visualScrollEvent(point: point, delta: Int32(delta), source: source) else {
                throw fail("event_creation_failed", "Could not construct scroll events")
            }
            move.flags = []
            try post(move, target: target); count += 1
            try guardCurrentWindow()
            try post(wheel, target: target); count += 1
            try verify(target)
            guard axBounds(inputWindow) == originalBounds else { throw fail("window_geometry_changed", "Window geometry changed after scroll events") }
            return ["method": "CGEventScroll", "x": point.x, "y": point.y, "delta_y": delta,
                "display_id": display.id, "window_id": windowID, "target_pid": target.pid,
                "coordinate_system": "quartz_global_points", "events_posted": count, "action_accepted": true,
                "viewport_verified": false, "verification_source": "events_posted_only",
                "foreground_verified_before_action": true, "automatic_replay_allowed": false]
        } catch {
            let underlying = error as? HelperError ?? fail("scroll_failed", error.localizedDescription)
            var details = underlying.details
            details["events_posted"] = count; details["scroll_may_be_partial"] = count > 0
            details["viewport_verified"] = false; details["automatic_replay_allowed"] = false
            throw fail(underlying.code, underlying.message, details)
        }
    }

    func press(_ request: [String: Any], target: Target, permitCenter: Bool) throws -> [String: Any] {
        try verify(target)
        let returnCandidate = feishuModalReturnCandidate(target)
        var openCandidate: OwnedFeishuSearchOpen?
        func completedNavigation(_ result: [String: Any]) -> [String: Any] {
            if previousFocus?.ownedFeishuReturnDiagnostic?["navigation_kind"] as? String == "main_to_search" {
                previousFocus?.ownedFeishuReturnDiagnostic?["action_accepted"] = result["action_accepted"] as? Bool == true
                previousFocus?.ownedFeishuReturnDiagnostic?["candidate_retained"] = false
                if let openCandidate {
                    previousFocus?.ownedFeishuReturnDiagnostic?["activity_revision_matches"] = openCandidate.main.activityRevision == monitor.focusQuietObservation.revision
                    previousFocus?.ownedFeishuReturnDiagnostic?["adoption_reason"] = "candidate_not_retained"
                }
            }
            if target.bundleID == "com.bytedance.macos.feishu", target.expectedTitle == feishuSearchWindowTitle,
               result["action_accepted"] as? Bool == true {
                previousFocus?.ownedFeishuReturnDiagnostic?["action_accepted"] = true
            }
            if let returnCandidate, result["action_accepted"] as? Bool == true, monitor.reason == nil,
               previousFocus?.task.pid == target.pid,
               previousFocus.map({ CFEqual($0.task.window, target.window) }) == true {
                previousFocus?.ownedFeishuReturn = returnCandidate
            }
            if let openCandidate, result["action_accepted"] as? Bool == true,
               monitor.reason == nil, monitor.available,
               openCandidate.main.activityRevision == monitor.focusQuietObservation.revision,
               previousFocus?.runtimeTaskID == currentRuntimeTaskID,
               previousFocus?.runtimeOperationID == runtimeOperationID,
               previousFocus?.task.pid == target.pid,
               previousFocus.map({ CFEqual($0.task.window, target.window) }) == true {
                previousFocus?.ownedFeishuOpen = openCandidate
                previousFocus?.ownedFeishuReturnDiagnostic?["candidate_retained"] = true
                previousFocus?.ownedFeishuReturnDiagnostic?["accepted_navigation"] = "exact_search_AXPress"
            }
            return result
        }
        if request["element_id"] == nil {
            guard request["x"] != nil && request["y"] != nil else { throw fail("invalid_request", "Provide element_id or both x and y") }
            return completedNavigation(try coordinateClick(CGPoint(x: number(request, "x"), y: number(request, "y")), target: target))
        }
        let element = try cached(request, target: target)
        guard axBool(element, kAXEnabledAttribute) != false else { throw fail("element_disabled", "Target element is disabled") }
        if axActions(element).contains(kAXPressAction) {
            try verify(target)
            openCandidate = feishuSearchOpenCandidate(target, element: element)
            let activityRevision = monitor.focusQuietObservation.revision
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            guard result == .success else { throw fail("ax_action_failed", "AXPress failed: \(result.rawValue)") }
            if previousFocus?.ownedFeishuReturnDiagnostic?["navigation_kind"] as? String == "main_to_search" {
                previousFocus?.ownedFeishuReturnDiagnostic?["action_accepted"] = true
                previousFocus?.ownedFeishuReturnDiagnostic?["activity_revision_matches"] = activityRevision == monitor.focusQuietObservation.revision
            }
            try checkAfterAcceptedAction("AXPress")
            if !["com.tencent.xinWeChat", "com.bytedance.macos.feishu"].contains(target.bundleID),
               let operation = runtimeOperationID, monitor.reason == nil,
               monitor.focusQuietObservation.revision == activityRevision,
               previousFocus?.runtimeTaskID == currentRuntimeTaskID, previousFocus?.claimComplete == true {
                acceptedAXWindowTransition = (currentRuntimeTaskID, operation, target.pid, target.bundleID,
                    activityRevision, ProcessInfo.processInfo.systemUptime + 15)
            }
            return completedNavigation(["method": "AXPress", "element_id": request["element_id"]!,
                "action_accepted": true, "foreground_verified_before_action": true])
        }
        if request["x"] != nil || request["y"] != nil {
            return completedNavigation(try coordinateClick(CGPoint(x: number(request, "x"), y: number(request, "y")), target: target))
        }
        guard permitCenter else { throw fail("action_unsupported", "Element has no AXPress; an explicit click fallback is required") }
        guard let rect = axBounds(element) else { throw fail("element_bounds_unavailable", "Target element has no accessible bounds") }
        return completedNavigation(try coordinateClick(CGPoint(x: rect.midX, y: rect.midY), target: target))
    }

    func text(_ request: [String: Any]) throws -> String {
        let value = try string(request, "text", required: false)
        guard let value else { throw fail("invalid_request", "Missing string field: text") }
        guard value.count <= 65536 else { throw fail("text_too_large", "text is limited to 65536 characters") }
        return value
    }

    func typedText(_ request: [String: Any]) throws -> String {
        let value = try text(request)
        guard !value.utf16.contains(0x000D), !value.utf16.contains(0x0009) else {
            throw fail("unsupported_text_control", "type_text supports LF newlines; CR and TAB are rejected before any action")
        }
        return value
    }

    func explicitExpectedValue(_ request: [String: Any], text: String) throws -> String? {
        guard let raw = request["expected_value"] else { return nil }
        guard let expected = raw as? String else { throw fail("invalid_request", "expected_value must be a string") }
        guard expected.count <= 65536 else { throw fail("text_too_large", "expected_value is limited to 65536 characters") }
        guard !text.isEmpty, expected.contains(text) else {
            throw fail("invalid_request", "expected_value must contain the nonempty requested text")
        }
        return expected
    }

    func setText(_ request: [String: Any], target: Target) throws -> [String: Any] {
        let value = try text(request)
        try verify(target)
        let element = try cached(request, target: target)
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else {
            throw fail("value_not_settable", "AXValue is not settable; use type_text for an editable focused control")
        }
        try verify(target)
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        guard result == .success else { throw fail("ax_set_failed", "AXValue write failed: \(result.rawValue)") }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        repeat {
            try verify(target)
            if axString(element, kAXValueAttribute) == value {
                return ["method": "AXValue", "element_id": request["element_id"]!, "verified": true,
                    "characters": value.count, "value": String(value.prefix(4000))]
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw fail("postcondition_failed", "AXValue did not equal requested text after the write")
    }

    func focusElement(_ element: AXUIElement, target: Target, actionAccepted: ((Int) -> Void)? = nil) throws {
        try verify(target)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue {
            let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard result == .success else { throw fail("element_focus_failed", "Could not focus target element") }
            actionAccepted?(0)
        } else if let current = try? focused(target), CFEqual(current, element) {
            return
        } else {
            guard let bounds = axBounds(element) else { throw fail("element_focus_failed", "Element cannot be focused and has no click bounds") }
            do {
                let result = try coordinateClick(CGPoint(x: bounds.midX, y: bounds.midY), target: target)
                actionAccepted?(result["events_posted"] as? Int ?? 0)
            } catch {
                if let failure = error as? HelperError, failure.details["action_accepted"] as? Bool == true,
                   failure.details["method"] as? String == "CGEvent" { actionAccepted?(2) }
                throw error
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        repeat {
            try verify(target)
            if let current = try? focused(target), CFEqual(current, element) { return }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw fail("element_focus_failed", "Focused element does not match selected element")
    }

    func clearExpectedValues(_ request: [String: Any]) throws -> (current: String, empty: String) {
        func requiredValue(_ name: String) throws -> String {
            guard let value = try string(request, name, required: false) else {
                throw fail("invalid_request", "Missing string field: \(name)")
            }
            guard value.count <= 65536 else { throw fail("text_too_large", "\(name) is limited to 65536 characters") }
            return value
        }
        return (try requiredValue("expected_value"), try requiredValue("expected_empty_value"))
    }

    func clearText(_ request: [String: Any], target: Target) throws -> [String: Any] {
        let expected = try clearExpectedValues(request)
        var keyboardEvents = 0
        var focusEvents = 0
        var focusActionAccepted = false
        var focusStarted = false
        var completedSteps: [String] = []
        do {
            try requireEvents()
            try verify(target)
            let element = try cached(request, target: target)
            guard ["AXTextArea", "AXTextField", "AXComboBox"].contains(axString(element, kAXRoleAttribute) ?? "") else {
                throw fail("unsupported_text_role", "clear_text requires a readable text area, text field or combo box")
            }
            guard let before = axString(element, kAXValueAttribute) else {
                throw fail("value_unreadable", "clear_text requires a readable string AXValue")
            }
            guard before == expected.current else {
                throw fail("precondition_failed", "AXValue does not exactly equal expected_value; no clear events were posted")
            }
            focusStarted = true
            try focusElement(element, target: target) { count in
                focusActionAccepted = true; focusEvents += count
            }
            func verifyElement() throws {
                try verify(target)
                try denySecure(element)
                let current = try focused(target)
                guard CFEqual(current, element) else { throw fail("element_focus_changed", "Focused element changed during clear_text") }
            }
            func postKey(_ code: CGKeyCode, flags: CGEventFlags) throws {
                try verifyElement()
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                    throw fail("event_creation_failed", "Could not construct clear_text keyboard events")
                }
                down.flags = flags; up.flags = []
                try post(down, target: target); keyboardEvents += 1
                // Balance the accepted down even when the user takes over between events.
                up.setIntegerValueField(.eventSourceUserData, value: monitor.marker)
                up.post(tap: .cghidEventTap); keyboardEvents += 1
            }
            try verifyElement()
            guard axString(element, kAXValueAttribute) == expected.current else {
                throw fail("precondition_failed", "AXValue changed while focusing; no clear keyboard events were posted")
            }
            try postKey(0, flags: .maskCommand)
            completedSteps.append("select_all_events_posted")
            try verifyElement()
            guard axString(element, kAXValueAttribute) == expected.current else {
                throw fail("precondition_failed", "AXValue changed after select-all; deletion was not posted")
            }
            // Some rich editors expose a stale AXSelectedTextRange. Only the final
            // exact AXValue establishes completion of this explicit clear operation.
            try postKey(51, flags: [])
            completedSteps.append("backspace_events_posted")
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = started + 1
            repeat {
                try verifyElement()
                if axString(element, kAXValueAttribute) == expected.empty {
                    return ["method": "SelectAllBackspaceCGEvent", "element_id": request["element_id"]!,
                        "clear_verified": true, "value_verified": true, "verification_source": "explicit_expected_empty_value",
                        "selection_verified": false, "selection_verification": "not_used",
                        "events_posted": keyboardEvents + focusEvents, "keyboard_events_posted": keyboardEvents,
                        "focus_events_posted": focusEvents, "completed_steps": completedSteps,
                        "waited_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                        "value": String(expected.empty.prefix(4000)), "automatic_replay_allowed": false]
                }
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                Thread.sleep(forTimeInterval: 0.02)
            } while true
            throw fail("postcondition_failed", "Clear events were posted but AXValue does not exactly equal expected_empty_value")
        } catch {
            let underlying = error as? HelperError ?? fail("internal_error", error.localizedDescription)
            var details = underlying.details
            details["events_posted"] = keyboardEvents + focusEvents
            details["keyboard_events_posted"] = keyboardEvents
            details["focus_events_posted"] = focusEvents
            details["completed_steps"] = completedSteps
            details["focus_may_have_changed"] = focusStarted
            details["action_accepted"] = keyboardEvents > 0 || focusActionAccepted
            details["selection_may_have_changed"] = keyboardEvents > 0
            details["clearing_may_have_occurred"] = keyboardEvents >= 3
            details["clear_state_uncertain"] = keyboardEvents > 0
            details["automatic_replay_allowed"] = false
            throw fail(underlying.code, underlying.message, details)
        }
    }

    func replaceFeishuSearch(_ request: [String: Any], target: Target) throws -> [String: Any] {
        var events = 0, chunks = 0, selectionAccepted = false, beforeVerified = false
        var waitedMS = 0
        do {
            let expected = try FeishuSearchReplacement(request)
            guard target.bundleID == "com.bytedance.macos.feishu", target.expectedTitle == feishuSearchWindowTitle else {
                throw fail("search_replacement_target_denied", "replace_search is restricted to the known Feishu search modal")
            }
            try requireEvents()
            try verify(target)
            let element = try cached(request, target: target)
            let frame = axBounds(target.window)
            func guardEditor() throws {
                try verify(target)
                try denySecure(element)
                guard frame != nil, axBounds(target.window) == frame, axBool(element, kAXEnabledAttribute) != false,
                      axString(element, kAXRoleAttribute) == "AXTextArea",
                      CFEqual(try focused(target), element) else {
                    throw fail("element_focus_changed", "Search replacement requires the same enabled, focused editor and window")
                }
            }
            try guardEditor()
            guard feishuSearchReplacementTargetAllowed(bundle: target.bundleID,
                    title: axString(target.window, kAXTitleAttribute) ?? "", role: axString(element, kAXRoleAttribute) ?? "",
                    focused: true, secure: isSecure(element), actualBefore: axString(element, kAXValueAttribute), expectedBefore: expected.before) else {
                throw fail("precondition_failed", "Actual search editor does not exactly match expected_before; no events were posted")
            }
            beforeVerified = true
            func pair(_ code: CGKeyCode, flags: CGEventFlags = [], text: [UniChar]? = nil) throws {
                try guardEditor()
                if events == 0, axString(element, kAXValueAttribute) != expected.before {
                    throw fail("precondition_failed", "Complete search value changed before first event")
                }
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                    throw fail("event_creation_failed", "Could not construct search replacement events")
                }
                down.flags = flags; up.flags = []
                if var text {
                    text.withUnsafeMutableBufferPointer { buffer in
                        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                    }
                }
                try post(down, target: target); events += 1
                // Balance the accepted down even if a new interruption occurs.
                up.setIntegerValueField(.eventSourceUserData, value: monitor.marker)
                up.post(tap: .cghidEventTap); events += 1
            }
            if !expected.beforeQuery.isEmpty {
                try pair(0, flags: .maskCommand)
                selectionAccepted = true
                try guardEditor()
                guard axString(element, kAXValueAttribute) == expected.before else {
                    throw fail("precondition_failed", "Search value changed after select-all; no replacement text was posted")
                }
            }
            // This search-only route verifies the final complete AX serialization,
            // rather than relying on an intermediate AXSelectedTextRange.
            let units = Array(expected.text.utf16)
            var offset = 0
            while offset < units.count {
                var end = min(offset + 20, units.count)
                if end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
                try pair(0, text: Array(units[offset..<end]))
                chunks += 1; offset = end
            }
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = started + 3
            repeat {
                try guardEditor()
                let value = axString(element, kAXValueAttribute)
                waitedMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                if let verified = feishuSearchVerifiedAfter(value, query: expected.text) {
                    return ["method": "FeishuSearchSelectAllUnicode", "replace_search": true,
                        "value_verified": true, "value": verified.value, "verification_source": "exact_known_search_AX_serialization",
                        "query_verified": true, "query_value": expected.text, "search_value_serialization": verified.serialization,
                        "expected_before_verified": true, "search_selection_events_accepted": selectionAccepted,
                        "selection_verified": false, "events_posted": events, "chunks": chunks,
                        "characters": expected.text.count, "utf16_units": units.count, "newline_count": 0,
                        "waited_ms": waitedMS, "verification_limit_ms": 3000, "automatic_replay_allowed": false]
                }
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                _ = CFRunLoopRunInMode(.defaultMode, 0.02, true)
            } while true
            throw fail("postcondition_failed", "Search replacement events were posted but complete AXValue was not verified")
        } catch {
            let underlying = error as? HelperError ?? fail("search_replacement_failed", error.localizedDescription)
            var details = underlying.details
            details["replace_search"] = true; details["events_posted"] = events
            details["search_selection_events_accepted"] = selectionAccepted
            details["expected_before_verified"] = beforeVerified
            details["input_may_be_partial"] = events > 0; details["automatic_replay_allowed"] = false
            details["waited_ms"] = waitedMS; details["verification_limit_ms"] = 3000
            throw fail(underlying.code, underlying.message, details)
        }
    }

    func typeText(_ request: [String: Any], target: Target) throws -> [String: Any] {
        if try boolean(request, "replace_search") { return try replaceFeishuSearch(request, target: target) }
        let value = try typedText(request)
        let explicitExpected = try explicitExpectedValue(request, text: value)
        try requireEvents()
        try verify(target)
        let element: AXUIElement
        if request["element_id"] != nil {
            element = try cached(request, target: target)
            try focusElement(element, target: target)
        } else { element = try focused(target) }
        try denySecure(element)
        let before = axString(element, kAXValueAttribute)
        let selection = axSelectedRange(element)
        let selectionExpected: String?
        if let before, let selection, selection.location <= (before as NSString).length,
           selection.length <= (before as NSString).length - selection.location {
            selectionExpected = (before as NSString).replacingCharacters(
                in: NSRange(location: selection.location, length: selection.length), with: value)
        } else { selectionExpected = nil }
        let expected = explicitExpected ?? selectionExpected
        let verificationSource = explicitExpected != nil ? "explicit_expected_value" :
            (selectionExpected != nil ? "selection" : "changed_contains_text")
        let units = Array(value.utf16)
        var offset = 0
        var chunks = 0
        var newlineCount = 0
        while offset < units.count {
            try verify(target)
            let current = try focused(target)
            guard CFEqual(current, element) else { throw fail("element_focus_changed", "Focused element changed during text input") }
            let newline = units[offset] == 0x000A
            var end = newline ? offset + 1 : min(offset + 20, units.count)
            if !newline {
                if let lineBreak = units[offset..<end].firstIndex(of: 0x000A) { end = lineBreak }
                if end < units.count && units[end - 1] >= 0xD800 && units[end - 1] <= 0xDBFF { end -= 1 }
            }
            var chunk = Array(units[offset..<end])
            let virtualKey: CGKeyCode = newline ? 36 : 0
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
                throw fail("event_creation_failed", "Could not construct Unicode keyboard events")
            }
            // CGEvent inherits source-state flags. Unicode input must never inherit a
            // preceding shortcut's Command/Option/Control/Shift state.
            down.flags = []; up.flags = []
            if newline {
                // Cocoa treats a control character in a Unicode keyDown as a command
                // and can discard the rest of that event's payload. Send Return alone.
                newlineCount += 1
            } else {
                chunk.withUnsafeMutableBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
            }
            try post(down, target: target)
            up.setIntegerValueField(.eventSourceUserData, value: monitor.marker)
            up.post(tap: .cghidEventTap)
            chunks += 1
            offset = end
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var observed: String?
        var verified = value.isEmpty
        repeat {
            try verify(target)
            observed = axString(element, kAXValueAttribute)
            if let expected { verified = observed == expected }
            else if !value.isEmpty { verified = observed != nil && observed != before && observed?.contains(value) == true }
            if verified || (before == nil && explicitExpected == nil) { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        if (before != nil || explicitExpected != nil) && !verified {
            throw fail("postcondition_failed", "Unicode events were posted but accessible value does not match the expected insertion/replacement",
                ["events_posted": chunks * 2, "characters": value.count, "verification_source": verificationSource])
        }
        return ["method": "UnicodeCGEvent", "characters": value.count, "utf16_units": units.count,
            "chunks": chunks, "newline_count": newlineCount, "value_verified": verified,
            "selection_verified": verificationSource == "selection" && verified, "verification_source": verificationSource,
            "value": observed.map { String($0.prefix(4000)) } ?? NSNull()]
    }

    let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53,
        "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111]

    func key(_ request: [String: Any], target: Target) throws -> [String: Any] {
        let name = try string(request, "key")!.lowercased()
        guard let code = keyCodes[name] else { throw fail("unsupported_key", "Unsupported key: \(name)") }
        var flags: CGEventFlags = []
        if let raw = request["modifiers"] {
            guard let modifiers = raw as? [String], modifiers.count <= 5 else { throw fail("invalid_request", "modifiers must be an array of at most 5 strings") }
            for modifier in modifiers {
                switch modifier.lowercased() {
                case "cmd", "command": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "ctrl", "control": flags.insert(.maskControl)
                case "alt", "option": flags.insert(.maskAlternate)
                case "fn": flags.insert(.maskSecondaryFn)
                default: throw fail("unsupported_modifier", "Unsupported modifier: \(modifier)")
                }
            }
        }
        try requireEvents()
        try verify(target)
        let element = try keyFocusedElement(target, name: name, flags: flags)
        let simpleEscape = name == "escape" && flags.isEmpty
        if simpleEscape { try denySecure(target.window) }
        let returnCandidate = feishuSearchEscapeReturnEligible(bundle: target.bundleID, title: target.expectedTitle, key: name, flags: flags)
            ? feishuModalReturnCandidate(target) : nil
        var expectedSelection: CFRange?
        if let element, flags == .maskCommand, let current = axString(element, kAXValueAttribute), let selected = axSelectedRange(element) {
            let length = (current as NSString).length
            if name == "a" { expectedSelection = CFRange(location: 0, length: length) }
            else if name == "right", selected.location <= length, selected.length <= length - selected.location {
                // Command-right means the end of the current line in Cocoa text controls.
                let start = selected.location + selected.length
                let remaining = NSRange(location: start, length: length - start)
                let newline = (current as NSString).rangeOfCharacter(from: .newlines, options: [], range: remaining)
                expectedSelection = CFRange(location: newline.location == NSNotFound ? length : newline.location, length: 0)
            }
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw fail("event_creation_failed", "Could not construct keyboard events")
        }
        down.flags = flags
        // There are no separately held modifier keys in this protocol. Release the
        // shortcut's synthetic modifier state when balancing its key-up event.
        up.flags = []
        try post(down, target: target)
        up.setIntegerValueField(.eventSourceUserData, value: monitor.marker)
        up.post(tap: .cghidEventTap)
        if simpleEscape {
            try checkAfterAcceptedAction("CGEvent")
            try verifyDisplayTopology(target)
            if let returnCandidate, monitor.reason == nil, previousFocus?.claimComplete == true,
               previousFocus?.task.pid == target.pid,
               previousFocus.map({ CFEqual($0.task.window, target.window) }) == true {
                previousFocus?.ownedFeishuReturn = returnCandidate
                previousFocus?.ownedFeishuReturnDiagnostic?["action_accepted"] = true
                previousFocus?.ownedFeishuReturnDiagnostic?["accepted_navigation"] = "plain_search_modal_escape"
            }
            return ["method": "CGEvent", "key": name, "foreground_verified_before_action": true,
                "events_posted": 2, "focused_element_available": element != nil,
                "selection_verified": false, "window_closed_verified": false, "navigation_only": true]
        }
        try verify(target, focusedWindow: false)
        var selectionVerified = false
        if let expected = expectedSelection {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            repeat {
                try verify(target)
                if let element, let actual = axSelectedRange(element), actual.location == expected.location && actual.length == expected.length {
                    selectionVerified = true; break
                }
                Thread.sleep(forTimeInterval: 0.02)
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard selectionVerified else { throw fail("postcondition_failed", "Shortcut was posted but the expected text selection did not settle") }
        }
        return ["method": "CGEvent", "key": name, "foreground_verified": true,
            "events_posted": 2, "selection_verified": selectionVerified, "focused_element_available": element != nil]
    }

    func waitText(_ request: [String: Any], target: Target) throws -> [String: Any] {
        let expected = try text(request)
        let timeout = try integer(request, "timeout_ms", default: 1000, range: 0...5000)
        let element = try request["element_id"] != nil ? cached(request, target: target) : focused(target)
        let started = ProcessInfo.processInfo.systemUptime
        repeat {
            if let interruption = monitor.reason { throw fail("user_interrupted", "User input interrupted control (\(interruption))") }
            try verifyDisplayTopology(target)
            guard !target.application.isTerminated else { throw fail("app_not_running", "Target application terminated") }
            try denySecure(element)
            if let current = axString(element, kAXValueAttribute), current.contains(expected) {
                return ["matched": true, "waited_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                    "value": String(current.prefix(4000))]
            }
            if ProcessInfo.processInfo.systemUptime - started >= Double(timeout) / 1000 { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while true
        throw fail("wait_text_timeout", "Accessible value did not contain the requested text within \(timeout) ms")
    }

    func submitText(_ request: [String: Any], target: Target) throws -> [String: Any] {
        var events = 0
        do {
            let expected = try NativeSubmitExpected(request)
            guard target.bundleID == "com.bytedance.macos.feishu", target.expectedTitle == "飞书" else {
                throw fail("submit_target_unsupported", "submit_text requires the exact Feishu main window")
            }
            try requireEvents(); try verify(target)
            let composer = try cached(["element_id": expected.composerID], target: target)
            let recipient = try cached(["element_id": expected.recipientID], target: target)
            func chatAncestor(_ element: AXUIElement) throws -> AXUIElement {
                var node: AXUIElement? = element
                for _ in 0..<64 {
                    guard let item = node else { break }
                    if axString(item, kAXRoleAttribute) == "AXWebArea", axString(item, kAXTitleAttribute) == "messenger-chat" { return item }
                    node = axElement(item, kAXParentAttribute)
                }
                throw fail("submit_recipient_unverified", "Could not prove messenger-chat ancestry")
            }
            func belongsToWindow(_ element: AXUIElement) -> Bool {
                var node: AXUIElement? = element
                for _ in 0..<64 {
                    guard let item = node else { return false }
                    if CFEqual(item, target.window) { return true }
                    node = axElement(item, kAXParentAttribute)
                }
                return false
            }
            func observe() throws -> NativeSubmitObservation {
                let c = try cached(["element_id": expected.composerID], target: target)
                let r = try cached(["element_id": expected.recipientID], target: target)
                guard CFEqual(c, composer), CFEqual(r, recipient),
                      let windowBounds = axBounds(target.window), let composerBounds = axBounds(c), let recipientBounds = axBounds(r),
                      let value = axString(c, kAXValueAttribute) else { throw fail("stale_element", "Submit elements or their complete values are unavailable") }
                let cChat = try chatAncestor(c), rChat = try chatAncestor(r)
                guard let chatBounds = axBounds(cChat) else { throw fail("submit_recipient_unverified", "Chat geometry unavailable") }
                let label = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { axString(r, $0) }.first { !$0.isEmpty } ?? ""
                let focus = axElement(target.axApplication, kAXFocusedUIElementAttribute)
                return NativeSubmitObservation(bundle: target.bundleID, title: axString(target.window, kAXTitleAttribute) ?? "",
                    topology: try currentDisplays().signature, window: windowBounds, chat: chatBounds,
                    composer: composerBounds, recipient: recipientBounds,
                    composerRole: axString(c, kAXRoleAttribute) ?? "", recipientRole: axString(r, kAXRoleAttribute) ?? "",
                    recipientText: label, value: value,
                    sameChatAndWindow: CFEqual(cChat, rChat) && belongsToWindow(cChat) && belongsToWindow(rChat),
                    focused: focus.map { CFEqual($0, c) } ?? false, enabled: axBool(c, kAXEnabledAttribute) == true)
            }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
                throw fail("event_creation_failed", "Could not construct single Return pair")
            }
            down.flags = []; up.flags = []
            try performNativeSubmit(expected: expected, observe: observe, guardTarget: {
                try self.verify(target); try self.denySecure(target.window)
                try self.denySecure(composer); try self.denySecure(recipient)
            }, down: { try self.post(down, target: target) }, up: {
                up.setIntegerValueField(.eventSourceUserData, value: self.monitor.marker); up.post(tap: .cghidEventTap)
            }, events: &events)
            cache.removeValue(forKey: expected.composerID); cache.removeValue(forKey: expected.recipientID)
            try monitor.check()
            return ["method": "guarded_single_Return", "events_posted": events,
                    "submit_events_posted": true, "submit_preconditions_verified": true,
                    "send_verified": false, "action_accepted": true, "automatic_replay_allowed": false,
                    "post_submit_verification_required": true]
        } catch {
            if events > 0 { cache.removeAll(keepingCapacity: true) }
            let error = error as? HelperError ?? fail("submit_failed", error.localizedDescription)
            var details = error.details
            details["events_posted"] = events; details["submit_events_posted"] = events > 0
            details["input_may_be_partial"] = events > 0; details["send_verified"] = false
            details["automatic_replay_allowed"] = false
            throw fail(error.code, error.message, details)
        }
    }

    func validateAction(_ action: [String: Any]) throws {
        let command = try string(action, "command")!
        guard ["press", "click", "scroll", "set_text", "type_text", "clear_text", "submit_text", "key", "wait_text", "visual_read", "visual_click", "visual_type_text", "visual_key", "visual_scroll"].contains(command) else {
            throw fail("unsupported_batch_command", "Batch command is not supported: \(command)")
        }
        guard action["app"] == nil, action["window_title"] == nil else {
            throw fail("batch_target_override", "Batch actions must not override app or window_title")
        }
        if command.hasPrefix("visual_") { try visual.validate(action); return }
        if command == "submit_text" { _ = try NativeSubmitExpected(action) }
        if ["set_text", "type_text", "wait_text"].contains(command) { _ = try text(action) }
        if command == "type_text" {
            let value = try typedText(action)
            _ = try explicitExpectedValue(action, text: value)
            if try boolean(action, "replace_search") { _ = try FeishuSearchReplacement(action) }
        }
        if command == "wait_text" { _ = try integer(action, "timeout_ms", default: 1000, range: 0...5000) }
        if command == "set_text" { _ = try string(action, "element_id") }
        if command == "clear_text" {
            _ = try string(action, "element_id")
            _ = try clearExpectedValues(action)
        }
        if command == "scroll" { try validateScroll(action) }
        if command == "key" {
            let name = try string(action, "key")!.lowercased()
            guard keyCodes[name] != nil else { throw fail("unsupported_key", "Unsupported key: \(name)") }
            if let raw = action["modifiers"] {
                guard let modifiers = raw as? [String], modifiers.count <= 5,
                      modifiers.allSatisfy({ ["cmd", "command", "shift", "ctrl", "control", "alt", "option", "fn"].contains($0.lowercased()) }) else {
                    throw fail("invalid_request", "Invalid modifiers")
                }
            }
        }
        if ["press", "click"].contains(command) {
            guard action["element_id"] != nil || (action["x"] != nil && action["y"] != nil) else {
                throw fail("invalid_request", "Provide element_id or both x and y")
            }
            if action["x"] != nil || action["y"] != nil { _ = try number(action, "x"); _ = try number(action, "y") }
        }
        if action["element_id"] != nil { _ = try string(action, "element_id") }
    }

    func executeAction(_ request: [String: Any], target: Target) throws -> [String: Any] {
        visual.beginNativeCommand(taskID: currentRuntimeTaskID, operationID: runtimeOperationID,
                                  command: request["command"] as? String ?? "invalid")
        switch try string(request, "command")! {
        case "press": return try press(request, target: target, permitCenter: false)
        case "click": return try press(request, target: target, permitCenter: true)
        case "scroll": return try scroll(request, target: target)
        case "set_text": return try setText(request, target: target)
        case "type_text": return try typeText(request, target: target)
        case "clear_text": return try clearText(request, target: target)
        case "submit_text": return try submitText(request, target: target)
        case "key": return try key(request, target: target)
        case "wait_text": return try waitText(request, target: target)
        case "visual_read": return try visual.read(request, target: target, helper: self)
        case "visual_click", "visual_type_text", "visual_key", "visual_scroll": return try visual.action(request, target: target, helper: self)
        default: throw fail("unknown_command", "Unknown action command")
        }
    }

    func handle(_ original: [String: Any]) throws -> [String: Any] {
        let transport: (request: [String: Any], taskID: String, operationID: String?)
        do { transport = try nativeRuntimeRequest(original, legacyTaskID: legacyRuntimeTaskID) }
        catch {
            visual.beginNativeCommand(taskID: legacyRuntimeTaskID, operationID: nil, command: "invalid")
            throw error
        }
        let request = transport.request
        let previousRuntimeTaskID = runtimeTaskID
        let previousRuntimeOperationID = runtimeOperationID
        runtimeTaskID = transport.taskID
        runtimeOperationID = transport.operationID
        defer { runtimeTaskID = previousRuntimeTaskID; runtimeOperationID = previousRuntimeOperationID }
        visual.beginNativeCommand(taskID: currentRuntimeTaskID, operationID: runtimeOperationID,
                                  command: request["command"] as? String ?? "invalid")
        let command = try string(request, "command")!
        if command == "_finish_operation" {
            guard runtimeOperationID != nil else { throw fail("invalid_request", "Operation release requires runtime correlation") }
            visualWarmCaptureRelease()
            let released = visualCaptureDrain(timeout: 5)
            guard released else { throw fail("visual_capture_release_timeout", "Capture cleanup is still pending before operation handoff", ["completion_unknown": true]) }
            return ["capture_scope_released": true, "event_count": 0]
        }
        guard commands.contains(command) else { throw fail("unknown_command", "Unknown command: \(command)") }
        if command == "status" {
            let displays = try currentDisplays()
            let frontmost = foregroundMetadata()
            let frontmostPID = frontmost.pid
            let frontmostBundle = frontmostPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            return ["version": "0.1.72", "arch": "x86_64", "persistent_jsonl": true, "capture_lifecycle": visualCaptureLifecycleStatus(),
                "permissions": ["accessibility": AXIsProcessTrusted(), "post_event": CGPreflightPostEventAccess(),
                    "listen_event": CGPreflightListenEventAccess(), "screen_capture": CGPreflightScreenCaptureAccess()],
                "takeover_monitor_available": monitor.available,
                "frontmost_app_bundle_id": frontmostBundle ?? "",
                "frontmost_pid": frontmostPID ?? 0,
                "frontmost_source": frontmost.source,
                "interrupted": monitor.reason.map { $0 as Any } ?? NSNull(),
                "last_interruption_event": monitor.lastInterruption.map { $0 as Any } ?? NSNull(),
                "takeover_policy": ["pointer_min_duration_ms": 500, "pointer_idle_reset_ms": 250,
                    "keyboard_min_duration_ms": 600, "keyboard_idle_reset_ms": 600,
                    "isolated_click_scroll_key_yields": false, "event_tap": "listen_only"],
                "capabilities": commands.sorted(), "screenshots": true, "automatic_screenshots": false,
                "clipboard": true, "clipboard_policy": "temporary_feishu_paste_CAS_restore",
                "clipboard_commands_exposed": false, "clipboard_isolated": false, "visual": visual.status,
                "coordinate_system": quartzCoordinateSystem, "displays": displays.displays.map { $0.json },
                "display_topology_generation": displayTopologyGeneration,
                "requires_inspect_after_display_change": displayChangeNeedsInspect,
                "limits": ["max_depth": 40, "max_nodes": 2000, "max_actions": 32, "max_text_characters": 65536,
                    "max_value_characters": 4000, "max_wait_ms": 5000, "ax_timeout_ms": 800]]
        }
        if command == "ping" { return ["pong": true] }
        try requireAX()
        if command == "focus", try boolean(request,"restore_previous") {return try restorePreviousFocus(request)}
        if command == "inspect" { return try inspect(request) }
        if command == "background_observe" { return try observation.read(request, helper: self) }
        if command == "background_type_text" { return try backgroundTypeText(request) }
        if command == "background_chat_edit" { return try backgroundChatInput(request, bundle: try string(request, "app")!, atomic: true) }
        if command == "background_visual_read" {
            try visual.validate(request)
            let chosen = try target(request)
            let scope = try BackgroundCommandScope(target: chosen, control: nil, mode: .readOnly)
            backgroundScope = scope
            defer { scope.stop(); backgroundScope = nil }
            return try visual.read(request, target: chosen, helper: self, background: true)
        }
        if command == "visual_read" {
            try visual.validate(request)
            return try visual.read(request, target: target(request), helper: self)
        }
        if command == "select_text" {
            let background = try boolean(request, "background")
            let chosen = try target(request)
            if !background { try ensureForegroundClaim(chosen); try monitor.begin() }
            defer { if !background { monitor.end() } }
            return try selectText(request, target: chosen)
        }
        var actions: [[String: Any]] = []
        if command == "batch" {
            guard let raw = request["actions"] as? [[String: Any]], !raw.isEmpty, raw.count <= 32 else {
                throw fail("invalid_request", "actions must contain between 1 and 32 action objects")
            }
            for action in raw { try validateAction(action) }
            var hasLocalVisualProducer = false
            for (index, action) in raw.enumerated() {
                let name = action["command"] as? String ?? ""
                if name.hasPrefix("visual_"), name != "visual_read", action["snapshot_id"] as? String == "latest", !hasLocalVisualProducer {
                    throw fail("batch_snapshot_unavailable", "latest requires an earlier visual_read/action in this batch",
                        ["failed_index": index, "events_posted": 0, "completed_count": 0])
                }
                if name.hasPrefix("visual_") { hasLocalVisualProducer = true }
            }
            actions = raw
        } else if command != "focus" && command != "resume" {
            var action = request
            action.removeValue(forKey: "app"); action.removeValue(forKey: "window_title")
            try validateAction(action)
            if command.hasPrefix("visual_"), request["snapshot_id"] as? String == "latest" {
                throw fail("batch_snapshot_unavailable", "latest is scoped to snapshots produced inside one batch", ["events_posted": 0])
            }
        }
        let chosen = try target(request)
        let mutating = mutationCommands.contains(command)
        if mutating && command != "focus" && command != "resume" {
            let hasInput = command != "batch" || actions.contains { !["visual_read", "wait_text"].contains($0["command"] as? String ?? "") }
            if hasInput { try ensureForegroundClaim(chosen) }
            try monitor.begin()
        }
        defer { if mutating { monitor.end() } }
        if command == "focus" || command == "resume" { return try focus(chosen) }
        if command == "wait_text" { return try waitText(request, target: chosen) }
        let visualBatch = command == "batch" && actions.contains { ($0["command"] as? String)?.hasPrefix("visual_") == true }
        try verify(chosen, focusedWindow: !command.hasPrefix("visual_") && !visualBatch)
        if command == "batch" {
            var completed: [[String: Any]] = []
            var postedEvents = 0
            var visualChain: [String: String] = [:]
            var latestVisualSnapshotID: String?
            for (index, action) in actions.enumerated() {
                do {
                    let isVisual = (action["command"] as? String)?.hasPrefix("visual_") == true
                    try verify(chosen, focusedWindow: !isVisual)
                    var effective = action
                    if isVisual, let original = action["snapshot_id"] as? String {
                        if original == "latest" {
                            guard let latest = latestVisualSnapshotID else { throw fail("batch_snapshot_unavailable", "No snapshot was produced by this batch", ["events_posted": 0]) }
                            effective["snapshot_id"] = latest
                        } else if let latest = visualChain[original] { effective["snapshot_id"] = latest }
                    }
                    let result = try executeAction(effective, target: chosen)
                    postedEvents += max(0, result["events_posted"] as? Int ?? 0)
                    if isVisual, let next = result["snapshot_id"] as? String {
                        latestVisualSnapshotID = next
                        if let original = action["snapshot_id"] as? String, original != "latest" { visualChain[original] = next }
                    }
                    completed.append(["index": index, "command": action["command"]!, "result": result])
                } catch {
                    let underlying = error as? HelperError ?? fail("internal_error", error.localizedDescription)
                    var detail = underlying.details
                    detail["events_posted"] = postedEvents + max(0, underlying.details["events_posted"] as? Int ?? 0)
                    detail["failed_index"] = index
                    detail["completed_results"] = completed
                    detail["completed_count"] = completed.count
                    throw fail(underlying.code, underlying.message, detail)
                }
            }
            return ["app": chosen.bundleID, "target_pid": chosen.pid, "events_posted": postedEvents,
                    "completed_count": completed.count, "results": completed]
        }
        return try executeAction(request, target: chosen)
    }
}

func nativeSubmitSelfTests() -> [String: Any] {
    var tests: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { tests.append(["name": name, "passed": passed]) }
    func code(_ body: () throws -> Void) -> String { do { try body(); return "none" } catch { return (error as? HelperError)?.code ?? "other" } }
    let text = "授权中文消息", name = "示例联系人·离线测试"
    let suffix = "\u{200B}\n\u{200B}\n\u{200B}"
    let empty = "发送给 " + name + "\n" + suffix
    let request: [String: Any] = ["allow_submit": true, "element_id": "composer", "recipient_element_id": "header", "expected_recipient": name, "expected_value": text + suffix, "expected_empty_value": empty]
    func observation(_ change: String = "") -> NativeSubmitObservation {
        NativeSubmitObservation(bundle: change == "app" ? "other" : "com.bytedance.macos.feishu", title: change == "title" ? "other" : "飞书",
            topology: change == "topology" ? "other" : "topology", window: CGRect(x: 0, y: 0, width: 2000, height: 1200),
            chat: CGRect(x: 905, y: 118, width: 676, height: 738), composer: CGRect(x: 930, y: change == "geometry" ? 749 : 750, width: 600, height: 90),
            recipient: CGRect(x: change == "counter" ? 1500 : 965, y: change == "body" ? 300 : 143, width: 119, height: 19),
            composerRole: change == "composerRole" ? "AXButton" : "AXTextArea", recipientRole: change == "headerRole" ? "AXTextArea" : "AXStaticText",
            recipientText: change == "recipient" ? "他人" : name, value: change == "value" ? "其他草稿" : text + suffix,
            sameChatAndWindow: change != "ancestry", focused: change != "focus", enabled: change != "disabled")
    }
    do {
        let expected = try NativeSubmitExpected(request)
        for variant in ["missing", "false", "number"] {
            var changed = request
            if variant == "missing" { changed.removeValue(forKey: "allow_submit") }
            else { changed["allow_submit"] = variant == "false" ? false as Any : 1 as Any }
            check("authorization_" + variant + "_denied_before_events", code { _ = try NativeSubmitExpected(changed) } != "none")
        }
        for variant in ["same_ids", "same_empty", "known_empty", "voice_empty", "empty_invisibles"] {
            var changed = request
            if variant == "same_ids" { changed["recipient_element_id"] = "composer" }
            if variant == "same_empty" { changed["expected_empty_value"] = text + suffix }
            if variant == "known_empty" { changed["expected_value"] = empty; changed["expected_empty_value"] = "caller misleading empty" }
            if variant == "voice_empty" { changed["expected_value"] = "按住 \nfn \n说话\n" + empty; changed["expected_empty_value"] = "caller misleading empty" }
            if variant == "empty_invisibles" { changed["expected_value"] = suffix }
            check(variant + "_denied", code { _ = try NativeSubmitExpected(changed) } != "none")
        }
        for variant in ["app", "title", "counter", "body", "composerRole", "headerRole", "recipient", "value", "ancestry", "focus", "disabled"] {
            var count = 0, down = 0, up = 0
            let result = code { try performNativeSubmit(expected: expected, observe: { observation(variant) }, guardTarget: {}, down: { down += 1 }, up: { up += 1 }, events: &count) }
            check(variant + "_mismatch_zero_events", result != "none" && count == 0 && down == 0 && up == 0)
        }
        for variant in ["geometry", "topology", "recipient", "value", "focus"] {
            var count = 0, observations = 0, posted = 0
            let result = code { try performNativeSubmit(expected: expected, observe: { observations += 1; return observation(observations == 1 ? "" : variant) }, guardTarget: {}, down: { posted += 1 }, up: { posted += 1 }, events: &count) }
            check("between_reads_" + variant + "_zero_events", result != "none" && posted == 0 && count == 0)
        }
        for guardIndex in 1...3 {
            var count = 0, checks = 0, posted = 0
            let result = code { try performNativeSubmit(expected: expected, observe: { observation() }, guardTarget: {
                checks += 1; if checks == guardIndex { throw fail("user_interrupted", "synthetic takeover") }
            }, down: { posted += 1 }, up: { posted += 1 }, events: &count) }
            check("takeover_guard_\(guardIndex)_zero_events", result == "user_interrupted" && count == 0 && posted == 0)
        }
        var count = 0, down = 0, up = 0, observed = 0
        try performNativeSubmit(expected: expected, observe: { observed += 1; return observation() }, guardTarget: {}, down: { down += 1 }, up: { up += 1 }, events: &count)
        check("single_submit_exactly_one_pair_no_retry", down == 1 && up == 1 && count == 2 && observed == 2)
        count = 0; down = 0; up = 0
        let failed = code { try performNativeSubmit(expected: expected, observe: { observation() }, guardTarget: {}, down: { down += 1; throw fail("post_event_unavailable", "synthetic prepost failure") }, up: { up += 1 }, events: &count) }
        check("prepost_failure_never_retries_or_releases_unpressed_key", failed == "post_event_unavailable" && down == 1 && up == 0 && count == 0)
        check("exact_serialization_does_not_trim_zero_width_text", code { try validateNativeSubmit(observation("value"), expected: expected) } == "submit_value_mismatch")
    } catch { tests.append(["name": "unexpected_error", "passed": false, "error": String(describing: error)]) }
    return ["ok": tests.allSatisfy { $0["passed"] as? Bool == true }, "case_count": tests.count, "cases": tests, "capture_executed": false, "events_posted": 0, "live_submit_executed": false]
}

if CommandLine.arguments.contains("--feishu-search-hint-self-test") {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
    let query = "离线搜索Fixture"
    let canonical = query + feishuSearchStructure
    let hint = canonical + feishuSearchEnterHint
    check("actual_40_hint_fixture_query_exact", feishuSearchValue(hint)?.query == query)
    check("actual_40_hint_fixture_kind_exact", feishuSearchValue(hint)?.serialization == "query_ZW_LF_enter_hint")
    check("canonical_query_exact", feishuSearchValue(canonical)?.query == query)
    check("canonical_kind_exact", feishuSearchValue(canonical)?.serialization == "query_ZW_LF")
    check("after_canonical_preserved", feishuSearchVerifiedAfter(canonical, query: query)?.value == canonical)
    check("after_hint_complete_raw_preserved", feishuSearchVerifiedAfter(hint, query: query)?.value == hint)
    check("different_query_with_known_hint_denied", feishuSearchVerifiedAfter(hint, query: query + "错") == nil)
    check("query_prefix_not_enough", feishuSearchVerifiedAfter(hint, query: "本地插件") == nil)
    check("hint_words_in_query_not_stripped", feishuSearchValue("回车查看答案" + feishuSearchStructure)?.query == "回车查看答案")
    check("leading_and_trailing_query_spaces_preserved", feishuSearchValue("  查询  " + feishuSearchStructure + feishuSearchEnterHint)?.query == "  查询  ")
    for (name, value) in [
        ("unknown_hint", canonical + "\n回车发送答案"),
        ("incomplete_hint", canonical + "\n回车查看答"),
        ("hint_extra_line", hint + "\n"),
        ("hint_space", hint + " "),
        ("doubled_hint", hint + feishuSearchEnterHint),
        ("missing_separator", canonical + "回车查看答案"),
        ("different_separator", canonical + "\r回车查看答案"),
        ("multiline_query", "查\n询" + feishuSearchStructure + feishuSearchEnterHint),
        ("query_extra_ZW", "查\u{200B}询" + feishuSearchStructure + feishuSearchEnterHint),
        ("query_C0_start", "查\u{0001}询" + feishuSearchStructure),
        ("query_C0_end", "查\u{001F}询" + feishuSearchStructure),
        ("query_DEL", "查\u{007F}询" + feishuSearchStructure),
        ("query_line_separator", "查\u{2028}询" + feishuSearchStructure),
        ("query_paragraph_separator", "查\u{2029}询" + feishuSearchStructure),
        ("unknown_nested_serialization", canonical + "\n其他" + feishuSearchStructure)
    ] { check(name + "_denied", feishuSearchValue(value) == nil) }
    let request: [String: Any] = ["text": "下一个查询", "expected_before": hint,
        "expected_value": "下一个查询" + feishuSearchStructure, "element_id": "fixture"]
    check("request_accepts_exact_known_before_hint", (try? FeishuSearchReplacement(request))?.before == hint)
    check("request_after_remains_canonical", (try? FeishuSearchReplacement(request.merging(["expected_value": "下一个查询" + feishuSearchStructure + feishuSearchEnterHint]) { _, new in new })) == nil)
    check("stale_before_hint_change_denied_before_events", !feishuSearchReplacementTargetAllowed(bundle: "com.bytedance.macos.feishu",
        title: feishuSearchWindowTitle, role: "AXTextArea", focused: true, secure: false, actualBefore: hint, expectedBefore: canonical))
    let empty = try? FeishuSearchReplacement(request.merging(["expected_before": feishuSearchStructure]) { _, new in new })
    check("empty_query_requires_no_select_all", empty?.beforeQuery.isEmpty == true)
    let spaces = try? FeishuSearchReplacement(request.merging(["expected_before": "  " + feishuSearchStructure]) { _, new in new })
    check("spaces_are_not_an_empty_query", spaces?.beforeQuery == "  " && spaces?.beforeQuery.isEmpty == false)
    let result: [String: Any] = ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count,
        "cases": cases, "events_posted": 0, "live_AX_probe_executed": false, "capture_executed": false, "event_tap_created": false]
    print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--feishu-stability-self-test") {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
    let base: [String: Any] = ["text": "新的中文😀", "expected_before": "旧查询\u{200B}\n", "expected_value": "新的中文😀\u{200B}\n", "element_id": "fixture"]
    func accepts(_ delta: [String: Any]) -> Bool { (try? FeishuSearchReplacement(base.merging(delta) { _, new in new })) != nil }
    check("complete_singleline_query_accepted", accepts([:]))
    check("empty_old_query_is_safe", accepts(["expected_before": "\u{200B}\n"]))
    check("space_only_old_query_preserved_exactly", accepts(["expected_before": "  \u{200B}\n"]))
    check("space_only_new_query_rejected", !accepts(["text": "  ", "expected_value": "  \u{200B}\n"]))
    for (name, delta) in [
        ("empty_new_query", ["text": "", "expected_value": "\u{200B}\n"]),
        ("new_query_return", ["text": "a\nb", "expected_value": "a\nb\u{200B}\n"]),
        ("old_query_multiline", ["expected_before": "a\nb\u{200B}\n"]),
        ("old_query_extra_structure", ["expected_before": "a\u{200B}\n\u{200B}\n"]),
        ("old_query_extra_zero_width", ["expected_before": "a\u{200B}b\u{200B}\n"]),
        ("incomplete_before", ["expected_before": "旧查询"]),
        ("different_complete_after", ["expected_value": "其他\u{200B}\n"]),
        ("tab_query", ["text": "a\tb", "expected_value": "a\tb\u{200B}\n"])
    ] { check(name + "_rejected", !accepts(delta)) }
    func target(_ bundle: String = "com.bytedance.macos.feishu", _ title: String = feishuSearchWindowTitle,
                _ role: String = "AXTextArea", _ focused: Bool = true, _ secure: Bool = false,
                _ actual: String? = "完整\u{200B}\n") -> Bool {
        feishuSearchReplacementTargetAllowed(bundle: bundle, title: title, role: role, focused: focused,
            secure: secure, actualBefore: actual, expectedBefore: "完整\u{200B}\n")
    }
    check("exact_search_editor_allowed", target())
    check("other_app_denied", !target("com.tencent.xinWeChat"))
    check("main_composer_denied", !target("com.bytedance.macos.feishu", "飞书"))
    check("other_role_denied", !target("com.bytedance.macos.feishu", feishuSearchWindowTitle, "AXTextField"))
    check("focus_unknown_denied", !target("com.bytedance.macos.feishu", feishuSearchWindowTitle, "AXTextArea", false))
    check("secure_denied", !target("com.bytedance.macos.feishu", feishuSearchWindowTitle, "AXTextArea", true, true))
    check("full_before_not_normalized", !target("com.bytedance.macos.feishu", feishuSearchWindowTitle, "AXTextArea", true, false, " 完整\u{200B}\n"))
    check("unreadable_before_denied", !target("com.bytedance.macos.feishu", feishuSearchWindowTitle, "AXTextArea", true, false, nil))
    func returned(_ flags: [Bool]) -> Bool {
        ownedFeishuReturnAllowed(claimComplete: flags[0], interrupted: !flags[1], actionAccepted: flags[2],
            sameIdentity: flags[3], modalAbsent: flags[4], actualMainFocused: flags[5], topologyMatches: flags[6])
    }
    check("verified_owned_navigation_updates_without_new_claim", returned(Array(repeating: true, count: 7)))
    for (index, name) in ["claim", "no_takeover", "accepted_action", "same_window_identity", "closed_modal", "actual_main_focus", "same_topology"].enumerated() {
        var flags = Array(repeating: true, count: 7); flags[index] = false
        check("missing_" + name + "_denies_adoption", !returned(flags))
    }
    let mainFrame = CGRect(x: 100, y: 100, width: 1316, height: 750)
    let cgMain: [String: Any] = [kCGWindowNumber as String: 26296, kCGWindowOwnerPID as String: 92292,
        kCGWindowLayer as String: 0, kCGWindowIsOnscreen as String: true, kCGWindowAlpha as String: 1.0,
        kCGWindowBounds as String: mainFrame.dictionaryRepresentation, kCGWindowName as String: "飞书"]
    let cgModal = cgMain.merging([kCGWindowNumber as String: 34728, kCGWindowName as String: ""]) { _, new in new }
    func mainID(_ rows: [[String: Any]], _ title: String = "飞书") -> CGWindowID? {
        feishuReturnMainCGWindowID(pid: 92292, bounds: mainFrame, actualAXTitle: title, rows: rows)
    }
    check("actual_equal_frame_modal_main_resolved_by_exact_AX_title", mainID([cgModal, cgMain]) == 26296)
    check("CG_order_does_not_choose_main", mainID([cgMain, cgModal]) == 26296)
    check("duplicate_named_main_stays_ambiguous", mainID([cgMain, cgModal.merging([kCGWindowName as String: "飞书"]) { _, new in new }]) == nil)
    check("missing_named_main_is_not_replaced_with_modal", mainID([cgModal]) == nil)
    check("unexpected_actual_AX_title_denied", mainID([cgMain], "其他") == nil)
    for (name, key, value) in [
        ("foreign_PID", kCGWindowOwnerPID as String, 1), ("other_layer", kCGWindowLayer as String, 8),
        ("offscreen", kCGWindowIsOnscreen as String, false), ("transparent", kCGWindowAlpha as String, 0),
        ("different_frame", kCGWindowBounds as String, mainFrame.offsetBy(dx: 1, dy: 0).dictionaryRepresentation),
        ("null_window", kCGWindowNumber as String, 0)
    ] as [(String, String, Any)] {
        check("named_main_" + name + "_denied", mainID([cgMain.merging([key: value]) { _, new in new }]) == nil)
    }
    var missingTitle = cgMain; missingTitle.removeValue(forKey: kCGWindowName as String)
    check("unavailable_CG_name_denied", mainID([missingTitle, cgModal]) == nil)
    func escape(_ bundle: String = "com.bytedance.macos.feishu", _ title: String? = feishuSearchWindowTitle,
                _ key: String = "escape", _ flags: CGEventFlags = []) -> Bool {
        feishuSearchEscapeReturnEligible(bundle: bundle, title: title, key: key, flags: flags)
    }
    check("plain_known_Feishu_modal_escape_can_record_candidate", escape())
    check("escape_other_app_cannot_record_candidate", !escape("com.tencent.xinWeChat"))
    check("escape_main_window_cannot_record_candidate", !escape("com.bytedance.macos.feishu", "飞书"))
    check("escape_unknown_window_cannot_record_candidate", !escape("com.bytedance.macos.feishu", nil))
    check("other_key_cannot_record_candidate", !escape("com.bytedance.macos.feishu", feishuSearchWindowTitle, "return"))
    for flag: CGEventFlags in [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn] {
        check("modified_escape_\(flag.rawValue)_cannot_record_candidate", !escape("com.bytedance.macos.feishu", feishuSearchWindowTitle, "escape", flag))
    }
    // Real CoreGraphics event construction/copy/serialization, never post/tap.
    let own: Int64 = 123456789, foreign: Int64 = 987654321
    var constructed = 0
    var serializationDiagnostics: [[String: Any]] = []
    if let source = CGEventSource(stateID: .privateState) {
        check("source_default_user_data_zero", source.userData == 0)
        for key: CGKeyCode in [0, 51, 53] {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
                    check("event_creation", false); continue
                }
                constructed += 1
                event.setIntegerValueField(.eventSourceUserData, value: own)
                check("event_\(key)_\(down)_own_marker", event.getIntegerValueField(.eventSourceUserData) == own)
                check("event_\(key)_\(down)_copy_keeps_marker", event.copy()?.getIntegerValueField(.eventSourceUserData) == own)
                if let data = event.data, let decoded = CGEvent(withDataAllocator: nil, data: data) {
                    // This is a diagnostic, not the production posting route.
                    // Local CGEvent data round trips omit this field even with
                    // source.userData set; they cannot prove tap/post behaviour.
                    serializationDiagnostics.append(["keycode": key, "down": down,
                        "marker_preserved": decoded.getIntegerValueField(.eventSourceUserData) == own,
                        "decoded_user_data_zero": decoded.getIntegerValueField(.eventSourceUserData) == 0])
                } else { check("event_serialization", false) }
                check("event_\(key)_\(down)_foreign_helper_not_own", event.getIntegerValueField(.eventSourceUserData) != foreign)
            }
        }
        check("per_event_tag_does_not_mutate_source_user_data", source.userData == 0)
    } else { check("source_creation", false) }
    check("preclaim_known_old_event_ignored", !inputEventAfterClaim(99, baseline: 100))
    check("new_and_unknown_timestamp_still_interrupt", inputEventAfterClaim(101, baseline: 100) && inputEventAfterClaim(0, baseline: 100))
    let result: [String: Any] = ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count,
        "cases": cases, "events_constructed_not_posted": constructed, "events_posted": 0,
        "serialization_diagnostics_not_production_posting": serializationDiagnostics,
        "live_AX_probe_executed": false, "capture_executed": false, "event_tap_created": false]
    print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--native-interaction-self-test") {
    let result = nativeInteractionSelfTests()
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--sustained-input-self-test") {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]) }
    func ns(_ seconds: Double) -> UInt64 { UInt64((seconds * 1e9).rounded()) }
    var activity = SustainedInputActivity()
    func sample(_ type: CGEventType, _ seconds: Double, x: Double = 0,
                delay: Double = 0, own: Bool = false) -> String? {
        activity.observe(type: type, timestamp: ns(seconds), observed: ns(seconds + delay),
                         location: CGPoint(x: x, y: 0), own: own)
    }
    activity.reset(at: ns(10))
    let burst = [10.0, 10.02, 10.04, 10.0609].enumerated().map { sample(.mouseMoved, $0.element, x: Double($0.offset) * 20) }
    check("consumer_60ms_four_samples_is_not_takeover", burst.allSatisfy { $0 == nil })
    for type: CGEventType in [.leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged] {
        activity.reset(at: ns(10)); check("isolated_\(type.rawValue)_not_takeover", sample(type, 10) == nil)
    }
    activity.reset(at: ns(10)); var result: String?
    for index in 0...5 { result = sample(.mouseMoved, 10 + Double(index) * 0.1, x: Double(index) * 10) }
    check("continuous_half_second_motion_yields", result == "sustained_mouse_movement")
    activity.reset(at: ns(10)); result = nil
    for index in 0...5 { result = sample(.leftMouseDragged, 10 + Double(index) * 0.1, x: Double(index) * 10) }
    check("continuous_drag_yields_without_button_down_shortcut", result == "sustained_mouse_movement")
    activity.reset(at: ns(10)); var keyboard: [String?] = []
    for time in [10.0, 10.3, 10.61] {
        keyboard.append(sample(.keyDown, time)); _ = sample(.keyUp, time + 0.01)
    }
    check("continuous_keyboard_and_repeat_yield_after_duration", keyboard[0] == nil && keyboard[1] == nil && keyboard[2] == "sustained_keyboard_input")
    activity.reset(at: ns(10)); var idleKeys = true
    for time in [10.0, 10.7, 11.4, 12.1] { idleKeys = idleKeys && sample(.keyDown, time) == nil }
    check("isolated_keys_reset_on_idle", idleKeys)
    activity.reset(at: ns(10)); result = nil
    for (time, x) in [(10.0,0.0),(10.1,20.0),(10.5,40.0),(10.6,60.0)] { result = sample(.mouseMoved,time,x:x) }
    check("pointer_idle_breaks_continuity", result == nil)
    activity.reset(at: ns(10)); result = nil
    for index in 0...8 { result = sample(.mouseMoved,10 + Double(index)*0.1,x:0) }
    check("stationary_samples_not_takeover", result == nil)
    activity.reset(at: ns(10))
    check("pre_arm_event_ignored", sample(.keyDown,9) == nil)
    check("own_marked_events_ignored", sample(.keyDown,10,own:true) == nil && sample(.keyDown,10.3,own:true) == nil && sample(.keyDown,10.7) == nil)
    activity.reset(at: ns(10)); _ = sample(.keyDown,10); _ = sample(.keyDown,10.3)
    check("stale_queued_key_cannot_complete_takeover", sample(.keyDown,10.61,delay:0.3) == nil)
    activity.reset(at: ns(10)); _ = sample(.keyDown,10); _ = sample(.keyDown,10.3)
    check("reordered_event_resets_sequence", sample(.keyDown,10.1,delay:0.21) == nil && sample(.keyDown,10.61) == nil)
    activity.reset(at: ns(10))
    check("unknown_timestamp_cannot_establish_duration", sample(.keyDown,0,delay:10) == nil)
    activity.reset(at: ns(10)); _ = sample(.keyDown,10); _ = sample(.keyDown,10.3); activity.reset(at:ns(10.5))
    check("new_claim_discards_prior_activity", sample(.keyDown,10.61) == nil)
    check("isolated_key_invalidates_focus_without_latching_takeover", inputInvalidatesRetainedFocus(.keyDown, timestamp:101, baseline:100, own:false) && sample(.keyDown,10.62) == nil)
    check("own_events_preserve_retained_focus", !inputInvalidatesRetainedFocus(.leftMouseDown, timestamp:101, baseline:100, own:true))
    check("preclaim_events_preserve_new_focus", !inputInvalidatesRetainedFocus(.scrollWheel, timestamp:99, baseline:100, own:false))
    check("pure_pointer_motion_preserves_editor_focus", !inputInvalidatesRetainedFocus(.mouseMoved, timestamp:101, baseline:100, own:false))
    func policy(_ event: ScopedInputEvent, _ mode: ScopedInputMode) -> ScopedInputDecision {
        ScopedInputPolicy.decide(mode:mode,event:event,target:nil,context:nil)
    }
    check("shared_scroll_does_not_latch_takeover", policy(ScopedInputEvent(kind:.scroll,observedAt:10),.sharedHID) == .allow)
    check("shared_isolated_escape_not_takeover", policy(ScopedInputEvent(kind:.keyDown,observedAt:10,keyCode:53),.sharedHID) == .allow)
    check("shared_sustained_keyboard_yields", policy(ScopedInputEvent(kind:.keyDown,observedAt:10,sustainedKeyboard:true),.sharedHID) == .interrupt("sustained_keyboard_input"))
    check("readonly_sustained_input_remains_independent", policy(ScopedInputEvent(kind:.keyDown,observedAt:10,sustainedKeyboard:true),.readOnly) == .allow)
    check("background_unknown_target_still_refused", policy(ScopedInputEvent(kind:.keyDown,observedAt:10),.targetedBackground) == .interrupt("input_target_unknown"))
    check("monitor_loss_still_stops_input", policy(ScopedInputEvent(kind:.monitorDisabled,observedAt:10),.sharedHID) == .interrupt("input_monitor_disabled"))
    let resultJSON: [String: Any] = ["ok":cases.allSatisfy { $0["passed"] as? Bool == true },"case_count":cases.count,"cases":cases,"events_posted":0,"event_tap_created":false]
    print(String(data:try! JSONSerialization.data(withJSONObject:resultJSON,options:[.sortedKeys]),encoding:.utf8)!)
    exit(resultJSON["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--input-clock-diagnostic-self-test") {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
    let event = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                        mouseCursorPosition: CGPoint(x: 735, y: 298), mouseButton: .right)!
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    event.setIntegerValueField(.eventTargetUnixProcessID, value: 60682)
    event.setIntegerValueField(.eventSourceUserData, value: 0)
    var receipts: [[String: Any]] = []
    for (name, timestamp, baseline, expected): (String, UInt64, UInt64?, Bool) in [
        ("known_preclaim", 99, 100, false), ("exact_baseline", 100, 100, true),
        ("known_postclaim", 101, 100, true), ("unknown_event_timestamp", 0, 100, true),
        ("unknown_claim_baseline", 101, nil, true)
    ] {
        event.timestamp = timestamp
        let rawBefore = inputClaimTimestamp()
        let receipt = inputInterruptionEvent(.rightMouseDown, event, marker: 123,
            mode: .sharedHID, reason: "manual_6", cached: nil, claimTimestamp: baseline)
        let rawAfter = inputClaimTimestamp()
        check(name + "_event_ns_exact", receipt["event_timestamp_ns"] as? UInt64 == timestamp)
        if let baseline { check(name + "_baseline_ns_exact", receipt["claim_event_timestamp_ns"] as? UInt64 == baseline) }
        else { check(name + "_baseline_null", receipt["claim_event_timestamp_ns"] is NSNull) }
        check(name + "_uses_existing_policy", receipt["event_after_claim"] as? Bool == expected && expected == inputEventAfterClaim(timestamp, baseline: baseline))
        let raw = receipt["observed_raw_uptime_ns"] as? UInt64 ?? 0
        check(name + "_real_raw_clock_bracketed", rawBefore > 0 && rawBefore <= raw && raw <= rawAfter)
        check(name + "_unknown_source_stays_untrusted", receipt["source_user_data_matches_own"] as? Bool == false && receipt["source_unix_process_id"] as? Int64 == 0)
        receipts.append(receipt)
    }
    let encoded = try! JSONSerialization.data(withJSONObject: receipts, options: [.sortedKeys])
    let decoded = try! JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
    check("JSON_preserves_integer_event_and_null_baseline", (decoded[0]["event_timestamp_ns"] as? NSNumber)?.uint64Value == 99 && decoded[4]["claim_event_timestamp_ns"] is NSNull)
    let constructed = CGEvent(source: nil)?.timestamp
    let result: [String: Any] = ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count,
        "cases": cases, "receipts": receipts, "events_posted": 0, "event_tap_created": false,
        "live_AX_probe_executed": false, "capture_executed": false,
        "constructed_CG_event_timestamp_ns": constructed.map { $0 as Any } ?? NSNull(),
        "constructed_timestamp_is_live_input_clock_proof": false,
        "claim_clock": "CLOCK_UPTIME_RAW", "policy_changed": false]
    print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--focus-claim-self-test") {
    var cases:[[String:Any]]=[]
    func check(_ name:String,_ value:Bool){cases.append(["name":name,"passed":value])}
    let rawBefore=inputClaimTimestamp()
    var timebase=mach_timebase_info_data_t()
    let timebaseResult=mach_timebase_info(&timebase)
    let absolute=mach_absolute_time()
    let denominator=UInt64(max(1,timebase.denom)),numerator=UInt64(timebase.numer)
    let machNanoseconds=(absolute/denominator)*numerator+(absolute%denominator)*numerator/denominator
    let rawAfter=inputClaimTimestamp()
    check("real_uptime_nanoseconds_nonzero",rawBefore>0 && rawAfter>0)
    check("real_uptime_nanoseconds_monotonic",rawAfter>=rawBefore)
    check("real_uptime_clock_brackets_mach_absolute_nanoseconds",timebaseResult==KERN_SUCCESS && timebase.denom>0 && timebase.numer>0 && rawBefore<=machNanoseconds && machNanoseconds<=rawAfter)
    check("queued_preclaim_event_not_a_new_takeover",!inputEventAfterClaim(99,baseline:100))
    check("exact_baseline_event_is_conservatively_new",inputEventAfterClaim(100,baseline:100))
    check("postclaim_key_or_pointer_still_interrupts",inputEventAfterClaim(101,baseline:100))
    check("unknown_event_timestamp_never_ignored",inputEventAfterClaim(0,baseline:100))
    check("ordinary_command_without_claim_keeps_old_rule",inputEventAfterClaim(1,baseline:nil))
    check("missing_origin_skips",focusRestoreSuppression(hasRecord:false,claimComplete:true,interrupted:false,taskStillFocused:true,originExists:true,topologyMatches:true)=="no_previous_focus")
    check("failed_initial_focus_never_restores",focusRestoreSuppression(hasRecord:true,claimComplete:false,interrupted:false,taskStillFocused:true,originExists:true,topologyMatches:true)=="focus_claim_unconfirmed")
    check("same_app_user_typing_still_suppresses_restore",focusRestoreSuppression(hasRecord:true,claimComplete:true,interrupted:true,taskStillFocused:true,originExists:true,topologyMatches:true)=="user_takeover")
    check("user_changed_focus_never_pulled_back",focusRestoreSuppression(hasRecord:true,claimComplete:true,interrupted:false,taskStillFocused:false,originExists:true,topologyMatches:true)=="task_focus_changed")
    check("closed_origin_window_not_replaced_by_other_window",focusRestoreSuppression(hasRecord:true,claimComplete:true,interrupted:false,taskStillFocused:true,originExists:false,topologyMatches:true)=="previous_window_unavailable")
    check("hotplug_does_not_restore_stale_geometry",focusRestoreSuppression(hasRecord:true,claimComplete:true,interrupted:false,taskStillFocused:true,originExists:true,topologyMatches:false)=="display_topology_changed")
    check("verified_uninterrupted_claim_can_restore",focusRestoreSuppression(hasRecord:true,claimComplete:true,interrupted:false,taskStillFocused:true,originExists:true,topologyMatches:true)==nil)
    check("activation_request_does_not_authorize_early_raise",!focusRestoreShouldRaise(originFrontmost:false,originalWindowFocused:false,raiseAttempted:false))
    check("already_focused_original_window_needs_no_raise",!focusRestoreShouldRaise(originFrontmost:true,originalWindowFocused:true,raiseAttempted:false))
    check("active_origin_can_raise_only_recorded_window_once",focusRestoreShouldRaise(originFrontmost:true,originalWindowFocused:false,raiseAttempted:false))
    check("unknown_AXRaise_result_never_replayed",!focusRestoreShouldRaise(originFrontmost:true,originalWindowFocused:false,raiseAttempted:true))
    check("app_only_origin_requires_matching_PID_and_bundle",focusOriginAppMatches(pid:42,bundle:"test.origin",actualPID:42,actualBundle:"test.origin"))
    check("app_only_origin_rejects_changed_PID",!focusOriginAppMatches(pid:42,bundle:"test.origin",actualPID:43,actualBundle:"test.origin"))
    check("app_only_origin_rejects_changed_bundle",!focusOriginAppMatches(pid:42,bundle:"test.origin",actualPID:42,actualBundle:"test.other"))
    check("app_only_origin_rejects_unknown_focus",!focusOriginAppMatches(pid:42,bundle:"test.origin",actualPID:nil,actualBundle:nil))
    check("app_only_origin_rejects_missing_bundle",!focusOriginAppMatches(pid:42,bundle:"",actualPID:42,actualBundle:""))
    check("generic_TextEdit_origin_uses_same_exact_identity_rule",focusOriginAppMatches(pid:42,bundle:"com.apple.TextEdit",actualPID:42,actualBundle:"com.apple.TextEdit"))
    check("same_Chrome_bundle_other_process_never_substitutes_recorded_origin",!focusOriginAppMatches(pid:42,bundle:"com.google.chrome.for.testing",actualPID:43,actualBundle:"com.google.chrome.for.testing"))
    check("same_runtime_task_can_use_its_record",focusRecordTaskMatches("task-A","task-A"))
    check("same_app_or_window_never_overrides_different_runtime_task",!focusRecordTaskMatches("task-A","task-B"))
    let transport = try? nativeRuntimeRequest(["command":"visual_read","app":"test","_runtime_task_id":"task-A"],legacyTaskID:"legacy-session")
    check("runtime_metadata_stripped_before_visual_and_command_validation",transport?.taskID == "task-A" && transport?.request["_runtime_task_id"] == nil && transport?.request["command"] as? String == "visual_read" && transport?.request["app"] as? String == "test")
    let operationTransport = try? nativeRuntimeRequest(["command":"visual_key","_runtime_task_id":"task-A","_runtime_operation_id":"operation-A"], legacyTaskID:"legacy")
    check("runtime_operation_id_is_bound_and_stripped", operationTransport?.operationID == "operation-A" && operationTransport?.request["_runtime_operation_id"] == nil)
    check("legacy_transport_has_no_operation_proof_scope", transport?.operationID == nil)
    for invalidOperation: Any in ["", String(repeating:"a", count:129), "invalid\noperation", 42, true] {
        check("invalid_runtime_operation_id_rejected", (try? nativeRuntimeRequest(["_runtime_operation_id":invalidOperation], legacyTaskID:"legacy")) == nil)
    }
    let legacyFirst = try? nativeRuntimeRequest(["command":"focus"],legacyTaskID:"legacy-session")
    let legacyNext = try? nativeRuntimeRequest(["command":"focus","restore_previous":true],legacyTaskID:"legacy-session")
    check("missing_metadata_keeps_one_legacy_session_identity",legacyFirst?.taskID == "legacy-session" && legacyNext?.taskID == legacyFirst?.taskID)
    check("runtime_id_is_not_trimmed_or_case_folded",(try? nativeRuntimeRequest(["_runtime_task_id":" Task-A "],legacyTaskID:"legacy").taskID) == " Task-A ")
    check("runtime_id_128_ascii_boundary",(try? nativeRuntimeRequest(["_runtime_task_id":String(repeating:"a",count:128)],legacyTaskID:"legacy")) != nil)
    for invalid: Any in ["", String(repeating:"a",count:129), "task\nA", "任务A", 1, NSNull()] {
        check("invalid_runtime_id_rejected_\(cases.count)",(try? nativeRuntimeRequest(["_runtime_task_id":invalid],legacyTaskID:"legacy")) == nil)
    }
    check("live_recorded_window_keeps_exact_restore",focusRestoreKeepsWindow(hasRecordedWindow:true,identityVerified:true))
    check("invalidated_AX_wrapper_degrades_without_replacement",!focusRestoreKeepsWindow(hasRecordedWindow:true,identityVerified:false))
    check("app_only_origin_never_invents_a_window",!focusRestoreKeepsWindow(hasRecordedWindow:false,identityVerified:true))
    func scope(_ task: String = "task-A", _ operation: String? = "operation-A", _ pid: pid_t = 42,
               _ revision: UInt64 = 7, _ now: Double = 10) -> Bool {
        feishuOwnedScopeMatches(task: "task-A", operation: "operation-A", pid: 42, revision: 7, until: 15,
            currentTask: task, currentOperation: operation, currentPID: pid, currentRevision: revision, now: now)
    }
    check("owned_Feishu_transition_same_operation_scope", scope())
    check("owned_Feishu_transition_other_task_denied", !scope("task-B"))
    check("owned_Feishu_transition_other_operation_denied", !scope("task-A", "operation-B"))
    check("owned_Feishu_transition_missing_operation_denied", !scope("task-A", nil))
    check("owned_Feishu_transition_changed_PID_denied", !scope("task-A", "operation-A", 43))
    check("owned_Feishu_transition_any_external_activity_revision_denied", !scope("task-A", "operation-A", 42, 8))
    check("owned_Feishu_transition_expired_denied", !scope("task-A", "operation-A", 42, 7, 16))
    check("owned_Feishu_transition_nonfinite_clock_denied", !scope("task-A", "operation-A", 42, 7, .nan))
    check("owned_Feishu_transition_negative_clock_denied", !scope("task-A", "operation-A", 42, 7, -1))
    check("known_search_AXMenuItem_allowed", feishuSearchOpenControlAllowed(role:"AXMenuItem",title:"搜索",description:nil))
    for label in ["搜索", "搜索(⌘ K)", "搜索（⌘K）", "搜索（⌘＋K）"] {
        check("known_search_AXButton_allowed", feishuSearchOpenControlAllowed(role:"AXButton",title:nil,description:label))
    }
    for label in ["搜索消息", "搜索(其他)", "搜索网络", "搜索（⌘K）其他", "搜索(⌘+K)", "搜索（⌘＋J）", "搜索（⌘＋K）其他"] {
        check("other_search_label_not_transition_evidence", !feishuSearchOpenControlAllowed(role:"AXButton",title:nil,description:label))
    }
    check("text_with_search_name_not_transition_evidence", !feishuSearchOpenControlAllowed(role:"AXStaticText",title:"搜索",description:nil))
    func disposition(_ flags:[Bool]) -> String {
        implicitFocusClaimDisposition(sameTask:flags[0],sameOperation:flags[1],complete:flags[2],monitorAvailable:flags[3],
            interrupted:!flags[4],sameProcess:flags[5],stillFocused:flags[6])
    }
    check("continuous_exact_claim_avoids_new_focus", disposition(Array(repeating:true,count:7)) == "reuse")
    for (index, label) in [(2,"incomplete_claim"),(3,"monitor_unavailable"),(4,"real_user_interruption"),(5,"different_process"),(6,"unowned_window_transition")] {
        var flags=Array(repeating:true,count:7);flags[index]=false
        check("same_operation_"+label+"_stops_without_origin_replacement",disposition(flags)=="stop")
    }
    check("no_saved_claim_can_start_a_new_authorized_stage", disposition([false,false,false,true,true,true,true]) == "new_claim")
    // Pure producer/consumer regression for the reported path. Window IDs are
    // fake identities; no helper, AX read, notice, focus or event is created.
    let foreignOriginPID=900,feishuPID=42
    var originalPID=foreignOriginPID,claimedWindow="existing-modal",actualWindow="main",implicitRefocuses=0
    var allOwnedTransitions=true
    for nextWindow in ["main","new-search-modal","main"] {
        actualWindow=nextWindow
        let owned=scope() && ownedFeishuReturnAllowed(claimComplete:true,interrupted:false,actionAccepted:true,
            sameIdentity:true,modalAbsent:nextWindow=="main",actualMainFocused:nextWindow=="main",topologyMatches:true)
        // Forward opening has the same operation/revision binding and the
        // separate exact unique modal + current main identity checks above.
        let opened=nextWindow=="new-search-modal" && scope() &&
            feishuSearchOpenControlAllowed(role:"AXButton",title:"搜索",description:nil)
        if owned || opened { claimedWindow=actualWindow } else { allOwnedTransitions=false }
        let decision=disposition([true,true,true,true,true,true,claimedWindow==actualWindow])
        if decision=="new_claim" {implicitRefocuses+=1;originalPID=feishuPID}
        allOwnedTransitions = allOwnedTransitions && decision=="reuse"
    }
    check("existing_modal_escape_reopen_type_cleanup_keeps_first_foreign_origin",allOwnedTransitions && originalPID==foreignOriginPID && implicitRefocuses==0)
    check("missing_navigation_evidence_stops_instead_of_capturing_Feishu_origin",disposition([true,true,true,true,true,true,false])=="stop")
    check("AXMain_diagnostic_classifies_saved_main",feishuAXMainWindowKind(available:true,matchesSavedMain:true,matchesUniqueSearchModal:false)=="saved_main")
    check("AXMain_diagnostic_classifies_exact_unique_search_modal",feishuAXMainWindowKind(available:true,matchesSavedMain:false,matchesUniqueSearchModal:true)=="known_search_modal")
    check("AXMain_diagnostic_does_not_call_other_window_a_modal",feishuAXMainWindowKind(available:true,matchesSavedMain:false,matchesUniqueSearchModal:false)=="other")
    check("AXMain_diagnostic_missing_attribute_remains_unknown",feishuAXMainWindowKind(available:false,matchesSavedMain:false,matchesUniqueSearchModal:false)=="missing")
    check("AXMain_diagnostic_missing_attribute_rejects_stale_matches",feishuAXMainWindowKind(available:false,matchesSavedMain:true,matchesUniqueSearchModal:true)=="missing")
    check("all_windows_empty_transition_omits_menus_without_selecting_target",inspectionMenuWindowIndex(windowCount:0,focusedIndex:nil)==nil)
    check("all_windows_empty_transition_rejects_stale_focus_index",inspectionMenuWindowIndex(windowCount:0,focusedIndex:0)==nil)
    check("all_windows_ambiguous_unfocused_omits_menus",inspectionMenuWindowIndex(windowCount:2,focusedIndex:nil)==nil)
    check("all_windows_actual_focused_root_binds_menu",inspectionMenuWindowIndex(windowCount:2,focusedIndex:1)==1)
    check("all_windows_unique_root_binds_menu",inspectionMenuWindowIndex(windowCount:1,focusedIndex:nil)==0)
    check("all_windows_stale_focus_does_not_choose_first_root",inspectionMenuWindowIndex(windowCount:2,focusedIndex:2)==nil)
    check("all_windows_negative_focus_does_not_choose_first_root",inspectionMenuWindowIndex(windowCount:2,focusedIndex:-1)==nil)
    let result:[String:Any]=["ok":cases.allSatisfy{$0["passed"] as? Bool==true},"case_count":cases.count,"cases":cases,"events_posted":0,"capture_executed":false,"live_AX_probe_executed":false,
        "clock_proof":["clock":"CLOCK_UPTIME_RAW","before_ns":rawBefore,"mach_absolute_ns":machNanoseconds,"after_ns":rawAfter,"timebase_numer":timebase.numer,"timebase_denom":timebase.denom]]
    let data=try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]);print(String(data:data,encoding:.utf8)!)
    exit(result["ok"] as? Bool == true ? 0:1)
}

if CommandLine.arguments.contains("--text-selection-self-test") {
    let result = nativeTextSelectionSelfTests()
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--visual-1x-search-ocr-self-test") {
    let args = CommandLine.arguments
    let result = visualOneXSearchOCRSelfTests(args.firstIndex(of: "--fixture").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil })
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--visual-warm-capture-self-test") {
    let result = visualWarmCaptureSelfTests()
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    exit((result["ok"] as? Bool == true) ? 0 : 1)
}

if CommandLine.arguments.contains("--observation-self-test") {
    let result = nativeObservationSelfTests()
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--visual-search-transition-self-test") {
    let result = visualSearchTransitionSelfTests()
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--visual-prefix-delete-self-test") {
    let result=visualPrefixDeletionSelfTests()
    let data=try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
    print(String(data:data,encoding:.utf8)!)
    exit(result["ok"] as? Bool == true ? 0:1)
}

if CommandLine.arguments.contains("--visual-34-self-test") {
    let args=CommandLine.arguments
    let result=visual34SelfTests(args.firstIndex(of:"--fixture").flatMap { $0+1<args.count ? args[$0+1]:nil })
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--pointer-ownership-self-test") {
    let result = scopedPointerOwnershipSelfTests()
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--atomic-chat-edit-self-test") {
    let result = atomicBackgroundChatEditSelfTests()
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--background-input-self-test") {
    let result = backgroundInputSelfTests()
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--geometry-self-test") {
    let result = geometrySelfTests()
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--visual-self-test") {
    let result = visualSelfTests()
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--visual-multidisplay-self-test") {
    let result = visualMultiDisplaySelfTests()
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--submit-self-test") {
    let result = nativeSubmitSelfTests()
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--visual-search-text-self-test") {
    let args = CommandLine.arguments
    let fixture = args.firstIndex(of: "--fixture").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let result = visualSearchTextSelfTests(fixture)
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--visual-window-snapshot-self-test") {
    let result = visualWindowSnapshotSelfTests()
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

if CommandLine.arguments.contains("--visual-visibility-self-test") {
    let args = CommandLine.arguments
    let fixture = args.firstIndex(of: "--fixture").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let result = visualVisibilitySelfTests(fixture)
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

let helper = DesktopHelper()
let ownPID = ProcessInfo.processInfo.processIdentifier
let serviceInput = NativeServiceInput()
serviceInput.onShutdown = { helper.monitor.stop() }
while !serviceInput.shutdownRequested, let line = serviceInput.nextLine() {
    let start = ProcessInfo.processInfo.systemUptime
    var response: [String: Any] = ["id": NSNull(), "pid": ownPID]
    do {
        guard line.utf8.count <= 1024 * 1024 else { throw fail("request_too_large", "A JSONL request must be at most 1 MiB") }
        guard let data = line.data(using: .utf8),
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw fail("invalid_json", "Each input line must be one JSON object")
        }
        response["id"] = request["id"] ?? NSNull()
        response["result"] = try helper.handle(request)
        response["ok"] = true
    } catch {
        let error = error as? HelperError ?? fail("invalid_json", error.localizedDescription)
        var payload: [String: Any] = ["code": error.code, "message": error.message]
        var details = error.details
        if error.code == "user_interrupted", let event = helper.monitor.lastInterruption { details["last_interruption_event"] = event }
        if !details.isEmpty { payload["details"] = details }
        response["ok"] = false
        response["error"] = payload
    }
    response["elapsed_ms"] = Double(Int((ProcessInfo.processInfo.systemUptime - start) * 100000)) / 100
    do {
        let encoded = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .fragmentsAllowed])
        try FileHandle.standardOutput.write(contentsOf: encoded)
        try FileHandle.standardOutput.write(contentsOf: Data([10]))
    } catch {
        FileHandle.standardError.write(Data("Response output unavailable; draining capture cleanup\n".utf8))
        break
    }
}
helper.visual.stop()
visualWarmCaptureRelease()
// Pending starts own their cleanup until start and stop completion are known.
// Never exit merely because a drain interval expired.
while !visualCaptureDrain(timeout: 5, shuttingDown: true) {
    _ = CFRunLoopRunInMode(.defaultMode, 0.005, true)
}
helper.monitor.stop()
