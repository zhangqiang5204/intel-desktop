import Foundation
import CoreFoundation

enum TestFailure: Error { case assertion(String), transport }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.assertion(message) }
}

final class FakeCapture {
    typealias Completion = (Error?) -> Void
    private let lock = NSLock()
    private var starts: [Completion] = []
    private var stops: [Completion] = []
    private var calls: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    func start(_ completion: @escaping Completion) {
        lock.lock(); calls.append("start"); starts.append(completion); lock.unlock()
    }
    func stop(_ completion: @escaping Completion) {
        lock.lock(); calls.append("stop"); stops.append(completion); lock.unlock()
    }
    func takeStart() -> Completion { lock.lock(); defer { lock.unlock() }; return starts.removeFirst() }
    func takeStop() -> Completion { lock.lock(); defer { lock.unlock() }; return stops.removeFirst() }
    var key: ObjectIdentifier { ObjectIdentifier(self) }
}

@discardableResult
func register(_ fake: FakeCapture, _ registry: CaptureLifecycleRegistry) throws -> CaptureLifecycle {
    try registry.register(key: fake.key, start: fake.start, stop: fake.stop)
}
func pending(_ registry: CaptureLifecycleRegistry) -> Int {
    registry.status["capture_lifecycle_pending_count"] as! Int
}
func start(_ fake: FakeCapture, _ registry: CaptureLifecycleRegistry) {
    registry.start(key: fake.key) { _ in }
}
var results: [String: Bool] = [:]
var failures: [String: String] = [:]
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); results[name] = true }
    catch { results[name] = false; failures[name] = String(describing: error) }
}

