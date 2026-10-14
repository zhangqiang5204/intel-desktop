import ApplicationServices
import CoreGraphics
import Foundation

// CopyMultipleAttributeValues returns errors and missing values in array slots.
// Keep their positional correspondence instead of treating them as live values.
struct AXMetadataAttributeResult {
    let result: AXError
    let value: CFTypeRef?

    static func decode(_ result: AXError, _ value: CFTypeRef?) -> AXMetadataAttributeResult {
        guard result == .success, let value else {
            return AXMetadataAttributeResult(result: result, value: nil)
        }
        if CFGetTypeID(value) == CFNullGetTypeID() {
            return AXMetadataAttributeResult(result: .success, value: nil)
        }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let wrapped = unsafeBitCast(value, to: AXValue.self)
            if AXValueGetType(wrapped) == .axError {
                var error = AXError.failure
                guard AXValueGetValue(wrapped, .axError, &error) else {
                    return AXMetadataAttributeResult(result: .failure, value: nil)
                }
                return AXMetadataAttributeResult(result: error, value: nil)
            }
        }
        return AXMetadataAttributeResult(result: .success, value: value)
    }
}

struct AXAttributeBatch {
    let attributes: [String: AXMetadataAttributeResult]
    let usedBatch: Bool

    static func read(names: [String], batch: () -> (AXError, [CFTypeRef]?),
                     single: (String) -> (AXError, CFTypeRef?)) -> AXAttributeBatch {
        let (result, values) = batch()
        var attributes: [String: AXMetadataAttributeResult] = [:]
        if result == .success, let values, values.count == names.count {
            for (name, value) in zip(names, values) {
                attributes[name] = AXMetadataAttributeResult.decode(.success, value)
            }
            return AXAttributeBatch(attributes: attributes, usedBatch: true)
        }
        // An unsupported/failed operation or malformed array cannot establish
        // positional correspondence. Preserve the old individual read path.
        for name in names {
            let (result, value) = single(name)
            attributes[name] = AXMetadataAttributeResult.decode(result, value)
        }
        return AXAttributeBatch(attributes: attributes, usedBatch: false)
    }
}

// inspect-only metadata. Never add AXValue or other editable/body attributes.
// Content reads retain readableValue's separate fresh isSecure check.
struct AXMetadataAttributes {
    static let names = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXEnabled",
        "AXFocused", "AXProtectedContent", "AXPosition", "AXSize", "AXIdentifier"
    ]
    let attributes: [String: AXMetadataAttributeResult]
    let usedBatch: Bool

    // Injectable reads make decoder/fallback tests independent of live AX/UI.
    static func read(batch: () -> (AXError, [CFTypeRef]?),
                     single: (String) -> (AXError, CFTypeRef?)) -> AXMetadataAttributes {
        let result = AXAttributeBatch.read(names: names, batch: batch, single: single)
        return AXMetadataAttributes(attributes: result.attributes, usedBatch: result.usedBatch)
    }

    func string(_ name: String) -> String? {
        attributes[name]?.value as? String
    }

    func boolean(_ name: String) -> Bool? {
        (attributes[name]?.value as? NSNumber)?.boolValue
    }

    var isSecure: Bool {
        string("AXSubrole") == "AXSecureTextField" || string("AXRole") == "AXSecureTextField" ||
        boolean("AXProtectedContent") == true
    }

    var bounds: CGRect? {
        guard let position = attributes["AXPosition"]?.value, let size = attributes["AXSize"]?.value,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let pointValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetType(pointValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

// Observation always gets new metadata before reading a node's content. No
// notification, stored element, or previous result can establish this guard.
extension AXMetadataAttributes {
    var observationSecurityKnown: Bool {
        guard let role = string("AXRole"), !role.isEmpty else { return false }
        for name in ["AXSubrole", "AXProtectedContent"] {
            guard let attribute = attributes[name] else { return false }
            switch attribute.result {
            case .attributeUnsupported, .noValue: continue
            case .success:
                guard attribute.value == nil || (name == "AXSubrole" ? string(name) != nil : boolean(name) != nil) else { return false }
            default: return false
            }
        }
        return true
    }
}

struct AXObservationAttributes {
    static let contentNames = ["AXValue", "AXSelectedTextRange"]
    let metadata: AXMetadataAttributes
    let content: AXAttributeBatch?
    let batchCalls: Int
    let singleCalls: Int
    let deadlineReached: Bool

    // Metadata and content deliberately use separate calls: known secure or
    // unverified nodes must never trigger a content query, including fallback.
    static func read(mayRead: () -> Bool = { true },
                     batch: ([String]) -> (AXError, [CFTypeRef]?),
                     single: (String) -> (AXError, CFTypeRef?)) -> AXObservationAttributes {
        var batchCalls = 0, singleCalls = 0, deadlineReached = false
        func boundedBatch(_ names: [String]) -> (AXError, [CFTypeRef]?) {
            guard mayRead() else { deadlineReached = true; return (.cannotComplete, nil) }
            batchCalls += 1
            return batch(names)
        }
        func boundedSingle(_ name: String) -> (AXError, CFTypeRef?) {
            guard mayRead() else { deadlineReached = true; return (.cannotComplete, nil) }
            singleCalls += 1
            return single(name)
        }
        let metadata = AXMetadataAttributes.read(batch: { boundedBatch(AXMetadataAttributes.names) }, single: boundedSingle)
        let content = metadata.observationSecurityKnown && !metadata.isSecure
            ? AXAttributeBatch.read(names: contentNames, batch: { boundedBatch(contentNames) }, single: boundedSingle) : nil
        return AXObservationAttributes(metadata: metadata, content: content, batchCalls: batchCalls,
                                       singleCalls: singleCalls, deadlineReached: deadlineReached)
    }

    var selectedRange: CFRange? {
        guard let raw = content?.attributes["AXSelectedTextRange"]?.value,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }
}

func axObservationAttributes(_ element: AXUIElement, deadline: Double) -> AXObservationAttributes {
    AXObservationAttributes.read(mayRead: { ProcessInfo.processInfo.systemUptime < deadline }, batch: { names in
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
        return (result, values as? [CFTypeRef])
    }, single: { name in
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (result, value)
    })
}

func axMetadataAttributes(_ element: AXUIElement) -> AXMetadataAttributes {
    AXMetadataAttributes.read(batch: {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, AXMetadataAttributes.names as CFArray, [], &values)
        return (result, values as? [CFTypeRef])
    }, single: { name in
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (result, value)
    })
}
