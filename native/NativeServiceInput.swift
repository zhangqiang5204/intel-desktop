import Foundation
import CoreFoundation
import Darwin

// Keep the main run loop servicing capture completion and graceful termination
// while stdin is idle. JSONL decoding and command execution remain on main.
final class NativeServiceInput {
    private final class LineResult {
        private let lock = NSLock()
        private var ready = false
        private var line: String?
        func complete(_ value: String?) { lock.lock(); line = value; ready = true; lock.unlock() }
        func current() -> (Bool, String?) { lock.lock(); defer { lock.unlock() }; return (ready, line) }
    }
    private let inputQueue = DispatchQueue(label: "intel.desktop.jsonl-input")
    private let stateLock = NSLock()
    private var requested = false
    private let termination: DispatchSourceSignal
    var onShutdown: (() -> Void)?
    var shutdownRequested: Bool { stateLock.lock(); defer { stateLock.unlock() }; return requested }

    init() {
        // A closed caller pipe must take the same capture drain path as EOF.
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); self.requested = true; self.stateLock.unlock()
            self.onShutdown?()
        }
        termination.activate()
    }

    func nextLine() -> String? {
        guard !shutdownRequested else { return nil }
        let result = LineResult()
        inputQueue.async { result.complete(readLine(strippingNewline: true)) }
        while !shutdownRequested {
            let (ready, value) = result.current()
            if ready { return value }
            _ = CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
        return nil
    }
}
