import Foundation
import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import ScreenCaptureKit
import Darwin

let observationValueLimit = 65536
let observationTotalValueLimit = 524288
let observationImageByteLimit = 4 * 1024 * 1024

func observationFocusMaySettle(bundle: String, result: AXError, hasValue: Bool) -> Bool {
    bundle == "com.tencent.xinWeChat" && !hasValue && [AXError.success, .noValue, .cannotComplete].contains(result)
}

func observationString(_ value: String, remaining: Int) -> (text: String, complete: Bool) {
    let cap = min(observationValueLimit, max(0, remaining))
    let text = String(value.prefix(cap))
    return (text, text.count == value.count)
}

func observationDigest(_ rows: [[String: Any]]) throws -> [String: String] {
    var result: [String: String] = [:]
    for row in rows {
        guard let id = row["element_id"] as? String else { continue }
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        result[id] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return result
}

func observationDiff(before: [String: String], after: [String: String]) -> [String: Any] {
    ["added_ids": after.keys.filter { before[$0] == nil }.sorted(),
     "changed_ids": after.keys.filter { before[$0] != nil && before[$0] != after[$0] }.sorted(),
     "removed_ids": before.keys.filter { after[$0] == nil }.sorted()]
}

// Metadata only. Never reads the other application's element value or title.
func observationSystemFocus() -> [String: Any] {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.12)
    guard let app = axElement(system, kAXFocusedApplicationAttribute) else { return ["available": false, "source": "public_system_AX"] }
    AXUIElementSetMessagingTimeout(app, 0.12)
    var pid: pid_t = 0
    guard AXUIElementGetPid(app, &pid) == .success, pid > 0 else { return ["available": false, "source": "public_system_AX"] }
    var result: [String: Any] = ["available": true, "pid": pid, "source": "public_system_AX"]
    result["bundle_id"] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map { $0 as Any } ?? NSNull()
    if let window = axElement(app, kAXFocusedWindowAttribute), let frame = axBounds(window) {
        result["window_frame"] = rectJSON(frame)
        result["window_id"] = (try? scopedWindowID(pid: pid, frame: frame)).map { $0 as Any } ?? NSNull()
        if let displays = try? activeDisplays() { result["display_ids"] = displays.associations(for: frame)["display_ids"] }
    } else { result["window_frame"] = NSNull() }
    return result
}

func observationPNG(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw fail("observation_image_failed", "Could not create in-memory PNG encoder")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw fail("observation_image_failed", "PNG encoding failed") }
    return data as Data
}

