// Creating an AX object reference does not resolve/read an application. All
// count/copy IPC symbols in the extracted production helpers are replaced below.
let parent = AXUIElementCreateApplication(900001)
let childA = AXUIElementCreateApplication(900002)
let childB = AXUIElementCreateApplication(900003)
let childC = AXUIElementCreateApplication(900004)
var countFixtures: [String: (Int, AXError)] = [:]
var copyFixtures: [String: (AXError, [AnyObject]?)] = [:]
var countReads = 0, copyRequests: [Int] = []
func reset() { countFixtures = [:]; copyFixtures = [:]; countReads = 0; copyRequests = [] }
func fakeCount(_ element: AXUIElement, _ name: CFString, _ result: UnsafeMutablePointer<CFIndex>) -> AXError {
    countReads += 1
    let fixture = countFixtures[name as String] ?? (0, .attributeUnsupported)
    result.pointee = fixture.0; return fixture.1
}
func fakeCopy(_ element: AXUIElement, _ name: CFString, _ index: CFIndex, _ count: CFIndex,
              _ result: UnsafeMutablePointer<CFArray?>) -> AXError {
    copyRequests.append(count)
    let fixture = copyFixtures[name as String] ?? (.cannotComplete, nil)
    result.pointee = fixture.1.map { $0 as CFArray }; return fixture.0
}
func source(_ name: String = kAXChildrenAttribute, count: Int, result: AXError = .success,
            copied: AXError = .success, values: [AnyObject]? = []) {
    countFixtures[name] = (count, result); copyFixtures[name] = (copied, values)
}
