import Foundation
import CoreFoundation

// This owns the real asynchronous start/stop operations. A cancelled start is
// kept alive until its completion arrives, then stopped with a completion of
// its own. Neither a timeout nor a failed stop is evidence that capture ended.
final class CaptureLifecycle {
    typealias Operation = (@escaping (Error?) -> Void) -> Void
    enum State: String { case idle, starting, running, stopping, stopFailed, stopped }
    enum Failure: Error { case alreadyStarted, closing, cleanupPending }
    struct Snapshot {
        let state: State
        let stopRequested: Bool
        let startFailed: Bool
        let stopAttempts: Int
        var terminal: Bool { state == .stopped }
    }

    private let lock = NSLock()
    private let startOperation: Operation
    private let stopOperation: Operation
    private let startFailureIsTerminal: (Error) -> Bool
    private let onStopped: (CaptureLifecycle) -> Void
    private var state: State = .idle
    private var stopRequested = false
    private var startResolved = false
    private var startFailed = false
    private var stopAttempts = 0

    init(start: @escaping Operation, stop: @escaping Operation,
         startFailureIsTerminal: @escaping (Error) -> Bool = { _ in false },
         onStopped: @escaping (CaptureLifecycle) -> Void) {
        startOperation = start; stopOperation = stop; self.onStopped = onStopped
        self.startFailureIsTerminal = startFailureIsTerminal
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(state: state, stopRequested: stopRequested,
                        startFailed: startFailed, stopAttempts: stopAttempts)
    }

    func start(completion: @escaping (Error?) -> Void) {
        lock.lock()
        guard state == .idle, !stopRequested else {
            let error: Failure = stopRequested ? .closing : .alreadyStarted
            lock.unlock(); completion(error); return
        }
        state = .starting
        lock.unlock()
        startOperation { [self] error in
            let rejected = error.map(startFailureIsTerminal) ?? false
            lock.lock()
            guard !startResolved else { lock.unlock(); return }
            startResolved = true
            startFailed = error != nil
            if rejected {
                stopRequested = true; state = .stopped
                lock.unlock()
                onStopped(self); completion(error); return
            }
            // An interrupted start IPC can leave server-side work in flight.
            // Confirm a stop even after a failed start; do not silently drop it.
            if error != nil { stopRequested = true }
            state = .running
            let attempt: Int?
            if stopRequested {
                state = .stopping; stopAttempts += 1; attempt = stopAttempts
            } else { attempt = nil }
            lock.unlock()
            if let attempt { performStop(attempt: attempt) }
            completion(error)
        }
    }

    // One failed-stop retry per explicit request/drain, never a callback loop.
    func requestStop() {
        lock.lock()
        stopRequested = true
        var terminal = false
        var attempt: Int?
        switch state {
        case .idle:
            state = .stopped; terminal = true
        case .running, .stopFailed:
            state = .stopping; stopAttempts += 1; attempt = stopAttempts
        case .starting, .stopping, .stopped:
            break
        }
        lock.unlock()
        if terminal { onStopped(self) }
        if let attempt { performStop(attempt: attempt) }
    }

    private func performStop(attempt: Int) {
        stopOperation { [self] error in
            lock.lock()
            guard state == .stopping, stopAttempts == attempt else { lock.unlock(); return }
            state = error == nil ? .stopped : .stopFailed
            lock.unlock()
            if error == nil { onStopped(self) }
        }
    }

    // A delegate stop is authoritative after start resolves. During a pending
    // start it requests closure, so a later successful start is still stopped.
    func didStop() {
        lock.lock()
        stopRequested = true
        guard state != .stopped else { lock.unlock(); return }
        guard state != .starting else { lock.unlock(); return }
        state = .stopped
        lock.unlock()
        onStopped(self)
    }
}

