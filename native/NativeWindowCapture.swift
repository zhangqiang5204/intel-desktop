import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import ApplicationServices

// Error diagnostics never retain an NSError, description, userInfo or an
// arbitrary domain. These fields can safely travel through metadata-only logs.
private struct VisualCaptureSystemFailure {
    let domain: String
    let code: Int?
    init(_ error: Error) {
        let value = error as NSError
        let allowed = [SCStreamErrorDomain, NSOSStatusErrorDomain, NSPOSIXErrorDomain,
                       NSCocoaErrorDomain, NSMachErrorDomain]
        domain = allowed.contains(value.domain) ? value.domain : "unrecognized_domain"
        code = (Int(Int32.min)...Int(Int32.max)).contains(value.code) ? value.code : nil
    }
    var details: [String: Any] {
        ["capture_error_domain": domain, "capture_error_code": code.map { $0 as Any } ?? NSNull(),
         "capture_error_code_in_range": code != nil]
    }
}

private enum VisualWarmCaptureStage: String {
    case beforeShareableContent = "before_shareable_content"
    case primingReusedAppFilter = "priming_reused_app_filter"
    case refreshingCommittedExactFilter = "refreshing_committed_exact_filter"
    case startingAppFilter = "starting_app_filter"
    case warmingAppFilter = "warming_app_filter"
    case updatingExactWindowFilter = "updating_exact_window_filter"
    case awaitingPostupdateComplete = "awaiting_postupdate_complete"
    case beforeStaticExactReadReprime = "before_static_exact_read_reprime"
    case awaitingReprimedPostupdateComplete = "awaiting_reprimed_postupdate_complete"
    case completedTargetFrame = "completed_target_frame"
}

// Each request owns a fresh exact-filter update epoch, even when its strictly
// bound streams are reused. A cold stream first primes the app filter; an
// already committed identical exact filter need not leave its target scope.
// App-only/idle pixels are never retained, returned, or OCRed. Filter completion
// is a delivery barrier, not proof that application content changed.
struct VisualWarmEpoch {
    private(set) var armed = false
    private(set) var requestPTS = -Double.infinity
    private(set) var maximumDiscardedPTS = -Double.infinity
    private(set) var lastAcceptedPTS = -Double.infinity
    private(set) var discarded = 0
    mutating func prepare(at hostPTS: Double) { armed = false; requestPTS = hostPTS }
    mutating func finish() { armed = true }
    mutating func accepts(complete: Bool, pts: Double) -> Bool {
        guard complete else { return false }
        guard armed else {
            if pts.isFinite { maximumDiscardedPTS = max(maximumDiscardedPTS, pts) }
            discarded += 1; return false
        }
        guard pts.isFinite, requestPTS.isFinite, pts >= requestPTS,
              pts > maximumDiscardedPTS, pts > lastAcceptedPTS else { discarded += 1; return false }
        lastAcceptedPTS = pts; return true
    }
}

private final class VisualWarmReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "intel.desktop.window-filter-epoch")
    var epoch = VisualWarmEpoch()
    var buffer: CVPixelBuffer?
    var pts: Double?
    var error: VisualCaptureSystemFailure?
    var completeCount = 0
    func prepare() -> Double { queue.sync {
        let time = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        epoch.prepare(at: time); buffer = nil; pts = nil; return time
    }}
    func arm() { queue.sync { epoch.finish(); buffer = nil; pts = nil } }
    func suspend() { queue.sync { epoch.prepare(at: -.infinity); buffer = nil; pts = nil } }
    func discardedComplete(after boundary: Double) -> Bool { queue.sync { epoch.maximumDiscardedPTS > boundary } }
    func state() -> (CVPixelBuffer?, Double?, VisualCaptureSystemFailure?, Int, Int) {
        queue.sync { (buffer, pts, error, completeCount, epoch.discarded) }
    }
    func stream(_ stream: SCStream, didStopWithError failure: Error) {
        let diagnostic = VisualCaptureSystemFailure(failure)
        queue.async { self.error = diagnostic; self.buffer = nil }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let complete = (attachments?.first?[.status] as? Int) == SCFrameStatus.complete.rawValue
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard epoch.accepts(complete: complete, pts: time), let image = sample.imageBuffer,
              CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else { return }
        buffer = image; pts = time; completeCount += 1
    }
}

// These value bindings contain identity/geometry only. Shareable app/windows
// and every existing AX/CG/topology guard are refetched for each request; a
// cached stream never substitutes cached ownership or cached pixels.
private struct VisualWarmFragmentBinding: Equatable {
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let rect: CGRect
    let coverage: [CGRect]
    let pixelWidth: Int
    let pixelHeight: Int
}
private struct VisualWarmWindowBinding: Equatable {
    let id: CGWindowID
    let frame: CGRect
}
private struct VisualWarmBinding: Equatable {
    let selected: VisualIdentity
    let title: String?
    let width: Int
    let height: Int
    let fragments: [VisualWarmFragmentBinding]
    let windows: [VisualWarmWindowBinding]
}

private final class VisualWarmSession {
    let binding: VisualWarmBinding
    let streams: [SCStream]
    let outputs: [VisualWarmReceiver]
    let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var stopped = false
    private var exactFilterCommitted = false
    var usable: Bool {
        lock.lock(); let closed = stopped; lock.unlock()
        return !closed && outputs.allSatisfy { $0.state().2 == nil }
    }
    var cancellationDetails: [String: Any] {
        lock.lock(); let closed = stopped; lock.unlock()
        var details: [String: Any] = ["capture_session_stopped": closed,
            "capture_cancel_source": closed ? "session_stopped" : "session_unusable"]
        if let failure = outputs.lazy.compactMap({ $0.state().2 }).first {
            details.merge(failure.details) { _, new in new }
            details["capture_cancel_source"] = "stream_stop"
        }
        return details
    }
    init(binding: VisualWarmBinding, streams: [SCStream], outputs: [VisualWarmReceiver]) {
        self.binding = binding; self.streams = streams; self.outputs = outputs
    }
    var canRefreshCommittedExactFilter: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && exactFilterCommitted
    }
    func commitExactFilter() throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw fail("visual_capture_cancelled", "The exact-window stream stopped before its filter was committed",
            ["capture_cancel_source": "session_stopped", "capture_cancel_site": "commit_exact_filter", "capture_session_stopped": true]) }
        exactFilterCommitted = true
    }
    func start(_ stream: SCStream, completion: @escaping (Error?) -> Void) {
        stream.startCapture { [self] error in
            lock.lock(); let closed = stopped; lock.unlock()
            // A deadline/release can stop the session while startCapture is
            // still pending. Stop again after a late successful start so the
            // asynchronous callback cannot leave an orphaned capture stream.
            if closed, error == nil { stream.stopCapture(completionHandler: nil) }
            completion(error)
        }
    }
    func suspend() { outputs.forEach { $0.suspend() } }
    func stop() {
        lock.lock(); let alreadyStopped = stopped; stopped = true; exactFilterCommitted = false; lock.unlock()
        guard !alreadyStopped else { return }
        suspend(); streams.forEach { $0.stopCapture(completionHandler: nil) }
    }
}