// Only the model-facing image is resampled. OCR and action evidence retain frame.image.
// Every attempt starts from the original masked pixels, never a previous resized copy.
func observationBoundedPNG(_ original: CGImage, window: CGRect, coverage: [CGRect], byteLimit: Int = observationImageByteLimit) throws -> (image: CGImage, data: Data) {
    let maskedOriginal = try visualMaskImage(original, window: window, coverage: coverage)
    var image = maskedOriginal
    var scale = 1.0
    for _ in 0..<32 {
        let data = try observationPNG(image)
        if data.count <= byteLimit { return (image, data) }
        guard image.width > 1 || image.height > 1 else { break }
        // Leave headroom for PNG overhead; the loop verifies the encoded bytes.
        scale *= min(0.8, max(0.1, sqrt(Double(byteLimit) / Double(data.count)) * 0.9))
        let width = max(1, Int((Double(original.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(original.height) * scale).rounded(.down)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw fail("observation_image_failed", "Could not allocate bounded model-image resize")
        }
        context.interpolationQuality = .high
        context.draw(maskedOriginal, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw fail("observation_image_failed", "Could not resize model image") }
        // Clip again after interpolation so excluded pixels remain transparent.
        image = try visualMaskImage(resized, window: window, coverage: coverage)
    }
    throw fail("observation_image_too_large", "Model PNG could not fit the 4 MiB bound after bounded proportional downsampling")
}

func observationImage(_ frame: VisualFrame, identity: VisualIdentity, snapshotID: String, background: Bool) throws -> [String: Any] {
    guard frame.image.width > 0, frame.image.height > 0,
          frame.image.width <= 12000000 / frame.image.height else {
        throw fail("observation_image_too_large", "Source image exceeds 12 million pixels")
    }
    // No pre-mask debug image or independent screenshot enters the model output.
    let encoded = try observationBoundedPNG(frame.image, window: identity.frame, coverage: frame.capturedRegions ?? [])
    let image = encoded.image, data = encoded.data
    let downsampled = image.width != frame.image.width || image.height != frame.image.height
    return ["mime_type": "image/png", "data": data.base64EncodedString(), "width": image.width,
        "height": image.height, "snapshot_id": snapshotID, "masked": true, "byte_count": data.count,
        "target_pid": identity.pid, "window_id": identity.windowID, "window_frame": rectJSON(identity.frame),
        "display_topology_signature": identity.topology, "frame_complete_serial": frame.completeSerial,
        "pixel_to_point_scale_x": Double(image.width) / Double(identity.frame.width),
        "pixel_to_point_scale_y": Double(image.height) / Double(identity.frame.height),
        "downsampled": downsampled, "original_width": frame.image.width, "original_height": frame.image.height,
        "resampling_method": downsampled ? "proportional_high_quality_model_image_only" : "none",
        "ocr_frame_unchanged": true, "read_only_background": background, "source": frame.captureSource]
}

struct InspectionImagePrivacyNode {
    let element: AXUIElement
    let role: String
    let secure: Bool
    let bounds: CGRect?
    let children: [AXUIElement]
}

// launchDate is nil for the observed running Codex instance. Use the actual
// kernel process birth identity instead of treating nil as identity proof.
func inspectionProcessBirth(_ pid: pid_t) throws -> String {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let code = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    let start = info.kp_proc.p_un.__p_starttime
    guard code == 0, size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid,
          start.tv_sec > 0, start.tv_usec >= 0, start.tv_usec < 1000000 else {
        throw fail("inspection_image_launch_unknown", "Target kernel process launch identity is unavailable")
    }
    return "\(start.tv_sec):\(start.tv_usec)"
}

func inspectionImagePrivacyKnown(_ metadata: AXMetadataAttributes) -> Bool {
    guard metadata.string("AXRole") != nil else { return false }
    return ["AXSubrole", "AXProtectedContent"].allSatisfy { name in
        guard let result = metadata.attributes[name]?.result else { return false }
        return [.success, .attributeUnsupported, .noValue].contains(result)
    }
}

func inspectionImageCGWindowID(pid: pid_t, title: String, frame: CGRect,
                               rows: [[String: Any]]) throws -> CGWindowID {
    let matches = rows.filter { row in
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              row[kCGWindowName as String] as? String == title,
              let raw = row[kCGWindowBounds as String] as? NSDictionary,
              let actual = CGRect(dictionaryRepresentation: raw) else { return false }
        return actual == frame
    }
    guard matches.count == 1, let id = (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value, id > 0 else {
        throw fail("inspection_image_window_unverified", "Exactly one CG window must match the selected AX PID, title and frame")
    }
    return id
}

func inspectionImageCoverage(window: CGRect, secureBounds: [CGRect?], truncated: Bool) throws -> [CGRect] {
    guard !truncated else { throw fail("inspection_image_privacy_truncated", "A truncated AX tree cannot establish image privacy coverage") }
    var coverage = [window]
    for item in secureBounds {
        guard let item, item.minX.isFinite, item.minY.isFinite, item.width.isFinite, item.height.isFinite,
              item.width > 0, item.height > 0 else {
            throw fail("inspection_image_secure_geometry_unknown", "A secure AX region has no verified geometry")
        }
        // Padding removes text antialiasing at the protected field boundary.
        let cut = item.insetBy(dx: -2, dy: -2)
        coverage = coverage.flatMap { visualSubtract($0, cut) }
        guard coverage.count <= 256 else { throw fail("inspection_image_mask_limit", "Secure image masking exceeded its bounded region count") }
    }
    return coverage
}

private func inspectionImageRecheckPrivacy(_ nodes: [InspectionImagePrivacyNode], pid: pid_t,
                                           deadline: Double) throws {
    for node in nodes {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw fail("inspection_image_timeout", "Image privacy verification exceeded its deadline") }
        AXUIElementSetMessagingTimeout(node.element, 0.1)
        var owner: pid_t = 0
        let current = axMetadataAttributes(node.element)
        guard AXUIElementGetPid(node.element, &owner) == .success, owner == pid,
              inspectionImagePrivacyKnown(current), current.string("AXRole") == node.role,
              current.isSecure == node.secure, current.bounds == node.bounds else {
            throw fail("inspection_image_privacy_changed", "AX ownership, security or region geometry changed during capture")
        }
        if !node.secure {
            let counts = axChildCounts(node.element)
            guard counts.allSatisfy({ [.success, .attributeUnsupported, .noValue].contains($0.result) }) else {
                throw fail("inspection_image_privacy_unknown", "AX child coverage is unavailable")
            }
            let currentChildren = axNavigationChildren(node.element, limit: min(2001, node.children.count + 1), counts: counts)
            guard !currentChildren.truncated, currentChildren.elements.count == node.children.count,
                  zip(currentChildren.elements, node.children).allSatisfy({ CFEqual($0.0, $0.1) }) else {
                throw fail("inspection_image_privacy_changed", "AX child identities changed during capture")
            }
        }
    }
}

// An optional producer for generic inspect. It does not activate an app, start
// a stream, move the pointer, request permission, write a file or authorize input.
func inspectionTargetImage(helper: DesktopHelper, application: NSRunningApplication,
                           root: AXUIElement, window: AXUIElement, bundle: String, title: String,
                           frame: CGRect, topology: String, generation: Int,
                           privacyNodes: [InspectionImagePrivacyNode], truncated: Bool,
                           privacyKnown: Bool) throws -> [String: Any] {
    guard #available(macOS 14.2, *) else { throw fail("inspection_image_os_unsupported", "Target-only image capture requires macOS 14.2 or later") }
    guard CGPreflightScreenCaptureAccess() else { throw fail("inspection_image_permission_unavailable", "Screen recording permission is unavailable; no permission prompt was issued") }
    guard privacyKnown, !privacyNodes.isEmpty else { throw fail("inspection_image_privacy_unknown", "Complete AX image privacy metadata is unavailable") }
    let coverage = try inspectionImageCoverage(window: frame, secureBounds: privacyNodes.filter { $0.secure }.map { $0.bounds }, truncated: truncated)
    let pid = application.processIdentifier
    let birth = try inspectionProcessBirth(pid)
    let started = ProcessInfo.processInfo.systemUptime, deadline = started + 5
    let foregroundBefore = foregroundMetadata()
    let focusBefore = observationSystemFocus()
    let pointerBefore = CGEvent(source: nil)?.location
    func remaining() throws -> Double {
        let value = deadline - ProcessInfo.processInfo.systemUptime
        guard value > 0 else { throw fail("inspection_image_timeout", "Target image capture exceeded its deadline") }
        return value
    }
    func checkedTarget() throws -> CGWindowID {
        _ = try remaining()
        guard !application.isTerminated, application.bundleIdentifier == bundle,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundle,
              try inspectionProcessBirth(pid) == birth,
              try helper.currentDisplays().signature == topology,
              CFEqual(try helper.selectWindow(root, title: title), window), axBounds(window) == frame,
              axString(window, kAXTitleAttribute) == title else {
            throw fail("inspection_image_target_changed", "Selected process, AX window, title, geometry or topology changed")
        }
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid else {
            throw fail("inspection_image_target_changed", "Selected AX window process changed")
        }
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return try inspectionImageCGWindowID(pid: pid, title: title, frame: frame, rows: rows)
    }
    let id = try checkedTarget()
    try inspectionImageRecheckPrivacy(privacyNodes, pid: pid, deadline: deadline)
    let content: SCShareableContent = try visualAwait(try remaining()) { done in
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { value, error in
            if error != nil { done(.failure(fail("inspection_image_content_unavailable", "Public shareable content is unavailable"))) }
            else if let value { done(.success(value)) }
            else { done(.failure(fail("inspection_image_content_unavailable", "Public shareable content returned no target"))) }
        }
    }
    let matches = content.windows.filter { item in
        item.windowID == id && item.owningApplication?.processID == pid &&
        item.owningApplication?.bundleIdentifier == bundle && item.title == title &&
        item.frame == frame && item.windowLayer == 0 && item.isOnScreen
    }
    guard matches.count == 1, try checkedTarget() == id else { throw fail("inspection_image_target_changed", "Exact selected SCWindow is unavailable or changed") }
    let filter = SCContentFilter(desktopIndependentWindow: matches[0])
    let scale = Double(filter.pointPixelScale)
    guard scale.isFinite, scale > 0, frame.width > 0, frame.height > 0,
          frame.width <= 12000000, frame.height <= 12000000 else { throw fail("inspection_image_size_unverified", "Target image scale or bounds are invalid") }
    let boundedScale = min(scale, sqrt(12000000 / (frame.width * frame.height)))
    let width = max(1, Int((frame.width * boundedScale).rounded(.down)))
    let height = max(1, Int((frame.height * boundedScale).rounded(.down)))
    guard width <= 16384, height <= 16384, width <= 12000000 / height else { throw fail("inspection_image_too_large", "Target image exceeds its bounded pixel dimensions") }
    let configuration = SCStreamConfiguration()
    configuration.width = width; configuration.height = height
    configuration.showsCursor = false; configuration.capturesAudio = false
    configuration.shouldBeOpaque = false; configuration.ignoreShadowsSingleWindow = true
    configuration.includeChildWindows = false
    let pixels: CGImage = try visualAwait(try remaining()) { done in
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            if error != nil { done(.failure(fail("inspection_image_capture_failed", "Public target-window screenshot failed"))) }
            else if let image { done(.success(image)) }
            else { done(.failure(fail("inspection_image_capture_failed", "Public target-window screenshot returned no image"))) }
        }
    }
    guard pixels.width == width, pixels.height == height, try checkedTarget() == id else {
        throw fail("inspection_image_target_changed", "Captured target dimensions or window identity changed")
    }
    try inspectionImageRecheckPrivacy(privacyNodes, pid: pid, deadline: deadline)
    let encoded = try observationBoundedPNG(pixels, window: frame, coverage: coverage)
    guard try checkedTarget() == id else { throw fail("inspection_image_target_changed", "Target identity changed before image publication") }
    let image = encoded.image, snapshot = "inspect-g\(generation)-" + UUID().uuidString
    let downsampled = image.width != width || image.height != height
    let focusAfter = observationSystemFocus()
    let foregroundAfter = foregroundMetadata()
    let pointerAfter = CGEvent(source: nil)?.location
    let focusAvailable = focusBefore["available"] as? Bool == true && focusAfter["available"] as? Bool == true
    let focusPreserved: Any = focusAvailable ? NSDictionary(dictionary: focusBefore).isEqual(to: focusAfter) : NSNull()
    let identity: [String: Any] = ["snapshot_id": snapshot, "target_pid": pid, "window_id": id,
        "window_title": title, "window_frame": rectJSON(frame), "display_topology_signature": topology,
        "process_launch_identity_source": "sysctl.KERN_PROC_PID",
        "read_only_background": true, "pixel_size": ["width": width, "height": height],
        "image_snapshot_is_input_authorization": false, "ax_image_atomic": false,
        "system_focus_before": focusBefore, "system_focus_after": focusAfter,
        "foreground_preserved": focusPreserved,
        "foreground_pid_before": foregroundBefore.pid ?? 0, "foreground_pid_after": foregroundAfter.pid ?? 0,
        "foreground_source": foregroundBefore.source,
        "foreground_app_preserved": foregroundBefore.pid != nil && foregroundBefore.pid == foregroundAfter.pid,
        "pointer_preserved": pointerBefore != nil && pointerAfter != nil && pointerBefore == pointerAfter,
        "focus_takeover_attempted": false, "events_posted": 0,
        "capture_started_uptime": started, "capture_completed_uptime": ProcessInfo.processInfo.systemUptime]
    let imageMetadata: [String: Any] = ["mime_type": "image/png", "data": encoded.data.base64EncodedString(),
        "width": image.width, "height": image.height, "byte_count": encoded.data.count, "masked": true,
        "snapshot_id": snapshot, "target_pid": pid, "window_id": id, "window_frame": rectJSON(frame),
        "display_topology_signature": topology, "read_only_background": true,
        "pixel_to_point_scale_x": Double(image.width) / frame.width, "pixel_to_point_scale_y": Double(image.height) / frame.height,
        "downsampled": downsampled, "original_width": width, "original_height": height,
        "ocr_frame_unchanged": true, "resampling_method": downsampled ? "proportional_high_quality_model_image_only" : "none",
        "source": "ScreenCaptureKit.SCScreenshotManager.desktopIndependentWindow"]
    return identity.merging(["image": imageMetadata, "image_available": true,
        "secure_region_count": privacyNodes.filter { $0.secure }.count]) { _, new in new }
}

// One explicit observation target, no scanning, timer, or global event tap.
// Notifications are advisory; every read refetches the complete bounded public
// AX tree. Batched node attributes reduce IPC without reusing old content.
final class NativeObservation {
    private var observer: AXObserver?
    private var notifications: [(AXUIElement, String)] = []
    private var notificationSupport: [[String: Any]] = []
    private var revision = 0
    private var lastNotification: String?
    private var binding: String?
    private var window: AXUIElement?
    private var IDs: [(AXUIElement, String)] = []
    private var nextID = 0
    private var generation = 0
    private var previousID: String?
    private var previousRows: [String: String] = [:]

    deinit { stop() }
    func stop() {
        if let observer {
            for (element, name) in notifications { AXObserverRemoveNotification(observer, element, name as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; notifications = []; notificationSupport = []; IDs = []; nextID = 0
        binding = nil; window = nil; previousID = nil; previousRows = [:]
    }
    private func watch(_ root: AXUIElement, window: AXUIElement, pid: pid_t) {
        var created: AXObserver?
        let result = AXObserverCreate(pid, { _, _, name, context in
            guard let context else { return }
            let state = Unmanaged<NativeObservation>.fromOpaque(context).takeUnretainedValue()
            state.revision &+= 1; state.lastNotification = name as String
        }, &created)
        guard result == .success, let created else {
            notificationSupport = [["notification": "AXObserverCreate", "result": result.rawValue]]; return
        }
        observer = created
        for (element, name) in [(root, kAXFocusedWindowChangedNotification), (root, kAXFocusedUIElementChangedNotification),
                                (root, kAXWindowCreatedNotification), (window, kAXUIElementDestroyedNotification),
                                (window, kAXMovedNotification), (window, kAXResizedNotification),
                                (window, kAXValueChangedNotification), (window, "AXLayoutChanged")] {
            let code = AXObserverAddNotification(created, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            notificationSupport.append(["notification": name, "result": code.rawValue])
            if code == .success { notifications.append((element, name)) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }
    private func id(_ element: AXUIElement) -> String {
        if let old = IDs.first(where: { CFEqual($0.0, element) }) { return old.1 }
        nextID += 1; let value = "obs\(generation)-e\(nextID)"; IDs.append((element, value)); return value
    }

    func read(_ request: [String: Any], helper: DesktopHelper) throws -> [String: Any] {
        let bundle = try string(request, "app")!, title = try string(request, "window_title")!
        guard ["com.bytedance.macos.feishu", "com.tencent.xinWeChat"].contains(bundle) else {
            throw fail("observation_target_unsupported", "Background AX observation is scoped to WeChat and Feishu")
        }
        let includeImage = try boolean(request, "include_image")
        let maxDepth = try integer(request, "max_depth", default: 30, range: 0...40)
        let maxNodes = try integer(request, "max_nodes", default: 2000, range: 1...2000)
        let since = try string(request, "since_observation_id", required: false)
        guard (since?.count ?? 0) <= 128 else { throw fail("invalid_request", "since_observation_id is too long") }
        let layout = try helper.currentDisplays(), (application, root) = try helper.running(bundle)
        let selected = try helper.selectWindow(root, title: title)
        guard let frame = axBounds(selected), frame.width > 0, frame.height > 0 else {
            throw fail("observation_target_unverified", "Exact target-window geometry is unavailable")
        }
        try helper.denySecure(selected)
        let launch = application.launchDate?.timeIntervalSince1970
        let key = "\(application.processIdentifier)|\(launch ?? 0)|\(title)|\(frame)|\(layout.signature)"
        if binding != key || window.map({ !CFEqual($0, selected) }) != false {
            stop(); generation += 1; binding = key; window = selected
            watch(root, window: selected, pid: application.processIdentifier)
        }
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 8
        let focusBefore = observationSystemFocus(), revisionBefore = revision
        let targetFocusedWindow = axElement(root, kAXFocusedWindowAttribute)
        let focused = axElement(root, kAXFocusedUIElementAttribute)
        var queue: [(AXUIElement, Int, String?)] = [(selected, 0, nil)], index = 0
        var rows: [[String: Any]] = [], seen: [AXUIElement] = [], total = 0, reasons = Set<String>()
        var attributeBatchCalls = 0, attributeSingleCalls = 0, metadataBatchNodes = 0, contentBatchNodes = 0
        var securityUnknownNodes = 0
        var focusedRow: [String: Any] = ["available": false, "value_read": false]
        while index < queue.count && rows.count < maxNodes {
            guard ProcessInfo.processInfo.systemUptime < deadline else { reasons.insert("time_limit"); break }
            let (element, depth, parent) = queue[index]; index += 1
            if seen.contains(where: { CFEqual($0, element) }) { continue }; seen.append(element)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == application.processIdentifier else { reasons.insert("foreign_or_unknown_element_pid"); continue }
            let attributes = axObservationAttributes(element, deadline: deadline), metadata = attributes.metadata
            attributeBatchCalls += attributes.batchCalls; attributeSingleCalls += attributes.singleCalls
            if metadata.usedBatch { metadataBatchNodes += 1 }
            if attributes.content?.usedBatch == true { contentBatchNodes += 1 }
            if attributes.deadlineReached { reasons.insert("time_limit") }
            let securityKnown = metadata.observationSecurityKnown, secure = metadata.isSecure
            if !securityKnown { securityUnknownNodes += 1; reasons.insert("security_metadata_unavailable") }
            let readable = securityKnown && !secure
            let elementID = id(element), role = metadata.string("AXRole") ?? "AXUnknown"
            var row: [String: Any] = ["element_id": elementID, "role": role, "depth": depth, "secure": secure,
                "title": readable ? String((metadata.string("AXTitle") ?? "").prefix(4000)) : "",
                "description": readable ? String((metadata.string("AXDescription") ?? "").prefix(4000)) : "",
                "security_metadata_known": securityKnown,
                "input_eligible": false, "focused": focused.map { CFEqual($0, element) } ?? false]
            if readable, let identifier = metadata.string("AXIdentifier") { row["identifier"] = identifier }
            if let subrole = metadata.string("AXSubrole") { row["subrole"] = subrole }
            if let enabled = metadata.boolean("AXEnabled") { row["enabled"] = enabled }
            if let parent { row["parent_id"] = parent }
            if let bounds = metadata.bounds { row["position"] = ["x": bounds.minX, "y": bounds.minY]; row["size"] = ["width": bounds.width, "height": bounds.height] }
            if readable, let content = attributes.content {
                let valueResult = content.attributes["AXValue"]!
                row["value_read_result"] = valueResult.result.rawValue
                if let stringValue = valueResult.value as? String {
                    let value = observationString(stringValue, remaining: observationTotalValueLimit - total)
                    row["value"] = value.text; row["value_complete"] = value.complete; row["value_truncated"] = !value.complete
                    total += value.text.count
                    if !value.complete { reasons.insert("value_limit") }
                } else { row["value_complete"] = false; row["value_available"] = false }
                if let range = attributes.selectedRange { row["selected_range"] = ["location": range.location, "length": range.length] }
            } else { row["value_complete"] = false; row["readback_redacted"] = true }
            rows.append(row)
            if focused.map({ CFEqual($0, element) }) == true { focusedRow = row; focusedRow["available"] = true; focusedRow["within_selected_window"] = true }
            if readable {
                guard ProcessInfo.processInfo.systemUptime < deadline else { reasons.insert("time_limit"); break }
                let counts = axChildCounts(element)
                if depth < maxDepth {
                    let available = max(0, maxNodes - rows.count - (queue.count - index))
                    let children = axNavigationChildren(element, limit: available, counts: counts)
                    if children.truncated { reasons.insert("node_limit") }
                    queue += children.elements.map { ($0, depth + 1, elementID) }
                } else if counts.contains(where: { $0.count > 0 }) { reasons.insert("depth_limit") }
            }
        }
        if index < queue.count { reasons.insert("node_limit") }
        guard !application.isTerminated, application.launchDate?.timeIntervalSince1970 == launch,
              axBounds(selected) == frame, axString(selected, kAXTitleAttribute) == title,
              helper.windows(root).contains(where: { CFEqual($0, selected) }),
              try helper.currentDisplays().signature == layout.signature else {
            stop(); throw fail("observation_target_changed", "Selected background AX window, process or topology changed while reading")
        }
        try helper.denySecure(selected)
        for _ in 0..<8 { if CFRunLoopRunInMode(.defaultMode, 0, true) != .handledSource { break } }
        let focusAfter = observationSystemFocus(), currentID = UUID().uuidString
        let hashes = try observationDigest(rows)
        var result: [String: Any] = ["app": bundle, "target_pid": application.processIdentifier, "window_title": title,
            "window_frame": rectJSON(frame), "display_topology_signature": layout.signature, "coordinate_system": quartzCoordinateSystem,
            "read_only_background": true, "input_eligible": false, "events_posted": 0, "focus_changed_by_helper": false,
            "observation_id": currentID, "generation": generation, "elements": rows, "node_count": rows.count,
            "windows": rows.filter { $0["depth"] as? Int == 0 },
            "focused_element": focusedRow, "target_window_internally_focused": targetFocusedWindow.map { CFEqual($0, selected) } ?? false,
            "focus_context": ["before": focusBefore, "after": focusAfter, "scope": "metadata_only_no_foreign_content"],
            "truncated": !reasons.isEmpty, "truncation_reasons": reasons.sorted(), "values_max_characters": observationValueLimit,
            "total_value_characters": total, "tree_refetched": true, "notification_revision": revision,
            "read_strategy": "fresh_full_tree_batched_attributes", "cached_node_count": 0,
            "ax_read_cost": ["scope": "tree_node_metadata_value_and_selection_only",
                "batch_calls": attributeBatchCalls, "fallback_single_calls": attributeSingleCalls,
                "attribute_api_calls": attributeBatchCalls + attributeSingleCalls,
                "metadata_batch_nodes": metadataBatchNodes, "content_batch_nodes": contentBatchNodes,
                "security_unknown_nodes": securityUnknownNodes,
                "excludes": ["target_and_focus_proofs", "child_navigation", "pid_and_timeout_calls"]],
            "changed_during_read": revision != revisionBefore, "notification_support": notificationSupport,
            "observer_policy": "advisory_invalidation_always_refetch_no_background_polling", "image_requested": includeImage,
            "image_available": false, "image_unavailable_reason": includeImage ? "unsupported_app_AX_only_use_WeChat_background_visual_read" : "not_requested"]
        if let lastNotification { result["last_notification"] = lastNotification }
        if let since {
            if since == previousID { result["diff"] = observationDiff(before: previousRows, after: hashes); result["diff_base_observation_id"] = since }
            else { result["diff_unavailable_reason"] = "unknown_or_invalidated_baseline_full_tree_returned" }
        }
        previousID = currentID; previousRows = hashes
        let retained = Set(rows.compactMap { $0["element_id"] as? String }); IDs = IDs.filter { retained.contains($0.1) }
        result["observation_elapsed_ms"] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        return result
    }
}

func visualWindowSnapshotDiagnostics(_ image: CGImage, window: CGRect, regions: [CGRect]) -> [String: Any] {
    var result: [String: Any] = ["stage": "exact_main_normalized_pixels_before_auxiliary_masks", "width": image.width,
        "height": image.height, "bits_per_pixel": image.bitsPerPixel, "bits_per_component": image.bitsPerComponent,
        "alpha_info": image.alphaInfo.rawValue, "bytes_per_row": image.bytesPerRow]
    guard image.bitsPerPixel == 32, image.bitsPerComponent == 8,
          image.alphaInfo == .premultipliedLast || image.alphaInfo == .last,
          let data = image.dataProvider?.data, let pixels = CFDataGetBytePtr(data),
          CFDataGetLength(data) >= image.bytesPerRow * image.height else {
        result["format_supported"] = false; result["rejection_reason"] = "unsupported_normalized_pixel_format"; return result
    }
    result["format_supported"] = true
    let sx = Double(image.width) / window.width, sy = Double(image.height) / window.height
    let samples: [[String: Any]] = regions.flatMap { region in visualVisibilitySamples(region).map { point in
        let x = max(0, min(image.width - 1, Int((point.x - window.minX) * sx)))
        let y = max(0, min(image.height - 1, Int((point.y - window.minY) * sy)))
        return ["x": point.x, "y": point.y, "alpha": Int(pixels[y * image.bytesPerRow + x * 4 + 3])]
    } }
    result["alpha_samples"] = samples
    result["pre_mask_readable_region_count"] = visualWindowSnapshotCoverage(image, window: window, regions: regions).count
    if samples.allSatisfy({ ($0["alpha"] as? Int ?? 0) < 8 }) { result["rejection_reason"] = "exact_main_window_alpha_samples_transparent" }
    else if samples.contains(where: { ($0["alpha"] as? Int ?? 0) < 8 }) { result["rejection_reason"] = "exact_main_window_alpha_sample_coverage_incomplete" }
    return result
}

func visualWindowSnapshotCoverage(_ image: CGImage, window: CGRect, regions: [CGRect]) -> [CGRect] {
    guard image.bitsPerPixel == 32, image.bitsPerComponent == 8,
          image.alphaInfo == .premultipliedLast || image.alphaInfo == .last,
          let data = image.dataProvider?.data, let pixels = CFDataGetBytePtr(data),
          CFDataGetLength(data) >= image.bytesPerRow * image.height else { return [] }
    let sx = Double(image.width) / window.width, sy = Double(image.height) / window.height
    return regions.filter { region in
        visualVisibilitySamples(region).allSatisfy { point in
            let x = max(0, min(image.width - 1, Int((point.x - window.minX) * sx)))
            let y = max(0, min(image.height - 1, Int((point.y - window.minY) * sy)))
            return pixels[y * image.bytesPerRow + x * 4 + 3] >= 8
        }
    }
}

func nativeObservationSelfTests() -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ result: Bool) { cases.append(["name": name, "passed": result]) }
    do {
        let genericFrame = CGRect(x: -1920, y: 33, width: 100, height: 80)
        let genericWindow: [String: Any] = [kCGWindowOwnerPID as String: 91, kCGWindowNumber as String: 92,
            kCGWindowLayer as String: 0, kCGWindowName as String: "Generic fixture window",
            kCGWindowBounds as String: genericFrame.dictionaryRepresentation]
        check("generic_image_exact_CG_pid_title_frame_binding", try inspectionImageCGWindowID(pid: 91,
            title: "Generic fixture window", frame: genericFrame, rows: [genericWindow]) == 92)
        for (field, value) in [(kCGWindowOwnerPID as String, 93 as Any), (kCGWindowName as String, "Other window" as Any),
                               (kCGWindowLayer as String, 3 as Any),
                               (kCGWindowBounds as String, genericFrame.offsetBy(dx: 1, dy: 0).dictionaryRepresentation as Any)] {
            var changed = genericWindow; changed[field] = value
            var denied = false
            do { _ = try inspectionImageCGWindowID(pid: 91, title: "Generic fixture window", frame: genericFrame, rows: [changed]) }
            catch { denied = true }
            check("generic_image_CG_mismatch_denied_" + field, denied)
        }
        var duplicateDenied = false
        do { _ = try inspectionImageCGWindowID(pid: 91, title: "Generic fixture window", frame: genericFrame, rows: [genericWindow, genericWindow]) }
        catch { duplicateDenied = true }
        check("generic_image_ambiguous_CG_window_denied", duplicateDenied)
        check("generic_image_no_secure_regions_keeps_only_selected_window", try inspectionImageCoverage(window: genericFrame, secureBounds: [], truncated: false) == [genericFrame])
        var unknownSecureDenied = false, truncatedPrivacyDenied = false
        do { _ = try inspectionImageCoverage(window: genericFrame, secureBounds: [nil], truncated: false) } catch { unknownSecureDenied = true }
        do { _ = try inspectionImageCoverage(window: genericFrame, secureBounds: [], truncated: true) } catch { truncatedPrivacyDenied = true }
        check("generic_image_unknown_secure_geometry_denied", unknownSecureDenied)
        check("generic_image_truncated_AX_privacy_denied", truncatedPrivacyDenied)
        let secretRect = CGRect(x: -1910, y: 68, width: 20, height: 10)
        let safeCoverage = try inspectionImageCoverage(window: genericFrame, secureBounds: [secretRect], truncated: false)
        check("generic_image_secure_geometry_and_padding_excluded", !safeCoverage.contains { $0.contains(CGPoint(x: -1900, y: 73)) } &&
            !safeCoverage.contains { $0.contains(CGPoint(x: -1911, y: 73)) })
        guard let genericContext = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw fail("self_test_failed", "Generic image masking context unavailable")
        }
        genericContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        genericContext.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let genericPNG = try observationBoundedPNG(genericContext.makeImage()!, window: genericFrame, coverage: safeCoverage)
        let genericDecoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(genericPNG.data as CFData, nil)!, 0, nil)!
        let genericRGBA = try visualRGBA(genericDecoded), genericBytes = CFDataGetBytePtr(genericRGBA.dataProvider!.data!)!
        check("generic_model_PNG_secure_pixels_transparent", genericBytes[40 * genericRGBA.bytesPerRow + 20 * 4 + 3] == 0)
        check("generic_model_PNG_nonsecure_window_pixels_retained", genericBytes[50 * genericRGBA.bytesPerRow + 60 * 4 + 3] == 255)
        let limit = observationString(String(repeating: "字", count: 65537), remaining: observationTotalValueLimit)
        check("full_value_limit_is_explicit", limit.text.count == 65536 && !limit.complete)
        let emoji = observationString("中😀文", remaining: 2)
        check("value_limit_preserves_character_boundaries", emoji.text == "中😀" && !emoji.complete)
        check("ordinary_complete_value_preserved", observationString("业务 后缀\n", remaining: 100).complete)
        check("exhausted_total_budget_returns_incomplete", !observationString("x", remaining: 0).complete)
        let before = try observationDigest([["element_id": "obs1-e1", "value": "a"], ["element_id": "obs1-e2", "value": "keep"], ["element_id": "obs1-e3", "value": "gone"]])
        let after = try observationDigest([["element_id": "obs1-e1", "value": "b"], ["element_id": "obs1-e2", "value": "keep"], ["element_id": "obs1-e4", "value": "new"]])
        let diff = observationDiff(before: before, after: after)
        check("diff_changed_value_identified", diff["changed_ids"] as? [String] == ["obs1-e1"])
        check("diff_stable_node_not_reported_changed", !(diff["changed_ids"] as? [String] ?? []).contains("obs1-e2"))
        check("diff_removed_node_reported", diff["removed_ids"] as? [String] == ["obs1-e3"])
        check("diff_new_node_reported", diff["added_ids"] as? [String] == ["obs1-e4"])
        check("Qt_noValue_may_settle_readonly", observationFocusMaySettle(bundle: "com.tencent.xinWeChat", result: .noValue, hasValue: false))
        check("AX_cannotComplete_may_settle_readonly", observationFocusMaySettle(bundle: "com.tencent.xinWeChat", result: .cannotComplete, hasValue: false))
        check("AX_unsupported_not_treated_as_focus_transient", !observationFocusMaySettle(bundle: "com.tencent.xinWeChat", result: .attributeUnsupported, hasValue: false))
        check("real_other_focused_window_never_ignored", !observationFocusMaySettle(bundle: "com.tencent.xinWeChat", result: .success, hasValue: true))
        check("other_app_not_extrapolated", !observationFocusMaySettle(bundle: "com.bytedance.macos.feishu", result: .noValue, hasValue: false))
        let rect = CGRect(x: -100, y: 20, width: 40, height: 20)
        let id = VisualIdentity(pid: 9, windowID: 10, frame: rect, topology: "negative-mixed")
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let frame = VisualFrame(image: context.makeImage()!, completeSerial: 7, time: 1, completeTime: 1.1, idleConfirmed: false,
            capturedRegions: [CGRect(x: -100, y: 20, width: 20, height: 20)])
        let image = try observationImage(frame, identity: id, snapshotID: "opaque-test", background: true)
        check("model_image_is_bound_to_actual_snapshot", image["snapshot_id"] as? String == "opaque-test" && image["frame_complete_serial"] as? Int == 7)
        check("model_image_explicitly_masked_readonly", image["masked"] as? Bool == true && image["read_only_background"] as? Bool == true)
        check("point_scale_preserved", image["pixel_to_point_scale_x"] as? Double == 2 && image["pixel_to_point_scale_y"] as? Double == 2)
        let png = Data(base64Encoded: image["data"] as! String)!
        let source = CGImageSourceCreateWithData(png as CFData, nil)!, decoded = try visualRGBA(CGImageSourceCreateImageAtIndex(source, 0, nil)!)
        let bytes = decoded.dataProvider!.data!, raw = CFDataGetBytePtr(bytes)!
        check("occluded_pixels_never_leak_into_PNG", raw[20 * decoded.bytesPerRow + 60 * 4 + 3] == 0)
        check("permitted_pixels_preserved_in_PNG", raw[20 * decoded.bytesPerRow + 20 * 4 + 3] == 255)
        check("PNG_bound_below_stdio_envelope", png.count <= observationImageByteLimit && observationImageByteLimit * 4 / 3 < 8 * 1024 * 1024)
        check("small_PNG_is_not_resampled", image["downsampled"] as? Bool == false && image["ocr_frame_unchanged"] as? Bool == true)
        let noisyContext = CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let noise = noisyContext.data!.assumingMemoryBound(to: UInt8.self)
        var random: UInt32 = 0x1234abcd
        for y in 0..<64 { for x in 0..<128 {
            let offset = y * noisyContext.bytesPerRow + x * 4
            for c in 0..<3 { random = random &* 1664525 &+ 1013904223; noise[offset + c] = UInt8(truncatingIfNeeded: random >> 24) }
            noise[offset + 3] = 255
        } }
        let noisy = noisyContext.makeImage()!, noiseRect = CGRect(x: -100, y: 20, width: 64, height: 32)
        let allowed = CGRect(x: -100, y: 20, width: 48, height: 32)
        let originalDigest = SHA256.hash(data: noisy.dataProvider!.data! as Data)
        let bounded = try observationBoundedPNG(noisy, window: noiseRect, coverage: [allowed], byteLimit: 1024)
        check("over_budget_PNG_actually_downsampled", bounded.image.width < noisy.width && bounded.image.height < noisy.height)
        check("downsampled_PNG_meets_encoded_byte_budget", bounded.data.count <= 1024)
        check("downsampling_preserves_aspect_with_pixel_rounding", abs(Double(bounded.image.width) / 2 - Double(bounded.image.height)) <= 1)
        check("OCR_source_pixels_not_modified_by_model_encoding", originalDigest == SHA256.hash(data: noisy.dataProvider!.data! as Data))
        let resizedRaw = try visualRGBA(bounded.image), resizedBytes = CFDataGetBytePtr(resizedRaw.dataProvider!.data!)!
        let deniedX = resizedRaw.width - 1, middleY = resizedRaw.height / 2
        check("downsampling_keeps_excluded_region_transparent", resizedBytes[middleY * resizedRaw.bytesPerRow + deniedX * 4 + 3] == 0)
        context.clear(CGRect(x: 0, y: 0, width: 80, height: 40))
        check("transparent_exact_window_is_not_readable", visualWindowSnapshotCoverage(context.makeImage()!, window: rect, regions: [rect]).isEmpty)
        let transparentDiagnostic = visualWindowSnapshotDiagnostics(context.makeImage()!, window: rect, regions: [rect])
        check("transparent_source_diagnosed_before_own_window_masks", transparentDiagnostic["format_supported"] as? Bool == true && transparentDiagnostic["rejection_reason"] as? String == "exact_main_window_alpha_samples_transparent")
        check("opaque_exact_window_has_readable_coverage", visualWindowSnapshotCoverage(frame.image, window: rect, regions: [rect]) == [rect])
        let visual = VisualDesktop()
        try visual.validate(["command": "background_visual_read", "include_image": true, "background_capture": "exact_window"])
        check("explicit_background_exact_window_wire_contract", true)
        var foregroundRejected = false
        do { try visual.validate(["command": "visual_read", "background_capture": "exact_window"]) } catch { foregroundRejected = true }
        check("foreground_cannot_opt_into_background_capture", foregroundRejected)
        check("pure_tests_do_not_start_observer_or_capture", !visual.captureReady)
    } catch { cases.append(["name": "unexpected_error", "passed": false, "error": String(describing: error)]) }
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count, "cases": cases,
            "events_posted": 0, "capture_executed": false, "live_AX_probe_executed": false]
}