// Strong ownership belongs here until confirmed terminal cleanup, independent
// of the warm pool, request stack, cancellation, or local output receivers.
final class CaptureLifecycleRegistry {
    typealias Clock = () -> Double
    typealias Poll = () -> Void
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: CaptureLifecycle] = [:]
    private var shuttingDown = false
    private var drains = 0

    @discardableResult
    func register(key: ObjectIdentifier, start: @escaping CaptureLifecycle.Operation,
                  stop: @escaping CaptureLifecycle.Operation,
                  startFailureIsTerminal: @escaping (Error) -> Bool = { _ in false }) throws -> CaptureLifecycle {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown, drains == 0 else { throw CaptureLifecycle.Failure.closing }
        if let existing = entries[key] { return existing }
        guard !entries.values.contains(where: { $0.snapshot.stopRequested }) else {
            throw CaptureLifecycle.Failure.cleanupPending
        }
        let entry = CaptureLifecycle(start: start, stop: stop,
                                     startFailureIsTerminal: startFailureIsTerminal) { [weak self] stopped in
            self?.remove(key: key, entry: stopped)
        }
        entries[key] = entry
        return entry
    }

    private func remove(key: ObjectIdentifier, entry: CaptureLifecycle) {
        lock.lock(); defer { lock.unlock() }
        if entries[key] === entry { entries.removeValue(forKey: key) }
    }

    func start(key: ObjectIdentifier, completion: @escaping (Error?) -> Void) {
        lock.lock()
        let entry = entries[key]
        let closing = shuttingDown || drains > 0
        let pending = entries.contains { $0.key != key && $0.value.snapshot.stopRequested }
        lock.unlock()
        guard let entry else { completion(CaptureLifecycle.Failure.closing); return }
        guard !closing, !pending else {
            entry.requestStop()
            completion(closing ? CaptureLifecycle.Failure.closing : CaptureLifecycle.Failure.cleanupPending)
            return
        }
        entry.start(completion: completion)
    }

    func didStop(key: ObjectIdentifier) {
        lock.lock(); let entry = entries[key]; lock.unlock()
        entry?.didStop()
    }

    // Sequential captures can arrive before the preceding asynchronous stop
    // callback. Wait only for that requested cleanup; normal running streams
    // remain owned and untouched. Timeout never grants a new capture.
    func waitForPendingCleanup(timeout: Double,
               now: Clock = { ProcessInfo.processInfo.systemUptime },
               poll: Poll = { _ = CFRunLoopRunInMode(.defaultMode, 0.005, true) }) -> Bool {
        let deadline = now() + max(0, timeout)
        while true {
            lock.lock()
            let closing = shuttingDown || drains > 0
            let pending = entries.values.contains { !$0.snapshot.terminal && $0.snapshot.stopRequested }
            lock.unlock()
            if closing { return false }
            if !pending { return true }
            if now() >= deadline { return false }
            poll()
        }
    }

    @discardableResult
    func stop(keys: [ObjectIdentifier], timeout: Double = 0,
              now: Clock = { ProcessInfo.processInfo.systemUptime },
              poll: Poll = { _ = CFRunLoopRunInMode(.defaultMode, 0.005, true) }) -> Bool {
        lock.lock(); let selected = keys.compactMap { entries[$0] }; lock.unlock()
        selected.forEach { $0.requestStop() }
        let deadline = now() + max(0, timeout)
        while !selected.allSatisfy({ $0.snapshot.terminal }), now() < deadline { poll() }
        return selected.allSatisfy { $0.snapshot.terminal }
    }

    @discardableResult
    func drain(timeout: Double, shuttingDown: Bool = false,
               now: Clock = { ProcessInfo.processInfo.systemUptime },
               poll: Poll = { _ = CFRunLoopRunInMode(.defaultMode, 0.005, true) }) -> Bool {
        lock.lock()
        if shuttingDown { self.shuttingDown = true }
        drains += 1
        let selected = Array(entries.values)
        lock.unlock()
        defer { lock.lock(); drains -= 1; lock.unlock() }
        selected.forEach { $0.requestStop() }
        let deadline = now() + max(0, timeout)
        while !selected.allSatisfy({ $0.snapshot.terminal }), now() < deadline { poll() }
        return selected.allSatisfy { $0.snapshot.terminal }
    }

    var status: [String: Any] {
        lock.lock()
        let selected = Array(entries.values), closing = shuttingDown, draining = drains > 0
        lock.unlock()
        let states = selected.map { $0.snapshot }.filter { !$0.terminal }
        return ["capture_lifecycle_pending_count": states.count,
                "capture_lifecycle_starting_count": states.filter { $0.state == .starting }.count,
                "capture_lifecycle_stopping_count": states.filter { $0.state == .stopping }.count,
                "capture_lifecycle_stop_failed_count": states.filter { $0.state == .stopFailed }.count,
                "capture_lifecycle_start_failed_count": states.filter { $0.startFailed }.count,
                "capture_lifecycle_cleanup_pending_count": states.filter { $0.stopRequested }.count,
                "capture_lifecycle_draining": draining, "capture_lifecycle_shutting_down": closing]
    }
}