// One bounded pool per helper process. The lease token also prevents a late
// completion/timer from retaining a released or replacement session.
private let visualWarmCaptureIdleSeconds: Double = 60

private final class VisualWarmPool {
    private let lock = NSLock()
    private let idleQueue = DispatchQueue(label: "intel.desktop.window-capture-idle")
    private let idleSeconds: Double
    private var session: VisualWarmSession?
    private var busy = false
    private var generation: UInt64 = 0
    private var idleWork: DispatchWorkItem?
    private var reused = false
    init(idleSeconds: Double = visualWarmCaptureIdleSeconds) { self.idleSeconds = idleSeconds }
    func take(_ binding: VisualWarmBinding) throws -> (VisualWarmSession?, UInt64) {
        lock.lock()
        guard !busy else { lock.unlock(); throw fail("visual_capture_busy", "A bound capture request is already running") }
        idleWork?.cancel(); idleWork = nil; generation &+= 1; busy = true
        let old = session
        let matched = old?.binding == binding && old?.usable == true
        reused = matched
        if !matched { session = nil }
        let token = generation, value = session
        lock.unlock()
        if !matched { old?.stop() }
        return (value, token)
    }
    func install(_ value: VisualWarmSession, token: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard busy, generation == token, session == nil else { throw fail("visual_capture_cancelled", "Capture pool lease changed during setup",
            ["capture_cancel_source": "lease_changed", "capture_cancel_site": "pool_install"]) }
        session = value
    }
    func owns(_ value: VisualWarmSession, token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return busy && generation == token && session === value
    }
    func finish(_ value: VisualWarmSession, token: UInt64) throws {
        lock.lock()
        let ownsLease = busy && generation == token && session === value
        guard ownsLease, value.usable else {
            lock.unlock()
            var details = value.cancellationDetails
            if !ownsLease { details["capture_cancel_source"] = "lease_changed" }
            details["capture_cancel_site"] = "pool_finish"
            throw fail("visual_capture_cancelled", "Capture pool lease stopped before completion", details)
        }
        // Validate the lease before clearing receivers: a stale completion for
        // the same reused session must not suspend a newer active epoch.
        value.suspend() // No CVPixelBuffer survives an idle capture request.
        busy = false
        let work = DispatchWorkItem { [weak self] in self?.expire(token) }
        idleWork = work; lock.unlock()
        idleQueue.asyncAfter(deadline: .now() + idleSeconds, execute: work)
    }
    private func expire(_ token: UInt64) {
        lock.lock()
        guard generation == token, !busy else { lock.unlock(); return }
        let old = session; session = nil; idleWork = nil; generation &+= 1
        lock.unlock(); old?.stop()
    }
    func release(token: UInt64? = nil, onlyIdle: Bool = false) {
        lock.lock()
        guard (token == nil || generation == token), !onlyIdle || !busy else { lock.unlock(); return }
        idleWork?.cancel(); idleWork = nil; generation &+= 1
        let old = session; session = nil; busy = false
        lock.unlock(); old?.stop()
    }
    var status: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["stream_active": session?.usable == true, "capture_pool_reused": reused && session != nil,
                "capture_pool_busy": busy, "capture_pool_idle_timeout_ms": Int(idleSeconds * 1000),
                "capture_stream_count": session?.streams.count ?? 0]
    }
}
private let visualWarmPool = VisualWarmPool()

// Call explicitly at helper shutdown. Ordinary focus return/mode changes can
// keep this target-only pool warm; target/group changes and errors release it.
func visualWarmCaptureRelease() { visualWarmPool.release() }
func visualWarmCapturePoolStatus() -> [String: Any] { visualWarmPool.status }