test("unstarted_cleanup_does_not_call_stop") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    try register(fake, registry)
    try expect(registry.stop(keys: [fake.key]), "unused stream must be terminal")
    try expect(fake.events.isEmpty && pending(registry) == 0, "no transport was started")
    var rejected = false
    registry.start(key: fake.key) { rejected = $0 != nil }
    try expect(rejected && fake.events.isEmpty, "closed stream cannot start late")
}
test("normal_start_and_confirmed_stop") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    try register(fake, registry); start(fake, registry); fake.takeStart()(nil)
    try expect(!registry.stop(keys: [fake.key]), "request is not completion")
    try expect(fake.events == ["start", "stop"] && pending(registry) == 1, "stop remains registered")
    fake.takeStop()(nil)
    try expect(registry.stop(keys: [fake.key]) && pending(registry) == 0, "confirmed stop is terminal")
}
test("cancel_before_start_callback_retains_until_stop_callback") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    weak var retained: CaptureLifecycle?
    do { let lifecycle = try register(fake, registry); retained = lifecycle }
    start(fake, registry)
    try expect(!registry.drain(timeout: 0), "pending start cannot drain")
    try expect(fake.events == ["start"] && retained != nil, "no premature stop or object release")
    fake.takeStart()(nil)
    try expect(fake.events == ["start", "stop"] && retained != nil, "late success requires retained stop")
    fake.takeStop()(nil)
    try expect(retained == nil && registry.drain(timeout: 0), "release only after confirmed stop")
}
test("delegate_stop_before_start_success_does_not_skip_cleanup") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    try register(fake, registry); start(fake, registry)
    registry.didStop(key: fake.key)
    try expect(pending(registry) == 1 && fake.events == ["start"], "start still unresolved")
    fake.takeStart()(nil)
    try expect(fake.events == ["start", "stop"], "late start must still be closed")
    fake.takeStop()(nil)
    try expect(pending(registry) == 0, "late-start cleanup complete")
}
test("stop_failure_retry_and_stale_callbacks") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    try register(fake, registry); start(fake, registry); fake.takeStart()(nil)
    _ = registry.stop(keys: [fake.key]); let stale = fake.takeStop(); stale(TestFailure.transport)
    try expect(registry.status["capture_lifecycle_stop_failed_count"] as? Int == 1, "failure remains observable")
    try expect(!registry.drain(timeout: 0) && fake.events == ["start", "stop", "stop"], "one retry per drain")
    stale(nil)
    try expect(pending(registry) == 1, "old callback cannot complete a newer attempt")
    fake.takeStop()(nil)
    stale(TestFailure.transport)
    try expect(registry.drain(timeout: 0) && pending(registry) == 0, "stale failure cannot reopen terminal stream")
}
test("timeout_and_repeated_release_keep_pending_stop") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    try register(fake, registry); start(fake, registry); fake.takeStart()(nil)
    var time = 0.0
    try expect(!registry.stop(keys: [fake.key], timeout: 1, now: { time }, poll: { time += 0.25 }), "timeout must fail")
    try expect(!registry.drain(timeout: 0), "repeat release cannot claim success")
    try expect(fake.events == ["start", "stop"] && pending(registry) == 1, "no duplicate pending stop")
    fake.takeStop()(nil)
    try expect(registry.drain(timeout: 0), "later callback remains consumable")
}
test("multiple_streams_drain_only_after_all_terminal") {
    let registry = CaptureLifecycleRegistry(), first = FakeCapture(), second = FakeCapture()
    try register(first, registry); try register(second, registry)
    start(first, registry); start(second, registry); first.takeStart()(nil)
    try expect(!registry.drain(timeout: 0), "one stream still starting")
    try expect(first.events == ["start", "stop"] && second.events == ["start"], "each stream follows its own start")
    first.takeStop()(nil)
    try expect(pending(registry) == 1 && !registry.drain(timeout: 0), "partial stop is not full drain")
    second.takeStart()(nil); second.takeStop()(nil)
    try expect(registry.drain(timeout: 0), "all streams closed")
}
test("exit_drain_rejects_new_streams_and_waits_for_late_start") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture(), next = FakeCapture()
    try register(fake, registry); start(fake, registry)
    try expect(!registry.drain(timeout: 0, shuttingDown: true), "exit cannot ignore pending start")
    var rejected = false
    do { try register(next, registry) } catch { rejected = true }
    try expect(rejected && next.events.isEmpty, "shutdown registration gate")
    fake.takeStart()(nil); fake.takeStop()(nil)
    try expect(registry.drain(timeout: 0, shuttingDown: true), "exit eventually drains")
    rejected = false
    do { try register(next, registry) } catch { rejected = true }
    try expect(rejected, "shutdown gate stays closed")
}
test("failed_start_is_retained_until_cleanup_confirmed") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    try register(fake, registry); start(fake, registry); fake.takeStart()(TestFailure.transport)
    try expect(fake.events == ["start", "stop"] && pending(registry) == 1, "failed start needs confirmed cleanup")
    fake.takeStop()(TestFailure.transport)
    try expect(!registry.drain(timeout: 0), "failed cleanup stays pending")
    fake.takeStop()(nil)
    try expect(registry.drain(timeout: 0), "successful retry closes failed start")
}
test("cancel_then_definitive_start_rejection_is_terminal_without_stop") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    try registry.register(key: fake.key, start: fake.start, stop: fake.stop,
                          startFailureIsTerminal: { _ in true })
    start(fake, registry)
    try expect(!registry.drain(timeout: 0), "cancel still waits for pending start")
    fake.takeStart()(TestFailure.transport)
    try expect(registry.drain(timeout: 0) && pending(registry) == 0, "definitive rejection can exit")
    try expect(fake.events == ["start"], "do not stop a stream known never to have started")
}
test("new_capture_denied_while_old_cleanup_pending") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture(), next = FakeCapture()
    try register(fake, registry); start(fake, registry)
    _ = registry.stop(keys: [fake.key])
    var rejected = false
    do { try register(next, registry) } catch { rejected = true }
    try expect(rejected, "do not accumulate captures after cancelled request")
    fake.takeStart()(nil); fake.takeStop()(nil)
    try register(next, registry)
    try expect(registry.stop(keys: [next.key]), "new unused stream can close after recovery")
}
test("pending_cleanup_wait_accepts_delayed_stop_before_next_registration") {
    let registry = CaptureLifecycleRegistry(), old = FakeCapture(), next = FakeCapture()
    try register(old, registry); start(old, registry); old.takeStart()(nil)
    _ = registry.stop(keys: [old.key]); let finishStop = old.takeStop()
    var time = 0.0, polls = 0
    let ready = registry.waitForPendingCleanup(timeout: 1.5, now: { time }, poll: {
        polls += 1; time += 0.1
        _ = registry.status // Callback/reentrant inspection must not deadlock.
        if polls == 2 { finishStop(nil) }
    })
    try expect(ready && polls == 2 && pending(registry) == 0, "must consume real delayed stop callback")
    try expect(old.events == ["start", "stop"] && next.events.isEmpty, "waiting neither replays stop nor creates a stream")
    try register(next, registry); start(next, registry); next.takeStart()(nil)
    try expect(next.events == ["start"], "new stream starts only after old cleanup completed")
}
test("pending_cleanup_wait_timeout_retains_entry_and_registration_gate") {
    let registry = CaptureLifecycleRegistry(), old = FakeCapture(), next = FakeCapture()
    weak var retained: CaptureLifecycle?
    do { let entry = try register(old, registry); retained = entry }
    start(old, registry); old.takeStart()(nil); _ = registry.stop(keys: [old.key])
    var time = 0.0
    try expect(!registry.waitForPendingCleanup(timeout: 1.5, now: { time }, poll: { time += 0.25 }), "unconfirmed cleanup must time out")
    var rejected = false
    do { try register(next, registry) } catch CaptureLifecycle.Failure.cleanupPending { rejected = true }
    try expect(rejected && retained != nil && pending(registry) == 1, "timeout must retain real ownership and deny admission")
    try expect(old.events == ["start", "stop"] && next.events.isEmpty, "timeout cannot start or retry transport")
    old.takeStop()(nil)
    try expect(retained == nil && registry.waitForPendingCleanup(timeout: 0), "later real callback remains authoritative")
    try register(next, registry)
}
test("pending_cleanup_wait_does_not_retry_failed_stop") {
    let registry = CaptureLifecycleRegistry(), old = FakeCapture()
    let entry = try register(old, registry)
    start(old, registry); old.takeStart()(nil); _ = registry.stop(keys: [old.key])
    old.takeStop()(TestFailure.transport)
    var time = 0.0
    try expect(!registry.waitForPendingCleanup(timeout: 0.5, now: { time }, poll: { time += 0.1 }), "stop failure is still pending")
    try expect(entry.snapshot.state == .stopFailed && entry.snapshot.stopAttempts == 1, "waiting must not retry a failed stop")
    try expect(old.events == ["start", "stop"], "no implicit transport retry")
}
test("pending_cleanup_wait_never_stops_existing_running_stream") {
    let registry = CaptureLifecycleRegistry(), running = FakeCapture(), next = FakeCapture()
    let entry = try register(running, registry)
    start(running, registry); running.takeStart()(nil)
    var polls = 0, time = 0.0
    try expect(registry.waitForPendingCleanup(timeout: 1.5, now: { time }, poll: { polls += 1; time += 0.1 }), "running capture is not pending cleanup")
    try expect(polls == 0 && entry.snapshot.state == .running && !entry.snapshot.stopRequested, "must not drain a healthy running stream")
    try expect(running.events == ["start"], "no stop request for running stream")
    try register(next, registry)
}
test("pending_cleanup_wait_shutdown_rejects_even_after_all_stops_finish") {
    let registry = CaptureLifecycleRegistry(), old = FakeCapture(), next = FakeCapture()
    try register(old, registry); start(old, registry); old.takeStart()(nil)
    try expect(!registry.drain(timeout: 0, shuttingDown: true), "shutdown waits for actual stop")
    var polls = 0, time = 0.0
    try expect(!registry.waitForPendingCleanup(timeout: 1.5, now: { time }, poll: { polls += 1; time += 0.1 }), "closing registry never admits a new capture")
    try expect(polls == 0 && pending(registry) == 1, "shutdown gate cannot pump an admission wait")
    old.takeStop()(nil)
    try expect(!registry.waitForPendingCleanup(timeout: 0), "empty but shutdown remains closed")
    var rejected = false
    do { try register(next, registry) } catch CaptureLifecycle.Failure.closing { rejected = true }
    try expect(rejected && next.events.isEmpty, "registration guard survives completed shutdown cleanup")
}
test("pending_cleanup_wait_cancelled_start_needs_both_callbacks") {
    let registry = CaptureLifecycleRegistry(), old = FakeCapture(), next = FakeCapture()
    weak var retained: CaptureLifecycle?
    do { let entry = try register(old, registry); retained = entry }
    start(old, registry); _ = registry.stop(keys: [old.key])
    try expect(old.events == ["start"] && retained != nil, "cancel must retain unresolved start without premature stop")
    var time = 0.0, polls = 0, rejectedPhases = 0
    let ready = registry.waitForPendingCleanup(timeout: 1, now: { time }, poll: {
        polls += 1; time += 0.1
        do { try register(next, registry) } catch CaptureLifecycle.Failure.cleanupPending { rejectedPhases += 1 } catch { }
        if polls == 1 { old.takeStart()(nil) }
        if polls == 2 { old.takeStop()(nil) }
    })
    try expect(ready && polls == 2 && rejectedPhases == 2, "start completion alone must not release the admission gate")
    try expect(retained == nil && old.events == ["start", "stop"] && next.events.isEmpty, "release only after real stop completion")
    try register(next, registry)
}
test("pending_cleanup_wait_detects_shutdown_while_polling") {
    let registry = CaptureLifecycleRegistry(), old = FakeCapture()
    try register(old, registry); start(old, registry); old.takeStart()(nil)
    _ = registry.stop(keys: [old.key]); let finishStop = old.takeStop()
    var time = 0.0, polls = 0
    let ready = registry.waitForPendingCleanup(timeout: 1, now: { time }, poll: {
        polls += 1; time += 0.1
        _ = registry.drain(timeout: 0, shuttingDown: true)
        finishStop(nil)
    })
    try expect(!ready && polls == 1 && pending(registry) == 0, "shutdown wins even when cleanup completes during the same poll")
    try expect(old.events == ["start", "stop"], "shutdown must not duplicate an already pending stop")
}
test("pending_cleanup_wait_pumps_default_runloop_without_capturing") {
    let registry = CaptureLifecycleRegistry(), key = NSObject()
    var stopCalls = 0
    try registry.register(key: ObjectIdentifier(key), start: { completion in completion(nil) }, stop: { completion in
        stopCalls += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { completion(nil) }
    })
    registry.start(key: ObjectIdentifier(key)) { _ in }
    _ = registry.stop(keys: [ObjectIdentifier(key)])
    try expect(registry.waitForPendingCleanup(timeout: 1), "admission wait must pump the real completion callback")
    try expect(stopCalls == 1 && pending(registry) == 0, "one fake stop is confirmed, never replayed")
}
test("synchronous_reentrant_callbacks_do_not_hold_locks") {
    let registry = CaptureLifecycleRegistry(), key = NSObject()
    var stopCalls = 0, callbackCount = 0
    try registry.register(key: ObjectIdentifier(key), start: { completion in completion(nil) }, stop: { completion in
        stopCalls += 1; _ = registry.status; completion(nil)
    })
    registry.start(key: ObjectIdentifier(key)) { _ in
        callbackCount += 1
        if !registry.drain(timeout: 0) { callbackCount += 100 }
    }
    try expect(callbackCount == 1 && stopCalls == 1 && pending(registry) == 0, "reentrant callback must finish")
}
test("concurrent_stop_requests_issue_one_transport_stop") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    let lifecycle = try register(fake, registry); start(fake, registry); fake.takeStart()(nil)
    let group = DispatchGroup()
    for _ in 0..<32 {
        group.enter(); DispatchQueue.global().async { lifecycle.requestStop(); group.leave() }
    }
    try expect(group.wait(timeout: .now() + 2) == .success, "stop calls deadlocked")
    try expect(fake.events == ["start", "stop"], "coalesce simultaneous requests")
    fake.takeStop()(nil)
    try expect(pending(registry) == 0, "concurrent cleanup completed")
}
test("delegate_confirmation_and_out_of_order_stop_callback") {
    let registry = CaptureLifecycleRegistry(), fake = FakeCapture()
    try register(fake, registry); start(fake, registry); let duplicateStart = fake.takeStart(); duplicateStart(nil)
    _ = registry.stop(keys: [fake.key]); let lateStop = fake.takeStop()
    registry.didStop(key: fake.key)
    duplicateStart(nil); lateStop(TestFailure.transport)
    try expect(pending(registry) == 0 && fake.events == ["start", "stop"], "late callbacks cannot resurrect capture")
}
test("drain_pumps_main_runloop_for_start_and_stop_callbacks") {
    let registry = CaptureLifecycleRegistry(), key = NSObject()
    try registry.register(key: ObjectIdentifier(key), start: { completion in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { completion(nil) }
    }, stop: { completion in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { completion(nil) }
    })
    registry.start(key: ObjectIdentifier(key)) { _ in }
    try expect(registry.drain(timeout: 2, shuttingDown: true), "main callbacks must run during drain")
    try expect(pending(registry) == 0, "runloop drain finished")
}

let output: [String: Any] = ["ok": failures.isEmpty, "cases": results, "failures": failures,
                           "capture_performed": false, "input_performed": false]
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
exit(failures.isEmpty ? 0 : 1)
