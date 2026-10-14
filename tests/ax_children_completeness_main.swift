enum TestFailure: Error { case assertion(String) }
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure.assertion(message) }
}
var results: [String: Bool] = [:], failures: [String: String] = [:]
func test(_ name: String, _ body: () throws -> Void) {
    reset()
    do { try body(); results[name] = true }
    catch { results[name] = false; failures[name] = String(describing: error) }
}
test("normal_leaf_zero_unsupported_and_no_value_are_complete") {
    for first: AXError in [.success, .attributeUnsupported, .noValue] {
        for second: AXError in [.success, .attributeUnsupported, .noValue] {
            reset(); source(count: 0, result: first)
            source("AXChildrenInNavigationOrder", count: 0, result: second)
            let values = axNavigationChildren(parent, limit: 10, counts: axChildCounts(parent))
            try expect(values.elements.isEmpty && !values.truncated && copyRequests.isEmpty,
                       "Valid empty/absent sources must not turn normal leaves incomplete")
        }
    }
}
test("real_count_errors_are_unknown_not_empty") {
    for failure: AXError in [.cannotComplete, .failure, .invalidUIElement, .apiDisabled, .illegalArgument, .notImplemented] {
        reset(); source(count: 0, result: failure)
        let counts = axChildCounts(parent)
        let values = axNavigationChildren(parent, limit: 10, counts: counts)
        try expect(counts[0].result == failure && values.truncated && values.elements.isEmpty,
                   "Failed count must preserve its AX error and mark the tree incomplete")
        try expect(copyRequests.isEmpty, "Do not fetch values using an unknown count")
    }
}
test("one_failed_order_does_not_discard_usable_other_children") {
    source(count: 0, result: .cannotComplete)
    source("AXChildrenInNavigationOrder", count: 1, values: [childA])
    let values = axNavigationChildren(parent, limit: 10, counts: axChildCounts(parent))
    try expect(values.truncated && values.elements.count == 1 && CFEqual(values.elements[0], childA),
               "Keep current usable state without claiming complete coverage")
}
test("copy_failure_after_positive_count_cannot_be_an_empty_leaf") {
    for failure: AXError in [.cannotComplete, .attributeUnsupported, .noValue, .invalidUIElement] {
        reset(); source(count: 2, copied: failure, values: nil)
        let values = axNavigationChildren(parent, limit: 10, counts: axChildCounts(parent))
        try expect(values.truncated && values.elements.isEmpty,
                   "Even absence after a known positive count is an inconsistent read")
    }
}
test("malformed_or_short_successful_prefix_is_incomplete") {
    for prefix: [AnyObject]? in [nil, [], [childA], [childA, NSString(string: "not_an_AX_element")]] {
        reset(); source(count: 2, values: prefix)
        let values = axNavigationChildren(parent, limit: 10, counts: axChildCounts(parent))
        try expect(values.truncated, "Nil, short and non-element prefixes cannot prove complete coverage")
        if let prefix, !prefix.isEmpty { try expect(values.elements.count == 1, "Keep the validated element of a partial read") }
    }
}
test("zero_budget_distinguishes_leaf_unknown_and_known_children") {
    for (count, result, truncated): (Int, AXError, Bool) in [(0, .success, false), (0, .noValue, false),
        (0, .cannotComplete, true), (1, .success, true)] {
        reset(); source(count: count, result: result)
        let values = axNavigationChildren(parent, limit: 0, counts: axChildCounts(parent))
        try expect(values.truncated == truncated && copyRequests.isEmpty, "A zero node budget must not erase count failures")
    }
}
test("bounded_union_keeps_identity_deduplication_and_node_limit") {
    source(count: 2, values: [childA, childB])
    source("AXChildrenInNavigationOrder", count: 2, values: [childB, childA])
    var values = axNavigationChildren(parent, limit: 2, counts: axChildCounts(parent))
    try expect(!values.truncated && values.elements.count == 2, "Duplicate orders are a complete two-node union")
    reset(); source(count: 2, values: [childA, childB])
    source("AXChildrenInNavigationOrder", count: 2, values: [childB, childC])
    values = axNavigationChildren(parent, limit: 2, counts: axChildCounts(parent))
    try expect(values.truncated && values.elements.count == 2 && copyRequests == [2, 2],
               "Unique union over the budget stays bounded")
}
test("inspect_menu_and_observation_propagate_failed_counts_at_depth_limit") {
    for consume in [inspectCountReasons, menuCountReasons, observationCountReasons] {
        reset(); source(count: 0, result: .cannotComplete)
        let reasons = consume(parent)
        try expect(reasons == ["child_count_failed"], "Every consumer's count phase must mark unknown coverage before depth branching")
        reset(); source(count: 0, result: .noValue)
        try expect(consume(parent).isEmpty, "Normal absent children stay complete at the depth boundary too")
    }
}
test("inspect_menu_and_observation_report_read_failure_not_node_limit") {
    for consume in [inspectReadReasons, menuReadReasons, observationReadReasons] {
        reset(); source(count: 1, copied: .cannotComplete, values: nil)
        try expect(consume(parent) == ["child_read_failed"], "Read failure must reach the result as its real cause")
        reset(); source(count: 20, values: Array(repeating: childA as AnyObject, count: 16))
        try expect(consume(parent) == ["node_limit"], "A real size limit retains its existing reason")
    }
}
test("menu_root_absence_is_distinct_from_read_failure") {
    for absent: AXError in [.attributeUnsupported, .noValue] {
        try expect(menuRoot(absent, nil).reasons.isEmpty, "App without a menu bar is valid absence")
    }
    for failure: AXError in [.cannotComplete, .failure, .invalidUIElement, .success] {
        try expect(menuRoot(failure, nil).reasons == ["menu_read_failed"], "Failed or malformed menu read must be incomplete")
    }
    try expect(menuRoot(.success, parent).reasons.isEmpty, "Valid menu object stays complete")
}

let report: [String: Any] = ["ok": failures.isEmpty, "cases": results, "failures": failures,
    "live_ax_reads_performed": false, "input_performed": false]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
exit(failures.isEmpty ? 0 : 1)