// Bounded timings contain no window titles, OCR text, or event content.
final class VisualCaptureMetrics {
    let started = ProcessInfo.processInfo.systemUptime
    private var previous = ProcessInfo.processInfo.systemUptime
    private var phases: [String: Double] = [:]
    func mark(_ name: String) {
        let now = ProcessInfo.processInfo.systemUptime
        phases[name, default: 0] += (now - previous) * 1000; previous = now
    }
    func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { phases[name, default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        return try body()
    }
    var json: [String: Double] {
        var result = phases; result["total"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        return result
    }
}

struct VisualWarmCapture {
    let image: CGImage
    // Taken before every fragment's host-PTS update boundary. This is a
    // conservative uptime bound, not a conversion between clock domains.
    let frameNotBeforeUptime: Double
    let evidence: [String: Any]
}

// Observation has no HID claim: historical/manual input may stop input, but
// cannot revoke an identity-validated read. Do not clear or resume the monitor.
func visualCaptureInputPoll(readOnly: Bool, sharedCheck: () throws -> Void) rethrows {
    if !readOnly { try sharedCheck() }
}

struct VisualPopupShareableCandidate {
    let id: CGWindowID
    let pid: pid_t?
    let bundle: String?
    let frame: CGRect
    let titlePresent: Bool
    let titleEmpty: Bool
    let layer: Int
    let onScreen: Bool
}

// Record the real SC predicates without any window names or application text.
// The exact-ID candidate stays first even when the same app has many windows.
func visualPopupShareableDiagnostic(selected: VisualIdentity, overlay: VisualSearchOverlay,
                                   candidates: [VisualPopupShareableCandidate]) -> [String: Any] {
    let exactID = candidates.filter { $0.id == overlay.windowID }
    let related = exactID + candidates.filter { $0.id != overlay.windowID && $0.pid == selected.pid }
    let rows = related.prefix(24).map { item -> [String: Any] in
        ["window_id": item.id, "pid": item.pid.map { $0 as Any } ?? NSNull(),
         "bundle_id": item.bundle.map { $0 as Any } ?? NSNull(), "frame": rectJSON(item.frame),
         "title_present": item.titlePresent, "empty_title": item.titleEmpty,
         "layer": item.layer, "on_screen": item.onScreen,
         "matches": ["window_id": item.id == overlay.windowID, "pid": item.pid == selected.pid,
            "frame": item.frame == overlay.frame, "empty_title": item.titleEmpty,
            "layer": item.layer == 3, "on_screen": item.onScreen]]
    }
    return ["phase": "matching_shareable_search_popup",
        "expected_cg_popup": ["window_id": overlay.windowID, "pid": selected.pid,
            "frame": rectJSON(overlay.frame), "layer": 3, "empty_title": true, "on_screen": true],
        "selected_main": ["window_id": selected.windowID, "pid": selected.pid, "frame": rectJSON(selected.frame)],
        "expected_geometry_bound": visualSearchPopupBounds(overlay.frame, identity: selected),
        "sc_total_window_count": candidates.count, "sc_exact_id_count": exactID.count,
        "sc_related_candidate_count": related.count, "sc_related_candidates": rows,
        "sc_related_candidates_truncated": related.count > 24]
}

func visualWarmWindowCapture(selected: VisualIdentity, title: String?, plan: VisualCapturePlan,
                             overlay: VisualSearchOverlay?, auxiliaries: [VisualScreenWindow], deadline: Double,
                             check: () throws -> Void, poll: () throws -> Void) throws -> VisualWarmCapture {
    let timing = VisualCaptureMetrics()
    var activeSession: VisualWarmSession?, leaseToken: UInt64?
    var constructingStreams: [SCStream] = []
    var retained = false
    var captureStage = VisualWarmCaptureStage.beforeShareableContent
    defer {
        if !retained {
            activeSession?.stop(); constructingStreams.forEach { $0.stopCapture(completionHandler: nil) }
            visualWarmPool.release(token: leaseToken, onlyIdle: leaseToken == nil)
        }
    }
    do {
    guard #available(macOS 14.2, *), CGPreflightScreenCaptureAccess() else {
        throw fail("screen_capture_unavailable", "Granted screen capture access and macOS 14.2 are required")
    }
    func checkedTarget() throws {
        do { try timing.measure("full_identity_guard") { try check() } }
        catch var error as HelperError { error.details["capture_stage"] = captureStage.rawValue; throw error }
    }
    try checkedTarget()
    func remaining() throws -> Double {
        let value = deadline - ProcessInfo.processInfo.systemUptime
        guard value > 0 else { throw fail("visual_frame_timeout", "Fresh window-filter request exceeded its deadline") }
        return value
    }
    let content: SCShareableContent = try visualAwait(try remaining()) { done in
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { value, error in
            if let error { done(.failure(error)) } else if let value { done(.success(value)) }
            else { done(.failure(fail("visual_content_unavailable", "Shareable target content is unavailable"))) }
        }
    }
    timing.mark("shareable_content_and_initial_guard")
    let apps = content.applications.filter { $0.processID == selected.pid && $0.bundleIdentifier == "com.tencent.xinWeChat" }
    let main = content.windows.filter { $0.windowID == selected.windowID && $0.owningApplication?.processID == selected.pid &&
        $0.owningApplication?.bundleIdentifier == "com.tencent.xinWeChat" && $0.frame == selected.frame &&
        $0.title == title && $0.windowLayer == 0 && $0.isOnScreen }
    guard apps.count == 1, main.count == 1 else { throw fail("visual_target_changed", "Exact WeChat app/main SCWindow identity is unavailable") }
    var included = [main[0]]
    if let overlay {
        guard visualSearchPopupBounds(overlay.frame, identity: selected) else { throw fail("visual_search_overlay_unverified", "Popup geometry is not bound to the selected main window") }
        let matches = content.windows.filter { $0.windowID == overlay.windowID && $0.owningApplication?.processID == selected.pid &&
            $0.frame == overlay.frame && ($0.title ?? "").isEmpty && $0.windowLayer == 3 && $0.isOnScreen }
        guard matches.count == 1 else {
            let candidates = content.windows.map { item in
                VisualPopupShareableCandidate(id: item.windowID, pid: item.owningApplication?.processID,
                    bundle: item.owningApplication?.bundleIdentifier, frame: item.frame,
                    titlePresent: item.title != nil, titleEmpty: (item.title ?? "").isEmpty,
                    layer: item.windowLayer, onScreen: item.isOnScreen)
            }
            var diagnostic = visualPopupShareableDiagnostic(selected: selected, overlay: overlay, candidates: candidates)
            diagnostic["sc_exact_match_count"] = matches.count
            throw fail("visual_target_changed", "Exact known search-popup SCWindow changed", diagnostic)
        }
        included.append(matches[0])
    }
    // Preserve the existing strictly shaped IME hint pipeline. Its pixels are
    // captured only through this same display filter and must pass the existing
    // blue-pill signature mask; other own windows are never added.
    for auxiliary in auxiliaries {
        guard auxiliary.pid == selected.pid, auxiliary.inputHintCandidate,
              visualContains(selected.frame, auxiliary.frame) else { throw fail("visual_target_changed", "Unbound auxiliary capture request") }
        let matches = content.windows.filter { $0.windowID == auxiliary.id && $0.owningApplication?.processID == selected.pid &&
            $0.frame == auxiliary.frame && ($0.title ?? "").isEmpty && $0.windowLayer == 3 && $0.isOnScreen }
        guard matches.count == 1 else { throw fail("visual_target_changed", "Exact input-source indicator window changed") }
        included.append(matches[0])
    }
    var initialFilters: [SCContentFilter] = [], filters: [SCContentFilter] = []
    for fragment in plan.fragments {
        let displays = content.displays.filter { $0.displayID == fragment.displayID && $0.frame == fragment.displayBounds }
        guard displays.count == 1 else { throw fail("display_topology_changed", "Exact display fragment is no longer shareable") }
        initialFilters.append(SCContentFilter(display: displays[0], including: [apps[0]], exceptingWindows: []))
        filters.append(SCContentFilter(display: displays[0], including: included))
    }
    let binding = VisualWarmBinding(selected: selected, title: title, width: plan.width, height: plan.height,
        fragments: plan.fragments.map { VisualWarmFragmentBinding(displayID: $0.displayID, displayBounds: $0.displayBounds,
            rect: $0.rect, coverage: $0.coverage, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight) },
        windows: included.map { VisualWarmWindowBinding(id: $0.windowID, frame: $0.frame) })
    let lease = try visualWarmPool.take(binding)
    leaseToken = lease.1
    let reused = lease.0 != nil
    if let existing = lease.0 {
        activeSession = existing
    } else {
        var outputs: [VisualWarmReceiver] = []
        for (fragment, initial) in zip(plan.fragments, initialFilters) {
            let config = SCStreamConfiguration()
            config.width = fragment.pixelWidth; config.height = fragment.pixelHeight
            config.sourceRect = fragment.sourceRect; config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 3; config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            config.showsCursor = false; config.capturesAudio = false; config.shouldBeOpaque = false
            config.ignoreShadowsSingleWindow = true; config.ignoreShadowsDisplay = true; config.includeChildWindows = false
            let receiver = VisualWarmReceiver(), stream = SCStream(filter: initial, configuration: config, delegate: receiver)
            constructingStreams.append(stream)
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            outputs.append(receiver)
        }
        let created = VisualWarmSession(binding: binding, streams: constructingStreams, outputs: outputs)
        activeSession = created
        try visualWarmPool.install(created, token: lease.1)
        constructingStreams = []
    }
    let session = activeSession!, streams = session.streams, outputs = session.outputs
    // Only a completed, guarded exact-window request can establish this path.
    // The pool matched all current SC identities/geometry before this point;
    // no cached SCWindow, old frame, idle sample or input proof is reused.
    let refreshCommittedExact = reused && session.canRefreshCommittedExactFilter
    // Fragment start/update callbacks run concurrently; each result is examined.
    func pollGuard() throws {
        // This phase performs no input. Event monitoring remains continuous;
        // AX/CG/focus/secure checks run at the capture boundaries below instead
        // of repeating slow synchronous AX traversals every 50 milliseconds.
        try poll()
        let ownsLease = visualWarmPool.owns(session, token: lease.1)
        guard ownsLease, session.usable else {
            var details = session.cancellationDetails
            if !ownsLease { details["capture_cancel_source"] = "lease_changed" }
            details["capture_cancel_site"] = "poll_guard"
            throw fail("visual_capture_cancelled", "The bound capture pool was released or stopped", details)
        }
    }
    func awaitAll(_ boxes: [VisualCompletion<Bool>]) throws {
        while true {
            try pollGuard(); _ = try remaining()
            var complete = true
            for box in boxes { if let result = box.get() { _ = try result.get() } else { complete = false } }
            if complete { return }
            _ = CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
    }
    func primeAppFilters() throws {
        captureStage = .primingReusedAppFilter
        let primeBoundaries = outputs.map { $0.prepare() }
        let primes = zip(streams, initialFilters).map { stream, filter -> VisualCompletion<Bool> in
            let box = VisualCompletion<Bool>(); stream.updateContentFilter(filter) { error in box.complete(error.map { .failure($0) } ?? .success(true)) }; return box
        }
        try awaitAll(primes)
        // Prime only an already-running, identical binding. These samples are
        // discarded; the separate exact-filter epoch below is the sole source
        // of readable pixels. No app-only sample authorizes input or output.
        while !zip(outputs, primeBoundaries).allSatisfy({ pair in pair.0.discardedComplete(after: pair.1) }) {
            try pollGuard(); _ = try remaining(); _ = CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
        timing.mark("reused_app_filter_prime")
    }
    if refreshCommittedExact {
        captureStage = .refreshingCommittedExactFilter
    } else if reused {
        try primeAppFilters()
    } else {
        captureStage = .startingAppFilter
        let starts = streams.map { stream -> VisualCompletion<Bool> in
            let box = VisualCompletion<Bool>(); session.start(stream) { error in box.complete(error.map { .failure($0) } ?? .success(true)) }; return box
        }
        try awaitAll(starts)
        timing.mark("configure_and_start")
        captureStage = .warmingAppFilter
        let warmUntil = ProcessInfo.processInfo.systemUptime + 0.250
        while ProcessInfo.processInfo.systemUptime < warmUntil {
            try pollGuard(); _ = try remaining(); _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        timing.mark("app_warmup")
    }
    func updateExactFilters() throws -> (uptime: Double, boundaries: [Double]) {
        captureStage = .updatingExactWindowFilter
        try checkedTarget()
        let uptime = ProcessInfo.processInfo.systemUptime
        let boundaries = outputs.map { $0.prepare() }
        let updates = zip(streams, filters).map { stream, filter -> VisualCompletion<Bool> in
            let box = VisualCompletion<Bool>(); stream.updateContentFilter(filter) { error in box.complete(error.map { .failure($0) } ?? .success(true)) }; return box
        }
        try awaitAll(updates)
        outputs.forEach { $0.arm() }
        timing.mark("update_and_identity_guard")
        return (uptime, boundaries)
    }
    var update = try updateExactFilters()
    captureStage = .awaitingPostupdateComplete
    let completeAwaitStarted = ProcessInfo.processInfo.systemUptime
    var readReprimed = false
    var states: [(CVPixelBuffer?, Double?, VisualCaptureSystemFailure?, Int, Int)] = []
    while true {
        try pollGuard(); _ = try remaining()
        states = outputs.map { $0.state() }
        if let error = states.compactMap({ $0.2 }).first {
            var details = error.details; details["capture_cancel_source"] = "stream_stop"
            details["capture_cancel_site"] = "await_complete"
            throw fail("visual_capture_failed", "Window-filter stream stopped", details)
        }
        if states.allSatisfy({ $0.0 != nil && $0.1 != nil }) { break }
        if refreshCommittedExact, !readReprimed, ProcessInfo.processInfo.systemUptime - completeAwaitStarted >= 0.200 {
            // A same-filter update can be a no-op on static Qt content (seen
            // on the mixed-scale seam). After two 10fps frame intervals, use
            // the proven read-only app→exact transition once. Every fragment
            // starts a new epoch; no partial/old pixels or input are replayed.
            readReprimed = true
            timing.mark("committed_exact_no_complete_wait")
            captureStage = .beforeStaticExactReadReprime
            try checkedTarget()
            try primeAppFilters()
            update = try updateExactFilters()
            captureStage = .awaitingReprimedPostupdateComplete
            continue
        }
        _ = CFRunLoopRunInMode(.defaultMode, 0.005, true)
    }
    timing.mark("await_complete")
    let images = try states.enumerated().map { index, state -> CGImage in
        guard let buffer = state.0, CVPixelBufferGetWidth(buffer) == plan.fragments[index].pixelWidth,
              CVPixelBufferGetHeight(buffer) == plan.fragments[index].pixelHeight else { throw fail("visual_target_changed", "Completed fragment dimensions changed") }
        let input = CIImage(cvPixelBuffer: buffer)
        guard let image = session.context.createCGImage(input, from: input.extent) else { throw fail("visual_capture_failed", "Completed target pixels are unavailable") }
        return image
    }
    captureStage = .completedTargetFrame
    try checkedTarget()
    guard CGPreflightScreenCaptureAccess(), visualTopologyMatches(plan.topology) else { throw fail("visual_target_changed", "Capture permission or display topology changed") }
    let image = try plan.composite(images)
    timing.mark("convert_composite_and_final_guard")
    try session.commitExactFilter()
    try visualWarmPool.finish(session, token: lease.1)
    retained = true
    let committedRefreshDelivered = refreshCommittedExact && !readReprimed
    return VisualWarmCapture(image: image, frameNotBeforeUptime: update.uptime,
        evidence: ["request_id": UUID().uuidString, "new_stream_instances": !reused, "capture_pool_reused": reused,
        "capture_pool_idle_timeout_ms": Int(visualWarmCaptureIdleSeconds * 1000), "idle_pixel_buffers_retained": false,
        "fresh_shareable_content_verified": true, "capture_stream_count": streams.count,
        "capture_filter_path": committedRefreshDelivered ? "committed_exact_filter_fresh_update" : "app_prime_then_exact_filter",
        "exact_filter_committed_before_request": refreshCommittedExact,
        "committed_exact_refresh_attempted": refreshCommittedExact, "committed_exact_refresh_reprimed": readReprimed,
        "app_filter_prime_performed": !refreshCommittedExact || readReprimed,
        "initial_app_warmup_ms": reused ? 0 : 250, "accepted_epoch": lease.1,
        "initial_app_frames_discarded": true, "included_window_ids": included.map { $0.windowID },
        "window_filter_update_requested_host_PTS": update.boundaries,
        "window_filter_update_not_before_uptime": update.uptime,
        "frame_age_basis": "uptime_before_all_exact_filter_update_epochs_no_cross_clock_conversion",
        "accepted_complete_frame_PTS": states.compactMap { $0.1 },
        "discarded_complete_frames": states.map { $0.4 },
        "all_fragments_complete_after_update": true, "idle_frames_accepted": false,
        "pixel_change_proven": false, "source": committedRefreshDelivered ? "public_SCStream_committed_display_bound_exact_window_filter_refresh" : "public_SCStream_app_then_display_bound_exact_window_filter",
        "phase_ms": timing.json, "full_guard_schedule": "before_shareable_before_update_after_complete",
        "wait_poll_checks": "input_monitor_only_no_input_performed"])
    } catch var error as HelperError {
        error.details["capture_stage"] = captureStage.rawValue
        error.details["capture_phase_ms"] = timing.json; throw error
    } catch {
        var details = VisualCaptureSystemFailure(error).details
        details["capture_stage"] = captureStage.rawValue
        details["capture_cancel_source"] = "capture_api_error"
        details["capture_phase_ms"] = timing.json
        throw fail("visual_capture_failed", "Public window capture failed", details)
    }
}

func visualWarmCaptureSelfTests() -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
    let safeFailure = VisualCaptureSystemFailure(NSError(domain: SCStreamErrorDomain, code: -3817,
        userInfo: [NSLocalizedDescriptionKey: "private_capture_description", "private_key": "private_value"]))
    check("capture_failure_known_domain_and_code_retained", safeFailure.domain == SCStreamErrorDomain && safeFailure.code == -3817)
    let unknownFailure = VisualCaptureSystemFailure(NSError(domain: "private_domain", code: 42))
    check("capture_failure_unknown_domain_redacted", unknownFailure.domain == "unrecognized_domain" && unknownFailure.code == 42)
    let oversizedFailure = VisualCaptureSystemFailure(NSError(domain: NSCocoaErrorDomain, code: Int.max))
    check("capture_failure_code_is_bounded", oversizedFailure.code == nil && oversizedFailure.details["capture_error_code"] is NSNull)
    let failureJSON = (try? JSONSerialization.data(withJSONObject: safeFailure.details)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check("capture_failure_does_not_retain_error_text", !failureJSON.isEmpty && !failureJSON.contains("private_"))
    check("capture_failure_metadata_keys_are_closed", Set(safeFailure.details.keys) == Set(["capture_error_domain", "capture_error_code", "capture_error_code_in_range"]))
    var epoch = VisualWarmEpoch()
    check("initial_app_complete_never_readable", !epoch.accepts(complete: true, pts: 10))
    epoch.prepare(at: 20)
    check("complete_during_update_discarded", !epoch.accepts(complete: true, pts: 20.5))
    epoch.finish()
    check("old_epoch_delayed_callback_denied", !epoch.accepts(complete: true, pts: 19.9))
    check("update_inflight_PTS_replay_denied", !epoch.accepts(complete: true, pts: 20.5))
    check("idle_never_creates_snapshot", !epoch.accepts(complete: false, pts: 21))
    check("NaN_PTS_denied", !epoch.accepts(complete: true, pts: .nan))
    check("post_update_complete_accepted", epoch.accepts(complete: true, pts: 21))
    check("duplicate_complete_not_new_evidence", !epoch.accepts(complete: true, pts: 21))
    check("next_complete_accepted", epoch.accepts(complete: true, pts: 22))
    var next = VisualWarmEpoch(); next.prepare(at: 30); next.finish()
    check("next_request_cannot_reuse_prior_pixels", !next.accepts(complete: true, pts: 22))
    let viewport = CGRect(x: 106, y: 91, width: 261, height: 999)
    let window = CGRect(x: 50, y: 41, width: 855, height: 1079)
    let scrollPoint = CGPoint(x: 250, y: 800)
    let safe = try? visualControlSafetyRegion(command: "visual_scroll", control: viewport, window: window, point: scrollPoint)
    check("scroll_safety_OCR_is_bounded_at_actual_point", safe == CGRect(x: 202, y: 768, width: 96, height: 64))
    check("scroll_safety_OCR_does_not_cover_full_viewport", safe.map { $0.width * $0.height < viewport.width * viewport.height / 20 } == true)
    check("outside_scroll_point_rejected", (try? visualControlSafetyRegion(command: "visual_scroll", control: viewport, window: window, point: CGPoint(x: 900, y: 800))) == nil)
    for command in ["visual_click", "visual_type_text", "visual_key"] {
        check("\(command)_full_control_safety_unchanged", (try? visualControlSafetyRegion(command: command, control: viewport, window: window, point: scrollPoint)) == viewport.insetBy(dx: -12, dy: -12).intersection(window))
    }
    if let wheel = visualScrollEvent(point: scrollPoint, delta: -100, source: nil) {
        check("point_only_wheel_is_real_scroll_event", wheel.type == .scrollWheel)
        check("point_only_wheel_carries_Quartz_point", wheel.location == scrollPoint)
        check("point_only_wheel_has_no_modifiers", wheel.flags.isEmpty)
        check("point_only_wheel_preserves_delta", wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -100)
    } else { check("point_only_wheel_constructed_without_posting", false) }
    check("fresh_request_complete_accepted", next.accepts(complete: true, pts: 30.1))
    let identity = VisualIdentity(pid: 1, windowID: 8, frame: CGRect(x: -855, y: 33, width: 855, height: 1079), topology: "test")
    check("empty_query_popup_170_geometry", visualSearchPopupBounds(CGRect(x: -807, y: 68, width: 368, height: 170), identity: identity))
    check("results_popup_430_geometry", visualSearchPopupBounds(CGRect(x: -807, y: 68, width: 368, height: 430), identity: identity))
    check("unknown_popup_not_added", !visualSearchPopupBounds(CGRect(x: -807, y: 68, width: 369, height: 430), identity: identity))
    let expectedPopup = VisualSearchOverlay(windowID: 35609, frame: CGRect(x: -807, y: 68, width: 368, height: 172))
    func popupCandidate(id: CGWindowID = 35609, pid: pid_t? = 1, frame: CGRect? = nil,
                        empty: Bool = true, layer: Int = 3, onScreen: Bool = true) -> VisualPopupShareableCandidate {
        VisualPopupShareableCandidate(id: id, pid: pid, bundle: "com.tencent.xinWeChat",
            frame: frame ?? expectedPopup.frame, titlePresent: false, titleEmpty: empty, layer: layer, onScreen: onScreen)
    }
    func popupDiagnostic(_ rows: [VisualPopupShareableCandidate]) -> [String: Any] {
        visualPopupShareableDiagnostic(selected: identity, overlay: expectedPopup, candidates: rows)
    }
    func candidateMatches(_ candidate: VisualPopupShareableCandidate) -> [String: Bool] {
        let rows = popupDiagnostic([candidate])["sc_related_candidates"] as? [[String: Any]]
        return rows?.first?["matches"] as? [String: Bool] ?? [:]
    }
    check("SC_popup_diagnostic_exact_match_is_explicit", candidateMatches(popupCandidate()).count == 6 && candidateMatches(popupCandidate()).values.allSatisfy { $0 })
    for (name, item) in [
        ("window_id", popupCandidate(id: 35610)), ("pid", popupCandidate(pid: 99)),
        ("frame", popupCandidate(frame: expectedPopup.frame.offsetBy(dx: 0, dy: 1))),
        ("empty_title", popupCandidate(empty: false)), ("layer", popupCandidate(layer: 0)),
        ("on_screen", popupCandidate(onScreen: false))
    ] {
        check("SC_popup_diagnostic_identifies_" + name + "_mismatch", candidateMatches(item)[name] == false && candidateMatches(item).values.filter { !$0 }.count == 1)
    }
    check("SC_popup_diagnostic_missing_window_not_fabricated", popupDiagnostic([])["sc_exact_id_count"] as? Int == 0)
    check("SC_popup_diagnostic_nil_owner_is_not_expected_PID", candidateMatches(popupCandidate(pid: nil))["pid"] == false)
    let many = (1...40).map { popupCandidate(id: CGWindowID($0)) } + [popupCandidate()]
    let boundedPopup = popupDiagnostic(many)
    let diagnosticRows = boundedPopup["sc_related_candidates"] as? [[String: Any]]
    check("SC_popup_diagnostic_bounds_rows_and_prioritizes_exact_ID", diagnosticRows?.count == 24 &&
        diagnosticRows?.first?["window_id"] as? CGWindowID == 35609 && boundedPopup["sc_related_candidate_count"] as? Int == 41 &&
        boundedPopup["sc_related_candidates_truncated"] as? Bool == true)
    let popupJSON = try? JSONSerialization.data(withJSONObject: boundedPopup, options: [.sortedKeys])
    check("SC_popup_diagnostic_serializes_without_title_or_pixel_content", popupJSON != nil &&
        !String(data: popupJSON ?? Data(), encoding: .utf8)!.contains("\"title\":") &&
        !String(data: popupJSON ?? Data(), encoding: .utf8)!.contains("image"))
    let bounds = CGRect(x: 329, y: 41, width: 855, height: 1079)
    func row(_ id: Int, _ pid: Int, _ layer: Int) -> [String: Any] {
        [kCGWindowNumber as String:id, kCGWindowOwnerPID as String:pid, kCGWindowLayer as String:layer,
         kCGWindowIsOnscreen as String:true, kCGWindowBounds as String:bounds.dictionaryRepresentation]
    }
    check("notification_does_not_replace_actual_main", actualMainCGWindowID(pid: 8, bounds: bounds, rows: [row(1,8,8),row(2,8,0)]) == 2)
    check("ambiguous_main_CG_identity_denied", actualMainCGWindowID(pid: 8, bounds: bounds, rows: [row(1,8,0),row(2,8,0)]) == nil)
    check("foreign_same_frame_is_not_main", actualMainCGWindowID(pid: 8, bounds: bounds, rows: [row(1,9,0)]) == nil)
    let a = VisualScreenWindow(id: 4, pid: 8, frame: bounds, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    let b = VisualScreenWindow(id: 5, pid: 9, frame: bounds, layer: 3, alpha: 0.5, emptyTitle: true, dockSurface: false)
    let difference = visualWindowChangeDiagnostic([a], [a,b])
    check("diagnostic_identifies_added_window_without_content", difference["window_changes_count"] as? Int == 1 && (difference["after_window_order"] as? [CGWindowID]) == [4,5])
    let unchanged = visualWindowChangeDiagnostic([a,b], [b,a])
    check("diagnostic_separates_order_from_identity_change", unchanged["window_changes_count"] as? Int == 0)
    let selected = VisualIdentity(pid: 60682, windowID: 33789, frame: bounds, topology: "test")
    let chrome = VisualScreenWindow(id: 34049, pid: 60682, frame: CGRect(x: 335, y: 46, width: 52, height: 20), layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    check("actual_same_PID_new_aux_is_exclusion_only", visualNewContainedAuxiliaries(baseline: [b], current: [b,chrome], seen: [], identity: selected) == [chrome])
    check("temporary_aux_disappearance_keeps_exclusion_union", visualNewContainedAuxiliaries(baseline: [b], current: [b], seen: [chrome], identity: selected) == [chrome])
    let foreign = VisualScreenWindow(id: 34049, pid: 77, frame: chrome.frame, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    check("foreign_new_window_still_stops", visualNewContainedAuxiliaries(baseline: [b], current: [b,foreign], seen: [], identity: selected) == nil)
    let outside = VisualScreenWindow(id: 34049, pid: 60682, frame: CGRect(x: 320, y: 46, width: 52, height: 20), layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    check("partly_outside_own_window_still_stops", visualNewContainedAuxiliaries(baseline: [b], current: [b,outside], seen: [], identity: selected) == nil)
    let popup = VisualScreenWindow(id: 34049, pid: 60682, frame: CGRect(x: 377, y: 76, width: 368, height: 170), layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)
    check("popup_addition_cannot_use_aux_exception", visualNewContainedAuxiliaries(baseline: [b], current: [b,popup], seen: [], identity: selected) == nil)
    check("baseline_window_removal_still_stops", visualNewContainedAuxiliaries(baseline: [b], current: [chrome], seen: [], identity: selected) == nil)
    check("observed_aux_geometry_change_still_stops", visualNewContainedAuxiliaries(baseline: [b], current: [b,outside], seen: [chrome], identity: selected) == nil)
    let masked = visualSubtract(bounds, chrome.frame)
    check("actual_aux_pixels_not_authorized", !visualCovered(chrome.frame, by: masked) && visualCovered(CGRect(x: 660, y: 900, width: 300, height: 80), by: masked))
    if let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() {
        let frame = VisualFrame(image: image, completeSerial: 11, time: 100, completeTime: 100.1,
            idleConfirmed: false, capturedRegions: [])
        check("same_RPC_frame_is_fresh_at_two_seconds", visualFreshPreinputFrame(frame, after: 10, now: 102))
        check("same_RPC_reuse_cannot_extend_pixel_age", !visualFreshPreinputFrame(frame, after: 10, now: 102.001))
        check("prior_snapshot_serial_cannot_authorize_input", !visualFreshPreinputFrame(frame, after: 11, now: 101))
        check("future_or_invalid_clock_cannot_authorize_input", !visualFreshPreinputFrame(frame, after: 10, now: 99) && !visualFreshPreinputFrame(frame, after: 10, now: .nan))
        let idle = VisualFrame(image: image, completeSerial: 12, time: 100, completeTime: 100.1, idleConfirmed: true, capturedRegions: [])
        check("idle_refresh_never_authorizes_reused_frame", !visualFreshPreinputFrame(idle, after: 10, now: 101))
        let captured = VisualWarmCapture(image: image, frameNotBeforeUptime: 100,
            evidence: ["window_filter_update_requested_host_PTS": [1_000_000_000.0]])
        do {
            let display = DisplayGeometry(id: 1, bounds: CGRect(x: 0, y: 0, width: 4, height: 4), pixelWidth: 4, pixelHeight: 4)
            let plan = try VisualCapturePlan(window: display.bounds, topology: DisplaySnapshot(displays: [display]))
            let normalized = try visualExactWindowFrame(captured.image, plan: plan, previousSerial: 10, after: 10,
                requestStarted: captured.frameNotBeforeUptime, completed: 100.4)
            check("frame_age_uses_uptime_epoch_not_host_PTS_or_completion", normalized.time == 100 && normalized.completeTime == 100.4)
            check("startup_before_filter_epoch_does_not_age_pixels", visualFreshPreinputFrame(normalized, after: 10, now: 101.9))
            check("two_second_bound_remains_after_new_epoch", !visualFreshPreinputFrame(normalized, after: 10, now: 102.001))
        } catch { check("uptime_epoch_fixture", false) }
        let hint = VisualScreenWindow(id: 33787, pid: 60682, frame: CGRect(x: 351, y: 964, width: 84, height: 77), layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)
        let dock = VisualScreenWindow(id: 23, pid: 766, frame: CGRect(x: 0, y: 0, width: 1792, height: 1120), layer: 20, alpha: 1, emptyTitle: true, dockSurface: true)
        let hintIdentity = VisualIdentity(pid: 60682, windowID: 33789, frame: window, topology: "fixture")
        let pill = CGRect(x: 378, y: 991, width: 30, height: 23)
        let blankContext = CGContext(data: nil, width: 855, height: 1079, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        blankContext.setFillColor(CGColor(gray: 1, alpha: 1)); blankContext.fill(CGRect(x: 0, y: 0, width: 855, height: 1079))
        var before = VisualFrame(image: blankContext.makeImage()!, completeSerial: 1, time: 100, completeTime: 100.1,
            idleConfirmed: false, capturedRegions: [window], screenWindows: [dock, hint],
            excludedInputRegions: [pill.insetBy(dx: -1, dy: -1)], inputSourceHints: [pill])
        let ax = AXUIElementCreateApplication(getpid()) // local reference only; no AX query
        var snap = VisualSnapshot(id: "fixture", identity: hintIdentity, frame: before, created: 100.1,
            focusedWindow: ax, focusedFrame: window, focusedTitle: "微信", rows: [], anchors: ["搜索", "群标题"],
            confirmed: true, confirmationSource: "fixture", anchorRegions: [CGRect(x: 120, y: 56, width: 210, height: 27), CGRect(x: 376, y: 46, width: 300, height: 30)])
        let request: [String: Any] = ["command": "visual_scroll", "control_kind": "navigation", "control_rect": rectJSON(viewport), "x": 250, "y": 800]
        if let transition = VisualNavigationHintTransition(request: request, snapshot: snap) {
            var after = before; after.screenWindows = [dock]; after.excludedInputRegions = []; after.inputSourceHints = []
            check("known_pixel_hint_disappearance_can_be_freshly_observed", transition.acceptsFrames(before, after))
            check("same_known_hint_reappearance_requires_new_signature", transition.acceptsFrames(after, before))
            var unknown = before; unknown.inputSourceHints = []; unknown.excludedInputRegions = [hint.frame]
            check("84x77_geometry_without_pixel_signature_denied", !transition.acceptsFrames(before, unknown))
            let foreign = VisualScreenWindow(id: 24, pid: 999, frame: hint.frame, layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)
            check("foreign_window_change_never_retried", !transition.acceptsWindows([dock, hint], [dock, foreign]))
            let moved = VisualScreenWindow(id: hint.id, pid: hint.pid, frame: hint.frame.offsetBy(dx: 1, dy: 0), layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)
            check("known_hint_geometry_change_denied", !transition.acceptsWindows([dock, hint], [dock, moved]))
            let additional = VisualScreenWindow(id: 99, pid: hint.pid, frame: hint.frame, layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)
            check("unknown_same_PID_auxiliary_not_allowlisted", !transition.acceptsWindows([dock, hint], [dock, additional]))
            var changedCoverage = after; changedCoverage.capturedRegions = [viewport]
            check("unrelated_coverage_change_denied", !transition.acceptsFrames(before, changedCoverage))
            var changedExclusion = after; changedExclusion.excludedInputRegions = [CGRect(x: 230, y: 790, width: 10, height: 10)]
            check("scroll_point_occluder_denied", !transition.acceptsFrames(before, changedExclusion))
            do {
                try VisualDesktop().verifyNavigationHintAnchors(snap, frame: after, transition: transition)
                check("changed_hint_requires_actual_two_anchor_OCR", false)
            } catch let error as HelperError { check("changed_hint_requires_actual_two_anchor_OCR", error.code == "visual_target_unconfirmed") }
              catch { check("changed_hint_requires_actual_two_anchor_OCR", false) }
        } else { check("known_pixel_hint_transition_fixture", false) }
        check("hint_transition_denied_for_other_navigation_actions", VisualNavigationHintTransition(request: request.merging(["command": "visual_click"]) { _, new in new }, snapshot: snap) == nil)
        check("hint_transition_denied_near_pointer", VisualNavigationHintTransition(request: request.merging(["x": 360, "y": 980]) { _, new in new }, snapshot: snap) == nil)
        snap.readOnlyBackground = true
        check("background_snapshot_never_enables_hint_input", VisualNavigationHintTransition(request: request, snapshot: snap) == nil)
        snap.readOnlyBackground = false
        before.inputSourceHints = []
        check("metadata_alone_never_proves_known_hint", visualKnownHintWindows(before, identity: hintIdentity).isEmpty)
        // Empty coverage exercises the real cache without Vision, AX, or capture.
        let desktop = VisualDesktop()
        do {
            _ = try desktop.ocr(frame, identity: identity, region: identity.frame)
            _ = try desktop.ocr(frame, identity: identity, region: identity.frame)
            check("incomplete_same_frame_ROI_never_memoized", desktop.ocrRecognitionRuns == 2 && desktop.ocrCacheHits == 0)
            let nextFrame = VisualFrame(image: image, completeSerial: 12, time: 101, completeTime: 101.1, idleConfirmed: false, capturedRegions: [])
            _ = try desktop.ocr(nextFrame, identity: identity, region: identity.frame)
            check("incomplete_new_frame_ROI_never_reuses_OCR", desktop.ocrRecognitionRuns == 3 && desktop.ocrCacheHits == 0)
        } catch { check("same_frame_OCR_cache_boundary", false) }
    } else { check("pure_bitmap_fixture_available", false) }
    var attempts = 0
    do {
        let result: Int = try visualSettleNavigationHint(enabled: true, deadline: ProcessInfo.processInfo.systemUptime + 1, check: {}) {
            attempts += 1; if attempts == 1 { throw VisualNavigationHintObservationChanged() }; return 7
        }
        check("known_hint_discards_once_and_returns_only_new_capture", result == 7 && attempts == 2)
    } catch { check("known_hint_discards_once_and_returns_only_new_capture", false) }
    attempts = 0
    do {
        let _: Int = try visualSettleNavigationHint(enabled: true, deadline: ProcessInfo.processInfo.systemUptime + 1, check: {}) {
            attempts += 1; throw VisualNavigationHintObservationChanged()
        }
        check("hint_reobservation_is_bounded_to_two_attempts", false)
    } catch { check("hint_reobservation_is_bounded_to_two_attempts", attempts == 2) }
    attempts = 0
    do {
        let _: Int = try visualSettleNavigationHint(enabled: true, deadline: ProcessInfo.processInfo.systemUptime + 1, check: {}) {
            attempts += 1; throw fail("user_interrupted", "fixture")
        }
        check("takeover_is_never_retried", false)
    } catch { check("takeover_is_never_retried", attempts == 1) }
    var sharedChecks = 0
    do {
        try visualCaptureInputPoll(readOnly: true) { sharedChecks += 1; throw fail("user_interrupted", "retained historical interruption") }
        check("background_read_does_not_consume_historical_HID_interruption", sharedChecks == 0)
    } catch { check("background_read_does_not_consume_historical_HID_interruption", false) }
    do {
        try visualCaptureInputPoll(readOnly: false) { sharedChecks += 1; throw fail("user_interrupted", "retained historical interruption") }
        check("foreground_capture_preserves_interruption", false)
    } catch let error as HelperError { check("foreground_capture_preserves_interruption", error.code == "user_interrupted" && sharedChecks == 1) }
      catch { check("foreground_capture_preserves_interruption", false) }
    // Execute the production counter/callback primitive, including the prefix
    // sequence, with fake event sinks. No CGEvent, AX, capture, or monitor starts.
    var posted = 0, callbacks: [Int] = [], fakePosts = 0
    func countedGuard(_ observedCount: Int) throws { callbacks.append(observedCount) }
    do {
        for _ in 0..<3 {
            try visualPostCountedKeyPair(count: &posted, beforePost: countedGuard,
                down: { fakePosts += 1 }, up: { fakePosts += 1 })
        }
        check("dynamic_prefix_counter_callback_has_no_inout_alias", posted == 6 && fakePosts == 6 && callbacks == [0,1,2,3,4,5])
    } catch { check("dynamic_prefix_counter_callback_has_no_inout_alias", false) }
    posted = 0; fakePosts = 0
    do {
        try visualPostCountedKeyPair(count: &posted, beforePost: { observed in
            if observed == 0 { throw fail("stale_visual_snapshot", "first-event frame expired") }
        }, down: { fakePosts += 1 }, up: { fakePosts += 1 })
        check("expired_first_event_remains_zero_posts", false)
    } catch { check("expired_first_event_remains_zero_posts", posted == 0 && fakePosts == 0) }
    do {
        try visualPostCountedKeyPair(count: &posted, beforePost: { observed in
            if observed == 1 { throw fail("user_interrupted", "between key pair") }
        }, down: { fakePosts += 1 }, up: { fakePosts += 1 })
        check("key_up_interruption_preserves_partial_count", false)
    } catch { check("key_up_interruption_preserves_partial_count", posted == 1 && fakePosts == 1) }
    let display = CGRect(x: 0, y: 0, width: 1792, height: 1120), panel = CGRect(x: 1040, y: 0, width: 752, height: 1100)
    check("live_NC_structure_masks_conservative_panel", visualNotificationPanelBounds(display: display, window: display, wrapper: display, panels: [panel], complete: true) == [panel])
    check("incomplete_NC_structure_never_narrows_mask", visualNotificationPanelBounds(display: display, window: display, wrapper: display, panels: [panel], complete: false) == nil)
    check("empty_NC_children_never_proves_transparency", visualNotificationPanelBounds(display: display, window: display, wrapper: display, panels: [], complete: true) == nil)
    check("fullsize_child_and_outside_child_denied", visualNotificationPanelBounds(display: display, window: display, wrapper: display, panels: [display], complete: true) == nil && visualNotificationPanelBounds(display: display, window: display, wrapper: display, panels: [panel.offsetBy(dx: 1, dy: 0)], complete: true) == nil)
    check("nonmatching_NC_wrapper_denied", visualNotificationPanelBounds(display: display, window: display, wrapper: panel, panels: [panel], complete: true) == nil)
    let nc = VisualScreenWindow(id: 46, pid: 864, frame: display, layer: 23, alpha: 1, emptyTitle: false, dockSurface: false)
    do {
        let unknown = try visualScreenCoverage([selected.frame], windows: [nc], identity: selected, overlay: nil, dockRegions: nil)
        let verified = try visualScreenCoverage([selected.frame], windows: [nc], identity: selected, overlay: nil, dockRegions: nil, notificationRegions: [46: [panel]])
        check("unverified_NC_fullsurface_still_blocks", unknown.isEmpty)
        check("verified_NC_left_region_visible_panel_stays_masked", visualCovered(CGRect(x: 400, y: 100, width: 300, height: 100), by: verified) && !visualCovered(CGRect(x: 1060, y: 100, width: 100, height: 100), by: verified))
        func cgRow(_ id: UInt32, _ pid: Int32, _ frame: CGRect, _ layer: Int) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: 1, kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let rows = [cgRow(46, 864, display, 23), cgRow(selected.windowID, selected.pid, selected.frame, 0)]
        let left = CGPoint(x: 500, y: 200), right = CGPoint(x: 1100, y: 200)
        check("point_guard_only_skips_verified_panel_exterior", visualPointTargetMatches(left, identity: selected, rows: rows, dockPID: nil, dockRegions: nil, displays: [display], notificationRegions: [46: [panel]]) && !visualPointTargetMatches(right, identity: selected, rows: rows, dockPID: nil, dockRegions: nil, displays: [display], notificationRegions: [46: [panel]]) && !visualPointTargetMatches(left, identity: selected, rows: rows, dockPID: nil, dockRegions: nil, displays: [display]))
    } catch { check("NC_mask_and_point_policy", false) }
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "cases": cases, "count": cases.count, "capture_executed": false, "events_posted": 0]
}
