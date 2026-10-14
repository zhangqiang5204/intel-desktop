import Foundation
import CoreGraphics

struct FixtureFailure: Error { let code: String }
func fail(_ code: String, _ message: String) -> FixtureFailure { FixtureFailure(code: code) }
func visualContains(_ outer: CGRect, _ inner: CGRect) -> Bool { outer.contains(inner) }
func visualMergeOCRRows(_ groups: [[[String: Any]]]) -> [[String: Any]] { groups.flatMap { $0 } }
struct VisualIdentity: Equatable { let frame: CGRect }
struct VisualFrame { let image = 0 }
struct OCRColorProfile { init(_ image: Int) {} }
typealias Batch = (rows: [[String: Any]], regionRows: [[[String: Any]]], stageMS: [String: Double])

// PRODUCTION_SUPPORT

final class Harness {
    let ocrCacheLock = NSLock()
    var ocrCacheIdentity: VisualIdentity?
    var ocrCacheGeneration: UInt64 = 0
    var ocrCacheRows: [Int] = []
    var sourceOverride: [Int]?
    var expectedWorkers = 3
    var failIndex: Int?
    var invalidateIndex: Int?
    private let condition = NSCondition()
    private var entered = 0
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var calls: [Int] = []
    private(set) var lanes: [UInt: [Int]] = [:]
    private var regionIDs: [CGRect] = []

    func ocrRegionSources(_ frame: VisualFrame, identity: VisualIdentity, regions: [CGRect], now: Double) -> [Int] {
        regionIDs = regions
        return sourceOverride ?? Array(regions.indices)
    }

    func ocr(_ frame: VisualFrame, identity: VisualIdentity, region: CGRect, cacheGeneration: UInt64,
             colorProfile: OCRColorProfile?, timing: VisualCaptureMetrics?) throws -> [[String: Any]] {
        condition.lock()
        let index = regionIDs.firstIndex(of: region)!
        calls.append(index); lanes[UInt(bitPattern: pthread_self()), default: []].append(index)
        entered += 1; active += 1; maximumActive = max(maximumActive, active)
        if entered >= expectedWorkers { condition.broadcast() }
        let deadline = Date(timeIntervalSinceNow: 3)
        while entered < expectedWorkers {
            if !condition.wait(until: deadline) { condition.unlock(); throw fail("test_barrier_timeout", "") }
        }
        active -= 1; condition.unlock()
        if invalidateIndex == index {
            ocrCacheLock.lock(); ocrCacheGeneration += 1; ocrCacheLock.unlock()
        }
        if failIndex == index { throw fail("fixture_roi_failed", "") }
        timing?.mark("recognition_and_rows")
        return [["text": "roi_\(index)", "bounds": region]]
    }

    // PRODUCTION_SCHEDULER
}

let identity = VisualIdentity(frame: CGRect(x: 356, y: 25, width: 855, height: 1079))
let frame = VisualFrame()
let verificationRegion = CGRect(x: 686, y: 943, width: 495, height: 113)
let safetyRegion = verificationRegion.insetBy(dx: -12, dy: -12).intersection(identity.frame)

func postEdit(_ harness: Harness, scoped: Bool = true) throws -> Batch {
    let nativeCommandScope: String? = scoped ? "task_operation" : nil
    var postEditProof: Batch?
    // PRODUCTION_POST_EDIT_CALL
    return postEditProof!
}

var cases: [[String: Any]] = []
func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]) }
func rows(_ result: Batch) -> [String] { result.regionRows.map { $0.first?["text"] as? String ?? "missing" } }
func errorCode(_ body: () throws -> Void) -> String? { do { try body(); return nil } catch let error as FixtureFailure { return error.code } catch { return "unexpected" } }

let scoped = Harness()
let scopedResult = try postEdit(scoped)
check("scoped_outputs_keep_original_ROI_indices", rows(scopedResult) == ["roi_0", "roi_1", "roi_2", "roi_3"])
check("scoped_each_ROI_executes_once", scoped.calls.sorted() == [0, 1, 2, 3])
check("scoped_header_then_composer_share_one_lane", scoped.lanes.values.contains([0, 1]))
check("scoped_security_starts_in_own_lane", scoped.lanes.values.contains([2]))
check("scoped_Send_starts_in_own_lane", scoped.lanes.values.contains([3]))
check("scoped_parallelism_remains_three", scoped.maximumActive == 3)
check("scoped_timing_indices_stay_attached_to_original_ROIs", (0..<4).allSatisfy { scopedResult.stageMS["roi_\($0)_recognition_and_rows"] != nil })

// This model uses the recorded C per-ROI durations only. It proves the
// scheduling dependency changed; it is not a live wall-clock benchmark.
let cDuration = [248.0, 438.0, 690.0, 654.0]
let modelCriticalPath = scoped.lanes.values.map { $0.reduce(0.0) { $0 + cDuration[$1] } }.max()!
check("recorded_C_ROI_dependency_model_902_to_690ms", modelCriticalPath == 690)

let ordinary = Harness()
let regions = (0..<4).map { CGRect(x: 400 + $0 * 40, y: 100, width: 20, height: 20) }
_ = try ordinary.ocrRegions(frame, identity: identity, regions: regions, measurePerformance: true)
check("ordinary_four_ROI_call_keeps_original_packing", ordinary.lanes.values.contains([0, 3]))

let unscoped = Harness()
let unscopedResult = try postEdit(unscoped, scoped: false)
check("unscoped_post_edit_keeps_three_ROIs", rows(unscopedResult) == ["roi_0", "roi_1", "roi_2"] && unscoped.calls.sorted() == [0, 1, 2])

let reused = Harness(); reused.sourceOverride = [0, 1, 2, 0]
let reusedResult = try postEdit(reused)
check("deduplicated_jobs_keep_source_mapping", rows(reusedResult) == ["roi_0", "roi_1", "roi_2", "roi_0"] && reused.calls.sorted() == [0, 1, 2])
check("deduplicated_timing_remains_reuse", reusedResult.stageMS["roi_3_same_frame_reuse"] == 0)

let failed = Harness(); failed.failIndex = 2
check("failed_security_ROI_still_fails_whole_batch", errorCode { _ = try postEdit(failed) } == "fixture_roi_failed")
check("failed_batch_still_joins_every_started_ROI", failed.calls.sorted() == [0, 1, 2, 3])
let changed = Harness(); changed.invalidateIndex = 2
check("changed_cache_generation_still_fails_batch", errorCode { _ = try postEdit(changed) } == "visual_target_changed")

let report: [String: Any] = ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "cases": cases,
    "capture_performed": false, "input_performed": false, "recorded_C_ROI_model_ms": modelCriticalPath]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
if report["ok"] as? Bool != true { exit(1) }
