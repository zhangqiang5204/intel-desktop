import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

// The visual fallback is restricted to the observed WeChat AX shell. No capture
// starts at service startup. One bounded set of display fragments represents the
// exact target window; only its latest composite frame/snapshot is retained.
struct VisualIdentity: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let topology: String
}

func visualRect(_ raw: Any?, name: String = "region") throws -> CGRect {
    guard let fields = raw as? [String: Any] else { throw fail("invalid_request", "\(name) must be a rectangle object") }
    let width = try number(fields, "width")
    let height = try number(fields, "height")
    guard width > 0, height > 0 else { throw fail("invalid_request", "\(name) must have positive dimensions") }
    return try CGRect(x: number(fields, "x"), y: number(fields, "y"), width: width, height: height)
}

func visualContains(_ outer: CGRect, _ inner: CGRect) -> Bool {
    inner.width > 0 && inner.height > 0 && inner.minX >= outer.minX && inner.minY >= outer.minY &&
        inner.maxX <= outer.maxX && inner.maxY <= outer.maxY
}

func visualNavigationTargetKind(_ request: [String: Any]) throws -> String {
    guard let kind = try string(request, "navigation_target_kind", required: false) else { return "text" }
    guard request["command"] as? String == "visual_click", request["control_kind"] as? String == "navigation",
          ["text", "icon"].contains(kind) else {
        throw fail("invalid_request", "navigation_target_kind is text or icon on navigation visual_click only")
    }
    if kind == "icon" {
        guard request["target_text"] == nil else { throw fail("invalid_request", "Icon navigation uses an explicit point, not target_text") }
        let point = try CGPoint(x: number(request, "x"), y: number(request, "y"))
        guard pointIsInsideRect(point, try visualRect(request["control_rect"], name: "control_rect")) else {
            throw fail("coordinate_outside_control", "Icon point must lie inside the confirmed control rectangle")
        }
    }
    return kind
}

// The observed 1x full search-control crop (including its magnifier) needs
// 2x OCR sampling. The narrower editable-query lane and every other ROI stay
// native: offline evidence showed scaling that lane loses a real character.
func visualSearchControlNeedsOCRUpsample(actual: CGRect, window: CGRect, scaleX: Double, scaleY: Double) -> Bool {
    guard abs(scaleX - 1) < 0.000001, abs(scaleY - 1) < 0.000001 else { return false }
    let local = CGRect(x: 70, y: window.height * 0.014, width: 210, height: window.height * 0.025).integral
    return actual == local.offsetBy(dx: window.minX, dy: window.minY) && local.height <= 48
}
func visualSearchControlOCRImage(_ original: CGImage, actual: CGRect, window: CGRect,
                                 scaleX: Double, scaleY: Double) throws -> CGImage {
    guard visualSearchControlNeedsOCRUpsample(actual: actual, window: window, scaleX: scaleX, scaleY: scaleY) else { return original }
    guard original.width <= 210, original.height <= 48,
          let context = CGContext(data: nil, width: original.width * 2, height: original.height * 2,
              bitsPerComponent: 8, bytesPerRow: 0, space: original.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw fail("visual_OCR_preprocessing_failed", "Could not allocate the bounded 1x search-control OCR input")
    }
    context.interpolationQuality = .high
    context.draw(original, in: CGRect(x: 0, y: 0, width: original.width * 2, height: original.height * 2))
    guard let image = context.makeImage() else { throw fail("visual_OCR_preprocessing_failed", "Could not render search-control OCR input") }
    return image
}

func visualOCRBounds(_ normalized: CGRect, region: CGRect) -> CGRect {
    CGRect(x: region.minX + normalized.minX * region.width,
           y: region.minY + (1 - normalized.maxY) * region.height,
           width: normalized.width * region.width, height: normalized.height * region.height)
}

func visualNormalizedText(_ text: String) -> String {
    let invisible: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]
    return String(String.UnicodeScalarView(text.unicodeScalars.filter {
        !CharacterSet.whitespacesAndNewlines.contains($0) && !invisible.contains($0.value)
    }))
}

func visualUniqueOCRPoint(_ rows: [[String: Any]], target: String, region: CGRect) throws -> CGPoint? {
    let exact = rows.filter { row in
        guard let text = row["text"] as? String, let bounds = try? visualRect(row["bounds"]), visualContains(region, bounds) else { return false }
        return visualNormalizedText(text) == visualNormalizedText(target)
    }
    guard exact.count <= 1 else { throw fail("visual_navigation_ambiguous", "More than one visible OCR row exactly matches target_text in the selected region") }
    guard let row = exact.first, let bounds = try? visualRect(row["bounds"]) else { return nil }
    return CGPoint(x: bounds.midX, y: bounds.midY)
}
// The observed fixed-width WeChat sidebar search field has a magnifier at its
// left and a clear button at its right. Neither is part of the editable query.
// Keep the whole observed text lane; never trim OCR characters such as Q/x/&.
func visualSearchTextRegion(window: CGRect, control: CGRect) throws -> CGRect {
    let text = CGRect(x: window.minX + 91, y: control.minY, width: 156, height: min(control.maxY, window.minY + 35) - control.minY)
    guard visualContains(window, control), visualContains(control, text) else {
        throw fail("visual_search_value_region_unavailable", "Confirmed search control must contain the complete observed query-text region")
    }
    return text
}

func visualDraftSequence(_ value:String)->String {
    value.replacingOccurrences(of:"\r",with:"").replacingOccurrences(of:"\n",with:"")
}

// Whole-draft clearing has no prefix/reflow semantics. Both observations must
// retain the complete composer and exact recipient in one fresh visible frame.
func visualClearDraftHeaderText(_ value: String) -> String {
    // Match the caller's complete-title whitespace normalization, retaining
    // letters, counts, punctuation, ZWJ/ZWNJ and every other format character.
    String(String.UnicodeScalarView(value.unicodeScalars.filter {
        !$0.properties.isWhitespace && !(0x1C...0x1F).contains($0.value) && $0.value != 0x200B && $0.value != 0xFEFF
    }))
}

func visualClearDraftHeaderMatchCount(_ rows: [[String: Any]], title: String) -> Int {
    let expected = visualClearDraftHeaderText(title)
    guard !expected.isEmpty else { return 0 }
    return rows.filter { row in
        (row["text"] as? String).map { visualClearDraftHeaderText($0).utf16.elementsEqual(expected.utf16) } ?? false
    }.count
}

func visualVoiceComposerRegion(_ window: CGRect) -> CGRect {
    CGRect(x: window.minX + 330, y: window.minY + window.height * 0.85,
           width: window.width - 360, height: window.height * 0.105)
}

func visualVoiceHintText(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.filter {
        !$0.properties.isWhitespace && !(0x1C...0x1F).contains($0.value)
    }))
}

func visualVoiceHintRowMatches(_ row: [String: Any], hint: [String: Any]) -> Bool {
    guard let text = row["text"] as? String, let expected = hint["text"] as? String,
          let bounds = try? visualRect(row["bounds"]), let expectedBounds = try? visualRect(hint["bounds"]) else { return false }
    return text.utf16.elementsEqual(expected.utf16) && bounds == expectedBounds
}

// The observed light-theme voice placeholder is text, not an empty OCR result.
// Prove that one exact row from its current pixels; never erase a black user
// draft with the same words, a generic placeholder, or an unknown caret glyph.
func visualEmptyComposerHint(_ frame: VisualFrame, window: CGRect, rows: [[String: Any]], now: Double,
                             maximumAge: Double = 2) -> [String: Any]? {
    let composer = visualVoiceComposerRegion(window)
    guard visualContains(window, composer), let coverage = frame.capturedRegions,
          visualCovered(composer, by: coverage), !frame.idleConfirmed,
          frame.time.isFinite, now.isFinite, now >= frame.time,
          (maximumAge == 2 || maximumAge == 5), now - frame.time <= maximumAge,
          now - frame.time < 5 else { return nil }
    let candidates = rows.filter { row in
        guard let text = row["text"] as? String, visualVoiceHintText(text) == "按住鼠标语音输入文字",
              let bounds = try? visualRect(row["bounds"]), visualContains(composer, bounds) else { return false }
        return true
    }
    guard candidates.count == 1, let row = candidates.first,
          let bounds = try? visualRect(row["bounds"]),
          (4...18).contains(bounds.minX - composer.minX), (5...30).contains(bounds.minY - composer.minY),
          (120...185).contains(bounds.width), (10...23).contains(bounds.height) else { return nil }
    let sx = Double(frame.image.width) / window.width, sy = Double(frame.image.height) / window.height
    guard sx.isFinite, sy.isFinite, (0.95...2.05).contains(sx), (0.95...2.05).contains(sy) else { return nil }
    let pixels = CGRect(x: (bounds.minX-window.minX)*sx, y: (bounds.minY-window.minY)*sy,
                        width: bounds.width*sx, height: bounds.height*sy).integral
    guard let crop = frame.image.cropping(to: pixels), let raw = try? visualRGBA(crop),
          let data = raw.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
    var background = 0, grayCore = 0, caret = 0
    var caretCore = Set<Int>()
    var caretFringe: [(x: Int, y: Int, r: Double, g: Double, b: Double)] = []
    var caretMinX = raw.width, caretMaxX = -1, caretMinY = raw.height, caretMaxY = -1
    for y in 0..<raw.height { for x in 0..<raw.width {
        let i = y*raw.bytesPerRow+x*4, r = Int(p[i]), g = Int(p[i+1]), b = Int(p[i+2])
        guard p[i+3] >= 250 else { return nil }
        let low = min(r,g,b), high = max(r,g,b)
        if r <= 60, (155...215).contains(g), (70...150).contains(b), g-r >= 90, g-b >= 35 {
            caret += 1; caretMinX = min(caretMinX,x); caretMaxX = max(caretMaxX,x)
            caretMinY = min(caretMinY,y); caretMaxY = max(caretMaxY,y)
            caretCore.insert(y*raw.width+x)
        } else {
            // Any neutral dark ink or unknown colour is user content/unknown,
            // including a black caret. The known gray glyph core is 159/159/166.
            guard low >= 145 else { return nil }
            if high-low > 18 {
                // A mixed-scale fragment adds a one-pixel pale-green fringe
                // around the known solid caret. Its provenance is checked
                // below against adjacent core pixels, never accepted by hue.
                caretFringe.append((x,y,Double(r),Double(g),Double(b)))
                continue
            }
            if low >= 235, high-low <= 12 { background += 1 }
            if (145...190).contains(low), high <= 205 { grayCore += 1 }
        }
    } }
    let total = raw.width*raw.height
    guard Double(background)/Double(total) >= 0.45,
          Double(grayCore)/Double(total) >= 0.04, Double(grayCore)/Double(total) <= 0.40,
          Double(grayCore) >= 50*sx*sy else { return nil }
    if caret > 0 {
        // The saved 2x frame places its 2pt caret 4pt into Vision's text box.
        guard Double(caretMaxX+1) <= ceil(7*sx), Double(caretMaxX-caretMinX+1) <= ceil(2.5*sx),
              Double(caretMaxY-caretMinY+1) >= 6*sy, Double(caretMaxY-caretMinY+1) <= 23*sy else { return nil }
    }
    for fringe in caretFringe {
        var verified = false
        for y in max(0,fringe.y-1)...min(raw.height-1,fringe.y+1) {
            for x in max(0,fringe.x-1)...min(raw.width-1,fringe.x+1) where caretCore.contains(y*raw.width+x) {
                let i = y*raw.bytesPerRow+x*4, r = Double(p[i]), g = Double(p[i+1]), b = Double(p[i+2])
                let mix = (fringe.g-fringe.r)/(g-r)
                guard fringe.g > fringe.b, mix > 0, mix <= 0.5 else { continue }
                // Recover the underlying neutral gray/light pixel from the
                // observed green core and its interpolated neighbor. The
                // original gray/opacity floor and color spread remain intact.
                let neutral = [(fringe.r-mix*r)/(1-mix), (fringe.g-mix*g)/(1-mix), (fringe.b-mix*b)/(1-mix)].map { $0.rounded() }
                if neutral.min()! >= 145, neutral.max()! <= 255, neutral.max()!-neutral.min()! <= 18 { verified = true }
            }
        }
        guard verified else { return nil }
    }
    return ["verified": true, "kind": "wechat_voice_placeholder", "text": row["text"]!, "bounds": rectJSON(bounds),
        "frame_complete_serial": frame.completeSerial, "composer_region": rectJSON(composer),
        "proof_scope": maximumAge == 2 ? "input_value_observation" : "snapshot_semantics_only",
        "proof_frame_age_ms": (now-frame.time)*1000, "proof_max_age_ms": maximumAge*1000,
        "verification_source": "same_frame_OCR_geometry_and_gray_glyph_pixels", "style": "light_gray_on_light_background",
        "pixel_evidence": ["gray_core_pixels": grayCore, "light_background_pixels": background,
            "left_green_caret_pixels": caret, "left_green_caret_antialias_pixels": caretFringe.count,
            "sampled_pixels": total, "dark_or_unknown_pixels": 0,
            "pixel_to_point_scale_x": sx, "pixel_to_point_scale_y": sy]]
}

func visualRowsWithoutEmptyComposerHint(_ frame: VisualFrame, window: CGRect, rows: [[String: Any]], now: Double) -> [[String: Any]] {
    guard let hint = visualEmptyComposerHint(frame, window: window, rows: rows, now: now) else { return rows }
    return rows.filter { !visualVoiceHintRowMatches($0, hint: hint) }
}

struct VisualComposerCaretGlyph {
    let row: CGRect
    let glyph: CGRect
}

// The observed caret is a uniform 2pt x 16.5pt green component on a light
// composer. Bind it to Vision's same-frame final pipe glyph before masking
// only those green pixels. Black pipes/lines and every other pixel survive.
// No expected text participates in either the pixel proof or the new OCR.
func visualComposerTailCaretImage(_ original: CGImage, actual: CGRect, window: CGRect,
                                  glyphs: [VisualComposerCaretGlyph]) -> (image: CGImage, bounds: CGRect)? {
    let composer = visualVoiceComposerRegion(window)
    let sx = Double(original.width) / actual.width, sy = Double(original.height) / actual.height
    guard !glyphs.isEmpty, glyphs.count <= 128, visualContains(actual, composer),
          sx.isFinite, sy.isFinite, (0.95...2.05).contains(sx), (0.95...2.05).contains(sy), abs(sx-sy) < 0.01,
          original.bitsPerPixel == 32, original.bitsPerComponent == 8,
          original.alphaInfo == .premultipliedLast || original.alphaInfo == .last,
          let data = original.dataProvider?.data, let p = CFDataGetBytePtr(data),
          CFDataGetLength(data) >= (original.height-1)*original.bytesPerRow + original.width*4 else { return nil }
    var accepted: (points: Set<Int>, bounds: CGRect, background: [UInt8])?
    for witness in glyphs {
        let row = witness.row, glyph = witness.glyph
        guard visualContains(composer, row), visualContains(composer, glyph),
              (8...30).contains(row.height), (0.5...8).contains(glyph.width),
              abs(glyph.maxX-row.maxX) <= 2, abs(glyph.midY-row.midY) <= 4 else { continue }
        let scan = glyph.insetBy(dx: -3, dy: -5).intersection(composer)
        let x0 = max(0, Int(floor((scan.minX-actual.minX)*sx))), x1 = min(original.width, Int(ceil((scan.maxX-actual.minX)*sx)))
        let y0 = max(0, Int(floor((scan.minY-actual.minY)*sy))), y1 = min(original.height, Int(ceil((scan.maxY-actual.minY)*sy)))
        guard x0 < x1, y0 < y1 else { continue }
        var points = Set<Int>(), colors: [[Int]] = []
        for y in y0..<y1 { for x in x0..<x1 {
            let i = y*original.bytesPerRow+x*4, r = Int(p[i]), g = Int(p[i+1]), b = Int(p[i+2])
            if p[i+3] >= 250, r <= 60, (155...215).contains(g), (70...150).contains(b), g-r >= 90, g-b >= 35 {
                points.insert(y*original.width+x); colors.append([r,g,b])
            }
        } }
        guard let first = points.first else { continue }
        var remaining = points; remaining.remove(first)
        var queue = [first], index = 0, l = first%original.width, r = l, t = first/original.width, b = t
        while index < queue.count {
            let value = queue[index]; index += 1; let x = value%original.width, y = value/original.width
            l = min(l,x); r = max(r,x); t = min(t,y); b = max(b,y)
            for yy in max(y0,y-1)...min(y1-1,y+1) { for xx in max(x0,x-1)...min(x1-1,x+1) {
                let next = yy*original.width+xx; if remaining.remove(next) != nil { queue.append(next) }
            } }
        }
        let bounds = CGRect(x: actual.minX+Double(l)/sx, y: actual.minY+Double(t)/sy,
            width: Double(r-l+1)/sx, height: Double(b-t+1)/sy)
        guard remaining.isEmpty, (0.5...2.5).contains(bounds.width), (8...23).contains(bounds.height),
              Double(points.count)/Double((r-l+1)*(b-t+1)) >= 0.95,
              visualContains(glyph.insetBy(dx: -2, dy: -5), bounds), abs(bounds.maxX-row.maxX) <= 3,
              abs(bounds.midY-row.midY) <= 5,
              (0..<3).allSatisfy({ channel in
                  (colors.map { $0[channel] }.max()! - colors.map { $0[channel] }.min()!) <= 2
              }) else { continue }
        let haloX = max(1, Int(ceil(sx))), haloY = max(1, Int(ceil(sy)))
        guard l-haloX >= 0, r+haloX < original.width, t-haloY >= 0, b+haloY < original.height else { continue }
        var light = true
        for y in (t-haloY)...(b+haloY) { for x in (l-haloX)...(r+haloX) where !points.contains(y*original.width+x) {
            let i = y*original.bytesPerRow+x*4, values = [Int(p[i]),Int(p[i+1]),Int(p[i+2])]
            // The observed tail caret has two neighboring black Chinese-ink
            // pixels in its left halo. Neutral ink may precede the caret;
            // right/top/bottom stay light and colored neighbors still reject.
            let leftInk = x < l && y >= t && y <= b
            if p[i+3] < 250 || values.max()!-values.min()! > 12 || (values.min()! < 225 && !leftInk) { light = false }
        } }
        guard light else { continue }
        // More than one compatible component/row is ambiguous; preserve it.
        guard accepted == nil else { return nil }
        let sample = ((t+b)/2)*original.bytesPerRow+(r+haloX)*4
        accepted = (points, bounds, Array(UnsafeBufferPointer(start: p.advanced(by: sample), count: 4)))
    }
    guard let accepted else { return nil }
    let stride = original.width*4
    var pixels = [UInt8](repeating: 0, count: stride*original.height)
    for y in 0..<original.height {
        pixels.replaceSubrange((y*stride)..<((y+1)*stride), with: UnsafeBufferPointer(start: p.advanced(by: y*original.bytesPerRow), count: stride))
    }
    for point in accepted.points {
        let i = (point/original.width)*stride+(point%original.width)*4
        pixels.replaceSubrange(i..<(i+4), with: accepted.background)
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: original.width, height: original.height, bitsPerComponent: 8, bitsPerPixel: 32,
              bytesPerRow: stride, space: original.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: original.bitmapInfo,
              provider: provider, decode: nil, shouldInterpolate: original.shouldInterpolate, intent: original.renderingIntent) else { return nil }
    return (image, accepted.bounds)
}

func visualPrefixFinalValueMatches(_ frame: VisualFrame, window: CGRect, rows: [[String: Any]], expected: String, now: Double) -> Bool {
    if expected.isEmpty { return visualRowsWithoutEmptyComposerHint(frame, window: window, rows: rows, now: now).isEmpty }
    return visualDraftSequence(rows.compactMap { $0["text"] as? String }.joined(separator: "\n")) == visualDraftSequence(expected)
}

func visualClearDraftPostDiagnostic(_ frame: VisualFrame, window: CGRect, control: CGRect,
                                    composerRows: [[String: Any]], headerRows: [[String: Any]],
                                    title: String, observationCount: Int, now: Double) -> [String: Any] {
    let valueRows = visualRowsWithoutEmptyComposerHint(frame, window: window, rows: composerRows, now: now)
    return ["phase": "post_clear_observation", "observation_count": observationCount,
     "header_literal_match_count": headerRows.filter { ($0["text"] as? String).map { $0.utf16.elementsEqual(title.utf16) } ?? false }.count,
     "header_normalized_match_count": visualClearDraftHeaderMatchCount(headerRows, title: title),
     "header_normalization": "whitespace_U200B_UFEFF_only", "header_row_count": headerRows.count,
     "composer_row_count": composerRows.count, "composer_value_row_count": valueRows.count, "composer_empty": valueRows.isEmpty,
     "empty_composer_hint_verified": valueRows.count != composerRows.count,
     "composer_rows_within_return_limits": composerRows.count <= 100 && composerRows.allSatisfy {
         ($0["text"] as? String).map { !$0.isEmpty && $0.count < 1000 } ?? false
     },
     "complete_composer_coverage": frame.capturedRegions.map { visualCovered(control, by: $0) } ?? false,
     "complete_header_coverage": frame.capturedRegions.map { visualCovered(visualSubmitHeader(window), by: $0) } ?? false,
     "frame_complete_serial": frame.completeSerial, "frame_age_ms": (now - frame.time) * 1000]
}

func visualClearDraftObservation(_ frame: VisualFrame, window: CGRect, control: CGRect,
                                 composerRows: [[String: Any]], headerRows: [[String: Any]],
                                 expected: String, title: String, now: Double) throws -> Bool {
    let header = visualSubmitHeader(window)
    guard visualContains(window, control), let coverage = frame.capturedRegions,
          visualCovered(control, by: coverage), visualCovered(header, by: coverage) else {
        throw fail("visual_control_not_fully_visible", "Whole-draft clear requires complete composer and recipient coverage")
    }
    guard !frame.idleConfirmed, frame.time.isFinite, now.isFinite, now >= frame.time, now - frame.time <= 2 else {
        throw fail("stale_visual_snapshot", "Whole-draft clear requires fresh complete-frame pixels")
    }
    guard composerRows.count <= 100, composerRows.allSatisfy({ row in
        guard let text = row["text"] as? String else { return false }
        return !text.isEmpty && text.count < 1000
    }) else { throw fail("clear_draft_unverified", "Complete untruncated draft OCR is required") }
    guard visualClearDraftHeaderMatchCount(headerRows, title: title) == 1 else {
        throw fail("clear_recipient_mismatch", "Complete fresh recipient header differs from chat_title")
    }
    let valueRows = visualRowsWithoutEmptyComposerHint(frame, window: window, rows: composerRows, now: now)
    if expected.isEmpty { return valueRows.isEmpty }
    let actual = valueRows.compactMap { $0["text"] as? String }.joined(separator: "\n")
    return actual.utf16.elementsEqual(expected.utf16)
}

func visualClearDraftKeys(_ post: (CGKeyCode, CGEventFlags) throws -> Void) throws {
    try post(0, .maskCommand)
    try post(51, [])
}

struct VisualPrefixDeletion {
    let prefix: String
    let suffix: String
    let count: Int
}
func visualPrefixDeletion(_ draft: String, prefix: String) throws -> VisualPrefixDeletion {
    let scalars=Array(prefix.unicodeScalars)
    guard !scalars.isEmpty,scalars.count<=64,draft.utf16.count<=8192,
          scalars.count==prefix.count,scalars.count==prefix.utf16.count,
          scalars.allSatisfy({ scalar in
              guard scalar.value<=0xFFFF else{return false}
              switch scalar.properties.generalCategory {
              case .uppercaseLetter,.lowercaseLetter,.titlecaseLetter,.modifierLetter,.otherLetter,
                   .decimalNumber,.letterNumber,.otherNumber,.connectorPunctuation,.dashPunctuation,
                   .openPunctuation,.closePunctuation,.initialPunctuation,.finalPunctuation,.otherPunctuation: return true
              default:return false
              }
          }) else{throw fail("invalid_prefix","prefix must contain 1...64 ordinary single-line BMP characters without combining marks, emoji, format controls or joined characters")}
    guard Array(draft.utf16).starts(with:Array(prefix.utf16)),
          Array(String(draft.prefix(prefix.count)).utf16)==Array(prefix.utf16) else {
        throw fail("prefix_mismatch","expected_draft must start with the exact prefix at complete character boundaries")
    }
    return VisualPrefixDeletion(prefix:prefix,suffix:String(draft.dropFirst(prefix.count)),count:prefix.count)
}
// When Vision includes the green caret in its first text box, horizontal box
// margins alone cannot distinguish start-of-text from a caret after a narrow
// character. Require a completely light left line band and real ink to its right.
func visualPrefixCaretBeforeInk(_ image: CGImage, window: CGRect, control: CGRect, firstText: CGRect, caret: CGRect) -> Bool {
    guard visualContains(control, firstText), visualContains(control, caret),
          caret.minX-control.minX >= 4, caret.minX-control.minX <= 24,
          image.bitsPerPixel == 32, image.bitsPerComponent == 8, image.alphaInfo == .premultipliedLast,
          let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return false }
    let sx = Double(image.width)/window.width, sy = Double(image.height)/window.height
    let bandTop = max(control.minY, min(firstText.minY, caret.minY)-2)
    let bandBottom = min(control.maxY, max(firstText.maxY, caret.maxY)+2)
    let y0 = max(0,Int(floor((bandTop-window.minY)*sy))), y1 = min(image.height,Int(ceil((bandBottom-window.minY)*sy)))
    let left0 = max(0,Int(floor((control.minX-window.minX)*sx))), left1 = min(image.width,Int(floor((caret.minX-window.minX)*sx)))
    let right0 = max(0,Int(ceil((caret.maxX-window.minX)*sx)))
    let right1 = min(image.width,Int(floor((min(control.maxX,firstText.maxX+2)-window.minX)*sx)))
    guard y0<y1, left0<left1, right0<right1 else { return false }
    for y in y0..<y1 { for x in left0..<left1 {
        let i=y*image.bytesPerRow+x*4,r=Int(p[i]),g=Int(p[i+1]),b=Int(p[i+2])
        guard p[i+3]>=245,min(r,g,b)>=225,max(r,g,b)-min(r,g,b)<=18 else { return false }
    } }
    var rightInk=0
    for y in y0..<y1 { for x in right0..<right1 {
        let i=y*image.bytesPerRow+x*4,r=Int(p[i]),g=Int(p[i+1]),b=Int(p[i+2])
        if p[i+3]>=245,max(r,g,b)<=100,max(r,g,b)-min(r,g,b)<=24 { rightInk+=1 }
    } }
    return Double(rightInk)>=8*sx*sy
}

func visualPrefixCaretCaptureBudget(remaining: Double, previousDuration: Double?) -> Bool {
    remaining.isFinite && remaining >= max(0.3, previousDuration ?? 0.3)
}

func visualPrefixCaretAtStart(_ image: CGImage, window:CGRect, control:CGRect, firstText:CGRect) -> Bool {
    guard visualContains(control,firstText),firstText.height>=6,firstText.height<=40 else{return false}
    let sx=Double(image.width)/window.width,sy=Double(image.height)/window.height
    let scan=CGRect(x:firstText.minX-6,y:firstText.minY-6,width:10,height:firstText.height+12).intersection(control)
    guard !scan.isNull,image.bitsPerPixel==32,image.bitsPerComponent==8,image.alphaInfo == .premultipliedLast,
          let data=image.dataProvider?.data,let p=CFDataGetBytePtr(data) else{return false}
    let minX=max(0,Int(((scan.minX-window.minX)*sx).rounded(.down))),maxX=min(image.width,Int(((scan.maxX-window.minX)*sx).rounded(.up)))
    let minY=max(0,Int(((scan.minY-window.minY)*sy).rounded(.down))),maxY=min(image.height,Int(((scan.maxY-window.minY)*sy).rounded(.up)))
    guard minX<maxX,minY<maxY else{return false}
    var points=Set<Int>()
    for y in minY..<maxY {for x in minX..<maxX {let i=y*image.bytesPerRow+x*4,r=Int(p[i]),g=Int(p[i+1]),b=Int(p[i+2]);if p[i+3]>=245,g>=115,g-r>=45,g-b>=20 {points.insert(y*image.width+x)}}}
    var candidates=0, components=0
    while let start=points.first {
        components+=1
        points.remove(start);var queue=[start],index=0,l=start%image.width,r=l,t=start/image.width,b=t
        while index<queue.count {let point=queue[index];index+=1;let x=point%image.width,y=point/image.width;l=min(l,x);r=max(r,x);t=min(t,y);b=max(b,y)
            for yy in max(minY,y-1)...min(maxY-1,y+1){for xx in max(minX,x-1)...min(maxX-1,x+1){let next=yy*image.width+xx;if points.remove(next) != nil{queue.append(next)}}}
        }
        let rect=CGRect(x:window.minX+Double(l)/sx,y:window.minY+Double(t)/sy,width:Double(r-l+1)/sx,height:Double(b-t+1)/sy)
        let density=Double(queue.count)/Double((r-l+1)*(b-t+1))
        if rect.width>=0.5,rect.width<=3,rect.height>=max(8,firstText.height*0.7),rect.height<=firstText.height+8,
           rect.minX>=firstText.minX-5,abs(rect.midY-firstText.midY)<=5,density>=0.75 {
            if rect.maxX<=firstText.minX { candidates+=1 }
            else if rect.maxX<firstText.minX+4,
                    visualPrefixCaretBeforeInk(image,window:window,control:control,firstText:firstText,caret:rect) {
                candidates+=1
            }
        }
    }
    return candidates==1 && components==1
}

// Prior complete-draft bounds are only a cheap sampling filter. A candidate
// cannot authorise deletion until verify checks this same frame's full value,
// recipient and newly recognised first-glyph bounds.
func visualPrefixCaretCandidate(_ image: CGImage, window: CGRect, control: CGRect, priorFirstText: CGRect,
                                verify: () throws -> Bool) rethrows -> Bool {
    guard visualPrefixCaretAtStart(image, window: window, control: control, firstText: priorFirstText) else { return false }
    return try verify()
}

func visualPrefixCaretDiagnostic(_ image: CGImage, window: CGRect, control: CGRect, firstText: CGRect) -> [String: Any] {
    let scan = CGRect(x: firstText.minX - 6, y: firstText.minY - 6, width: 10, height: firstText.height + 12).intersection(control)
    var result: [String: Any] = ["scan_region": rectJSON(scan), "first_OCR_bounds": rectJSON(firstText),
        "authorizing_color": "green_only", "black_pixels_are_diagnostic_only": true]
    guard !scan.isNull, image.bitsPerPixel == 32, image.bitsPerComponent == 8, image.alphaInfo == .premultipliedLast,
          let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { result["available"] = false; return result }
    let sx = Double(image.width) / Double(window.width), sy = Double(image.height) / Double(window.height)
    let x0 = max(0, Int((scan.minX - window.minX) * sx)), x1 = min(image.width, Int(((scan.maxX - window.minX) * sx).rounded(.up)))
    let y0 = max(0, Int((scan.minY - window.minY) * sy)), y1 = min(image.height, Int(((scan.maxY - window.minY) * sy).rounded(.up)))
    var columns: [[String: Any]] = []
    if x0 < x1, y0 < y1 {
        for x in x0..<x1 {
            var green = 0, black = 0
            for y in y0..<y1 {
                let i = y * image.bytesPerRow + x * 4, r = Int(p[i]), g = Int(p[i+1]), b = Int(p[i+2])
                if p[i+3] >= 245 { if g >= 115 && g-r >= 45 && g-b >= 20 { green += 1 }; if max(r,g,b) <= 90 { black += 1 } }
            }
            if max(green, black) >= Int(max(4, firstText.height * sy * 0.5)), columns.count < 24 {
                columns.append(["x": window.minX + Double(x)/sx, "green_pixels": green, "black_pixels": black])
            }
        }
    }
    result["available"] = true; result["candidate_columns"] = columns; return result
}

func visualSubmitHeader(_ window: CGRect) -> CGRect {
    // Parent-owned 932/855-point consumer evidence: the sidebar stays 321 pt
    // wide. The recipient band excludes its add button and the first body row.
    guard window.width > 342, window.height > 50 else { return .null }
    return CGRect(x: window.minX + 326, y: window.minY + 5,
                  width: window.width - 342, height: 45)
}

func visualMergeOCRRows(_ groups: [[[String: Any]]]) -> [[String: Any]] {
    var rows: [[String: Any]] = []
    var positions: [String: [CGRect]] = [:]
    for group in groups {
        for row in group {
            guard let text = row["text"] as? String, let bounds = try? visualRect(row["bounds"]) else { continue }
            let key = visualNormalizedText(text)
            let duplicate = (positions[key] ?? []).contains { oldBounds in
                let intersection = oldBounds.intersection(bounds)
                return !intersection.isNull && intersection.width * intersection.height >= 0.8 * min(oldBounds.width * oldBounds.height, bounds.width * bounds.height)
            }
            if !duplicate { rows.append(row); positions[key, default: []].append(bounds) }
        }
    }
    return rows
}

func visualAnchorsVerified(_ anchors: [String], rows: [[String: Any]], confirmed: Bool) -> Bool {
    let matching = anchors.compactMap { anchor in rows.first { row in
        (row["text"] as? String).map { visualNormalizedText($0).contains(visualNormalizedText(anchor)) } ?? false
    }}
    let distinct = Set(matching.compactMap { (try? visualRect($0["bounds"])).map { NSStringFromRect($0) } })
    return confirmed && anchors.count >= 2 && matching.count == anchors.count && distinct.count >= 2
}

func visualReadAnchorBands(_ window: CGRect) -> [CGRect] {
    [CGRect(x: window.minX, y: window.minY, width: window.width, height: min(84, window.height * 0.15)),
     CGRect(x: window.minX + window.width * 0.70, y: window.minY + window.height * 0.85,
            width: window.width * 0.30, height: window.height * 0.15)]
}

// CG reports the Dock's transparent event-routing surface as a full-display
// alpha=1 window. Only that named, exact display surface is special-cased;
// its current AX interactive geometry remains an occluder.
func visualPointTargetMatches(_ point: CGPoint, identity: VisualIdentity, rows: [[String: Any]],
                              dockPID: pid_t?, dockRegions: [CGRect]?, displays: [CGRect], notificationRegions: [CGWindowID: [CGRect]] = [:]) -> Bool {
    guard rows.contains(where: { row in
        guard (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == identity.windowID,
              (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == identity.pid,
              let raw = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
        return bounds == identity.frame
    }) else { return false }
    for row in rows {
        // Use the same Window Server cursor exclusion as capture coverage;
        // moving the pointer onto a verified control cannot make it an occluder.
        if visualSystemCursorWindow(row) { continue }
        guard let raw = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
              pointIsInsideRect(point, bounds),
              (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { continue }
        let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        if pid == identity.pid { return true }
        let dockSurface = pid == dockPID && dockPID != nil &&
            row[kCGWindowName as String] as? String == "Dock" &&
            (row[kCGWindowLayer as String] as? NSNumber)?.int32Value == CGWindowLevelForKey(.dockWindow) &&
            displays.contains(bounds)
        if dockSurface, let dockRegions, !dockRegions.isEmpty,
           !dockRegions.contains(where: { pointIsInsideRect(point, $0.insetBy(dx: -12, dy: -12)) }) { continue }
        if let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
           let regions = notificationRegions[id], !regions.isEmpty,
           !regions.contains(where: { pointIsInsideRect(point, $0.insetBy(dx: -12, dy: -12)) }) { continue }
        return false
    }
    return false
}


func visualScrollEvent(point: CGPoint, delta: Int32, source: CGEventSource?) -> CGEvent? {
    guard let wheel = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                              wheel1: delta, wheel2: 0, wheel3: 0) else { return nil }
    wheel.location = point
    wheel.flags = []
    return wheel
}

func visualControlSafetyRegion(command: String, control: CGRect, window: CGRect, point: CGPoint?) throws -> CGRect {
    guard command == "visual_scroll" else { return control.insetBy(dx: -12, dy: -12).intersection(window) }
    guard let point, pointIsInsideRect(point, control), pointIsInsideRect(point, window) else {
        throw fail("coordinate_outside_control", "Scroll point must lie inside its confirmed navigation region")
    }
    // A scroll routes at this point; it neither chooses an OCR row nor edits
    // the whole viewport. Secure-field and live point-owner guards still run.
    return CGRect(x: point.x - 48, y: point.y - 32, width: 96, height: 64).intersection(window)
}

enum VisualHitOwnership { case target, notImplemented, foreign, unavailable }

// WindowServer's onscreen bounding rectangles can straddle a display where the
// window is not actually rendered. A successful system-wide AX hit on another
// process overrides that geometric rectangle. Qt's known notImplemented result
// is different: the PID-isolated, nontransparent capture supplies its pixels.
func visualHitObservation(_ point: CGPoint, identity: VisualIdentity, selectedWindow: AXUIElement? = nil, searchOverlay: VisualSearchOverlay? = nil, captureAuxiliaryFrames: [CGRect] = []) -> (ownership: VisualHitOwnership, details: [String: Any]) {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.12)
    var hit: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
    var details: [String: Any] = ["ax_hit_result": result.rawValue]
    if result == .notImplemented { return (.notImplemented, details) }
    guard result == .success, let hit else { return (.unavailable, details) }
    var pid: pid_t = 0
    let pidResult = AXUIElementGetPid(hit, &pid)
    details["ax_pid_result"] = pidResult.rawValue
    guard pidResult == .success else { return (.unavailable, details) }
    details["hit_pid"] = pid
    guard pid == identity.pid else { return (.foreign, details) }

    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
    var queue: [(AXUIElement, Int, String, Int)] = [(hit, 0, "hit", -1)]
    var visited: [AXUIElement] = [], trace: [[String: Any]] = []
    var candidateForeign = false, inspected = 0
    var checkedSelectedControls = false, traversalLimited = false
    var selectedControls: [(String, AXUIElement)] = []
    func finish(_ ownership: VisualHitOwnership, _ proof: String) -> (VisualHitOwnership, [String: Any]) {
        details["nodes"] = trace; details["ownership_proof"] = proof
        details["traversal_truncated"] = traversalLimited || inspected < queue.count
        return (ownership, details)
    }
    while inspected < queue.count && visited.count < 24 && ProcessInfo.processInfo.systemUptime < deadline {
        let (item, depth, relation, from) = queue[inspected]; inspected += 1
        if visited.contains(where: { CFEqual($0, item) }) { continue }
        visited.append(item)
        AXUIElementSetMessagingTimeout(item, 0.12)
        var nodePID: pid_t = 0
        let nodePIDResult = AXUIElementGetPid(item, &nodePID)
        var record: [String: Any] = ["index": trace.count, "depth": depth, "relation": relation,
            "from_node": from, "pid": nodePID, "pid_result": nodePIDResult.rawValue]
        guard nodePIDResult == .success else { record["rejected"] = "pid_unavailable"; trace.append(record); continue }
        guard nodePID == identity.pid else {
            record["rejected"] = "foreign_pid"; trace.append(record); candidateForeign = true; continue
        }
        let role = axString(item, kAXRoleAttribute)
        let bounds = axBounds(item)
        record["role"] = role ?? "unavailable"
        record["bounds"] = bounds.map { rectJSON($0) as Any } ?? NSNull()
        if role == kAXWindowRole, let bounds {
            details["hit_window_frame"] = rectJSON(bounds)
            if bounds == identity.frame || bounds == searchOverlay?.frame || captureAuxiliaryFrames.contains(bounds) {
                let proof = bounds == identity.frame ? "selected_main_frame" : (bounds == searchOverlay?.frame ? "captured_search_popup_frame" : "read_only_same_PID_auxiliary_frame")
                record["accepted"] = proof; trace.append(record)
                return finish(.target, "public_AX_relation_to_" + proof)
            }
            candidateForeign = true
            record["candidate_foreign_window"] = true
        }
        // Direct button ownership is stronger than Qt's contextual AXWindow
        // wrapper: compare the exact public controls of the selected main window.
        if !checkedSelectedControls, let selectedWindow, ProcessInfo.processInfo.systemUptime < deadline {
            checkedSelectedControls = true
            AXUIElementSetMessagingTimeout(selectedWindow, 0.12)
            var mainPID: pid_t = 0
            let verifiedMain = AXUIElementGetPid(selectedWindow, &mainPID) == .success && mainPID == identity.pid && axBounds(selectedWindow) == identity.frame
            details["selected_main_verified"] = verifiedMain
            if verifiedMain {
                var controls: [[String: Any]] = []
                for name in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { traversalLimited = true; break }
                    let control = axElement(selectedWindow, name)
                    controls.append(["attribute": name, "available": control != nil])
                    if let control { selectedControls.append((name, control)) }
                }
                details["selected_main_controls"] = controls
            }
        }
        if let matched = selectedControls.first(where: { CFEqual($0.1, item) }) {
            record["accepted"] = "CFEqual_selected_main_" + matched.0; trace.append(record)
            return finish(.target, "CFEqual_selected_main_window_control")
        }
        let nodeIndex = trace.count
        var links: [[String: Any]] = []
        // An application's container is not a path between sibling windows.
        // Never enumerate descendants or follow app-wide focused-window state.
        if role != "AXApplication", depth >= 8 { record["depth_limit_reached"] = true; traversalLimited = true }
        if role != "AXApplication", depth < 8 {
            for name in [kAXParentAttribute, kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
                guard ProcessInfo.processInfo.systemUptime < deadline, queue.count < 72 else { traversalLimited = true; break }
                let linked = axElement(item, name)
                let seen = linked.map { next in visited.contains(where: { CFEqual($0, next) }) || queue.dropFirst(inspected).contains(where: { CFEqual($0.0, next) }) } ?? false
                links.append(["attribute": name, "available": linked != nil, "already_seen": seen])
                if let linked, !seen { queue.append((linked, depth + 1, name, nodeIndex)) }
            }
        }
        record["links"] = links; trace.append(record)
    }
    return finish(candidateForeign ? .foreign : .unavailable, "no_public_relation_to_selected_main")
}

func visualHitOwnership(_ point: CGPoint, identity: VisualIdentity, selectedWindow: AXUIElement? = nil, searchOverlay: VisualSearchOverlay? = nil) -> VisualHitOwnership {
    visualHitObservation(point, identity: identity, selectedWindow: selectedWindow, searchOverlay: searchOverlay).ownership
}

func visualOwnershipAllowsPoint(_ hit: VisualHitOwnership) -> Bool {
    switch hit { case .target, .notImplemented: return true; case .foreign, .unavailable: return false }
}

func visualPointRejectionDiagnostic(_ branch: String, point: CGPoint, identity: VisualIdentity,
                                    screenWindows: [VisualScreenWindow], dockRegions: [CGRect]?,
                                    searchOverlay: VisualSearchOverlay?,
                                    observation: (ownership: VisualHitOwnership, details: [String: Any])? = nil) -> [String: Any] {
    var result: [String: Any] = ["branch": branch, "point": ["x": point.x, "y": point.y],
        "target_pid": identity.pid, "window_id": identity.windowID, "window_frame": rectJSON(identity.frame),
        "CG_windows": Array(screenWindows.prefix(64)).map(visualScreenWindowMetadata),
        "CG_window_count": screenWindows.count, "CG_windows_truncated": screenWindows.count > 64,
        "dock_regions": dockRegions.map { Array($0.prefix(64)).map { rectJSON($0) } as Any } ?? NSNull(),
        "dock_region_count": dockRegions?.count ?? 0, "dock_regions_truncated": (dockRegions?.count ?? 0) > 64,
        "search_overlay_window_id": searchOverlay.map { $0.windowID as Any } ?? NSNull(),
        "search_overlay_frame": searchOverlay.map { rectJSON($0.frame) as Any } ?? NSNull()]
    if let observation {
        let owner: String
        switch observation.ownership {
        case .target: owner = "target"
        case .notImplemented: owner = "notImplemented"
        case .foreign: owner = "foreign"
        case .unavailable: owner = "unavailable"
        }
        var details: [String: Any] = ["hit_ownership": owner]
        for key in ["ax_hit_result", "ax_pid_result", "hit_pid", "hit_window_frame", "ownership_proof", "traversal_truncated", "selected_main_verified"] {
            if let value = observation.details[key] { details[key] = value }
        }
        if let nodes = observation.details["nodes"] as? [[String: Any]] {
            let keys = Set(["role", "bounds", "pid", "pid_result", "accepted", "rejected", "candidate_foreign_window", "relation", "depth"])
            details["ownership_nodes"] = Array(nodes.prefix(8)).map { $0.filter { keys.contains($0.key) } }
            details["node_count"] = nodes.count; details["nodes_truncated"] = nodes.count > 8
        }
        result["AX_observation"] = details
    }
    return result
}

func guardDesktopPoint(_ point: CGPoint, identity: VisualIdentity, selectedWindow: AXUIElement? = nil, searchOverlay: VisualSearchOverlay? = nil) throws {
    guard pointIsInsideRect(point, identity.frame) else { throw fail("coordinate_outside_window", "Visual point lies outside snapshot window") }
    let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    var dockRegions: [CGRect]?
    if let dock, rows.contains(where: { row in
        (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dock.processIdentifier &&
            row[kCGWindowName as String] as? String == "Dock"
    }) {
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        let children = axElements(application, kAXChildrenAttribute, limit: 9)
        if !children.isEmpty && children.count < 9 {
            var regions: [CGRect] = []
            var complete = true
            for child in children {
                if let bounds = axBounds(child), bounds.width > 0, bounds.height > 0 { regions.append(bounds) }
                let items = axElements(child, kAXChildrenAttribute, limit: 65)
                if items.count >= 65 { complete = false; break }
                for item in items {
                    if let bounds = axBounds(item), bounds.width > 0, bounds.height > 0 { regions.append(bounds) }
                }
            }
            if complete && !regions.isEmpty { dockRegions = regions }
        }
    }
    let displayRects = try activeDisplays().displays.map { $0.bounds }
    guard displayRects.contains(where: { pointIsInsideRect(point, $0) }) else {
        throw fail("coordinate_not_on_display", "Point is outside all active displays or in a display gap")
    }
    let screenWindows = try visualScreenWindows(rows, identity: identity, displays: displayRects, dockPID: dock?.processIdentifier)
    let notificationRegions = visualNotificationMasks(screenWindows, displays: displayRects)
    guard visualPointTargetMatches(point, identity: identity, rows: rows,
        dockPID: dock?.processIdentifier, dockRegions: dockRegions, displays: displayRects, notificationRegions: notificationRegions) else {
        throw fail("coordinate_target_mismatch", "Visual point is covered by another application or its occlusion geometry could not be verified",
            visualPointRejectionDiagnostic("CG_point_coverage", point: point, identity: identity,
                screenWindows: screenWindows, dockRegions: dockRegions, searchOverlay: searchOverlay))
    }
    let observation = visualHitObservation(point, identity: identity, selectedWindow: selectedWindow, searchOverlay: searchOverlay)
    guard visualOwnershipAllowsPoint(observation.ownership) else {
        throw fail("coordinate_target_mismatch", "System-wide AX hit belongs to another window/application or its actual owner is unavailable",
            visualPointRejectionDiagnostic("AX_hit_ownership", point: point, identity: identity,
                screenWindows: screenWindows, dockRegions: dockRegions, searchOverlay: searchOverlay, observation: observation))
    }
}

final class VisualCompletion<T> {
    let lock = NSLock()
    var value: Result<T, Error>?
    func complete(_ result: Result<T, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

func visualAwait<T>(_ timeout: Double = 3, _ operation: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
    let box = VisualCompletion<T>()
    operation { box.complete($0) }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
        if let result = box.get() { return try result.get() }
        _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw fail("visual_capture_timeout", "Public capture callback did not complete within the bounded deadline")
}

// All rectangles here use Quartz global points, including negative origins.
// Subtraction also removes mirrored-display overlap and masks unobservable gaps.
func visualSubtract(_ rect: CGRect, _ cut: CGRect) -> [CGRect] {
    let overlap = rect.intersection(cut)
    guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [rect] }
    return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
            CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
            CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)]
        .filter { $0.width > 0 && $0.height > 0 }
}

func visualCovered(_ rect: CGRect, by coverage: [CGRect]) -> Bool {
    guard rect.width > 0, rect.height > 0 else { return false }
    var remaining = [rect]
    for covered in coverage { remaining = remaining.flatMap { visualSubtract($0, covered) } }
    return remaining.reduce(0) { $0 + $1.width * $1.height } < 0.000001
}

struct VisualCaptureFragment {
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let rect: CGRect
    let coverage: [CGRect]
    let pixelWidth: Int
    let pixelHeight: Int
    var sourceRect: CGRect { rect.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY) }
}

struct VisualCapturePlan {
    let window: CGRect
    let topology: DisplaySnapshot
    let fragments: [VisualCaptureFragment]
    let width: Int
    let height: Int
    var coverage: [CGRect] { fragments.flatMap { $0.coverage } }
    func pixels(_ rect: CGRect) -> CGRect {
        let sx = Double(width) / window.width, sy = Double(height) / window.height
        let left = ((rect.minX - window.minX) * sx).rounded()
        let top = ((rect.minY - window.minY) * sy).rounded()
        return CGRect(x: left, y: top,
            width: ((rect.maxX - window.minX) * sx).rounded() - left,
            height: ((rect.maxY - window.minY) * sy).rounded() - top)
    }
    init(window: CGRect, topology: DisplaySnapshot) throws {
        guard window.width > 0, window.height > 0, window.minX.isFinite, window.minY.isFinite,
              window.width.isFinite, window.height.isFinite else { throw fail("visual_image_too_large", "Invalid target crop") }
        var pieces: [VisualCaptureFragment] = [], claimed: [CGRect] = []
        var scaleX = 1.0, scaleY = 1.0
        let ordered = topology.displays.sorted { $0.main != $1.main ? $0.main : $0.id < $1.id }
        for display in ordered {
            let rect = window.intersection(display.bounds)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            guard display.scaleX.isFinite, display.scaleY.isFinite, display.scaleX > 0, display.scaleY > 0 else {
                throw fail("display_state_unavailable", "Display pixel scale is invalid")
            }
            var visible = [rect]
            for prior in claimed { visible = visible.flatMap { visualSubtract($0, prior) } }
            guard !visible.isEmpty else { continue }
            let pw = (rect.width * display.scaleX).rounded(.up), ph = (rect.height * display.scaleY).rounded(.up)
            guard pw > 0, ph > 0, pw <= 8192, ph <= 8192, pw * ph <= 20_000_000 else {
                throw fail("visual_image_too_large", "Display fragment exceeds bounded capture pixels")
            }
            pieces.append(VisualCaptureFragment(displayID: display.id, displayBounds: display.bounds,
                rect: rect, coverage: visible, pixelWidth: Int(pw), pixelHeight: Int(ph)))
            claimed += visible
            scaleX = max(scaleX, display.scaleX); scaleY = max(scaleY, display.scaleY)
        }
        guard !pieces.isEmpty else { throw fail("visual_region_unavailable", "Target has no visible area on an active display") }
        let pw = (window.width * scaleX).rounded(.up), ph = (window.height * scaleY).rounded(.up)
        guard pieces.count <= 8, pw <= 8192, ph <= 8192, pw * ph <= 20_000_000,
              pieces.reduce(0, { $0 + $1.pixelWidth * $1.pixelHeight }) <= 20_000_000 else {
            throw fail("visual_image_too_large", "Combined display fragments or composite exceed bounded pixel budget")
        }
        self.window = window; self.topology = topology; fragments = pieces; width = Int(pw); height = Int(ph)
    }
    func composite(_ images: [CGImage]) throws -> CGImage {
        guard images.count == fragments.count,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw fail("visual_capture_failed", "Could not allocate bounded window composite")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (fragment, image) in zip(fragments, images) {
            guard image.width == fragment.pixelWidth, image.height == fragment.pixelHeight else {
                throw fail("visual_target_changed", "Fragment pixel dimensions changed")
            }
            func destination(_ rect: CGRect) -> CGRect {
                let p = pixels(rect)
                return CGRect(x: p.minX, y: Double(height) - p.maxY, width: p.width, height: p.height)
            }
            context.saveGState()
            context.clip(to: fragment.coverage.map { destination($0) })
            context.draw(image, in: destination(fragment.rect))
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw fail("visual_capture_failed", "Could not finish window composite") }
        return image
    }
}

// CoreGraphics-only callback guard avoids using NSScreen from capture queues.
// Main-thread helper.verify still compares the full topology including AppKit scale.
func visualTopologyMatches(_ expected: DisplaySnapshot) -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
    guard CGGetActiveDisplayList(64, &ids, &count) == .success,
          ids.prefix(Int(count)).sorted() == expected.displays.map({ $0.id }).sorted() else { return false }
    return expected.displays.allSatisfy { display in
        guard let mode = CGDisplayCopyDisplayMode(display.id) else { return false }
        return CGDisplayBounds(display.id) == display.bounds && mode.pixelWidth == display.pixelWidth &&
            mode.pixelHeight == display.pixelHeight && CGSize(width: mode.width, height: mode.height) == display.modePointSize &&
            CGDisplayRotation(display.id) == display.rotation && (CGDisplayIsMain(display.id) != 0) == display.main &&
            (CGDisplayIsBuiltin(display.id) != 0) == display.builtin
    }
}

struct VisualSearchOverlay: Equatable {
    let windowID: CGWindowID
    let frame: CGRect
}

func visualSearchPopupBounds(_ bounds: CGRect, identity: VisualIdentity) -> Bool {
    bounds.minX == identity.frame.minX + 48 && bounds.minY == identity.frame.minY + 35 &&
        bounds.width == 368 && bounds.height >= 80 && bounds.height <= identity.frame.height - 63 &&
        visualContains(identity.frame, bounds)
}

struct VisualSearchActivation {
    let identity: VisualIdentity
    let control: CGRect
    func matches(_ target: VisualIdentity, queryRegion: CGRect) -> Bool {
        identity == target && (try? visualSearchTextRegion(window: target.frame, control: control)).map {
            $0.minX == queryRegion.minX && $0.width == queryRegion.width && visualContains(control, queryRegion)
        } == true
    }
}

func visualBoundSearchQuery(_ rows: [[String: Any]], fullyVisible: Bool, activated: Bool) -> String? {
    guard fullyVisible, rows.count <= 1, rows.isEmpty || rows[0]["text"] is String else { return nil }
    let value = visualNormalizedText(rows.first?["text"] as? String ?? "")
    if !value.isEmpty && !["搜索", "Search"].contains(value) { return value }
    // An empty active search lane has no textual anchor. It is only bound by
    // this helper's already-posted, confirmed click on that exact search field.
    return activated ? "" : nil
}

func visualSearchOverlay(_ rows: [[String: Any]], identity: VisualIdentity) throws -> VisualSearchOverlay? {
    var found: [VisualSearchOverlay] = []
    for row in rows {
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == identity.pid,
              (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value != identity.windowID,
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 3,
              (row[kCGWindowName as String] as? String ?? "").isEmpty,
              let raw = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
              !bounds.intersection(identity.frame).isNull else { continue }
        // Only this observed popup geometry identifies search results. Other
        // windows are handled by local screen-occlusion masking.
        guard (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 1,
              visualSearchPopupBounds(bounds, identity: identity),
              let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
            continue
        }
        found.append(VisualSearchOverlay(windowID: id, frame: bounds))
    }
    guard found.count <= 1 else { throw fail("visual_search_overlay_ambiguous", "More than one matching search popup is onscreen") }
    return found.first
}

func visualCurrentSearchOverlay(_ identity: VisualIdentity) throws -> VisualSearchOverlay? {
    try visualSearchOverlay(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [], identity: identity)
}

func visualComposeSearchOverlay(_ main: CGImage, popup: CGImage, window: CGRect, overlay: VisualSearchOverlay) throws -> CGImage {
    let sx = Double(main.width) / window.width, sy = Double(main.height) / window.height
    guard visualContains(window, overlay.frame),
          popup.width == Int((overlay.frame.width * sx).rounded(.up)),
          popup.height == Int((overlay.frame.height * sy).rounded(.up)),
          let context = CGContext(data: nil, width: main.width, height: main.height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw fail("visual_target_changed", "Search popup pixel geometry changed")
    }
    context.draw(main, in: CGRect(x: 0, y: 0, width: main.width, height: main.height))
    let destination = CGRect(x: (overlay.frame.minX - window.minX) * sx,
        y: Double(main.height) - (overlay.frame.maxY - window.minY) * sy,
        width: overlay.frame.width * sx, height: overlay.frame.height * sy)
    context.saveGState(); context.clip(to: destination); context.draw(popup, in: destination); context.restoreGState()
    guard let result = context.makeImage() else { throw fail("visual_capture_failed", "Could not composite the verified search popup") }
    return result
}

struct VisualScreenWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let layer: Int
    let alpha: Double
    let emptyTitle: Bool
    let dockSurface: Bool
    var inputHintCandidate: Bool { layer == 3 && emptyTitle && alpha == 1 && frame.width == 84 && frame.height == 77 }
}
// Bounded, content-free capture failure details. Foreign titles and AX values
// are deliberately absent; only public window identity/geometry is recorded.
func visualScreenWindowMetadata(_ item: VisualScreenWindow) -> [String: Any] {
    ["window_id": item.id, "pid": item.pid, "frame": rectJSON(item.frame), "layer": item.layer,
     "alpha": item.alpha, "empty_title": item.emptyTitle, "dock_surface": item.dockSurface]
}
func visualWindowChangeDiagnostic(_ before: [VisualScreenWindow], _ after: [VisualScreenWindow]) -> [String: Any] {
    let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let current = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let changedIDs = Set(before.map{$0.id} + after.map{$0.id}).filter { previous[$0] != current[$0] }.sorted()
    let changes = changedIDs.prefix(16).map { id -> [String: Any] in
        ["window_id": id, "before": previous[id].map(visualScreenWindowMetadata) as Any? ?? NSNull(),
         "after": current[id].map(visualScreenWindowMetadata) as Any? ?? NSNull()]
    }
    return ["before_count": before.count, "after_count": after.count,
        "before_window_order": Array(before.prefix(64).map{$0.id}), "after_window_order": Array(after.prefix(64).map{$0.id}),
        "window_changes": changes, "window_changes_count": changedIDs.count, "window_changes_truncated": changedIDs.count > 16]
}

// Capture can reveal a previously absent same-app auxiliary. Such a window is
// never trusted as the selected target. Admit only a bounded exclusion union;
// baseline windows/order, foreign windows, and search-popup identity stay strict.
func visualNewContainedAuxiliaries(baseline: [VisualScreenWindow], current: [VisualScreenWindow],
                                  seen: [VisualScreenWindow], identity: VisualIdentity) -> [VisualScreenWindow]? {
    let baseIDs = Set(baseline.map{$0.id})
    guard Set(current.map{$0.id}).count == current.count,
          current.filter({baseIDs.contains($0.id)}) == baseline else { return nil }
    var union = seen
    for item in current where !baseIDs.contains(item.id) {
        guard item.pid == identity.pid, item.id != identity.windowID, !item.dockSurface,
              item.alpha.isFinite, item.alpha > 0, item.alpha <= 1,
              visualContains(identity.frame, item.frame),
              !visualSearchPopupBounds(item.frame, identity: identity) else { return nil }
        if let previous = union.first(where:{$0.id == item.id}) {
            guard previous == item else { return nil }
        } else { union.append(item) }
    }
    guard union.count <= 16 else { return nil }
    return union
}
// WeChat can recreate its title-corner helper while the main-window filter
// is being updated. Both identities are untrusted, completely masked surfaces.
// Only their IDs may differ; no other window or its relative order may change.
func visualMaskedCornerWindowReplacement(_ before: [VisualScreenWindow], _ after: [VisualScreenWindow],
                                         identity: VisualIdentity) -> Bool {
    let corner = CGRect(x: identity.frame.minX + 6, y: identity.frame.minY + 5, width: 52, height: 20)
    guard visualContains(identity.frame, corner), before.count == after.count,
          Set(before.map { $0.id }).count == before.count, Set(after.map { $0.id }).count == after.count else { return false }
    func candidates(_ windows: [VisualScreenWindow]) -> [VisualScreenWindow] { windows.filter { $0.frame == corner } }
    let old = candidates(before), new = candidates(after)
    guard old.count == 1, new.count == 1, let a = old.first, let b = new.first, a.id != b.id else { return false }
    func owned(_ item: VisualScreenWindow) -> Bool {
        guard item.id != 0, item.id != identity.windowID, item.pid == identity.pid else { return false }
        return item.layer == 0 && item.alpha == 1 && !item.emptyTitle && !item.dockSurface
    }
    guard owned(a), owned(b) else { return false }
    let otherBefore = before.filter { $0.id != a.id }, otherAfter = after.filter { $0.id != b.id }
    return otherBefore == otherAfter
}

func visualAuxiliaryExclusionMetadata(_ items: [VisualScreenWindow]) -> [[String: Any]] {
    items.map { ["window_id": $0.id, "pid": $0.pid, "frame": rectJSON($0.frame), "layer": $0.layer,
        "alpha": $0.alpha, "content_captured": false, "input_authorized": false] }
}

// Only a posted search action may wait for this particular UI transition.
// The observed small same-app title-corner auxiliary can force a fresh
// observation, but remains an untrusted full-frame exclusion and never input.
struct VisualSearchTransition {
    let activation: VisualSearchActivation
    let windows: [VisualScreenWindow]
    let anchorRegions: [CGRect]
    let baselineCoverage: [CGRect]?
    init(activation: VisualSearchActivation, windows: [VisualScreenWindow], anchorRegions: [CGRect] = [],
         baselineCoverage: [CGRect]? = nil) {
        self.activation = activation; self.windows = windows; self.anchorRegions = anchorRegions
        self.baselineCoverage = baselineCoverage
    }
    private func expected(_ window: VisualScreenWindow, identity: VisualIdentity) -> Bool {
        window.pid == identity.pid && window.layer == 3 && window.emptyTitle && window.alpha == 1 &&
            (visualSearchPopupBounds(window.frame, identity: identity) ||
             (window.inputHintCandidate && visualContains(identity.frame, window.frame)))
    }
    // The real post-search click removed a fully masked 52x20 title-corner
    // auxiliary while opening the known popup. Admit only that disappearance
    // for a new observation, never as permission to post or replay any input.
    private func acceptsMaskedCornerDisappearance(_ before: [VisualScreenWindow], _ after: [VisualScreenWindow],
                                                  identity: VisualIdentity) -> Bool {
        let corner = CGRect(x: identity.frame.minX + 6, y: identity.frame.minY + 5, width: 52, height: 20)
        guard let coverage = baselineCoverage, !coverage.isEmpty, anchorRegions.count >= 2,
              visualContains(identity.frame, corner), coverage.allSatisfy({ $0.intersection(corner).isEmpty }),
              ([activation.control] + anchorRegions).allSatisfy({
                  visualContains(identity.frame, $0) && $0.intersection(corner).isEmpty && visualCovered($0, by: coverage)
              }),
              Set(before.map { $0.id }).count == before.count, Set(after.map { $0.id }).count == after.count else { return false }
        let corners = before.filter { $0.frame == corner }
        guard corners.count == 1, let removed = corners.first,
              removed.id != 0, removed.id != identity.windowID, removed.pid == identity.pid,
              removed.layer == 0, removed.alpha == 1, !removed.emptyTitle, !removed.dockSurface,
              !after.contains(where: { $0.id == removed.id || $0.frame == corner }) else { return false }
        return before.filter { $0.id != removed.id } == after
    }
    // Diagnostics use this same acceptance predicate. A successful transition
    // permits only a fresh guarded observation, never additional input.
    func rejectionReason(_ next: [VisualScreenWindow], identity: VisualIdentity) -> String? {
        guard activation.identity == identity else { return "activation_identity_mismatch" }
        guard (try? visualSearchTextRegion(window: identity.frame, control: activation.control)) != nil else {
            return "search_control_region_unverified"
        }
        guard next.filter({ $0.pid == identity.pid && $0.layer == 3 && $0.emptyTitle && $0.alpha == 1 && visualSearchPopupBounds($0.frame, identity: identity) }).count <= 1 else {
            return "ambiguous_known_search_popups"
        }
        let before = windows.filter { !expected($0, identity: identity) }, after = next.filter { !expected($0, identity: identity) }
        if visualMaskedCornerWindowReplacement(before, after, identity: identity) {
            let corner = CGRect(x: identity.frame.minX + 6, y: identity.frame.minY + 5, width: 52, height: 20)
            return ([activation.control] + anchorRegions).allSatisfy { $0.intersection(corner).isEmpty }
                ? nil : "corner_replacement_overlaps_control_or_anchor"
        }
        if acceptsMaskedCornerDisappearance(before, after, identity: identity) { return nil }
        guard let additions = visualNewContainedAuxiliaries(baseline: before, current: after,
            seen: [], identity: identity) else {
            return "baseline_window_changed_or_unrecognized_auxiliary"
        }
        return additions.allSatisfy { item in
            item.layer == 0 && !item.emptyTitle &&
                item.frame == CGRect(x: identity.frame.minX + 6, y: identity.frame.minY + 5, width: 52, height: 20) &&
                item.frame.intersection(activation.control).isNull &&
                anchorRegions.allSatisfy { item.frame.intersection($0).isNull }
        } ? nil : "new_auxiliary_not_exact_corner_or_overlaps_control_or_anchor"
    }
    func accepts(_ next: [VisualScreenWindow], identity: VisualIdentity) -> Bool {
        rejectionReason(next, identity: identity) == nil
    }
    // Bounded public geometry only: no titles, search query, OCR, or pixels.
    func diagnostic(_ next: [VisualScreenWindow], identity: VisualIdentity) -> [String: Any] {
        let reason = rejectionReason(next, identity: identity)
        return ["phase": "search_transition_initial", "transition_accepted": reason == nil,
            "transition_rejection_reason": reason.map { $0 as Any } ?? NSNull(),
            "activation_identity_matches": activation.identity == identity,
            "target_pid": identity.pid, "window_id": identity.windowID, "window_frame": rectJSON(identity.frame),
            "search_control_rect": rectJSON(activation.control),
            "baseline_coverage_available": baselineCoverage != nil,
            "baseline_corner_fully_masked": baselineCoverage.map { coverage in
                let corner = CGRect(x: identity.frame.minX + 6, y: identity.frame.minY + 5, width: 52, height: 20)
                return !coverage.isEmpty && coverage.allSatisfy { $0.intersection(corner).isEmpty }
            } ?? false,
            "anchor_region_count": anchorRegions.count, "anchor_regions": Array(anchorRegions.prefix(32)).map(rectJSON),
            "anchor_regions_truncated": anchorRegions.count > 32,
            "window_difference": visualWindowChangeDiagnostic(windows, next),
            "non_search_window_difference": visualWindowChangeDiagnostic(
                windows.filter { !expected($0, identity: identity) }, next.filter { !expected($0, identity: identity) })]
    }
}
struct VisualSearchObservationChanged: Error {
    let details: [String: Any]
    init(details: [String: Any] = [:]) { self.details = details }
}

func visualSearchPopupHeightRace(_ details: [String: Any], identity: VisualIdentity,
                                overlay: VisualSearchOverlay?, transition: VisualSearchTransition?,
                                activation: VisualSearchActivation?) -> Bool {
    guard let overlay, let transition, let activation,
          transition.activation.identity == identity, activation.identity == identity,
          transition.activation.control == activation.control,
          details["phase"] as? String == "matching_shareable_search_popup",
          details["sc_exact_id_count"] as? Int == 1, details["sc_exact_match_count"] as? Int == 0,
          let rows = details["sc_related_candidates"] as? [[String: Any]],
          let expected = details["expected_cg_popup"] as? [String: Any],
          (try? integer(expected, "window_id", default: 0, range: 1...Int(UInt32.max))) == Int(overlay.windowID),
          (try? integer(expected, "pid", default: 0, range: 1...Int(Int32.max))) == Int(identity.pid),
          (try? visualRect(expected["frame"])) == overlay.frame,
          visualSearchPopupBounds(overlay.frame, identity: identity) else { return false }
    let exact = rows.filter { (try? integer($0, "window_id", default: 0, range: 1...Int(UInt32.max))) == Int(overlay.windowID) }
    guard exact.count == 1, let row = exact.first,
          (try? integer(row, "pid", default: 0, range: 1...Int(Int32.max))) == Int(identity.pid),
          (try? integer(row, "layer", default: -1, range: 0...Int.max)) == 3,
          row["empty_title"] as? Bool == true, row["on_screen"] as? Bool == true,
          let frame = try? visualRect(row["frame"]), visualSearchPopupBounds(frame, identity: identity),
          frame.minX == overlay.frame.minX, frame.minY == overlay.frame.minY,
          frame.width == overlay.frame.width, frame.height != overlay.frame.height else { return false }
    return true
}

// Evidence lasts for this one navigation call only. Geometry alone never makes
// an auxiliary a known hint: the earlier immutable frame must have passed the
// blue-pill pixel signature, and any present hint must pass it again.
func visualKnownHintWindows(_ frame: VisualFrame, identity: VisualIdentity) -> [VisualScreenWindow] {
    frame.screenWindows.filter { window in
        guard window.pid == identity.pid, window.inputHintCandidate, visualContains(identity.frame, window.frame),
              frame.screenWindows.filter({ $0.inputHintCandidate && $0.frame == window.frame }).count == 1 else { return false }
        return frame.inputSourceHints.contains { visualContains(window.frame, $0) }
    }
}
struct VisualNavigationHintTransition {
    let identity: VisualIdentity
    let known: [VisualScreenWindow]
    let safetyRegion: CGRect
    let anchorRegions: [CGRect]
    init?(request: [String: Any], snapshot: VisualSnapshot) {
        guard request["command"] as? String == "visual_scroll", request["control_kind"] as? String == "navigation",
              snapshot.confirmed, !snapshot.readOnlyBackground, snapshot.anchors.count >= 2, !snapshot.anchorRegions.isEmpty,
              let x = try? number(request, "x"), let y = try? number(request, "y"),
              let control = try? visualRect(request["control_rect"]),
              let region = try? visualControlSafetyRegion(command: "visual_scroll", control: control,
                  window: snapshot.identity.frame, point: CGPoint(x: x, y: y)) else { return nil }
        let known = visualKnownHintWindows(snapshot.frame, identity: snapshot.identity)
        guard !known.isEmpty, known.allSatisfy({ item in
            ([region] + snapshot.anchorRegions).allSatisfy { $0.intersection(item.frame).isNull }
        }) else { return nil }
        self.identity = snapshot.identity; self.known = known
        self.safetyRegion = region; self.anchorRegions = snapshot.anchorRegions
    }
    func acceptsWindows(_ before: [VisualScreenWindow], _ after: [VisualScreenWindow]) -> Bool {
        let ids = Set(known.map { $0.id })
        guard Set(before.map { $0.id }).count == before.count, Set(after.map { $0.id }).count == after.count,
              (before + after).filter({ ids.contains($0.id) }).allSatisfy({ known.contains($0) }) else { return false }
        return before.filter { !ids.contains($0.id) } == after.filter { !ids.contains($0.id) }
    }
    func presentHintsVerified(_ frame: VisualFrame) -> Bool {
        let verified = visualKnownHintWindows(frame, identity: identity)
        return frame.screenWindows.filter { row in known.contains(where: { $0.id == row.id }) }.allSatisfy { verified.contains($0) }
    }
    func acceptsFrames(_ before: VisualFrame, _ after: VisualFrame) -> Bool {
        guard acceptsWindows(before.screenWindows, after.screenWindows), presentHintsVerified(before), presentHintsVerified(after),
              before.searchOverlay == after.searchOverlay, before.searchQuery == after.searchQuery,
              before.capturedRegions == after.capturedRegions,
              visualCovered(safetyRegion, by: after.capturedRegions ?? []),
              anchorRegions.allSatisfy({ visualCovered($0, by: after.capturedRegions ?? []) }) else { return false }
        func exclusions(_ frame: VisualFrame) -> [CGRect] {
            let removable = frame.inputSourceHints.filter { hint in known.contains { visualContains($0.frame, hint) } }.map { $0.insetBy(dx: -1, dy: -1) }
            return frame.excludedInputRegions.filter { !removable.contains($0) }
        }
        return exclusions(before) == exclusions(after) &&
            (before.excludedInputRegions + after.excludedInputRegions).allSatisfy { $0.intersection(safetyRegion).isNull }
    }
}
struct VisualNavigationHintObservationChanged: Error {}
func visualSettleNavigationHint<T>(enabled: Bool, deadline: Double, check: () throws -> Void, capture: () throws -> T) throws -> T {
    for attempt in 0..<2 {
        try check()
        do { return try capture() }
        catch is VisualNavigationHintObservationChanged {
            guard enabled, attempt == 0, ProcessInfo.processInfo.systemUptime < deadline else {
                throw fail("visual_target_changed", "Previously verified input-source hint did not settle; unknown auxiliary pixels remain excluded and input is not replayed")
            }
        }
    }
    throw fail("visual_target_changed", "Input-source hint observation did not complete")
}
func visualSettleSearchObservation<T>(enabled: Bool, deadline: Double, check: () throws -> Void,
                                      capture: () throws -> T) throws -> T {
    for attempt in 0..<4 {
        try check()
        do { return try capture() }
        catch let changed as VisualSearchObservationChanged {
            guard enabled, attempt < 3, ProcessInfo.processInfo.systemUptime < deadline else {
                throw fail("visual_target_changed", "Known search UI did not settle within the bounded fresh observation; input was not replayed", changed.details)
            }
        }
    }
    throw fail("visual_target_changed", "Search observation could not complete")
}

func visualSystemCursorWindow(_ row: [String: Any]) -> Bool {
    (row[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.cursorWindow)) &&
        row[kCGWindowOwnerName as String] as? String == "Window Server"
}
func visualScreenWindows(_ rows: [[String:Any]], identity: VisualIdentity, displays: [CGRect], dockPID: pid_t?) throws -> [VisualScreenWindow] {
    guard let main=rows.firstIndex(where:{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value==identity.windowID}),
          (rows[main][kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==identity.pid,
          let raw=rows[main][kCGWindowBounds as String] as? [String:Any],CGRect(dictionaryRepresentation:raw as CFDictionary)==identity.frame else {throw fail("visual_target_changed","Selected onscreen window identity changed")}
    var result:[VisualScreenWindow]=[]
    for row in rows.prefix(main) {
        // SCStream explicitly excludes the cursor. Its Window Server surface
        // changes shape/position without changing the captured target or owner.
        if visualSystemCursorWindow(row) { continue }
        guard let raw=row[kCGWindowBounds as String] as? [String:Any],let frame=CGRect(dictionaryRepresentation:raw as CFDictionary),
              !frame.intersection(identity.frame).isNull,(row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
              let id=(row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid=(row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else{continue}
        let title=row[kCGWindowName as String] as? String ?? "",layer=(row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let dock=pid==dockPID && dockPID != nil && title=="Dock" && layer==Int(CGWindowLevelForKey(.dockWindow)) && displays.contains(frame)
        result.append(VisualScreenWindow(id:id,pid:pid,frame:frame,layer:layer,alpha:(row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,emptyTitle:title.isEmpty,dockSurface:dock))
    }
    guard result.count<=64 else{throw fail("visual_occlusion_unavailable","Too many overlapping windows")};return result
}
func visualScreenCoverage(_ base:[CGRect], windows:[VisualScreenWindow], identity:VisualIdentity, overlay:VisualSearchOverlay?, dockRegions:[CGRect]?, notificationRegions: [CGWindowID: [CGRect]] = [:]) throws -> [CGRect] {
    var coverage=base
    for item in windows {
        if item.pid==identity.pid && (item.id==overlay?.windowID || (item.inputHintCandidate && visualContains(identity.frame,item.frame))) {continue}
        var exclusions:[CGRect]
        if item.dockSurface {
            guard let dockRegions,!dockRegions.isEmpty else{throw fail("visual_occlusion_unavailable","Transparent Dock surface has no verified interactive geometry")}
            exclusions=dockRegions.map{$0.insetBy(dx:-12,dy:-12)}
        }else if let regions = notificationRegions[item.id], !regions.isEmpty {
            exclusions = regions.map { $0.insetBy(dx: -12, dy: -12) }
        }else{exclusions=[item.frame]}
        for rect in exclusions {coverage=coverage.flatMap{visualSubtract($0,rect)}}
        guard coverage.count<=32 else{throw fail("visual_occlusion_unavailable","Visible screen fragments exceed the bounded limit")}
    }
    return coverage
}
// The verified fullscreen Notification Center AXWindow contains exactly one
// same-frame group. Its complete direct child groups conservatively bound the
// panel, including all notification content beneath them. Never infer an empty
// panel, inspect text, or accept partial/unknown trees as transparent.
func visualNotificationPanelBounds(display: CGRect, window: CGRect, wrapper: CGRect,
                                   panels: [CGRect], complete: Bool) -> [CGRect]? {
    guard complete, window == display, wrapper == display, !panels.isEmpty, panels.count <= 8,
          panels.allSatisfy({ $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite &&
              $0.width > 0 && $0.height > 0 && $0 != display && visualContains(display, $0) }) else { return nil }
    return panels
}

func visualNotificationMasks(_ windows: [VisualScreenWindow], displays: [CGRect]) -> [CGWindowID: [CGRect]] {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
        .filter { !$0.isTerminated && $0.bundleURL?.path == "/System/Library/CoreServices/NotificationCenter.app" }
    let pids = Set(apps.map { $0.processIdentifier })
    var masks: [CGWindowID: [CGRect]] = [:]
    for surface in windows where pids.contains(surface.pid) && surface.layer == 23 && surface.alpha == 1 && displays.contains(surface.frame) {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        let root = AXUIElementCreateApplication(surface.pid); AXUIElementSetMessagingTimeout(root, 0.08)
        func list(_ element: AXUIElement, _ name: String, range: ClosedRange<Int>) -> [AXUIElement]? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(element, name as CFString, &count) == .success, range.contains(count) else { return nil }
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(element, name as CFString, 0, count, &values) == .success,
                  let elements = values as? [AXUIElement], elements.count == count else { return nil }
            return elements
        }
        func node(_ element: AXUIElement, role: String) -> CGRect? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.08)
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == surface.pid,
                  axString(element, kAXRoleAttribute) == role else { return nil }
            return axBounds(element)
        }
        guard let allWindows = list(root, kAXWindowsAttribute, range: 1...8) else { continue }
        let matching = allWindows.filter { node($0, role: kAXWindowRole) == surface.frame }
        guard matching.count == 1, let window = matching.first,
              let children = list(window, kAXChildrenAttribute, range: 1...1), let wrapper = children.first,
              node(wrapper, role: kAXGroupRole) == surface.frame,
              let panels = list(wrapper, kAXChildrenAttribute, range: 1...8) else { continue }
        let bounds = panels.compactMap { node($0, role: kAXGroupRole) }
        guard bounds.count == panels.count,
              let verified = visualNotificationPanelBounds(display: surface.frame, window: surface.frame,
                  wrapper: surface.frame, panels: bounds, complete: true),
              let finalChildren = list(window, kAXChildrenAttribute, range: 1...1), CFEqual(finalChildren[0], wrapper),
              let finalPanels = list(wrapper, kAXChildrenAttribute, range: 1...8), finalPanels.count == panels.count,
              zip(finalPanels, panels).allSatisfy({ CFEqual($0.0, $0.1) }),
              node(window, role: kAXWindowRole) == surface.frame,
              node(wrapper, role: kAXGroupRole) == surface.frame,
              panels.compactMap({ node($0, role: kAXGroupRole) }) == bounds else { continue }
        masks[surface.id] = verified
    }
    return masks
}
func visualNotificationMaskMetadata(_ masks: [CGWindowID: [CGRect]]) -> [[String: Any]] {
    masks.keys.sorted().map { ["window_id": $0, "panel_regions": masks[$0]!.map { rectJSON($0) },
        "padding_points": 12, "proof": "exact_system_app_AXWindow_single_same_frame_wrapper_complete_direct_groups"] }
}

// Diagnostic only. Exact system identity/geometry selects the probe, never
// grants visibility. No titles, values, notification text, or foreign pixels.
func visualNotificationSurfaceDiagnostic(_ windows: [VisualScreenWindow], identity: VisualIdentity,
                                         displays: [CGRect]) -> [String: Any]? {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
    let pids = Set(apps.filter { !$0.isTerminated }.map { $0.processIdentifier })
    let candidates = windows.filter { pids.contains($0.pid) && $0.layer == 23 && $0.alpha == 1 && displays.contains($0.frame) }
    guard !candidates.isEmpty, candidates.count <= 2 else { return nil }
    let started = ProcessInfo.processInfo.systemUptime, deadline = ProcessInfo.processInfo.systemUptime + 0.8
    let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.10)
    var samples: [[String: Any]] = [], tree: [[String: Any]] = []
    let positions = [("search", 0.22, 0.035), ("body", 0.66, 0.50), ("composer", 0.66, 0.90)]
    for (label, x, y) in positions {
        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
        let point = CGPoint(x: identity.frame.minX + identity.frame.width * x, y: identity.frame.minY + identity.frame.height * y)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        var row: [String: Any] = ["region": label, "point": ["x": point.x, "y": point.y], "AX_hit_result": error.rawValue]
        if error == .success, let hit {
            AXUIElementSetMessagingTimeout(hit, 0.08)
            var pid: pid_t = 0
            let pidError = AXUIElementGetPid(hit, &pid)
            row["pid_result"] = pidError.rawValue
            if pidError == .success {
                row["pid"] = pid; row["same_target_PID"] = pid == identity.pid
                row["role"] = axString(hit, kAXRoleAttribute) ?? "unavailable"
                row["bounds"] = axBounds(hit).map { rectJSON($0) as Any } ?? NSNull()
            }
        }
        samples.append(row)
    }
    var queue: [(AXUIElement, Int, Int)] = []
    for pid in Set(candidates.map { $0.pid }) { queue.append((AXUIElementCreateApplication(pid), 0, -1)) }
    var visited: [AXUIElement] = [], cursor = 0, truncated = false
    while cursor < queue.count && visited.count < 24 && ProcessInfo.processInfo.systemUptime < deadline {
        let (element, depth, parent) = queue[cursor]; cursor += 1
        if visited.contains(where: { CFEqual($0, element) }) { continue }
        visited.append(element); AXUIElementSetMessagingTimeout(element, 0.08)
        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(element, &pid)
        var row: [String: Any] = ["node": tree.count, "parent_node": parent, "depth": depth, "pid_result": pidError.rawValue]
        guard pidError == .success, pids.contains(pid) else { row["rejected"] = "unverified_system_PID"; tree.append(row); continue }
        row["pid"] = pid
        func attribute(_ name: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; return nil }
            var value: CFTypeRef?; let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            row[name + "_result"] = error.rawValue; return error == .success ? value : nil
        }
        row["role"] = attribute(kAXRoleAttribute) as? String ?? "unavailable"
        if let position = attribute(kAXPositionAttribute), let size = attribute(kAXSizeAttribute),
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero, dimensions = CGSize.zero
            if AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
               AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) {
                row["bounds"] = rectJSON(CGRect(origin: point, size: dimensions))
            }
        }
        for name in depth == 0 ? [kAXWindowsAttribute, kAXChildrenAttribute] : [kAXChildrenAttribute] {
            guard ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; break }
            var count: CFIndex = 0
            let error = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
            row[name + "_count_result"] = error.rawValue
            if error == .success {
                row[name + "_count"] = count
                if count > 0, depth < 3, count <= 24, queue.count + count <= 48 {
                    var values: CFArray?
                    let result = AXUIElementCopyAttributeValues(element, name as CFString, 0, count, &values)
                    row[name + "_read_result"] = result.rawValue
                    if result == .success, let elements = values as? [AXUIElement] {
                        queue += elements.map { ($0, depth + 1, tree.count) }
                    } else { truncated = true }
                } else if count > 0 { truncated = true }
            }
        }
        tree.append(row)
    }
    truncated = truncated || cursor < queue.count
    return ["diagnostic_only": true, "changes_visibility": false, "AX_trusted": AXIsProcessTrusted(),
        "candidate_bundle_id": "com.apple.notificationcenterui",
        "candidate_windows": candidates.map { ["window_id": $0.id, "pid": $0.pid, "layer": $0.layer, "alpha": $0.alpha, "bounds": rectJSON($0.frame)] as [String: Any] },
        "point_samples": samples, "system_AX_nodes": tree, "tree_truncated": truncated,
        "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000]
}

func visualDockRegions(_ pid:pid_t?) -> [CGRect]? {
    guard let pid else{return nil};let application=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(application,0.15)
    let children=axElements(application,kAXChildrenAttribute,limit:9);guard !children.isEmpty,children.count<9 else{return nil}
    var regions:[CGRect]=[]
    for child in children {
        if let bounds=axBounds(child),bounds.width>0,bounds.height>0{regions.append(bounds)}
        let items=axElements(child,kAXChildrenAttribute,limit:65);guard items.count<65 else{return nil}
        for item in items {if let bounds=axBounds(item),bounds.width>0,bounds.height>0{regions.append(bounds)}}
    }
    return regions.isEmpty ? nil:regions
}

// These two observed UI artifacts are recognised from their pixels, never by
// deleting OCR characters. Other coloured names, emoji and unknown windows remain.
func visualRGBA(_ image: CGImage) throws -> CGImage {
    guard let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw fail("visual_capture_failed", "RGBA allocation failed") }
    c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = c.makeImage() else { throw fail("visual_capture_failed", "RGBA image unavailable") }; return result
}
func visualPaintNeutral(_ image: CGImage, boxes: [CGRect], allowSearchFocusRing: Bool = false) throws -> CGImage {
    let raw = try visualRGBA(image)
    guard let data = raw.dataProvider?.data, let p = CFDataGetBytePtr(data),
          let c = CGContext(data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw fail("visual_capture_failed", "UI artifact pixels unavailable") }
    c.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
    for original in boxes {
        let b = original.insetBy(dx: -1, dy: -1).integral
        guard visualContains(CGRect(x: 1, y: 1, width: raw.width - 2, height: raw.height - 2), b) else { throw fail("visual_artifact_unverified", "UI artifact reaches crop boundary") }
        // Sample both sides on each row. The real exposed cap straddles the
        // search/background boundary; preserving this local neutral gradient
        // avoids assuming the popup's whole bounding box is opaque.
        for y in Int(b.minY)..<Int(b.maxY) {
            var tones:[[Int]]=[]
            for x in [Int(b.minX)-1,Int(b.maxX)] {
                let i=y*raw.bytesPerRow+x*4,rgb=[Int(p[i]),Int(p[i+1]),Int(p[i+2])]
                let neutral=rgb.min()! >= (allowSearchFocusRing ? 180:200) && rgb.max()!-rgb.min()!<=8
                let searchGreen=allowSearchFocusRing && rgb[0]<=20 && (175...200).contains(rgb[1]) && (95...130).contains(rgb[2])
                guard p[i+3]==255,neutral || searchGreen else{throw fail("visual_artifact_unverified","UI artifact surrounding row is not a verified background")}
                tones.append(rgb)
            }
            guard zip(tones[0],tones[1]).allSatisfy({abs($0-$1)<=6}) else{throw fail("visual_artifact_unverified","UI artifact overlaps a background edge")}
            for x in Int(b.minX)..<Int(b.maxX) {
                let i=y*raw.bytesPerRow+x*4,r=Int(p[i]),g=Int(p[i+1]),bl=Int(p[i+2])
                guard !(max(r,g,bl)<180 && max(r,g,bl)-min(r,g,bl)<50) else{throw fail("visual_artifact_unverified","UI artifact overlaps neutral text ink")}
            }
            let rgb=(0..<3).map{CGFloat(tones[0][$0]+tones[1][$0])/510}
            c.setFillColor(CGColor(red:rgb[0],green:rgb[1],blue:rgb[2],alpha:1))
            c.fill(CGRect(x:b.minX,y:CGFloat(raw.height-y-1),width:b.width,height:1))
        }
    }
    guard let result=c.makeImage() else { throw fail("visual_capture_failed", "UI artifact mask failed") }; return result
}
func visualInputHint(_ image: CGImage, window: CGRect, auxiliary: CGRect, frontPopup: CGRect? = nil) throws -> CGRect? {
    guard auxiliary.width == 84, auxiliary.height == 77, visualContains(window, auxiliary) else { return nil }
    let sx=Double(image.width)/window.width, sy=Double(image.height)/window.height
    let pixels=CGRect(x:(auxiliary.minX-window.minX)*sx,y:(auxiliary.minY-window.minY)*sy,width:84*sx,height:77*sy).integral
    guard let crop=image.cropping(to:pixels) else { return nil };let raw=try visualRGBA(crop)
    guard let data=raw.dataProvider?.data,let p=CFDataGetBytePtr(data) else{return nil}
    var minX=raw.width,minY=raw.height,maxX = -1,maxY = -1,blue=0
    for y in 0..<raw.height {for x in 0..<raw.width {let i=y*raw.bytesPerRow+x*4;let r=Int(p[i]),g=Int(p[i+1]),b=Int(p[i+2]);if p[i+3]>200 && b>190 && b-r>100 && g>65 && g<180 {minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y);blue+=1}}}
    guard maxX>=minX,maxY>=minY else{return nil}
    let box=CGRect(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1)
    let bounds=CGRect(x:window.minX+(pixels.minX+box.minX)/sx,y:window.minY+(pixels.minY+box.minY)/sy,width:box.width/sx,height:box.height/sy)
    let expected=CGRect(x:auxiliary.minX+27,y:auxiliary.minY+27,width:30,height:23)
    if let frontPopup, visualContains(frontPopup,expected), bounds.height>=1,bounds.height<=6,
       abs(bounds.minY-expected.minY)<=1,abs(bounds.midX-expected.midX)<=1,
       bounds.width>=12,bounds.width<=30,Double(blue)/(box.width*box.height)>0.60 {
        // Observed search state: only the capsule's curved blue top is visible;
        // the front popup hides its white glyph. Verify that precise cap curve,
        // not the popup's overall alpha or the auxiliary's aliased screenshot.
        var curve=true
        for y in minY...maxY {
            var left=raw.width,right = -1
            for x in minX...maxX {let i=y*raw.bytesPerRow+x*4,r=Int(p[i]),g=Int(p[i+1]),b=Int(p[i+2]);if p[i+3]>200 && b>190 && b-r>100 && g>65 && g<180 {left=min(left,x);right=max(right,x)}}
            guard right>=left else{curve=false;break}
            let dy=(Double(y)+0.5)/sy-27, radius=11.5
            let half=3.5+sqrt(max(0,2*radius*dy-dy*dy))
            let expectedLeft=(42-half)*sx,expectedRight=(42+half)*sx
            if abs(Double(left)-expectedLeft)>2*sx || abs(Double(right+1)-expectedRight)>2*sx {curve=false;break}
        }
        if curve { _ = try visualPaintNeutral(raw,boxes:[box],allowSearchFocusRing:true);return bounds }
    }
    guard abs(bounds.minX-expected.minX)<=1,abs(bounds.minY-expected.minY)<=1,
          (29...31).contains(bounds.width),(22...25).contains(bounds.height),Double(blue)/(box.width*box.height)>0.68,
          let pill=raw.cropping(to:box.insetBy(dx:-2,dy:-2)) else{return nil}
    let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["zh-Hans"];request.usesLanguageCorrection=false
    try VNImageRequestHandler(cgImage:pill,options:[:]).perform([request])
    guard request.results?.count==1,let candidate=request.results?.first?.topCandidates(1).first,
          candidate.string=="拼",candidate.confidence>=0.5 else{return nil}
    // The real hint is a blue rounded pill with a white glyph. Black user text
    // called 拼 and generic blue components cannot meet these pixel conditions.
    let glyph=visualOCRBounds(request.results![0].boundingBox,region:box.insetBy(dx:-2,dy:-2))
    var white=0
    for y in max(0,Int(glyph.minY))..<min(raw.height,Int(glyph.maxY.rounded(.up))) {for x in max(0,Int(glyph.minX))..<min(raw.width,Int(glyph.maxX.rounded(.up))) {let i=y*raw.bytesPerRow+x*4;if p[i]>225 && p[i+1]>225 && p[i+2]>225 {white+=1}}}
    guard white>=Int(8*sx*sy) else{return nil}
    _ = try visualPaintNeutral(raw,boxes:[box])
    return bounds
}
func visualClawBadge(_ image: CGImage, actual: CGRect, window: CGRect, observation: VNRecognizedTextObservation, candidate: VNRecognizedText) throws -> (CGImage,CGRect,Double)? {
    let text=candidate.string,bounds=visualOCRBounds(observation.boundingBox,region:actual)
    guard bounds.minX>=window.minX+326,bounds.minX<=window.minX+360,
          bounds.minY>=window.minY+5,bounds.maxY<=window.minY+40,
          let regex=try? NSRegularExpression(pattern:"[（(][0-9]{1,6}[）)]"),
          let last=regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).last,
          let countRange=Range(last.range,in:text),countRange.upperBound<text.endIndex,
          let suffixBox=try candidate.boundingBox(for:countRange.upperBound..<text.endIndex)?.boundingBox else{return nil}
    let suffix=visualOCRBounds(suffixBox,region:actual)
    let sx=Double(image.width)/actual.width,sy=Double(image.height)/actual.height
    let scan=CGRect(x:(suffix.minX-actual.minX-4)*sx,y:(bounds.minY-actual.minY-2)*sy,width:(suffix.width+8)*sx,height:(bounds.height+4)*sy).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
    let raw=try visualRGBA(image);guard let data=raw.dataProvider?.data,let p=CFDataGetBytePtr(data) else{return nil}
    func category(_ x:Int,_ y:Int)->UInt8 {let i=y*raw.bytesPerRow+x*4;let r=Int(p[i]),g=Int(p[i+1]),b=Int(p[i+2]);guard p[i+3]>200 else{return 0};if b>170 && b-r>70 && g>70 && g<220{return 1};if r>170 && r-b>60 && g>65 && g<230{return 2};if g>130 && g-r>40 && g-b>15{return 3};return 0}
    var minX=raw.width,minY=raw.height,maxX = -1,maxY = -1,counts=[0,0,0,0]
    guard !scan.isNull,scan.width<=80*sx,scan.height<=40*sy else{return nil}
    for y in Int(scan.minY)..<Int(scan.maxY) {for x in Int(scan.minX)..<Int(scan.maxX) {let c=Int(category(x,y));if c>0 {counts[c]+=1;minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)}}}
    guard maxX>=minX,maxY>=minY else{return nil};let box=CGRect(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1)
    let global=CGRect(x:actual.minX+box.minX/sx,y:actual.minY+box.minY/sy,width:box.width/sx,height:box.height/sy)
    guard (16...21).contains(global.width),(13...18).contains(global.height),!global.intersection(suffix).isNull,
          counts[1]>=Int(25*sx*sy),counts[2]>=Int(4*sx*sy),counts[3]>=Int(2*sx*sy) else{return nil}
    // Measured blue speech-bubble + lower-right green/orange sparkle signature.
    // This is deliberately not a general coloured-emoji detector.
    let referenceRows: [String] = ["......BBBB..........","...BBBBBBBBBB.......","..BB........BB......",".BB..........BB.....",".B............BB....","BB.............B....","BB.............B....","BB.............G....","BB............GGG...",".B.............GG...",".BB.........WW...GB.","..BB.......WWW...BBB","...BBBBBBBB..W...BB.","..BBB.........WWB...","..............WWW...","...............W...."]
    let reference: [[UInt8]] = referenceRows.map { line in line.map { char -> UInt8 in
        switch char { case "B": return 1; case "W": return 2; case "G": return 3; default: return 0 }
    }}
    var observed=[[UInt8]](repeating:[UInt8](repeating:0,count:20),count:16)
    for y in 0..<16 {for x in 0..<20 {observed[y][x]=category(Int(box.minX+(Double(x)+0.5)*box.width/20),Int(box.minY+(Double(y)+0.5)*box.height/16))}}
    func similarity(_ a:[[UInt8]],_ b:[[UInt8]])->Double {var n=0,m=0;for y in 0..<16 {for x in 0..<20 where a[y][x]>0 {n+=1;var hit=false;for yy in max(0,y-1)...min(15,y+1){for xx in max(0,x-1)...min(19,x+1){if a[y][x]==b[yy][xx]{hit=true}}};if hit{m+=1}}};return n>0 ? Double(m)/Double(n):0}
    let score=min(similarity(reference,observed),similarity(observed,reference));guard score>=0.90 else{return nil}
    return (try visualPaintNeutral(raw,boxes:[box]),global,score)
}

struct VisualFrame {
    let image: CGImage
    let completeSerial: Int
    let time: Double
    let completeTime: Double
    let idleConfirmed: Bool
    var capturedRegions: [CGRect]? = nil
    var searchOverlay: VisualSearchOverlay? = nil
    var searchQuery: String? = nil
    var screenWindows: [VisualScreenWindow] = []
    var captureAuxiliaryFrames: [CGRect] = []
    var excludedInputRegions: [CGRect] = []
    var inputSourceHints: [CGRect] = []
    var debugRawImage: CGImage? = nil
    var coverageDiagnostics: [[String: Any]]? = nil
    var captureSource = "SCScreenshotManager_verified_screen_regions"
    var visibleRegions: [CGRect]? = nil
    var contentDigest: String? = nil
    var contentUnchanged: Bool? = nil
    var contentUnavailableReason: String? = nil
    var mainContentDiagnostics: [String: Any]? = nil
    var captureEvidence: [String: Any]? = nil
}

// Failure-only evidence for the exact predicates used by guardSnapshot. Do not
// include OCR, query contents, window titles, raw pixels or captureEvidence.
func visualSnapshotVisibilityDiagnostic(_ before: VisualFrame, _ after: VisualFrame,
                                       now: Double) -> [String: Any] {
    func regions(_ values: [CGRect]?) -> [String: Any] {
        ["present": values != nil, "count": values?.count ?? 0,
         "rects": Array((values ?? []).prefix(32)).map(rectJSON),
         "truncated": (values?.count ?? 0) > 32]
    }
    func unionEqual(_ a: [CGRect]?, _ b: [CGRect]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.allSatisfy { visualCovered($0, by: b) } && b.allSatisfy { visualCovered($0, by: a) }
    }
    func overlay(_ value: VisualSearchOverlay?) -> Any {
        guard let value else { return NSNull() }
        return ["window_id": value.windowID, "frame": rectJSON(value.frame)] as [String: Any]
    }
    func age(_ time: Double) -> Any {
        guard now.isFinite, time.isFinite else { return NSNull() }
        return (now - time) * 1000
    }
    return [
        "equal": ["captured_regions": before.capturedRegions == after.capturedRegions,
            "captured_region_union": unionEqual(before.capturedRegions, after.capturedRegions),
            "screen_windows": before.screenWindows == after.screenWindows,
            "excluded_input_regions": before.excludedInputRegions == after.excludedInputRegions,
            "excluded_region_union": unionEqual(before.excludedInputRegions, after.excludedInputRegions),
            "search_overlay": before.searchOverlay == after.searchOverlay,
            "search_query": before.searchQuery == after.searchQuery,
            "input_source_hints": before.inputSourceHints == after.inputSourceHints,
            "capture_auxiliary_frames": before.captureAuxiliaryFrames == after.captureAuxiliaryFrames],
        "before_captured_regions": regions(before.capturedRegions), "after_captured_regions": regions(after.capturedRegions),
        "before_excluded_input_regions": regions(before.excludedInputRegions), "after_excluded_input_regions": regions(after.excludedInputRegions),
        "before_input_source_hints": regions(before.inputSourceHints), "after_input_source_hints": regions(after.inputSourceHints),
        "before_capture_auxiliary_frames": regions(before.captureAuxiliaryFrames), "after_capture_auxiliary_frames": regions(after.captureAuxiliaryFrames),
        "before_search_overlay": overlay(before.searchOverlay), "after_search_overlay": overlay(after.searchOverlay),
        "before_query_present": before.searchQuery != nil, "after_query_present": after.searchQuery != nil,
        "before_query_nonempty": before.searchQuery?.isEmpty == false, "after_query_nonempty": after.searchQuery?.isEmpty == false,
        "before_serial": before.completeSerial, "after_serial": after.completeSerial,
        "before_frame_age_ms": age(before.time), "after_frame_age_ms": age(after.time),
        "before_complete_frame_age_ms": age(before.completeTime), "after_complete_frame_age_ms": age(after.completeTime),
        "windows": visualWindowChangeDiagnostic(before.screenWindows, after.screenWindows)
    ]
}

func visualExactWindowFrame(_ image: CGImage, plan: VisualCapturePlan, previousSerial: Int, after: Int,
                           requestStarted: Double, completed: Double) throws -> VisualFrame {
    guard requestStarted.isFinite, completed.isFinite, completed >= requestStarted,
          completed - requestStarted <= 2, previousSerial >= 0, previousSerial < Int.max,
          previousSerial + 1 > after else { throw fail("visual_frame_timeout", "Exact-window request did not meet serial/time bounds") }
    guard image.width == plan.width, image.height == plan.height,
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw fail("visual_target_changed", "Exact-window screenshot pixel dimensions do not match the selected-window plan")
    }
    // Normalise channel order only, preserving every pixel at the requested scale.
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let rgba = context.makeImage() else { throw fail("visual_capture_failed", "Could not normalise exact-window pixels") }
    return VisualFrame(image: rgba, completeSerial: previousSerial + 1, time: requestStarted,
        completeTime: completed, idleConfirmed: false, capturedRegions: plan.coverage)
}

func visualVisibilitySamples(_ region: CGRect) -> [CGPoint] {
    let dx = min(12, region.width / 4), dy = min(12, region.height / 4)
    return [CGPoint(x: region.midX, y: region.midY),
            CGPoint(x: region.minX + dx, y: region.minY + dy), CGPoint(x: region.maxX - dx, y: region.minY + dy),
            CGPoint(x: region.minX + dx, y: region.maxY - dy), CGPoint(x: region.maxX - dx, y: region.maxY - dy)]
}

// This is an exclusion, never ownership evidence. A small independent same-PID
// dialog may cover only a few pixels of the selected main window. Require the
// complete public hit graph and known geometry; foreign/unknown hits still deny
// the original capture fragment. Include the hit's bounds to mask wrapper edges.
func visualSmallUntrustedWindow(_ details: [String: Any], point: CGPoint, identity: VisualIdentity) -> CGRect? {
    guard details["hit_pid"] as? Int32 == identity.pid,
          details["selected_main_verified"] as? Bool == true,
          details["traversal_truncated"] as? Bool == false,
          details["ownership_proof"] as? String == "no_public_relation_to_selected_main",
          let nodes = details["nodes"] as? [[String: Any]], !nodes.isEmpty, nodes.count <= 24 else { return nil }
    var exclusion: CGRect?, hasWindow = false
    for node in nodes {
        guard node["pid"] as? Int32 == identity.pid, node["pid_result"] as? Int32 == AXError.success.rawValue,
              node["rejected"] == nil, let role = node["role"] as? String, role != "unavailable" else { return nil }
        if role == "AXApplication" { continue }
        guard let bounds = try? visualRect(node["bounds"]), visualContains(identity.frame, bounds) else { return nil }
        if role == kAXWindowRole { hasWindow = true }
        exclusion = exclusion.map { $0.union(bounds) } ?? bounds
    }
    guard hasWindow, let exclusion, exclusion.width <= 100, exclusion.height <= 40,
          pointIsInsideRect(point, exclusion), visualContains(identity.frame, exclusion) else { return nil }
    return exclusion
}

func visualVerifiedCoverage(_ frame: VisualFrame, identity: VisualIdentity,
                            diagnostic: (([String: Any]) -> Void)? = nil,
                            hit: (CGPoint) -> VisualHitOwnership) -> [CGRect] {
    visualVerifiedObservedCoverage(frame, identity: identity, diagnostic: diagnostic) { (hit($0), [:]) }
}

func visualVerifiedObservedCoverage(_ frame: VisualFrame, identity: VisualIdentity,
                                    diagnostic: (([String: Any]) -> Void)? = nil,
                                    summary: (([String: Any]) -> Void)? = nil,
                                    hit: (CGPoint) -> (ownership: VisualHitOwnership, details: [String: Any])) -> [CGRect] {
    var sampleCount = 0, hitCount = 0
    var firstFailure: [String: Any]?, rejectionReason: String?
    defer {
        summary?(["input_region_count": (frame.capturedRegions ?? []).count,
            "sample_count": sampleCount, "AX_hit_count": hitCount,
            "first_failed_sample": firstFailure.map { $0 as Any } ?? NSNull(),
            "rejection_reason": rejectionReason.map { $0 as Any } ?? NSNull()])
    }
    let supported = frame.image.bitsPerPixel == 32 && frame.image.bitsPerComponent == 8 &&
        (frame.image.alphaInfo == .premultipliedLast || frame.image.alphaInfo == .last)
    diagnostic?(["kind": "image_format", "width": frame.image.width, "height": frame.image.height,
        "bits_per_pixel": frame.image.bitsPerPixel, "bits_per_component": frame.image.bitsPerComponent,
        "bytes_per_row": frame.image.bytesPerRow, "alpha_info": frame.image.alphaInfo.rawValue,
        "bitmap_info": frame.image.bitmapInfo.rawValue, "format_supported": supported,
        "reason": supported ? "rgba_supported" : "unsupported_pixel_format"])
    guard supported else { rejectionReason = "unsupported_pixel_format"; return [] }
    guard let data = frame.image.dataProvider?.data, let pixels = CFDataGetBytePtr(data) else {
        rejectionReason = "pixel_data_unavailable"
        diagnostic?(["kind": "rejection", "reason": "pixel_data_unavailable"]); return []
    }
    guard CFDataGetLength(data) >= frame.image.bytesPerRow * frame.image.height else {
        rejectionReason = "pixel_data_too_short"
        diagnostic?(["kind": "rejection", "reason": "pixel_data_too_short", "data_bytes": CFDataGetLength(data)]); return []
    }
    let sx = Double(frame.image.width) / identity.frame.width, sy = Double(frame.image.height) / identity.frame.height
    var coverage: [CGRect] = []
    for (index, original) in (frame.capturedRegions ?? []).enumerated() {
        var pieces = [original], exclusions: [CGRect] = [], samples = 0, completed = false
        // The observed small-dialog case takes two rounds and 25 samples.
        // Bound additional dialogs/fragments without weakening any hard rejection.
        for round in 0..<3 {
            var accepted = true, newExclusions: [CGRect] = []
            for region in pieces {
                for point in visualVisibilitySamples(region) {
                    guard samples < 100 else { accepted = false; break }
                    samples += 1
                    sampleCount += 1
                    let x = min(frame.image.width - 1, max(0, Int((point.x - identity.frame.minX) * sx)))
                    let y = min(frame.image.height - 1, max(0, Int((point.y - identity.frame.minY) * sy)))
                    let alpha = pixels[y * frame.image.bytesPerRow + x * 4 + 3]
                    if alpha >= 8 { hitCount += 1 }
                    let observed = alpha >= 8 ? hit(point) : nil
                    let allowed = observed.map { visualOwnershipAllowsPoint($0.ownership) } == true
                    let owner: String
                    var exclusion: CGRect?
                    switch observed?.ownership {
                    case .target?: owner = "target"
                    case .notImplemented?: owner = "notImplemented"
                    case .foreign?:
                        owner = "foreign"
                        exclusion = visualSmallUntrustedWindow(observed!.details, point: point, identity: identity)
                    case .unavailable?: owner = "unavailable"
                    case nil: owner = "not_queried_transparent_pixel"
                    }
                    // Metadata-only reporting must not enable the debug scan:
                    // retain normal first-failure short-circuiting and AX cost.
                    if summary != nil, firstFailure == nil, !allowed {
                        var failure: [String: Any] = ["region_index": index, "round": round,
                            "point": ["x": point.x, "y": point.y], "alpha": Int(alpha),
                            "hit_ownership": owner]
                        for key in ["ax_hit_result", "ax_pid_result", "hit_pid", "ownership_proof", "traversal_truncated"] {
                            if let value = observed?.details[key] { failure[key] = value }
                        }
                        firstFailure = failure
                    }
                    var record: [String: Any] = ["kind": "sample", "region_index": index, "region": rectJSON(region),
                        "round": round, "point": ["x": point.x, "y": point.y], "pixel_x": x, "pixel_y": y,
                        "alpha": Int(alpha), "hit_ownership": owner, "accepted": allowed,
                        "reason": alpha < 8 ? "transparent_pixel" : (allowed ? "target_pixel_verified" : "AX_" + owner)]
                    if let observed, !observed.details.isEmpty { record["AX_details"] = observed.details }
                    if let exclusion {
                        record["excluded_untrusted_window"] = rectJSON(exclusion)
                        if !exclusions.contains(exclusion), !newExclusions.contains(exclusion) { newExclusions.append(exclusion) }
                        else if exclusions.contains(exclusion) { accepted = false }
                    } else if !allowed { accepted = false }
                    diagnostic?(record)
                    if !accepted && diagnostic == nil { break }
                }
                if !accepted && diagnostic == nil { break }
            }
            guard accepted else { break }
            if newExclusions.isEmpty { completed = true; break }
            guard exclusions.count + newExclusions.count <= 4 else { break }
            for exclusion in newExclusions { pieces = pieces.flatMap { visualSubtract($0, exclusion) } }
            exclusions += newExclusions
            diagnostic?(["kind": "region_subtraction", "region_index": index, "round": round,
                "excluded_regions": newExclusions.map { rectJSON($0) }, "remaining_regions": pieces.map { rectJSON($0) }])
            guard !pieces.isEmpty, pieces.count <= 16 else { break }
        }
        if completed { coverage += pieces }
        else if !exclusions.isEmpty { diagnostic?(["kind": "rejection", "region_index": index, "reason": "remaining_fragment_not_fully_verified"]) }
    }
    return coverage
}

func visualMaskImage(_ image: CGImage, window: CGRect, coverage: [CGRect]) throws -> CGImage {
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw fail("visual_capture_failed", "Could not allocate target visibility mask")
    }
    let sx = Double(image.width) / window.width, sy = Double(image.height) / window.height
    let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.clear(canvas)
    let clips = coverage.map { rect in CGRect(x: (rect.minX - window.minX) * sx,
        y: Double(image.height) - (rect.maxY - window.minY) * sy, width: rect.width * sx, height: rect.height * sy) }
    if !clips.isEmpty {
        context.clip(to: clips)
        context.draw(image, in: canvas)
    }
    guard let masked = context.makeImage() else { throw fail("visual_capture_failed", "Could not mask non-target pixels") }
    return masked
}

// Use the same exact-main provider bytes for the digest, readable coverage and
// alpha diagnostics. Diagnostics formerly fetched the provider again and then
// repeated the same coverage sampling. No pixels or provider are retained.
func visualWindowSnapshotPixelEvidence(_ image: CGImage, window: CGRect, regions: [CGRect],
                                       data: CFData?) -> (coverage: [CGRect], diagnostics: [String: Any]) {
    var diagnostics: [String: Any] = ["stage": "exact_main_normalized_pixels_before_auxiliary_masks", "width": image.width,
        "height": image.height, "bits_per_pixel": image.bitsPerPixel, "bits_per_component": image.bitsPerComponent,
        "alpha_info": image.alphaInfo.rawValue, "bytes_per_row": image.bytesPerRow]
    guard image.bitsPerPixel == 32, image.bitsPerComponent == 8,
          image.alphaInfo == .premultipliedLast || image.alphaInfo == .last,
          let data, let pixels = CFDataGetBytePtr(data), CFDataGetLength(data) >= image.bytesPerRow * image.height else {
        diagnostics["format_supported"] = false; diagnostics["rejection_reason"] = "unsupported_normalized_pixel_format"
        return ([], diagnostics)
    }
    diagnostics["format_supported"] = true
    let sx = Double(image.width) / window.width, sy = Double(image.height) / window.height
    var coverage: [CGRect] = [], samples: [[String: Any]] = [], alphas: [UInt8] = []
    for region in regions {
        let points = visualVisibilitySamples(region)
        var readable = true
        for point in points {
            let x = max(0, min(image.width - 1, Int((point.x - window.minX) * sx)))
            let y = max(0, min(image.height - 1, Int((point.y - window.minY) * sy)))
            let alpha = pixels[y * image.bytesPerRow + x * 4 + 3]
            samples.append(["x": point.x, "y": point.y, "alpha": Int(alpha)])
            alphas.append(alpha); if alpha < 8 { readable = false }
        }
        if readable { coverage.append(region) }
    }
    diagnostics["alpha_samples"] = samples
    diagnostics["pre_mask_readable_region_count"] = coverage.count
    if alphas.allSatisfy({ $0 < 8 }) { diagnostics["rejection_reason"] = "exact_main_window_alpha_samples_transparent" }
    else if alphas.contains(where: { $0 < 8 }) { diagnostics["rejection_reason"] = "exact_main_window_alpha_sample_coverage_incomplete" }
    return (coverage, diagnostics)
}

final class VisualFrames: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "intel.desktop.visual.frames")
    let lock = NSLock()
    let context = CIContext(options: [.cacheIntermediates: false])
    let valid: () -> Bool
    var phase = "baseline"
    var phaseGeneration = 0
    var deliverySerial = 0
    var completeSerial = 0
    var latest: VisualFrame?
    var failure: String?
    init(valid: @escaping () -> Bool) { self.valid = valid }
    func state() -> (Int, Int, VisualFrame?, String?) {
        lock.lock(); defer { lock.unlock() }
        return (deliverySerial, completeSerial, latest, failure)
    }
    func setPhase(_ value: String) { lock.lock(); phase = value; phaseGeneration += 1; latest = nil; lock.unlock() }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); failure = error.localizedDescription; latest = nil; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid else { return }
        guard valid() else {
            lock.lock(); failure = "Target foreground or geometry changed"; latest = nil; lock.unlock()
            stream.stopCapture(completionHandler: nil)
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let status = attachments?.first?[.status] as? Int ?? -1
        lock.lock(); deliverySerial += 1
        if status == SCFrameStatus.complete.rawValue { completeSerial += 1 }
        let currentPhase = phase
        let currentGeneration = phaseGeneration
        let currentSerial = completeSerial
        if status == SCFrameStatus.idle.rawValue, currentPhase == "restored", let old = latest {
            // Idle is explicit stream liveness with unchanged pixels, not a new
            // complete frame. Input verification still requires a new completeSerial.
            latest = VisualFrame(image: old.image, completeSerial: old.completeSerial,
                                 time: ProcessInfo.processInfo.systemUptime, completeTime: old.completeTime, idleConfirmed: true)
        }
        lock.unlock()
        guard status == SCFrameStatus.complete.rawValue, currentPhase == "restored",
              let buffer = sample.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(ci, from: ci.extent) else { return }
        lock.lock()
        if phase == "restored", phaseGeneration == currentGeneration, failure == nil {
            let now = ProcessInfo.processInfo.systemUptime
            latest = VisualFrame(image: image, completeSerial: currentSerial, time: now, completeTime: now, idleConfirmed: false)
        }
        lock.unlock()
    }
}

// One independently live public stream per display. Idle never advances the
// aggregate complete serial; every component must be current before it is read.
final class VisualFrameGroup {
    let outputs: [VisualFrames]
    let plan: VisualCapturePlan
    var cached: VisualFrame?
    var revisions: [Int] = []
    var compositionFailure: String?
    var minimumCompleteSerial: [Int] = []
    init(outputs: [VisualFrames], plan: VisualCapturePlan) { self.outputs = outputs; self.plan = plan }
    func setPhase(_ phase: String) {
        outputs.forEach { $0.setPhase(phase) }; cached = nil; revisions = []; compositionFailure = nil; minimumCompleteSerial = []
    }
    func requireComplete(after serials: [Int]) { minimumCompleteSerial = serials; cached = nil; revisions = [] }
    func deliveryVector() -> [Int] { outputs.map { $0.state().0 } }
    func delivered(after before: [Int]) -> Bool {
        let now = deliveryVector()
        return before.count == now.count && zip(now, before).allSatisfy { $0 > $1 }
    }
    func state() -> (Int, Int, VisualFrame?, String?) {
        combine(outputs.map { $0.state() }, now: ProcessInfo.processInfo.systemUptime)
    }
    func combine(_ states: [(Int, Int, VisualFrame?, String?)], now: Double) -> (Int, Int, VisualFrame?, String?) {
        let delivered = states.reduce(0) { $0 + $1.0 }
        let serial = states.allSatisfy({ $0.1 > 0 }) ? states.reduce(0) { $0 + $1.1 } : 0
        if let failure = states.compactMap({ $0.3 }).first ?? compositionFailure { cached = nil; return (delivered, serial, nil, failure) }
        let parts = states.compactMap { $0.2 }
        guard states.count == plan.fragments.count, parts.count == states.count, !parts.isEmpty,
              minimumCompleteSerial.isEmpty || (minimumCompleteSerial.count == parts.count && zip(parts, minimumCompleteSerial).allSatisfy { $0.completeSerial > $1 }),
              parts.allSatisfy({ now >= $0.time && now - $0.time <= 2 }) else {
            // Keep the previous age for the read-only stale-stream recovery path.
            // Never renew it from a partial set of callbacks.
            return (delivered, serial, cached, nil)
        }
        let next = parts.map { $0.completeSerial }
        let timestamp = parts.map { $0.time }.min()!
        if revisions != next || cached == nil {
            // An unchanged fragment must acknowledge liveness after this update
            // cycle began, rather than laundering an older image into a new serial.
            let changedTimes = parts.enumerated().compactMap { index, part -> Double? in
                revisions.count != parts.count || revisions[index] != part.completeSerial ? part.completeTime : nil
            }
            if let boundary = changedTimes.min(), parts.contains(where: { $0.time < boundary }) {
                return (delivered, serial, cached, nil)
            }
            do {
                let image = try plan.composite(parts.map { $0.image })
                cached = VisualFrame(image: image, completeSerial: next.reduce(0, +), time: timestamp,
                    completeTime: parts.map { $0.completeTime }.max()!, idleConfirmed: false, capturedRegions: plan.coverage)
                revisions = next
            } catch { compositionFailure = error.localizedDescription; cached = nil }
        } else if let old = cached {
            cached = VisualFrame(image: old.image, completeSerial: old.completeSerial, time: timestamp,
                completeTime: old.completeTime, idleConfirmed: parts.contains { $0.idleConfirmed }, capturedRegions: plan.coverage)
        }
        return (delivered, serial, cached, compositionFailure)
    }
}

// The callback receives a value, never an alias of the active inout counter.
// Count each successful post immediately so a failing key-up guard is partial.
func visualPostCountedKeyPair(count: inout Int, beforePost: ((Int) throws -> Void)?,
                              down: () throws -> Void, up: () throws -> Void) throws {
    try beforePost?(count)
    try down(); count += 1
    try beforePost?(count)
    try up(); count += 1
}

func visualFreshPreinputFrame(_ frame: VisualFrame, after serial: Int, now: Double) -> Bool {
    frame.completeSerial > serial && !frame.idleConfirmed && frame.time.isFinite && now.isFinite &&
        now >= frame.time && now - frame.time <= 2
}

struct VisualPrefixEvidence {
    let time: Double
    let serial: Int
    func current(at now: Double) -> Bool { now.isFinite && now >= time && now-time <= 5 }
}

// An in-action prefix proof renews only from new, fully verified pixels. Its
// clock remains the capture's conservative time, never the later proof time.
func visualPrefixEvidence(_ frame: VisualFrame, identity: VisualIdentity, currentIdentity: VisualIdentity,
                          control: CGRect, rows: [[String: Any]], headerRows: [[String: Any]],
                          expected: String, title: String, allowReflow: Bool, after serial: Int,
                          now: Double) -> VisualPrefixEvidence? {
    guard identity == currentIdentity, visualFreshPreinputFrame(frame, after: serial, now: now),
          visualContains(identity.frame, control), visualCovered(control, by: frame.capturedRegions ?? []),
          visualCovered(visualSubmitHeader(identity.frame), by: frame.capturedRegions ?? []),
          rows.count <= 100, rows.allSatisfy({ $0["text"] is String }),
          headerRows.filter({ $0["text"] as? String == title }).count == 1 else { return nil }
    let actual = rows.compactMap { $0["text"] as? String }.joined(separator: "\n")
    let matches = expected.isEmpty ? visualPrefixFinalValueMatches(frame, window: identity.frame, rows: rows, expected: "", now: now) :
        (allowReflow ? visualDraftSequence(actual) == visualDraftSequence(expected) : actual == expected)
    guard matches else { return nil }
    return VisualPrefixEvidence(time: frame.time, serial: frame.completeSerial)
}

struct VisualSnapshot {
    let id: String
    let identity: VisualIdentity
    let frame: VisualFrame
    let created: Double
    let focusedWindow: AXUIElement
    let focusedFrame: CGRect
    let focusedTitle: String
    let rows: [[String: Any]]
    let anchors: [String]
    let confirmed: Bool
    let confirmationSource: String
    var anchorRegions: [CGRect] = []
    var readOnlyBackground = false
}

struct VisualNativeCommandScope: Equatable {
    let taskID: String
    let operationID: String
}

func visualContinuousSubmitRowsComplete(_ groups: [[[String: Any]]]) -> Bool {
    groups.count == 3 && groups.allSatisfy { rows in
        !rows.isEmpty && rows.count < 128 && rows.allSatisfy { row in
            guard let text = row["text"] as? String, !text.isEmpty, text.count < 1000,
                  (try? visualRect(row["bounds"])) != nil else { return false }
            return true
        }
    }
}

// One native type result may be consumed by its immediately following Return.
// This records observed content, never sending authorization or a caller proof.
struct VisualContinuousSubmitProof {
    let scope: VisualNativeCommandScope
    let helperID: ObjectIdentifier
    let snapshotID: String
    let identity: VisualIdentity
    let serial: Int
    let frameTime: Double
    let inputFinishedAt: Double
    let verifiedAt: Double
    let control: CGRect
    let message: String
    let title: String
    let revision: UInt64
    let securityVerified: Bool

    func matches(_ request: [String: Any], scope: VisualNativeCommandScope?, helperID: ObjectIdentifier,
                 snapshot: VisualSnapshot, revision: UInt64, now: Double) -> Bool {
        guard scope == self.scope, helperID == self.helperID, securityVerified,
              now.isFinite, verifiedAt.isFinite, frameTime.isFinite, inputFinishedAt.isFinite,
              frameTime >= inputFinishedAt, verifiedAt >= frameTime, now >= verifiedAt,
              now - verifiedAt <= 0.2, now - frameTime <= 1,
              self.revision == revision, snapshot.id == snapshotID, snapshot.identity == identity,
              snapshot.confirmed, !snapshot.readOnlyBackground, !snapshot.frame.idleConfirmed,
              snapshot.frame.completeSerial == serial, snapshot.frame.time == frameTime,
              snapshot.frame.searchOverlay == nil, snapshot.frame.searchQuery == nil,
              request["snapshot_id"] as? String == snapshotID,
              (try? boolean(request, "confirm_control")) == true,
              (try? visualRect(request["control_rect"])) == control,
              visualCornerSubmitNeedsFreshRevalidation(request),
              let expected = request["expected_message"] as? String, let recipient = request["chat_title"] as? String,
              !message.isEmpty, !title.isEmpty, visualNormalizedText(expected) == message,
              visualNormalizedText(recipient) == title,
              let coverage = snapshot.frame.capturedRegions, !coverage.isEmpty, coverage.count <= 32,
              let safety = try? visualControlSafetyRegion(command: "visual_key", control: control, window: identity.frame, point: nil),
              [control, safety, visualSubmitHeader(identity.frame)].allSatisfy({ visualCovered($0, by: coverage) }) else { return false }
        return true
    }
}

// The proof's immutable pixels already exclude every listed auxiliary. A new,
// missing or changed scene cannot use continuous proof, even away from the point.
func visualContinuousSubmitSceneMatches(_ frame: VisualFrame, current: [VisualScreenWindow], identity: VisualIdentity) -> Bool {
    let before = frame.screenWindows
    guard before.count <= 64, current.count <= 64,
          Set(before.map { $0.id }).count == before.count, Set(current.map { $0.id }).count == current.count else { return false }
    let rawExtra = frame.captureEvidence?["additional_own_auxiliary_exclusions"]
    guard rawExtra == nil || rawExtra is [[String: Any]] else { return false }
    let extra = rawExtra as? [[String: Any]] ?? []
    guard extra.count <= 16 else { return false }
    var extraIDs = Set<CGWindowID>()
    for row in extra {
        guard let id = try? integer(row, "window_id", default: 0, range: 1...Int(UInt32.max)),
              let pid = try? integer(row, "pid", default: 0, range: 1...Int(Int32.max)), pid == identity.pid,
              let bounds = try? visualRect(row["frame"]), visualContains(identity.frame, bounds),
              let layer = try? integer(row, "layer", default: -1, range: 0...Int.max),
              let alpha = try? number(row, "alpha"), alpha > 0, alpha <= 1,
              row["content_captured"] as? Bool == false, row["input_authorized"] as? Bool == false,
              CGWindowID(id) != identity.windowID, extraIDs.insert(CGWindowID(id)).inserted,
              !before.contains(where: { $0.id == CGWindowID(id) }),
              let item = current.first(where: { $0.id == CGWindowID(id) }),
              item.pid == identity.pid, item.frame == bounds, item.layer == layer, item.alpha == alpha, !item.dockSurface,
              (frame.capturedRegions ?? []).allSatisfy({ $0.intersection(bounds).isEmpty }) else { return false }
    }
    return current.filter { !extraIDs.contains($0.id) } == before
}

// An additional exclusion cannot authorize its pixels. This one observed
// corner change is usable only for a text navigation click wholly elsewhere.
func visualCornerExclusionHasOwnerProof(_ frame: VisualFrame, identity: VisualIdentity, corner: CGRect) -> Bool {
    guard let rows = frame.captureEvidence?["additional_own_auxiliary_exclusions"] as? [[String: Any]], rows.count <= 16 else { return false }
    let matches = rows.filter { (try? visualRect($0["frame"])) == corner }
    guard matches.count == 1, let row = matches.first,
          let windowID = try? integer(row, "window_id", default: 0, range: 1...Int(UInt32.max)), windowID != Int(identity.windowID),
          (try? integer(row, "pid", default: 0, range: 1...Int(Int32.max))) == Int(identity.pid),
          (try? integer(row, "layer", default: -1, range: 0...Int.max)) == 0,
          row["content_captured"] as? Bool == false, row["input_authorized"] as? Bool == false else { return false }
    return true
}

// This recognizes a submit request's required UI comparison fields only. It
// grants no sending permission: the high-level send entry validates exact human
// authorization, and action() must still re-read the full composer and recipient
// from a complete post-input frame before its one Return. Only the native
// one-use continuous proof below may carry that same-frame verification.
// Corner equivalence itself can never bypass value/recipient revalidation.
// guardSnapshot already acquired and validated this frame in this same RPC.
// Reuse only a new, complete, recent frame with the entire composer/header.
func visualSubmitGuardFrameReusable(_ frame: VisualFrame, snapshot: VisualSnapshot,
                                   control: CGRect, now: Double) -> Bool {
    guard !snapshot.readOnlyBackground, snapshot.confirmed, !frame.idleConfirmed,
          frame.completeSerial > snapshot.frame.completeSerial,
          now.isFinite, frame.time.isFinite, frame.completeTime.isFinite,
          frame.time <= frame.completeTime, frame.completeTime <= now,
          now - frame.time <= 1,
          visualContains(snapshot.identity.frame, control),
          visualCovered(control, by: frame.capturedRegions ?? []),
          visualCovered(visualSubmitHeader(snapshot.identity.frame), by: frame.capturedRegions ?? []) else { return false }
    return true
}

func visualCornerSubmitNeedsFreshRevalidation(_ request: [String: Any]) -> Bool {
    guard request["command"] as? String == "visual_key",
          ["return", "enter"].contains((request["key"] as? String)?.lowercased() ?? ""),
          request["control_kind"] as? String == "chat_composer",
          (try? boolean(request, "allow_submit")) == true,
          let message = request["expected_message"] as? String, message.count <= 4096,
          !visualNormalizedText(message).isEmpty,
          let title = request["chat_title"] as? String, title.count <= 128,
          !visualNormalizedText(title).isEmpty,
          !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else { return false }
    if let raw = request["modifiers"] {
        guard let values = raw as? [String], values.isEmpty else { return false }
    }
    return true
}

// A corner window first observed during capture is stored in the exclusion
// metadata, outside that frame's baseline CG list. On the next capture the same
// window can enter the baseline list and is still subtracted by screen coverage.
// Compare this one representation change by exact identity; its pixels remain
// unavailable. A fully specified submit may reach its independent fresh-value
// revalidation. A different window, coverage, window ordering or foreign surface fails.
func visualNavigationCornerExclusionMigration(_ request: [String: Any], snapshot: VisualSnapshot,
                                              after: VisualFrame) -> Bool {
    guard let command = request["command"] as? String,
          ["visual_click", "visual_scroll", "visual_type_text", "visual_key"].contains(command),
          let kind = request["control_kind"] as? String,
          ["navigation", "search", "chat_composer"].contains(kind),
          (try? boolean(request, "confirm_control")) == true,
          snapshot.confirmed, !snapshot.readOnlyBackground, snapshot.anchors.count >= 2, !snapshot.anchorRegions.isEmpty,
          let control = try? visualRect(request["control_rect"]), visualContains(snapshot.identity.frame, control),
          let beforeCoverage = snapshot.frame.capturedRegions, !beforeCoverage.isEmpty, beforeCoverage.count <= 32,
          let afterCoverage = after.capturedRegions, !afterCoverage.isEmpty, afterCoverage.count <= 32,
          beforeCoverage.allSatisfy({ visualCovered($0, by: afterCoverage) }),
          afterCoverage.allSatisfy({ visualCovered($0, by: beforeCoverage) }),
          after.completeSerial > snapshot.frame.completeSerial, !after.idleConfirmed else { return false }
    let edits = command == "visual_type_text" || command == "visual_key"
    if edits {
        guard ["search", "chat_composer"].contains(kind), snapshot.anchorRegions.count >= 2 else { return false }
        if command == "visual_key", ["return", "enter"].contains((request["key"] as? String)?.lowercased() ?? ""),
           !visualCornerSubmitNeedsFreshRevalidation(request) { return false }
    } else if kind != "navigation" && command != "visual_click" { return false }
    let before = snapshot.frame, identity = snapshot.identity
    let corner = CGRect(x: identity.frame.minX + 6, y: identity.frame.minY + 5, width: 52, height: 20)
    guard before.searchOverlay == after.searchOverlay, before.searchQuery == after.searchQuery,
          before.inputSourceHints == after.inputSourceHints, before.captureAuxiliaryFrames == after.captureAuxiliaryFrames,
          beforeCoverage.allSatisfy({ $0.intersection(corner).isEmpty }),
          before.excludedInputRegions.filter({ $0 != corner }) == after.excludedInputRegions.filter({ $0 != corner }) else { return false }
    let beforeCount = before.excludedInputRegions.filter { $0 == corner }.count
    let afterCount = after.excludedInputRegions.filter { $0 == corner }.count
    guard (beforeCount == 1 && afterCount == 0) || (beforeCount == 0 && afterCount == 1) else { return false }
    let excluded = beforeCount == 1 ? before : after
    let baseline = beforeCount == 1 ? after : before
    guard visualCornerExclusionHasOwnerProof(excluded, identity: identity, corner: corner),
          let exclusions = excluded.captureEvidence?["additional_own_auxiliary_exclusions"] as? [[String: Any]],
          let row = exclusions.first(where: { (try? visualRect($0["frame"])) == corner }),
          let windowID = try? integer(row, "window_id", default: 0, range: 1...Int(UInt32.max)),
          let alpha = try? number(row, "alpha"), alpha == 1,
          !excluded.screenWindows.contains(where: { $0.id == CGWindowID(windowID) || $0.frame == corner }) else { return false }
    let matches = baseline.screenWindows.filter { $0.id == CGWindowID(windowID) }
    guard matches.count == 1, let window = matches.first,
          window.pid == identity.pid, window.id != identity.windowID, window.frame == corner,
          window.layer == 0, window.alpha == alpha, !window.emptyTitle, !window.dockSurface,
          baseline.screenWindows.filter({ $0.frame == corner }).count == 1,
          baseline.screenWindows.filter({ $0.id != window.id }) == excluded.screenWindows else { return false }
    let point: CGPoint?
    if request["x"] != nil || request["y"] != nil {
        guard let x = try? number(request, "x"), let y = try? number(request, "y"),
              pointIsInsideRect(CGPoint(x: x, y: y), control) else { return false }
        point = CGPoint(x: x, y: y)
    } else { point = nil }
    guard let safety = try? visualControlSafetyRegion(command: command, control: control, window: identity.frame, point: point),
          ((edits ? [control, safety] : [safety]) + snapshot.anchorRegions).allSatisfy({ region in
              region.intersection(corner).isEmpty && visualCovered(region, by: beforeCoverage)
          }) else { return false }
    return true
}

// A completed frame may carry the recreated corner's new ID. Input still
// needs identical full coverage and independently guarded control/anchor pixels.
func visualInputMaskedCornerReplacement(_ request: [String: Any], snapshot: VisualSnapshot,
                                        after: VisualFrame) -> Bool {
    guard let command = request["command"] as? String,
          ["visual_click", "visual_scroll", "visual_type_text", "visual_key"].contains(command),
          let kind = request["control_kind"] as? String, ["navigation", "search", "chat_composer"].contains(kind),
          (try? boolean(request, "confirm_control")) == true, snapshot.confirmed, !snapshot.readOnlyBackground,
          snapshot.anchors.count >= 2, snapshot.anchorRegions.count >= 2,
          let control = try? visualRect(request["control_rect"]), visualContains(snapshot.identity.frame, control),
          let coverage = snapshot.frame.capturedRegions, !coverage.isEmpty, coverage == after.capturedRegions,
          after.completeSerial > snapshot.frame.completeSerial, !after.idleConfirmed else { return false }
    if command == "visual_key", ["return", "enter"].contains((request["key"] as? String)?.lowercased() ?? ""),
       !visualCornerSubmitNeedsFreshRevalidation(request) { return false }
    let before = snapshot.frame, identity = snapshot.identity
    let corner = CGRect(x: identity.frame.minX + 6, y: identity.frame.minY + 5, width: 52, height: 20)
    guard visualMaskedCornerWindowReplacement(before.screenWindows, after.screenWindows, identity: identity),
          before.excludedInputRegions == after.excludedInputRegions,
          before.searchOverlay == after.searchOverlay, before.searchQuery == after.searchQuery,
          before.inputSourceHints == after.inputSourceHints, before.captureAuxiliaryFrames == after.captureAuxiliaryFrames,
          coverage.allSatisfy({ $0.intersection(corner).isEmpty }) else { return false }
    let point: CGPoint?
    if request["x"] != nil || request["y"] != nil {
        guard let x = try? number(request, "x"), let y = try? number(request, "y"),
              pointIsInsideRect(CGPoint(x: x, y: y), control) else { return false }
        point = CGPoint(x: x, y: y)
    } else { point = nil }
    guard let safety = try? visualControlSafetyRegion(command: command, control: control, window: identity.frame, point: point),
          ([control, safety] + snapshot.anchorRegions).allSatisfy({ region in
              region.intersection(corner).isEmpty && visualCovered(region, by: coverage)
          }) else { return false }
    return true
}

func visualTextNavigationCornerMaskChange(_ request: [String: Any], snapshot: VisualSnapshot,
                                         after: VisualFrame) -> Bool {
    guard request["command"] as? String == "visual_click", request["control_kind"] as? String == "navigation",
          [nil, "text"].contains(request["navigation_target_kind"] as? String),
          (try? boolean(request, "confirm_control")) == true,
          let label = request["target_text"] as? String, !label.isEmpty,
          snapshot.confirmed, !snapshot.readOnlyBackground, snapshot.anchors.count >= 2, !snapshot.anchorRegions.isEmpty,
          let control = try? visualRect(request["control_rect"]), visualContains(snapshot.identity.frame, control),
          let beforeCoverage = snapshot.frame.capturedRegions, let afterCoverage = after.capturedRegions,
          !beforeCoverage.isEmpty, !afterCoverage.isEmpty,
          after.completeSerial > snapshot.frame.completeSerial, !after.idleConfirmed else { return false }
    let before = snapshot.frame, window = snapshot.identity.frame
    let corner = CGRect(x: window.minX + 6, y: window.minY + 5, width: 52, height: 20)
    let beforeMasked = before.excludedInputRegions.contains(corner), afterMasked = after.excludedInputRegions.contains(corner)
    guard before.screenWindows == after.screenWindows, before.searchOverlay == after.searchOverlay,
          before.searchQuery == after.searchQuery, before.inputSourceHints == after.inputSourceHints,
          before.captureAuxiliaryFrames == after.captureAuxiliaryFrames,
          beforeMasked != afterMasked,
          before.excludedInputRegions.filter({ $0 == corner }).count <= 1, after.excludedInputRegions.filter({ $0 == corner }).count <= 1,
          before.excludedInputRegions.filter({ $0 != corner }) == after.excludedInputRegions.filter({ $0 != corner }),
          visualCornerExclusionHasOwnerProof(beforeMasked ? before : after, identity: snapshot.identity, corner: corner),
          ([control] + snapshot.anchorRegions).allSatisfy({ region in
              region.intersection(corner).isNull && visualCovered(region, by: beforeCoverage) && visualCovered(region, by: afterCoverage)
          }) else { return false }
    if request["x"] != nil || request["y"] != nil {
        guard let x = try? number(request, "x"), let y = try? number(request, "y"),
              pointIsInsideRect(CGPoint(x: x, y: y), control) else { return false }
    }
    let masked = beforeMasked ? beforeCoverage : afterCoverage
    let expected = (beforeMasked ? afterCoverage : beforeCoverage).flatMap { visualSubtract($0, corner) }
    return masked.allSatisfy { $0.intersection(corner).isEmpty } &&
        expected.allSatisfy { visualCovered($0, by: masked) } && masked.allSatisfy { visualCovered($0, by: expected) }
}

func visualLiteralNavigationProof(_ beforeRows: [[String: Any]], freshRows: [[String: Any]], label: String, control: CGRect,
                                  point: CGPoint?) -> Bool {
    let requested = visualNormalizedText(label)
    guard !requested.isEmpty, point.map({ pointIsInsideRect($0, control) }) ?? true else { return false }
    func matches(_ rows: [[String: Any]]) -> [String] {
        rows.compactMap { row -> String? in
            guard let text = row["text"] as? String, let bounds = try? visualRect(row["bounds"]),
                  visualContains(control, bounds) else { return nil }
            let normalized = visualNormalizedText(text)
            if let point {
                // Preserve normal explicit-point navigation's label matching,
                // then bind the whole observed row, including its ellipsis.
                guard normalized.contains(requested), pointIsInsideRect(point, bounds.insetBy(dx: -2, dy: -2)) else { return nil }
            } else if normalized != requested { return nil }
            return text
        }
    }
    let before = matches(beforeRows), fresh = matches(freshRows)
    return before.count == 1 && fresh.count == 1 && before[0] == fresh[0]
}

func visualReboundNavigationSnapshot(_ old: VisualSnapshot, frame: VisualFrame, rows: [[String: Any]]) -> VisualSnapshot {
    VisualSnapshot(id: old.id, identity: old.identity, frame: frame, created: old.created,
        focusedWindow: old.focusedWindow, focusedFrame: old.focusedFrame, focusedTitle: old.focusedTitle,
        rows: rows, anchors: old.anchors, confirmed: old.confirmed, confirmationSource: old.confirmationSource,
        anchorRegions: old.anchorRegions, readOnlyBackground: old.readOnlyBackground)
}

final class VisualDesktop {
    var backgroundReadOnly = false
    var backgroundCapture = "auto"
    var capturePlan: VisualCapturePlan?
    var latestWindowFrame: VisualFrame?
    var windowCaptureSerial = 0
    var captureReady: Bool { identity != nil && capturePlan != nil }
    var diagnosticsRequested = false
    var latestWarmEvidence: [String: Any]? = nil
    var stream: SCStream?
    var frames: VisualFrameGroup?
    var streams: [SCStream] = []
    var identity: VisualIdentity?
    var selectedAXWindow: AXUIElement?
    var snapshot: VisualSnapshot?
    var content: SCShareableContent?
    var selectedInput: (VisualIdentity, String, CGRect, AXUIElement)?
    var selectedInputRevision: UInt64?
    var searchActivation: VisualSearchActivation?
    private var nativeCommandScope: VisualNativeCommandScope?
    private var continuousSubmitProof: VisualContinuousSubmitProof?
    let captureClearColor = CGColor(gray: 0, alpha: 0)
    var visibilitySource: CGImage?
    var visibilityRegions: [CGRect] = []
    var visibilityImage: CGImage?

    // Reuse text only after hashing the current, fully covered ROI. These
    // entries retain no image, pixel buffer, frame, or input authorization.
    struct OCRCacheKey: Equatable {
        let identity: VisualIdentity
        let region: CGRect
        let pixels: CGRect
        let actual: CGRect
        let scaleX: Double
        let scaleY: Double
        let imageWidth: Int
        let imageHeight: Int
        let coverage: [CGRect]
        let visibleRegions: [CGRect]?
        let exclusions: [CGRect]
        let pixelFormat: UInt32
        let colorSpaceName: String
        let colorProfileDigest: [UInt8]?
        let renderingIntent: Int32
        let interpolate: Bool
    }
    struct OCRCacheEntry {
        let key: OCRCacheKey
        let digest: [UInt8]
        let rows: [[String: Any]]
        let created: Double
        let serial: Int
    }
    // Call-local preparation only: never stored in the text cache or used as
    // input authorization. Vision consumes the exact crop whose raw bits were
    // fingerprinted, instead of cropping the same ROI a second time.
    struct OCRRaster {
        let image: CGImage
        let actual: CGRect
        let scaleX: Double
        let scaleY: Double
    }
    struct OCRColorProfile {
        let space: CGColorSpace
        let name: String
        let digest: [UInt8]?
        init?(_ image: CGImage) {
            guard let space = image.colorSpace, let name = space.name else { return nil }
            self.space = space; self.name = name as String
            digest = space.copyICCData().map { Array(SHA256.hash(data: $0 as Data)) }
        }
    }
    let ocrCacheLock = NSLock()
    var ocrCacheIdentity: VisualIdentity?
    var ocrCacheGeneration: UInt64 = 0
    var ocrCacheRows: [OCRCacheEntry] = []
    var ocrRecognitionRuns = 0
    var ocrCacheHits = 0
    var ocrCrossFrameCacheHits = 0
    // End OCR cache fields.

    // Called by the native dispatch owner for every command, before execution.
    // The existing same-operation status check has no UI/input side effect.
    func beginNativeCommand(taskID: String, operationID: String?, command: String) {
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy { (32...126).contains(Int($0.value)) }
        }
        let scope = operationID.flatMap { operation in
            valid(taskID) && valid(operation) ? VisualNativeCommandScope(taskID: taskID, operationID: operation) : nil
        }
        if scope == nil || scope != nativeCommandScope || !["status", "visual_key"].contains(command) {
            continuousSubmitProof = nil
        }
        nativeCommandScope = scope
    }

    private func takeContinuousSubmitProof() -> VisualContinuousSubmitProof? {
        defer { continuousSubmitProof = nil }
        return continuousSubmitProof
    }

    func clearOCRCache() {
        ocrCacheLock.lock(); defer { ocrCacheLock.unlock() }
        ocrCacheIdentity = nil; ocrCacheGeneration &+= 1
        ocrCacheRows.removeAll(keepingCapacity: true)
    }

    var status: [String: Any] {
        var result: [String: Any] = ["available": true, "restricted_bundle_id": "com.tencent.xinWeChat",
         "stream_invalidated": false, "capture_ready": captureReady,
         "snapshot_available": snapshot != nil && captureReady, "capture_started_automatically": false,
         "capture_method": snapshot?.frame.captureSource ?? "SCStream_app_then_exact_display_windows", "ocr": "local_Apple_Vision",
         "max_snapshot_age_ms": 5000, "max_ocr_observations": 128, "ocr_observation_limit_scope": "per_region", "max_read_regions": 8, "max_visual_text_characters": 4096]
        result.merge(visualWarmCapturePoolStatus()) { _, current in current }
        return result
    }

    func stop() {
        continuousSubmitProof = nil
        clearOCRCache()
        capturePlan = nil; latestWindowFrame = nil; latestWarmEvidence = nil
        visibilitySource = nil; visibilityImage = nil; visibilityRegions = []
        let old = streams
        stream = nil; streams = []; frames = nil; identity = nil; selectedAXWindow = nil; snapshot = nil; content = nil; selectedInput = nil; searchActivation = nil
        old.forEach { $0.stopCapture(completionHandler: nil) }
    }

    func selectedIdentity(_ target: Target) throws -> VisualIdentity {
        guard target.bundleID == "com.tencent.xinWeChat", target.expectedTitle == "微信" else {
            throw fail("visual_target_unsupported", "Visual fallback requires the explicitly selected WeChat main window titled 微信")
        }
        guard let bounds = axBounds(target.window), bounds.width >= 400, bounds.height >= 300 else {
            throw fail("visual_target_unsupported", "An accessible WeChat main-window geometry is required")
        }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let matches = windows.filter { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let raw = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
            return abs(rect.minX - bounds.minX) < 0.5 && abs(rect.minY - bounds.minY) < 0.5 &&
                abs(rect.width - bounds.width) < 0.5 && abs(rect.height - bounds.height) < 0.5
        }
        guard matches.count == 1, let id = (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
            throw fail("visual_window_ambiguous", "Expected one onscreen CGWindow matching the selected AX window geometry and PID")
        }
        return VisualIdentity(pid: target.pid, windowID: id, frame: bounds, topology: target.displaySignature)
    }

    func focusedWindow(_ target: Target, identity: VisualIdentity, helper: DesktopHelper) throws -> (AXUIElement, CGRect, String) {
        if backgroundReadOnly {
            // A read binds the selected window, without claiming internal focus.
            guard let bounds = axBounds(target.window), bounds == identity.frame else {
                throw fail("visual_target_changed", "Read-only target window geometry changed")
            }
            try DesktopHelperSecureCheck(target.window)
            return (target.window, bounds, target.expectedTitle ?? "")
        }
        let focused = try helper.settledFocusedWindow(target)
        guard let bounds = axBounds(focused) else { throw fail("window_mismatch", "Visual capture requires accessible focused-window geometry") }
        var pid: pid_t = 0
        let focusedTitle = axString(focused, kAXTitleAttribute) ?? ""
        let ownedSearchOverlay = focusedTitle.isEmpty && visualContains(identity.frame, bounds) &&
            bounds.maxX <= identity.frame.minX + identity.frame.width * 0.65 &&
            bounds.minY <= identity.frame.minY + identity.frame.height * 0.15
        guard AXUIElementGetPid(focused, &pid) == .success, pid == target.pid,
              CFEqual(focused, target.window) || ownedSearchOverlay else {
            throw fail("window_mismatch", "Focused window is neither the selected main window nor its observed upper-left empty-title search overlay")
        }
        try DesktopHelperSecureCheck(focused)
        return (focused, bounds, focusedTitle)
    }

    func DesktopHelperSecureCheck(_ element: AXUIElement) throws {
        var current: AXUIElement? = element
        for _ in 0..<64 {
            guard let item = current else { return }
            if isSecure(item) { throw fail("secure_field_denied", "Protected fields/windows cannot use visual fallback") }
            current = axElement(item, kAXParentAttribute)
        }
        throw fail("ancestry_limit", "Protected-field ancestry check did not finish")
    }

    func ensureCapture(_ target: Target, helper: DesktopHelper, identity newIdentity: VisualIdentity) throws {
        guard #available(macOS 15.2, *) else {
            throw fail("visual_capture_unsupported", "Verified screen-region capture requires macOS 15.2 or newer; aliased window captures and stale app streams are not fallbacks")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw fail("screen_capture_unavailable", "Existing screen capture permission is required; this helper never prompts")
        }
        if identity == newIdentity, captureReady { selectedAXWindow = target.window; return }
        stop()
        let topology = try helper.currentDisplays()
        guard topology.signature == newIdentity.topology else { throw fail("display_topology_changed", "Display topology changed during capture setup") }
        let plan = try VisualCapturePlan(window: newIdentity.frame, topology: topology)
        identity = newIdentity; selectedAXWindow = target.window; capturePlan = plan
    }

    // Each call acquires current pixels only in verified screen regions. Qt
    // auxiliary-window captures alias to the main window and are not used.
    func readFrame(_ target: Target, helper: DesktopHelper, identity selected: VisualIdentity,
                   allowRefresh: Bool, timeout: Double = 3, after: Int = -1) throws -> (frame: VisualFrame, refreshed: Bool, refreshMS: Int) {
        let started = ProcessInfo.processInfo.systemUptime
        if backgroundReadOnly, backgroundCapture != "visible_screen" {
            // AX/CG ownership does not prove screen pixels belong to an excluded
            // window. Background auto always uses the exact main-window source.
            let frame = try backgroundWindowFrame(target: target, helper: helper, selected: selected, after: after)
            return (frame, false, Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
        }
        guard identity == selected,
              let frame = try waitFrame(helper: helper, target: target, timeout: timeout, after: after) else {
            throw fail("visual_frame_timeout", "No completed exact-window snapshot")
        }
        return (frame, false, Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
    }

    func exactMainImage(target: Target, selected: VisualIdentity, plan: VisualCapturePlan, deadline: Double,
                        overlay: VisualSearchOverlay? = nil, auxiliaries: [VisualScreenWindow] = [],
                        check: () throws -> Void, poll: () throws -> Void) throws -> VisualWarmCapture {
        latestWarmEvidence = nil
        let captured = try visualWarmWindowCapture(selected: selected, title: target.expectedTitle, plan: plan,
            overlay: overlay, auxiliaries: auxiliaries, deadline: deadline, check: check, poll: poll)
        latestWarmEvidence = captured.evidence
        latestWarmEvidence?["wait_poll_checks"] = backgroundReadOnly ? "read_only_no_shared_HID_dependency" : "input_monitor_only_no_input_performed"
        return captured
    }

    func backgroundWindowFrame(target: Target, helper: DesktopHelper, selected: VisualIdentity, after: Int) throws -> VisualFrame {
        guard #available(macOS 14.0, *), backgroundReadOnly, let plan = capturePlan else {
            throw fail("background_capture_unavailable", "Exact-window capture is a read-only background source")
        }
        let timing = VisualCaptureMetrics()
        // This internal scope belongs to the atomic PID/window-local editor.
        // It grants no global HID or physical screen visibility authority.
        let evaluatePhysicalVisibility = helper.backgroundTargetReadDepth == 0
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        func rows() -> [[String: Any]] { CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [] }
        let beforeRows = rows()
        let before = try visualScreenWindows(beforeRows, identity: selected, displays: plan.topology.displays.map { $0.bounds }, dockPID: dockPID)
        let popup = try visualSearchOverlay(beforeRows, identity: selected)
        let notificationMasks = visualNotificationMasks(before, displays: plan.topology.displays.map { $0.bounds })
        timing.mark("screen_metadata")
        var additionalOwnWindows: [VisualScreenWindow] = []
        var targetGuardMS = 0.0
        func guardTarget() throws {
            let guardStarted = ProcessInfo.processInfo.systemUptime
            defer { targetGuardMS += (ProcessInfo.processInfo.systemUptime - guardStarted) * 1000 }
            try helper.verify(target, focusedWindow: false)
            try helper.denySecure(target.window)
            let currentIdentity = try selectedIdentity(target)
            let topologyMatches = visualTopologyMatches(plan.topology)
            let currentRows = rows()
            let currentWindows = try visualScreenWindows(currentRows, identity: selected, displays: plan.topology.displays.map { $0.bounds }, dockPID: dockPID)
            let updatedOwnWindows = visualNewContainedAuxiliaries(baseline: before, current: currentWindows,
                seen: additionalOwnWindows, identity: selected)
            guard currentIdentity == selected, topologyMatches, updatedOwnWindows != nil else {
                var diagnostic = visualWindowChangeDiagnostic(before, currentWindows)
                diagnostic["target_identity_equal"] = currentIdentity == selected
                diagnostic["display_topology_equal"] = topologyMatches
                diagnostic["target_window_id_before"] = selected.windowID; diagnostic["target_window_id_after"] = currentIdentity.windowID
                diagnostic["target_frame_before"] = rectJSON(selected.frame); diagnostic["target_frame_after"] = rectJSON(currentIdentity.frame)
                diagnostic["search_overlay_id_before"] = popup.map { $0.windowID as Any } ?? NSNull()
                diagnostic["search_overlay_id_after"] = (try? visualSearchOverlay(currentRows, identity: selected)).map { $0.windowID as Any } ?? NSNull()
                throw fail("background_target_changed", "Exact-window target or overlay changed during capture", diagnostic)
            }
            guard visualNotificationMasks(currentWindows, displays: plan.topology.displays.map { $0.bounds }) == notificationMasks else {
                throw fail("background_target_changed", "Notification Center panel geometry changed during capture")
            }
            additionalOwnWindows = updatedOwnWindows!
        }
        let captured = try exactMainImage(target: target, selected: selected, plan: plan, deadline: deadline, overlay: popup, check: guardTarget, poll: { try visualCaptureInputPoll(readOnly: backgroundReadOnly) { try helper.monitor.check() } })
        timing.mark("exact_capture")
        let raw = captured.image
        let excludedOwnWindows = additionalOwnWindows
        var frame = try visualExactWindowFrame(raw, plan: plan, previousSerial: windowCaptureSerial, after: after,
            requestStarted: captured.frameNotBeforeUptime, completed: ProcessInfo.processInfo.systemUptime)
        let previousDigest = latestWindowFrame?.contentDigest
        let bytes = frame.image.dataProvider?.data
        let digest = bytes.map { SHA256.hash(data: $0 as Data).map { String(format: "%02x", $0) }.joined() }
        timing.mark("pixel_digest")
        // Exact-main capture excludes other applications, but Qt's independent
        // popup capture aliases to its parent. Mask every own auxiliary first.
        let pixels = visualWindowSnapshotPixelEvidence(frame.image, window: selected.frame, regions: plan.coverage, data: bytes)
        var coverage = pixels.coverage
        let mainPixelsAvailable = !coverage.isEmpty
        var mainDiagnostic = pixels.diagnostics
        for item in before + excludedOwnWindows where item.pid == selected.pid && item.id != popup?.windowID { coverage = coverage.flatMap { visualSubtract($0, item.frame) } }
        guard coverage.count <= 32 else { throw fail("visual_occlusion_unavailable", "Too many own-window exclusions") }
        timing.mark("pixel_coverage_and_masks")
        let visible: [CGRect]?
        if evaluatePhysicalVisibility {
            let dockRegions = before.contains(where: { $0.dockSurface }) ? visualDockRegions(dockPID) : nil
            var screenCoverage = (try? visualScreenCoverage(plan.coverage, windows: before, identity: selected, overlay: popup, dockRegions: dockRegions, notificationRegions: notificationMasks)) ?? []
            for item in excludedOwnWindows { screenCoverage = screenCoverage.flatMap { visualSubtract($0, item.frame) } }
            var visibleProbe = frame; visibleProbe.capturedRegions = screenCoverage
            visible = visualVerifiedObservedCoverage(visibleProbe, identity: selected) { point in
                visualHitObservation(point, identity: selected, selectedWindow: selectedAXWindow, searchOverlay: popup)
            }
        } else {
            visible = nil // Unknown, never a fully-visible claim or input witness.
        }
        timing.mark("physical_visibility")
        var image = try visualMaskImage(frame.image, window: selected.frame, coverage: coverage)
        timing.mark("pixel_mask")
        if let popup {
            let control = CGRect(x: selected.frame.minX + 70, y: selected.frame.minY + selected.frame.height * 0.014, width: 210, height: selected.frame.height * 0.025)
            let queryRegion = try visualSearchTextRegion(window: selected.frame, control: control)
            var queryFrame = frame; queryFrame.capturedRegions = coverage
            let queryRows = try ocrUncached(queryFrame, identity: selected, region: queryRegion)
            if let query = visualBoundSearchQuery(queryRows, fullyVisible: visualCovered(queryRegion, by: coverage), activated: false), !query.isEmpty {
                frame.searchOverlay = popup; frame.searchQuery = query
            } else {
                coverage = coverage.flatMap { visualSubtract($0, popup.frame) }
                image = try visualMaskImage(image, window: selected.frame, coverage: coverage)
            }
        }
        timing.mark("search_overlay_evidence")
        try guardTarget()
        guard additionalOwnWindows == excludedOwnWindows else { throw fail("background_target_changed", "An additional auxiliary appeared after the image exclusion mask was finalized") }
        guard ProcessInfo.processInfo.systemUptime <= deadline, ProcessInfo.processInfo.systemUptime - frame.time <= 2 else { throw fail("visual_frame_timeout", "Background snapshot exceeded freshness bound") }
        timing.mark("final_target_guard")
        var result = VisualFrame(image: image, completeSerial: frame.completeSerial, time: frame.time,
            completeTime: frame.completeTime, idleConfirmed: false, capturedRegions: coverage,
            searchOverlay: frame.searchOverlay, searchQuery: frame.searchQuery, screenWindows: before,
            excludedInputRegions: (before.filter { $0.pid == selected.pid } + excludedOwnWindows).map { $0.frame })
        result.captureSource = latestWarmEvidence?["capture_filter_path"] as? String == "committed_exact_filter_fresh_update" ?
            "SCStream_committed_exact_display_window_filter_fresh_update_read_only" : "SCStream_app_then_exact_display_windows_read_only"
        result.captureEvidence = latestWarmEvidence ?? [:]
        var validationMS = timing.json; validationMS["target_guards"] = targetGuardMS
        result.captureEvidence?["validation_phase_ms"] = validationMS
        result.captureEvidence?["physical_visibility"] = evaluatePhysicalVisibility ? "evaluated" : "not_evaluated"
        if !evaluatePhysicalVisibility { result.captureEvidence?["fully_visible"] = false }
        result.captureEvidence?["notification_panel_masks"] = visualNotificationMaskMetadata(notificationMasks)
        result.captureEvidence?["additional_own_auxiliary_exclusions"] = visualAuxiliaryExclusionMetadata(excludedOwnWindows)
        result.visibleRegions = visible; result.contentDigest = digest
        mainDiagnostic["own_auxiliary_mask_count"] = before.filter { $0.pid == selected.pid }.count + excludedOwnWindows.count
        mainDiagnostic["post_mask_readable_region_count"] = coverage.count; result.mainContentDiagnostics = mainDiagnostic
        if coverage.isEmpty { result.contentUnavailableReason = mainPixelsAvailable ? "selected_main_content_fully_masked" : (mainDiagnostic["rejection_reason"] as? String ?? "exact_main_window_has_no_readable_pixels_public_capture") }
        result.contentUnchanged = previousDigest.flatMap { old in digest.map { $0 == old } }
        windowCaptureSerial = result.completeSerial; latestWindowFrame = result
        return result
    }

    func waitFrame(helper: DesktopHelper, target: Target, timeout: Double, after: Int = -1, baseline: Bool = false,
                   searchTransition: VisualSearchTransition? = nil,
                   navigationHintTransition: VisualNavigationHintTransition? = nil) throws -> VisualFrame? {
        let deadline = ProcessInfo.processInfo.systemUptime + min(3, max(0.05, timeout))
        do {
            return try visualSettleNavigationHint(enabled: navigationHintTransition != nil, deadline: deadline,
                check: { if navigationHintTransition != nil { try helper.monitor.check(); try helper.verify(target, focusedWindow: false) } }) {
              try visualSettleSearchObservation(enabled: searchTransition != nil, deadline: deadline,
                check: {
                    if searchTransition != nil { try helper.monitor.check() }
                    try helper.verify(target, focusedWindow: false)
                }) {
                    try captureFrame(helper: helper, target: target,
                        timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), after: after,
                        baseline: baseline, searchTransition: searchTransition, navigationHintTransition: navigationHintTransition)
                }
            }
        } catch { stop(); throw error }
    }

    func captureFrame(helper: DesktopHelper, target: Target, timeout: Double, after: Int = -1, baseline: Bool = false,
                      searchTransition: VisualSearchTransition? = nil,
                      navigationHintTransition: VisualNavigationHintTransition? = nil) throws -> VisualFrame? {
        guard #available(macOS 15.2, *) else { throw fail("visual_capture_unsupported", "Verified target-window capture requires macOS 15.2 or newer") }
        guard !baseline, let selected = identity, let plan = capturePlan else { throw fail("visual_capture_unavailable", "No selected-window capture binding") }
        let deadline = ProcessInfo.processInfo.systemUptime + min(3, max(0.001, timeout))
        let initialFocus = try focusedWindow(target, identity: selected, helper: helper)
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        func rows() -> [[String: Any]] { CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [] }
        let initialRows = rows(), observedOverlay = try visualSearchOverlay(initialRows, identity: selected)
        let observedWindows = try visualScreenWindows(initialRows, identity: selected, displays: plan.topology.displays.map{$0.bounds}, dockPID: dockPID)
        let auxiliaries = observedWindows.filter{$0.pid == selected.pid && $0.inputHintCandidate && visualContains(selected.frame,$0.frame)}
        let notificationMasks = visualNotificationMasks(observedWindows, displays: plan.topology.displays.map { $0.bounds })
        var additionalOwnWindows: [VisualScreenWindow] = []
        var verifiedCornerWindows = observedWindows
        if let transition = searchTransition {
            guard transition.accepts(observedWindows, identity: selected),
                  initialFocus.1 == selected.frame || visualSearchPopupBounds(initialFocus.1, identity: selected) else {
                var diagnostic = transition.diagnostic(observedWindows, identity: selected)
                diagnostic["focused_frame"] = rectJSON(initialFocus.1)
                diagnostic["focused_AX_reference_is_selected_main"] = CFEqual(initialFocus.0, target.window)
                diagnostic["focused_title_empty"] = initialFocus.2.isEmpty
                diagnostic["focused_frame_matches_main"] = initialFocus.1 == selected.frame
                diagnostic["focused_frame_matches_search_popup_bounds"] = visualSearchPopupBounds(initialFocus.1, identity: selected)
                diagnostic["observed_search_popup_id"] = observedOverlay.map { $0.windowID as Any } ?? NSNull()
                diagnostic["observed_search_popup_frame"] = observedOverlay.map { rectJSON($0.frame) as Any } ?? NSNull()
                diagnostic["search_activation_identity_matches"] = searchActivation?.identity == selected
                diagnostic["search_activation_control_matches"] = searchActivation?.control == transition.activation.control
                throw fail("visual_target_changed", "Unexpected occluder or focus changed after search input", diagnostic)
            }
        }
        func guardTarget() throws {
            try helper.verify(target, focusedWindow: false)
            let currentRows = rows()
            guard identity == selected, capturePlan?.topology.signature == plan.topology.signature,
                  try selectedIdentity(target) == selected, visualTopologyMatches(plan.topology) else {
                throw fail("visual_target_changed", "Screen target or topology changed")
            }
            let currentOverlay = try visualSearchOverlay(currentRows, identity: selected)
            let currentWindows = try visualScreenWindows(currentRows, identity:selected, displays:plan.topology.displays.map{$0.bounds},dockPID:dockPID)
            let focused = try focusedWindow(target, identity: selected, helper: helper)
            let cornerReplacement = additionalOwnWindows.isEmpty &&
                visualMaskedCornerWindowReplacement(observedWindows, currentWindows, identity: selected)
            let updatedOwnWindows = visualNewContainedAuxiliaries(baseline: observedWindows, current: currentWindows,
                seen: additionalOwnWindows, identity: selected) ?? (cornerReplacement ? [] : nil)
            if let navigation = navigationHintTransition, navigation.identity == selected,
               observedWindows != currentWindows, currentOverlay == observedOverlay,
               CFEqual(focused.0, initialFocus.0), focused.1 == initialFocus.1, focused.2 == initialFocus.2,
               navigation.acceptsWindows(observedWindows, currentWindows) {
                // Both disappearance and reappearance need a new exact filter;
                // the previous attempt may not contain the current hint pixels.
                throw VisualNavigationHintObservationChanged()
            }
            if currentOverlay != observedOverlay || updatedOwnWindows == nil ||
                !CFEqual(focused.0, initialFocus.0) || focused.1 != initialFocus.1 || focused.2 != initialFocus.2 {
                if let transition = searchTransition, transition.accepts(currentWindows, identity: selected),
                   focused.1 == selected.frame || visualSearchPopupBounds(focused.1, identity: selected) {
                    // Discard every pixel from this attempt. Take another fresh
                    // snapshot; never relax before/after identity on an image.
                    throw VisualSearchObservationChanged()
                }
                var diagnostic = visualWindowChangeDiagnostic(observedWindows, currentWindows)
                diagnostic["search_overlay_equal"] = currentOverlay == observedOverlay
                diagnostic["search_overlay_id_before"] = observedOverlay.map { $0.windowID as Any } ?? NSNull()
                diagnostic["search_overlay_id_after"] = currentOverlay.map { $0.windowID as Any } ?? NSNull()
                diagnostic["focused_AX_reference_equal"] = CFEqual(focused.0, initialFocus.0)
                diagnostic["focused_frame_before"] = rectJSON(initialFocus.1); diagnostic["focused_frame_after"] = rectJSON(focused.1)
                diagnostic["focused_title_equal"] = focused.2 == initialFocus.2
                diagnostic["focused_window_pid"] = selected.pid
                throw fail("visual_target_changed", "Screen overlay, occluders or focused window changed", diagnostic)
            }
            guard visualNotificationMasks(currentWindows, displays: plan.topology.displays.map { $0.bounds }) == notificationMasks else {
                throw fail("visual_target_changed", "Notification Center panel geometry changed during capture")
            }
            additionalOwnWindows = updatedOwnWindows!
            verifiedCornerWindows = cornerReplacement ? currentWindows : observedWindows
            try helper.denySecure(target.window)
            if let element = axElement(target.axApplication, kAXFocusedUIElementAttribute) { try helper.denySecure(element) }
        }
        let timing = VisualCaptureMetrics()
        do {
            let captured = try exactMainImage(target: target, selected: selected, plan: plan, deadline: deadline,
                overlay: observedOverlay, auxiliaries: auxiliaries, check: guardTarget, poll: { try visualCaptureInputPoll(readOnly: backgroundReadOnly) { try helper.monitor.check() } })
            let raw = captured.image
            timing.mark("fresh_stream")
            let excludedOwnWindows = additionalOwnWindows
            let normalized = try visualExactWindowFrame(raw, plan: plan, previousSerial: windowCaptureSerial,
                after: after, requestStarted: captured.frameNotBeforeUptime, completed: ProcessInfo.processInfo.systemUptime)
            let dockRegions = observedWindows.contains(where:{$0.dockSurface}) ? visualDockRegions(dockPID) : nil
            var coverage = try visualScreenCoverage(plan.coverage, windows: observedWindows, identity: selected, overlay: observedOverlay, dockRegions: dockRegions, notificationRegions: notificationMasks)
            var coverageStages: [String: Any] = ["input_regions": plan.coverage.map { rectJSON($0) },
                "after_CG_occluders": coverage.map { rectJSON($0) },
                "CG_occluder_windows": observedWindows.map(visualScreenWindowMetadata)]
            if let overlay = observedOverlay {
                coverage = coverage.flatMap{visualSubtract($0,overlay.frame)} + coverage.compactMap{let r=$0.intersection(overlay.frame);return r.isNull || r.isEmpty ? nil:r}
            }
            for item in excludedOwnWindows { coverage = coverage.flatMap { visualSubtract($0, item.frame) } }
            guard coverage.count <= 32 else { throw fail("visual_occlusion_unavailable", "Additional auxiliary exclusions exceeded the bounded coverage limit") }
            coverageStages["after_own_auxiliary_masks"] = coverage.map { rectJSON($0) }
            // One complete owner/alpha pass on this immutable capture. Keep the
            // result for hint masking and query OCR; a second identical AX scan
            // cannot make these pixels newer. The final live identity/focus/CG
            // guard below still rejects changes during all image processing.
            var owned = normalized; owned.capturedRegions = coverage
            owned.searchOverlay = observedOverlay; owned.screenWindows = observedWindows
            owned.captureAuxiliaryFrames = auxiliaries.map{$0.frame}
            timing.mark("normalize_and_CG_coverage")
            let visible = try visibleFrame(owned, identity: selected, summary: { coverageStages["AX_observation"] = $0 })
            coverage = visible.capturedRegions ?? []
            coverageStages["after_AX_ownership"] = coverage.map { rectJSON($0) }
            timing.mark("AX_owner_coverage")
            var image = try visualMaskImage(visible.image, window: selected.frame, coverage: coverage)
            var hints:[CGRect]=[], excludedInputs:[CGRect]=excludedOwnWindows.map{$0.frame}
            for auxiliary in auxiliaries {
                let popupInFront: CGRect? = observedOverlay.flatMap { overlay in
                    guard let popupIndex=observedWindows.firstIndex(where:{$0.id==overlay.windowID}),let auxiliaryIndex=observedWindows.firstIndex(where:{$0.id==auxiliary.id}),popupIndex<auxiliaryIndex else{return nil};return overlay.frame
                }
                if visualCovered(auxiliary.frame,by:coverage),let hint=try? visualInputHint(image,window:selected.frame,auxiliary:auxiliary.frame,frontPopup:popupInFront),
                   let painted=try? visualPaintNeutral(image,boxes:[plan.pixels(hint)],allowSearchFocusRing:hint.height<=6) {
                    image=painted;hints.append(hint);excludedInputs.append(hint.insetBy(dx:-1,dy:-1))
                }else{
                    let unknown=[auxiliary.frame]
                    for rect in unknown {coverage=coverage.flatMap{visualSubtract($0,rect)}};excludedInputs += unknown
                }
            }
            // Mask unknown hint padding once; preserve the original frame time
            // and serial rather than normalising the full bitmap a second time.
            if coverage != visible.capturedRegions { image = try visualMaskImage(image, window: selected.frame, coverage: coverage) }
            var frame = VisualFrame(image: image, completeSerial: normalized.completeSerial, time: normalized.time,
                completeTime: normalized.completeTime, idleConfirmed: false, capturedRegions: coverage)
            frame.searchOverlay=observedOverlay;frame.screenWindows=observedWindows
            frame.captureAuxiliaryFrames=auxiliaries.map{$0.frame};frame.excludedInputRegions=excludedInputs;frame.inputSourceHints=hints;frame.debugRawImage=diagnosticsRequested ? normalized.image:nil
            frame.coverageDiagnostics = visible.coverageDiagnostics
            coverageStages["after_hint_masks"] = coverage.map { rectJSON($0) }
            timing.mark("hint_mask")
            if let navigation = navigationHintTransition, !navigation.presentHintsVerified(frame) {
                throw VisualNavigationHintObservationChanged() // Unknown 84x77 remains unusable.
            }
            if let overlay=observedOverlay {
                let control=CGRect(x:selected.frame.minX+70,y:selected.frame.minY+selected.frame.height*0.014,width:210,height:selected.frame.height*0.025)
                let queryRegion=try visualSearchTextRegion(window:selected.frame,control:control)
                let queryRows=try ocr(frame,identity:selected,region:queryRegion)
                if let value = visualBoundSearchQuery(queryRows,
                    fullyVisible: visualCovered(queryRegion, by: frame.capturedRegions ?? []),
                    activated: searchActivation?.matches(selected, queryRegion: queryRegion) == true) {
                    frame.searchQuery=value
                }else{
                    frame.searchOverlay=nil
                    frame.capturedRegions=(frame.capturedRegions ?? []).flatMap{visualSubtract($0,overlay.frame)}
                }
            }
            timing.mark("query_OCR")
            coverageStages["after_query_binding"] = (frame.capturedRegions ?? []).map { rectJSON($0) }
            // The frame's pixels are masked again if the query could not bind a popup.
            if frame.searchOverlay == nil && observedOverlay != nil {
                frame = VisualFrame(image:try visualMaskImage(frame.image,window:selected.frame,coverage:frame.capturedRegions ?? []),completeSerial:frame.completeSerial,time:frame.time,completeTime:frame.completeTime,idleConfirmed:false,capturedRegions:frame.capturedRegions,searchOverlay:nil,searchQuery:nil,screenWindows:frame.screenWindows,captureAuxiliaryFrames:frame.captureAuxiliaryFrames,excludedInputRegions:frame.excludedInputRegions,inputSourceHints:frame.inputSourceHints,debugRawImage:frame.debugRawImage,coverageDiagnostics:frame.coverageDiagnostics)
            }
            try guardTarget()
            timing.mark("final_identity_guard")
            guard additionalOwnWindows == excludedOwnWindows else { throw fail("visual_target_changed", "An additional auxiliary appeared after the image exclusion mask was finalized") }
            if verifiedCornerWindows != observedWindows {
                let corner = CGRect(x: selected.frame.minX + 6, y: selected.frame.minY + 5, width: 52, height: 20)
                guard let coverage = frame.capturedRegions, coverage.allSatisfy({ $0.intersection(corner).isEmpty }) else {
                    throw fail("visual_target_changed", "Recreated corner-window pixels must remain fully excluded")
                }
                // Publish the last fully guarded scene; the main pixels, frame
                // timestamp and exclusion geometry are unchanged by this ID update.
                frame.screenWindows = verifiedCornerWindows
            }
            guard ProcessInfo.processInfo.systemUptime<=deadline,ProcessInfo.processInfo.systemUptime-frame.time<=2 else{throw fail("visual_frame_timeout","Screen capture and ownership validation exceeded freshness bound")}
        frame.captureSource = latestWarmEvidence?["capture_filter_path"] as? String == "committed_exact_filter_fresh_update" ?
            "SCStream_committed_exact_display_window_filter_fresh_update_visible_regions" : "SCStream_app_then_exact_display_windows_visible_regions"
            frame.captureEvidence = latestWarmEvidence
            frame.captureEvidence?["coverage_stages"] = coverageStages
            frame.captureEvidence?["notification_panel_masks"] = visualNotificationMaskMetadata(notificationMasks)
            frame.captureEvidence?["additional_own_auxiliary_exclusions"] = visualAuxiliaryExclusionMetadata(excludedOwnWindows)
            if verifiedCornerWindows != observedWindows {
                let corner = CGRect(x: selected.frame.minX + 6, y: selected.frame.minY + 5, width: 52, height: 20)
                frame.captureEvidence?["masked_corner_window_replacement"] = [
                    "before_window_id": observedWindows.first(where: { $0.frame == corner })!.id,
                    "after_window_id": verifiedCornerWindows.first(where: { $0.frame == corner })!.id,
                    "pid": selected.pid, "frame": rectJSON(corner), "pixels_excluded": true, "corner_input_authorized": false]
            }
            frame.mainContentDiagnostics = visualWindowSnapshotDiagnostics(raw, window: selected.frame, regions: plan.coverage)
            let digest = frame.image.dataProvider?.data.map { SHA256.hash(data: $0 as Data).map { String(format: "%02x", $0) }.joined() }
            frame.contentDigest = digest
            frame.contentUnchanged = latestWindowFrame?.contentDigest.flatMap { old in digest.map { $0 == old } }
            if (frame.capturedRegions ?? []).isEmpty { frame.contentUnavailableReason = "no_readable_and_visible_target_pixels" }
            timing.mark("digest_and_diagnostics")
            frame.captureEvidence?["validation_phase_ms"] = timing.json
            guard ProcessInfo.processInfo.systemUptime <= deadline,
                  ProcessInfo.processInfo.systemUptime - frame.time <= 2 else {
                throw fail("visual_frame_timeout", "Completed target frame expired during final diagnostics")
            }
            if diagnosticsRequested, (frame.capturedRegions ?? []).isEmpty,
               let diagnostic = visualNotificationSurfaceDiagnostic(observedWindows, identity: selected, displays: plan.topology.displays.map { $0.bounds }) {
                frame.captureEvidence?["blocked_system_surface_diagnostic"] = diagnostic
            }
            windowCaptureSerial=frame.completeSerial;latestWindowFrame=frame;return frame
        } catch is VisualSearchObservationChanged { throw VisualSearchObservationChanged() }
          catch is VisualNavigationHintObservationChanged { throw VisualNavigationHintObservationChanged() }
          catch var error as HelperError {
            if error.details["phase"] as? String == "matching_shareable_search_popup" {
                error.details["search_transition_bound"] = searchTransition?.activation.identity == selected
                error.details["search_activation_bound"] = searchActivation?.identity == selected
                error.details["search_activation_control_matches_transition"] = searchTransition.map {
                    searchActivation?.control == $0.activation.control
                } ?? false
                error.details["read_only_background"] = backgroundReadOnly
                if !backgroundReadOnly, visualSearchPopupHeightRace(error.details, identity: selected,
                    overlay: observedOverlay, transition: searchTransition, activation: searchActivation) {
                    try helper.monitor.check()
                    try guardTarget()
                    throw VisualSearchObservationChanged(details: error.details)
                }
            }
            error.details["validation_phase_ms"] = timing.json
            if let evidence = latestWarmEvidence { error.details["capture_delivery_evidence"] = evidence }
            stop(); throw error
          } catch { stop(); throw error }
    }

    func visibleFrame(_ frame: VisualFrame, identity: VisualIdentity,
                      summary: (([String: Any]) -> Void)? = nil) throws -> VisualFrame {
        var diagnostics: [[String: Any]] = []
        let recorder: (([String: Any]) -> Void)? = diagnosticsRequested ? { diagnostics.append($0) } : nil
        var sampled = frame
        if let overlay = frame.searchOverlay {
            let original = frame.capturedRegions ?? []
            sampled.capturedRegions = original.flatMap { visualSubtract($0, overlay.frame) } + original.compactMap {
                let intersection = $0.intersection(overlay.frame)
                return intersection.isNull || intersection.width <= 0 || intersection.height <= 0 ? nil : intersection
            }
        }
        let coverage = visualVerifiedObservedCoverage(sampled, identity: identity, diagnostic: recorder, summary: summary) { point in
            visualHitObservation(point, identity: identity, selectedWindow: selectedAXWindow, searchOverlay: frame.searchOverlay, captureAuxiliaryFrames: frame.captureAuxiliaryFrames)
        }
        guard ProcessInfo.processInfo.systemUptime - frame.time <= 2 else {
            throw fail("visual_frame_timeout", "Target-visibility validation outlived the two-second frame bound")
        }
        let image: CGImage
        if coverage == frame.capturedRegions { image = frame.image }
        else if visibilitySource === frame.image, visibilityRegions == coverage, let saved = visibilityImage { image = saved }
        else {
            image = try visualMaskImage(frame.image, window: identity.frame, coverage: coverage)
            visibilitySource = frame.image; visibilityRegions = coverage; visibilityImage = image
        }
        return VisualFrame(image: image, completeSerial: frame.completeSerial, time: frame.time,
            completeTime: frame.completeTime, idleConfirmed: frame.idleConfirmed, capturedRegions: coverage,
            searchOverlay: frame.searchOverlay, searchQuery: frame.searchQuery,
            screenWindows: frame.screenWindows, captureAuxiliaryFrames: frame.captureAuxiliaryFrames, excludedInputRegions: frame.excludedInputRegions, inputSourceHints: frame.inputSourceHints,
            debugRawImage: diagnosticsRequested ? (frame.debugRawImage ?? frame.image) : nil, coverageDiagnostics: diagnosticsRequested ? diagnostics : nil)
    }

    func ocrReuseFingerprint(_ frame: VisualFrame, identity: VisualIdentity, region: CGRect,
                             now: Double, colorProfile: OCRColorProfile? = nil) -> (key: OCRCacheKey, digest: [UInt8], raster: OCRRaster)? {
        guard !frame.idleConfirmed, frame.completeSerial > 0,
              frame.time.isFinite, frame.completeTime.isFinite, frame.completeTime >= frame.time,
              now >= frame.time, now - frame.time < 5,
              let coverage = frame.capturedRegions, coverage.count <= 32,
              (frame.visibleRegions?.count ?? 0) <= 32, frame.excludedInputRegions.count <= 32,
              visualCovered(region, by: coverage) else { return nil }
        let scaleX = Double(frame.image.width) / identity.frame.width
        let scaleY = Double(frame.image.height) / identity.frame.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return nil }
        let pixels = CGRect(x: (region.minX - identity.frame.minX) * scaleX,
                            y: (region.minY - identity.frame.minY) * scaleY,
                            width: region.width * scaleX, height: region.height * scaleY).integral
        let actual = CGRect(x: identity.frame.minX + pixels.minX / scaleX, y: identity.frame.minY + pixels.minY / scaleY,
                            width: pixels.width / scaleX, height: pixels.height / scaleY)
        guard pixels.minX >= 0, pixels.minY >= 0, pixels.maxX <= CGFloat(frame.image.width), pixels.maxY <= CGFloat(frame.image.height),
              visualCovered(actual, by: coverage), let cropped = frame.image.cropping(to: pixels),
              cropped.width == Int(pixels.width), cropped.height == Int(pixels.height),
              cropped.bitsPerComponent == 8, cropped.bitsPerPixel == 32, !cropped.isMask, cropped.decode == nil,
              let colorSpace = cropped.colorSpace, let colorName = colorSpace.name,
              let bytes = cropped.dataProvider?.data, let base = CFDataGetBytePtr(bytes) else { return nil }
        let rowBytes = cropped.width * 4
        guard cropped.height > 0, rowBytes > 0, cropped.bytesPerRow >= rowBytes,
              CFDataGetLength(bytes) >= (cropped.height - 1) * cropped.bytesPerRow + rowBytes else { return nil }
        var hash = SHA256()
        // Crop providers preserve the parent row stride. Hash every pixel bit,
        // excluding row padding; drawing/normalization could erase a one-bit
        // source change and cannot establish exact equality.
        if cropped.bytesPerRow == rowBytes {
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: base, count: rowBytes * cropped.height))
        } else {
            for row in 0..<cropped.height {
                hash.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: row * cropped.bytesPerRow), count: rowBytes))
            }
        }
        let sharedProfile = colorProfile.flatMap { CFEqual($0.space, colorSpace) ? $0 : nil }
        let profileDigest: [UInt8]?
        if let sharedProfile { profileDigest = sharedProfile.digest }
        else { profileDigest = colorSpace.copyICCData().map { Array(SHA256.hash(data: $0 as Data)) } }
        let key = OCRCacheKey(identity: identity, region: region, pixels: pixels, actual: actual,
            scaleX: scaleX, scaleY: scaleY, imageWidth: frame.image.width, imageHeight: frame.image.height,
            coverage: coverage, visibleRegions: frame.visibleRegions, exclusions: frame.excludedInputRegions,
            pixelFormat: cropped.bitmapInfo.rawValue, colorSpaceName: sharedProfile?.name ?? colorName as String,
            colorProfileDigest: profileDigest, renderingIntent: cropped.renderingIntent.rawValue,
            interpolate: cropped.shouldInterpolate)
        return (key, Array(hash.finalize()), OCRRaster(image: cropped, actual: actual, scaleX: scaleX, scaleY: scaleY))
    }

    func ocr(_ frame: VisualFrame, identity: VisualIdentity, region requested: CGRect? = nil,
             cacheGeneration: UInt64? = nil, colorProfile: OCRColorProfile? = nil,
             timing: VisualCaptureMetrics? = nil) throws -> [[String: Any]] {
        let region = requested ?? identity.frame
        guard visualContains(identity.frame, region) else { throw fail("visual_region_outside_window", "OCR region must lie inside the exact selected window") }
        let started = ProcessInfo.processInfo.systemUptime
        let fingerprint = ocrReuseFingerprint(frame, identity: identity, region: region, now: started, colorProfile: colorProfile)
        timing?.mark("fingerprint")
        ocrCacheLock.lock()
        if let cacheGeneration, ocrCacheGeneration != cacheGeneration || ocrCacheIdentity != identity {
            ocrCacheLock.unlock()
            throw fail("visual_target_changed", "OCR target/cache changed during parallel region recognition")
        }
        if ocrCacheIdentity != identity {
            ocrCacheIdentity = identity; ocrCacheGeneration &+= 1
            ocrCacheRows.removeAll(keepingCapacity: true)
        }
        // Other ROI workers may have started later and finished first. Use the
        // current locked lookup time, not this worker's older start time.
        let lookupTime = ProcessInfo.processInfo.systemUptime
        ocrCacheRows.removeAll { lookupTime < $0.created || lookupTime - $0.created >= 5 }
        if let fingerprint, let index = ocrCacheRows.firstIndex(where: { $0.key == fingerprint.key && $0.digest == fingerprint.digest }) {
            let saved = ocrCacheRows.remove(at: index)
            ocrCacheRows.append(saved) // LRU movement never renews its five-second expiry.
            ocrCacheHits += 1
            if saved.serial != frame.completeSerial { ocrCrossFrameCacheHits += 1 }
            ocrCacheLock.unlock()
            timing?.mark("cache_hit")
            return saved.rows
        }
        let generation = ocrCacheGeneration
        ocrRecognitionRuns += 1
        ocrCacheLock.unlock()
        timing?.mark("cache_miss")
        let rows = try ocrUncached(frame, identity: identity, region: region, raster: fingerprint?.raster, timing: timing)
        timing?.mark("recognition_and_rows")
        ocrCacheLock.lock()
        let completed = ProcessInfo.processInfo.systemUptime
        // A stop/target change during Vision cannot repopulate the cleared
        // cache. A late old-frame result cannot replace a newer ROI entry.
        if let fingerprint, ocrCacheGeneration == generation, ocrCacheIdentity == identity,
           completed >= started, completed - started < 5,
           !ocrCacheRows.contains(where: { $0.key.region == region && $0.serial > frame.completeSerial }) {
            ocrCacheRows.removeAll { $0.key.region == region || completed < $0.created || completed - $0.created >= 5 }
            if ocrCacheRows.count >= 8 { ocrCacheRows.removeFirst() }
            ocrCacheRows.append(OCRCacheEntry(key: fingerprint.key, digest: fingerprint.digest, rows: rows, created: started, serial: frame.completeSerial))
        }
        ocrCacheLock.unlock()
        timing?.mark("cache_store")
        return rows
    }

    func ocrUncached(_ frame: VisualFrame, identity: VisualIdentity, region: CGRect,
                     raster: OCRRaster? = nil, timing: VisualCaptureMetrics? = nil) throws -> [[String: Any]] {
        if let coverage = frame.capturedRegions,
           !coverage.contains(where: { !$0.intersection(region).isNull && $0.intersection(region).width > 0 && $0.intersection(region).height > 0 }) { return [] }
        let scaleX = raster?.scaleX ?? Double(frame.image.width) / identity.frame.width
        let scaleY = raster?.scaleY ?? Double(frame.image.height) / identity.frame.height
        let pixels = CGRect(x: (region.minX - identity.frame.minX) * scaleX,
                            y: (region.minY - identity.frame.minY) * scaleY,
                            width: region.width * scaleX, height: region.height * scaleY).integral
        guard let cropped = raster?.image ?? frame.image.cropping(to: pixels) else { throw fail("visual_region_unavailable", "Could not crop OCR region") }
        let actual = raster?.actual ?? CGRect(x: identity.frame.minX + pixels.minX / scaleX, y: identity.frame.minY + pixels.minY / scaleY,
                            width: pixels.width / scaleX, height: pixels.height / scaleY)
        var image = try visualSearchControlOCRImage(cropped, actual: actual, window: identity.frame, scaleX: scaleX, scaleY: scaleY)
        let searchUpsampled = image.width != cropped.width
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        if let timing { try timing.measure("vision") { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } }
        else { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        var observations = request.results ?? []
        var caretBounds: CGRect?
        let now = ProcessInfo.processInfo.systemUptime
        let composer = visualVoiceComposerRegion(identity.frame)
        if !frame.idleConfirmed, frame.completeSerial > 0, now >= frame.time, now-frame.time < 5,
           let coverage = frame.capturedRegions, visualCovered(actual, by: coverage), visualCovered(composer, by: coverage) {
            let glyphs = observations.prefix(128).compactMap { observation -> VisualComposerCaretGlyph? in
                guard let candidate = observation.topCandidates(1).first, candidate.string.last == "|",
                      let glyph = try? candidate.boundingBox(for: candidate.string.index(before: candidate.string.endIndex)..<candidate.string.endIndex) else { return nil }
                return VisualComposerCaretGlyph(row: visualOCRBounds(observation.boundingBox, region: actual),
                    glyph: visualOCRBounds(glyph.boundingBox, region: actual))
            }
            if let masked = visualComposerTailCaretImage(image, actual: actual, window: identity.frame, glyphs: glyphs) {
                let repeated = VNRecognizeTextRequest()
                repeated.recognitionLevel = .accurate; repeated.recognitionLanguages = ["zh-Hans", "en-US"]
                repeated.usesLanguageCorrection = false
                if let timing { try timing.measure("vision") { try VNImageRequestHandler(cgImage: masked.image, options: [:]).perform([repeated]) } }
                else { try VNImageRequestHandler(cgImage: masked.image, options: [:]).perform([repeated]) }
                image = masked.image; observations = repeated.results ?? []; caretBounds = masked.bounds
            }
        }
        return observations.prefix(128).compactMap { observation -> [String: Any]? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let bounds = visualOCRBounds(observation.boundingBox, region: actual)
            if let coverage = frame.capturedRegions, !visualCovered(bounds, by: coverage) { return nil }
            // A clipped recipient string is not evidence for the complete chat
            // header, even if its surviving prefix exactly matches a query.
            let header = visualSubmitHeader(identity.frame)
            if let coverage = frame.capturedRegions, !visualCovered(header, by: coverage),
               !bounds.intersection(header).isNull { return nil }
            if let badge = try? visualClawBadge(image, actual: actual, window: identity.frame, observation: observation, candidate: candidate) {
                let lane = bounds.union(badge.1).insetBy(dx: -4, dy: -3).intersection(actual)
                let sx = Double(image.width) / actual.width, sy = Double(image.height) / actual.height
                let cropRect = CGRect(x: (lane.minX-actual.minX)*sx, y: (lane.minY-actual.minY)*sy, width: lane.width*sx, height: lane.height*sy).integral
                if let clean = badge.0.cropping(to: cropRect) {
                    let repeated = VNRecognizeTextRequest(); repeated.recognitionLevel = .accurate
                    repeated.recognitionLanguages = ["zh-Hans", "en-US"]; repeated.usesLanguageCorrection = false
                    let repeatResult: Void?
                    if let timing { repeatResult = try? timing.measure("vision") { try VNImageRequestHandler(cgImage: clean, options: [:]).perform([repeated]) } }
                    else { repeatResult = try? VNImageRequestHandler(cgImage: clean, options: [:]).perform([repeated]) }
                    if repeatResult != nil,
                       repeated.results?.count == 1, let row = repeated.results?.first, let value = row.topCandidates(1).first,
                       let regex = try? NSRegularExpression(pattern: "[（(][0-9]{1,6}[）)]"),
                       let last = regex.matches(in: candidate.string, range: NSRange(candidate.string.startIndex..., in: candidate.string)).last,
                       let count = Range(last.range, in: candidate.string),
                       visualNormalizedText(value.string) == visualNormalizedText(String(candidate.string[..<count.upperBound])) {
                        let cropGlobal=CGRect(x:actual.minX+cropRect.minX/sx,y:actual.minY+cropRect.minY/sy,width:cropRect.width/sx,height:cropRect.height/sy)
                        return ["text": String(value.string.prefix(1000)), "confidence": value.confidence,
                            "bounds": rectJSON(visualOCRBounds(row.boundingBox,region:cropGlobal)),
                            "header_badge_removed":true,"header_badge_bounds":rectJSON(badge.1),"header_badge_shape_score":badge.2]
                    }
                }
            }
            var row: [String: Any] = ["text": String(candidate.string.prefix(1000)), "confidence": candidate.confidence,
                    "bounds": rectJSON(bounds)]
            if let caretBounds, visualContains(composer, bounds) {
                row["ocr_preprocessing"] = "same_frame_proven_green_tail_caret_pixels_masked"
                row["composer_caret_bounds"] = rectJSON(caretBounds)
            }
            if searchUpsampled { row["ocr_preprocessing"] = "full_search_control_1x_to_2x_high_quality"; row["ocr_coordinate_scale_unchanged"] = true }
            return row
        }.sorted { a, b in
            let first = try! visualRect(a["bounds"]); let second = try! visualRect(b["bounds"])
            if abs(first.minY - second.minY) > 8 { return first.minY < second.minY }
            return first.minX < second.minX
        }
    }

    func readRegions(_ request: [String: Any]) throws -> [CGRect]? {
        guard request["region"] == nil || request["regions"] == nil else {
            throw fail("invalid_request", "region and regions are mutually exclusive")
        }
        if let region = request["region"] { return [try visualRect(region)] }
        if let raw = request["regions"] {
            guard let regions = raw as? [[String: Any]], !regions.isEmpty, regions.count <= 8 else {
                throw fail("invalid_request", "regions must contain between 1 and 8 rectangle objects")
            }
            return try regions.map { try visualRect($0, name: "regions") }
        }
        return nil
    }

    func ocrRegionSources(_ frame: VisualFrame, identity: VisualIdentity, regions: [CGRect], now: Double) -> [Int] {
        // Only identical requested rectangles share a result, within this
        // immutable, fresh complete frame. Containing/overlapping ROIs still
        // get their own recognition and their own 128-observation budget.
        guard regions.indices.contains(where: { regions[..<$0].contains(regions[$0]) }) else { return Array(regions.indices) }
        guard !frame.idleConfirmed, frame.completeSerial > 0,
              frame.time.isFinite, frame.completeTime.isFinite, frame.completeTime >= frame.time,
              now.isFinite, now >= frame.time, now - frame.time < 5,
              let coverage = frame.capturedRegions, coverage.count <= 32,
              (frame.visibleRegions?.count ?? 0) <= 32, frame.excludedInputRegions.count <= 32 else { return Array(regions.indices) }
        let sx = Double(frame.image.width) / identity.frame.width
        let sy = Double(frame.image.height) / identity.frame.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return Array(regions.indices) }
        return regions.indices.map { index in
            let region = regions[index]
            let pixels = CGRect(x: (region.minX-identity.frame.minX)*sx, y: (region.minY-identity.frame.minY)*sy,
                width: region.width*sx, height: region.height*sy).integral
            let actual = CGRect(x: identity.frame.minX+pixels.minX/sx, y: identity.frame.minY+pixels.minY/sy,
                width: pixels.width/sx, height: pixels.height/sy)
            guard visualCovered(region, by: coverage), visualCovered(actual, by: coverage) else { return index }
            return regions[..<index].firstIndex(of: region) ?? index
        }
    }

    func ocrRegions(_ frame: VisualFrame, identity: VisualIdentity, regions: [CGRect],
                    measurePerformance: Bool = false) throws -> (rows: [[String: Any]], regionRows: [[[String: Any]]], stageMS: [String: Double]) {
        let timing = measurePerformance ? VisualCaptureMetrics() : nil
        guard regions.allSatisfy({ visualContains(identity.frame, $0) }) else {
            throw fail("visual_region_outside_window", "Every OCR region must lie inside the selected window before any recognition starts")
        }
        guard !regions.isEmpty else { return ([], [], [:]) }
        ocrCacheLock.lock()
        if ocrCacheIdentity != identity {
            ocrCacheIdentity = identity; ocrCacheGeneration &+= 1
            ocrCacheRows.removeAll(keepingCapacity: true)
        }
        let generation = ocrCacheGeneration
        ocrCacheLock.unlock()
        let sources = ocrRegionSources(frame, identity: identity, regions: regions, now: ProcessInfo.processInfo.systemUptime)
        let jobs = regions.indices.filter { sources[$0] == $0 }
        let colorProfile = OCRColorProfile(frame.image)
        timing?.mark("batch_prepare")
        let results = regions.map { _ in VisualCompletion<(rows: [[String: Any]], timing: [String: Double])>() }
        let workers = min(3, jobs.count)
        // At most three synchronous worker lanes. Every OCR invocation owns
        // its Vision requests; the joins finish before pixels/results escape.
        DispatchQueue.concurrentPerform(iterations: workers) { lane in
            for job in stride(from: lane, to: jobs.count, by: workers) {
                let index = jobs[job]
                results[index].complete(Result {
                    let localTiming = measurePerformance ? VisualCaptureMetrics() : nil
                    let rows = try self.ocr(frame, identity: identity, region: regions[index], cacheGeneration: generation,
                        colorProfile: colorProfile, timing: localTiming)
                    return (rows, localTiming?.json ?? [:])
                })
            }
        }
        timing?.mark("parallel_join")
        let recognized = try sources.map { source -> (rows: [[String: Any]], timing: [String: Double]) in
            guard let result = results[source].get() else { throw fail("visual_OCR_failed", "Parallel region recognition did not complete") }
            return try result.get()
        }
        let groups = recognized.map { $0.rows }
        ocrCacheLock.lock()
        let unchanged = ocrCacheGeneration == generation && ocrCacheIdentity == identity
        ocrCacheLock.unlock()
        guard unchanged else { throw fail("visual_target_changed", "OCR target/cache changed before region results were joined") }
        let rows = visualMergeOCRRows(groups)
        timing?.mark("merge_and_generation_guard")
        var stages = timing?.json ?? [:]
        for (index, item) in recognized.enumerated() {
            if sources[index] != index {
                if timing != nil { stages["roi_\(index)_same_frame_reuse"] = 0 }
                continue
            }
            for (name, milliseconds) in item.timing { stages["roi_\(index)_\(name)"] = milliseconds }
        }
        return (rows, groups, stages)
    }

    func anchors(_ request: [String: Any]) throws -> [String] {
        guard let raw = request["anchor_texts"] else { return [] }
        guard let values = raw as? [String], values.count <= 8,
              values.allSatisfy({ !$0.isEmpty && $0.count <= 100 && !$0.contains("\n") }) else {
            throw fail("invalid_request", "anchor_texts must contain at most 8 nonempty single-line strings of at most 100 characters")
        }
        return Array(Set(values)).sorted()
    }

    func matches(_ expected: String, rows: [[String: Any]]) -> Bool {
        let all = rows.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return !expected.isEmpty && visualNormalizedText(all).contains(visualNormalizedText(expected))
    }

    func preparedContinuationAnchorsVerified(_ anchors: [String], regions: [CGRect], rows: [[String: Any]]) -> Bool {
        let freshAnchorRows = rows.filter { row in
            guard let bounds = try? visualRect(row["bounds"]) else { return false }
            return regions.contains { visualContains($0, bounds) }
        }
        return anchors.contains { matches($0, rows: freshAnchorRows) }
    }

    func makeSnapshot(_ frame: VisualFrame, target: Target, helper: DesktopHelper, anchors: [String], confirmed: Bool,
                      continuation: VisualSnapshot? = nil, controlRegion: CGRect? = nil,
                      controlRows: [[String: Any]]? = nil, preparedRows: [[String: Any]]? = nil,
                      timing: VisualCaptureMetrics? = nil) throws -> VisualSnapshot {
        try helper.verify(target, focusedWindow: false)
        let current = try selectedIdentity(target)
        guard current == identity else { throw fail("visual_target_changed", "Capture target geometry/PID/window/topology changed") }
        timing?.mark("initial_target_guard")
        let focused = try focusedWindow(target, identity: current, helper: helper)
        timing?.mark("initial_window_security")
        let rows: [[String: Any]]
        let anchorRegions: [CGRect]
        if let preparedRows {
            rows = preparedRows
            if let previous = continuation {
                guard previous.confirmed, previous.identity == current, captureReady,
                      !previous.anchorRegions.isEmpty else { throw fail("visual_target_unconfirmed", "Prepared continuation requires a previously confirmed same warm target") }
                guard preparedContinuationAnchorsVerified(anchors, regions: previous.anchorRegions, rows: rows) else {
                    throw fail("visual_target_unconfirmed", "No previous anchor was freshly recognized within its observed region")
                }
                anchorRegions = previous.anchorRegions
            } else {
                anchorRegions = anchors.compactMap { anchor in
                    guard let row = rows.first(where: { ($0["text"] as? String).map {
                        visualNormalizedText($0).contains(visualNormalizedText(anchor))
                    } ?? false }), let bounds = try? visualRect(row["bounds"]) else { return nil }
                    return bounds.insetBy(dx: -12, dy: -8).intersection(current.frame)
                }
            }
        } else if let previous = continuation, let controlRegion {
            guard previous.confirmed, previous.identity == current, captureReady else {
                throw fail("visual_target_unconfirmed", "A bounded action continuation requires the previously confirmed same exact-window capture binding")
            }
            anchorRegions = previous.anchorRegions
            guard !anchorRegions.isEmpty else { throw fail("visual_target_unconfirmed", "No previously observed anchor regions are available") }
            var localRows = try controlRows ?? ocr(frame, identity: current, region: controlRegion)
            var anchorRows: [[String: Any]] = []
            for region in anchorRegions { anchorRows += try ocr(frame, identity: current, region: region) }
            guard anchors.contains(where: { matches($0, rows: anchorRows) }) else {
                throw fail("visual_target_unconfirmed", "No previously verified visible anchor remains in its observed region in the new action frame")
            }
            localRows += anchorRows
            // The Send witness is refreshed even when the caller's input ROI
            // deliberately excludes the button. No full chat OCR runs here.
            let sendRegion = CGRect(x: current.frame.minX + current.frame.width * 0.70,
                y: current.frame.minY + current.frame.height * 0.85,
                width: current.frame.width * 0.30, height: current.frame.height * 0.15)
            localRows += try ocr(frame, identity: current, region: sendRegion)
            rows = localRows
        } else {
            rows = try ocr(frame, identity: current)
            anchorRegions = anchors.compactMap { anchor in
                guard let row = rows.first(where: { ($0["text"] as? String).map {
                    visualNormalizedText($0).contains(visualNormalizedText(anchor))
                } ?? false }), let bounds = try? visualRect(row["bounds"]) else { return nil }
                return bounds.insetBy(dx: -12, dy: -8).intersection(current.frame)
            }
        }
        timing?.mark("row_and_anchor_binding")
        try helper.verify(target, focusedWindow: false)
        timing?.mark("final_target_guard")
        let finalFocus = try focusedWindow(target, identity: current, helper: helper)
        timing?.mark("final_window_security")
        guard CFEqual(finalFocus.0, focused.0), finalFocus.1 == focused.1,
              try selectedIdentity(target) == current else { throw fail("visual_target_changed", "Target or focused window changed during OCR") }
        timing?.mark("final_identity_guard")
        let anchorsVerified = visualAnchorsVerified(anchors, rows: rows, confirmed: confirmed)
        let continuityVerified = continuation?.confirmed == true && continuation?.identity == current && captureReady
        var value = VisualSnapshot(id: UUID().uuidString, identity: current, frame: frame,
            created: ProcessInfo.processInfo.systemUptime, focusedWindow: focused.0, focusedFrame: focused.1,
            focusedTitle: focused.2, rows: rows, anchors: anchors,
            confirmed: anchorsVerified || continuityVerified,
            confirmationSource: anchorsVerified ? "caller_confirmation_and_two_spatially_distinct_OCR_anchors" :
                (continuityVerified ? "same_window_binding_and_fresh_local_anchor_OCR" : "unconfirmed"), anchorRegions: anchorRegions)
        value.readOnlyBackground = backgroundReadOnly
        snapshot = value
        timing?.mark("snapshot_commit")
        return value
    }

    func json(_ snapshot: VisualSnapshot, rows: [[String: Any]]? = nil) -> [String: Any] {
        let observations = rows ?? snapshot.rows
        let visibilityEvaluated = snapshot.frame.captureEvidence?["physical_visibility"] as? String != "not_evaluated"
        let visibleRegions = visibilityEvaluated ? (snapshot.frame.visibleRegions ?? snapshot.frame.capturedRegions ?? []) : []
        var result: [String: Any] = ["read_only_background": snapshot.readOnlyBackground, "input_eligible": !snapshot.readOnlyBackground && snapshot.confirmed && !(snapshot.frame.capturedRegions ?? []).isEmpty, "snapshot_id": snapshot.id, "target_pid": snapshot.identity.pid, "window_id": snapshot.identity.windowID,
            "window_frame": rectJSON(snapshot.identity.frame), "focused_window_title": snapshot.readOnlyBackground ? NSNull() as Any : snapshot.focusedTitle as Any,
            "focused_window_frame": snapshot.readOnlyBackground ? NSNull() as Any : rectJSON(snapshot.focusedFrame) as Any, "coordinate_system": quartzCoordinateSystem,
            "pixel_size": ["width": snapshot.frame.image.width, "height": snapshot.frame.image.height],
            "captured_regions": (snapshot.frame.capturedRegions ?? [snapshot.identity.frame]).map { rectJSON($0) },
            "input_source_hint_regions": snapshot.frame.inputSourceHints.map { rectJSON($0) },
            "excluded_input_regions": snapshot.frame.excludedInputRegions.map { rectJSON($0) },
            "window_fully_visible": visibilityEvaluated && visualCovered(snapshot.identity.frame, by: visibleRegions),
            "visible_regions": visibleRegions.map { rectJSON($0) },
            "physical_visibility": visibilityEvaluated ? "evaluated" : "not_evaluated",
            "content_readable_regions": (snapshot.frame.capturedRegions ?? []).map { rectJSON($0) },
            "content_available": !(snapshot.frame.capturedRegions ?? []).isEmpty,
            "content_unavailable_reason": snapshot.frame.contentUnavailableReason.map { $0 as Any } ?? ((snapshot.frame.capturedRegions ?? []).isEmpty ? "no_verified_target_coverage" as Any : NSNull()),
            "screen_capture_permission_preflight": CGPreflightScreenCaptureAccess(),
            "main_window_content_diagnostics": snapshot.frame.mainContentDiagnostics.map { $0 as Any } ?? NSNull(),
            "background_capture_source": snapshot.frame.captureSource,
            "content_sha256": snapshot.frame.contentDigest.map { $0 as Any } ?? NSNull(),
            "content_unchanged_since_previous_capture": snapshot.frame.contentUnchanged.map { $0 as Any } ?? NSNull(),
            "freshness_evidence": snapshot.frame.captureEvidence?["capture_filter_path"] as? String == "committed_exact_filter_fresh_update" ?
                "committed_exact_stream_fresh_filter_epoch_complete_PTS_barrier_and_identity_before_after" :
                snapshot.frame.captureEvidence?["capture_pool_reused"] as? Bool == true ?
                "reused_target_bound_stream_fresh_app_to_window_filter_epoch_complete_PTS_barrier_and_identity_before_after" :
                "new_stream_app_warmup_then_window_filter_epoch_and_complete_PTS_barrier_with_identity_before_after_not_pixel_change_proof",
            "capture_delivery_evidence": snapshot.frame.captureEvidence.map { $0 as Any } ?? NSNull(),
            "coverage_verification": !visibilityEvaluated ? "SC_exact_main_identity_before_after_own_aux_masks_physical_visibility_not_evaluated" : (snapshot.frame.visibleRegions == nil ? "CG_occluders_and_systemwide_AX_before_after_with_target_isolated_pixels" : "AX_CG_SC_exact_main_and_verified_popup_identity_before_after_with_own_aux_masks"),
            "display_fragment_count": capturePlan?.fragments.filter { fragment in
                (snapshot.frame.capturedRegions ?? []).contains {
                    let intersection = $0.intersection(fragment.rect)
                    return !intersection.isNull && intersection.width > 0 && intersection.height > 0
                }
            }.count ?? 0,
            "capture_stream_count": snapshot.frame.captureEvidence?["capture_stream_count"] ?? 0,
            "search_overlay_window_id": snapshot.frame.searchOverlay.map { $0.windowID as Any } ?? NSNull(),
            "search_overlay_frame": snapshot.frame.searchOverlay.map { rectJSON($0.frame) as Any } ?? NSNull(),
            "search_overlay_query_verified": snapshot.frame.searchOverlay != nil && snapshot.frame.searchQuery?.isEmpty == false,
            "search_overlay_activation_verified": snapshot.frame.searchOverlay != nil && snapshot.frame.searchQuery == "",
            "search_lane_text": snapshot.frame.searchQuery.map { $0 as Any } ?? NSNull(),
            "search_lane_frame": snapshot.frame.searchQuery.flatMap { _ in try? visualSearchTextRegion(window: snapshot.identity.frame,
                control: CGRect(x: snapshot.identity.frame.minX + 70, y: snapshot.identity.frame.minY + snapshot.identity.frame.height * 0.014,
                    width: 210, height: snapshot.identity.frame.height * 0.025)) }.map { rectJSON($0) as Any } ?? NSNull(),
            "pixel_to_point_scale_x": Double(snapshot.frame.image.width) / snapshot.identity.frame.width,
            "pixel_to_point_scale_y": Double(snapshot.frame.image.height) / snapshot.identity.frame.height,
            "observation_materialized_uptime_ms": ProcessInfo.processInfo.systemUptime * 1000,
            "frame_complete_serial": snapshot.frame.completeSerial, "frame_age_ms": Int((ProcessInfo.processInfo.systemUptime - snapshot.frame.time) * 1000),
            "complete_frame_age_ms": Int((ProcessInfo.processInfo.systemUptime - snapshot.frame.completeTime) * 1000),
            "frame_liveness_source": snapshot.frame.captureEvidence?["capture_filter_path"] as? String == "committed_exact_filter_fresh_update" ?
                "reused_committed_exact_SCStream_new_complete_after_fresh_exact_window_filter_update" :
                snapshot.frame.captureEvidence?["capture_pool_reused"] as? Bool == true ?
                "reused_SCStream_new_complete_after_fresh_app_to_exact_window_filter_update" :
                "new_SCStream_complete_after_app_to_exact_window_filter_update",
            "snapshot_max_age_ms": 5000, "display_topology_signature": snapshot.identity.topology,
            "ocr": observations, "text": String(observations.compactMap { $0["text"] as? String }.joined(separator: "\n").prefix(16000)),
            "target_visible_verified": visibilityEvaluated && snapshot.confirmed && (snapshot.frame.visibleRegions == nil || visualCovered(snapshot.identity.frame, by: snapshot.frame.visibleRegions ?? [])),
            "target_identity_verified": true, "visibility_verification_source": snapshot.confirmationSource,
            "anchor_matches": snapshot.anchors.map { anchor in ["anchor_text": anchor,
                "matching_ocr": Array(snapshot.rows.filter { row in (row["text"] as? String).map { visualNormalizedText($0).contains(visualNormalizedText(anchor)) } ?? false }.prefix(2))] as [String: Any] },
            "anchor_texts": snapshot.anchors, "capture_method": snapshot.frame.captureSource,
            "ocr_method": "local_Apple_Vision", "image_saved": false]
        if var hint = visualEmptyComposerHint(snapshot.frame, window: snapshot.identity.frame, rows: observations,
                                             now: ProcessInfo.processInfo.systemUptime, maximumAge: 5) {
            hint["snapshot_id"] = snapshot.id
            result["empty_composer_hint"] = hint
        }
        return result
    }

    // A narrow evidence reader for the process-directed editor. These snapshots
    // stay read-only: the background input owner must separately bind system
    // focus, event ownership and the exact target before posting anything.
    func backgroundComposerEvidence(target: Target, helper: DesktopHelper, title: String,
                                    expected: String, bindingSnapshotID: String? = nil) throws -> [String: Any] {
        try backgroundComposerState(target: target, helper: helper, title: title, expected: expected,
                                    bindingSnapshotID: bindingSnapshotID)
    }

    // The atomic editor discovers the current recipient and complete draft on
    // the same fresh frame. This reader never grants input eligibility and does
    // not reuse a caller's snapshot as fresh value/focus evidence.
    func backgroundComposerState(target: Target, helper: DesktopHelper, title: String? = nil,
                                 expected: String? = nil, bindingSnapshotID: String? = nil) throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        try helper.verify(target, focusedWindow: false)
        try helper.denySecure(target.window)
        let selected = try selectedIdentity(target)
        if let id = bindingSnapshotID {
            guard let previous = snapshot, previous.id == id, previous.readOnlyBackground,
                  previous.identity == selected else {
                throw fail("background_snapshot_changed", "The supplied read-only snapshot no longer binds the exact background window")
            }
        }
        let composer = visualVoiceComposerRegion(selected.frame)
        let header = visualSubmitHeader(selected.frame)
        let send = CGRect(x: selected.frame.maxX - 120, y: selected.frame.minY + selected.frame.height * 0.94,
                          width: 110, height: selected.frame.height * 0.06)
        if !backgroundReadOnly { stop(); backgroundReadOnly = true }
        backgroundCapture = "exact_window"; selectedInput = nil
        try ensureCapture(target, helper: helper, identity: selected)
        let captureStarted = ProcessInfo.processInfo.systemUptime
        let frame = try readFrame(target, helper: helper, identity: selected, allowRefresh: true).frame
        let ocrStarted = ProcessInfo.processInfo.systemUptime
        guard [header, composer, send].allSatisfy({ visualCovered($0, by: frame.capturedRegions ?? []) }) else {
            throw fail("background_composer_unverified", "The complete current recipient and composer are required")
        }
        let recognized = try ocrRegions(frame, identity: selected, regions: [header, composer, send], measurePerformance: true)
        let rows = recognized.rows
        let ocrEnded = ProcessInfo.processInfo.systemUptime
        guard rows.count <= 100 else { throw fail("background_composer_unverified", "Complete chat evidence exceeds the bounded row limit") }
        let titleRows = rows.filter { row in
            guard let bounds = try? visualRect(row["bounds"]) else { return false }
            return visualContains(header, bounds) && !(row["text"] as? String ?? "").isEmpty
        }
        guard titleRows.count == 1, let actualTitle = titleRows.first?["text"] as? String,
              !visualNormalizedText(actualTitle).isEmpty,
              !actualTitle.hasSuffix("…"), !actualTitle.hasSuffix("..."),
              title.map({ visualNormalizedText(actualTitle) == visualNormalizedText($0) }) ?? true else {
            throw fail("background_recipient_changed", "The complete selected recipient no longer matches")
        }
        guard rows.contains(where: { row in
            guard let bounds = try? visualRect(row["bounds"]), let text = row["text"] as? String else { return false }
            return visualContains(send, bounds) && visualNormalizedText(text).contains("发送")
        }) else { throw fail("background_composer_unverified", "The same complete frame lacks its Send control witness") }
        let composerRows = rows.filter { row in
            guard let bounds = try? visualRect(row["bounds"]) else { return false }
            return visualContains(composer, bounds)
        }
        let emptyHintStarted = ProcessInfo.processInfo.systemUptime
        let valueRows = visualRowsWithoutEmptyComposerHint(frame, window: selected.frame,
            rows: composerRows, now: ProcessInfo.processInfo.systemUptime)
        let emptyHintMS = (ProcessInfo.processInfo.systemUptime - emptyHintStarted) * 1000
        let actual = valueRows.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard expected.map({ actual == $0 }) ?? true else {
            throw fail("background_draft_changed", "The complete current composer differs from the exact expected value; no replay")
        }
        let bindingStarted = ProcessInfo.processInfo.systemUptime
        let bindingTiming = VisualCaptureMetrics()
        guard try selectedIdentity(target) == selected else {
            throw fail("background_target_changed", "The background target changed during composer evidence collection")
        }
        bindingTiming.mark("pre_snapshot_identity")
        let current = try makeSnapshot(frame, target: target, helper: helper, anchors: [actualTitle, "发送"],
                                       confirmed: true, preparedRows: rows, timing: bindingTiming)
        guard current.readOnlyBackground, current.confirmed else {
            throw fail("background_composer_unverified", "Complete same-frame recipient and Send anchors were not verified")
        }
        let completed = ProcessInfo.processInfo.systemUptime
        var phases = ["setup": (captureStarted - started) * 1000,
            "capture": (ocrStarted - captureStarted) * 1000,
            "ocr_and_binding": (completed - ocrStarted) * 1000,
            "ocr_regions": (ocrEnded - ocrStarted) * 1000,
            "value_evidence": (bindingStarted - ocrEnded) * 1000,
            "empty_composer_hint": emptyHintMS,
            "snapshot_binding": (completed - bindingStarted) * 1000]
        // Outer wall spans are already present. Omit duplicate nested totals
        // and tiny cache-store spans to keep the native stage budget bounded.
        for (name, milliseconds) in recognized.stageMS where name != "total" && !name.hasSuffix("_total") && !name.hasSuffix("_cache_store") {
            phases["ocr_\(name)"] = milliseconds
        }
        for (name, milliseconds) in bindingTiming.json where name != "total" { phases["binding_\(name)"] = milliseconds }
        for (key, prefix) in [("phase_ms", "capture_sc_"), ("validation_phase_ms", "capture_visual_")] {
            if let values = frame.captureEvidence?[key] as? [String: Double] {
                for (name, milliseconds) in values where name != "total" { phases[prefix + name] = milliseconds }
            }
        }
        var result: [String: Any] = ["snapshot_id": current.id, "target_pid": selected.pid,
            "window_id": selected.windowID, "read_only_background": true, "input_eligible": false,
            "background_recipient": actualTitle, "frame_complete_serial": frame.completeSerial,
            "background_evidence_stage_ms": phases]
        if let visibility = frame.captureEvidence?["physical_visibility"] { result["physical_visibility"] = visibility }
        if frame.visibleRegions == nil { result["fully_visible"] = false }
        result["background_composer_verified"] = true
        result["background_recipient_verified"] = true
        result["background_composer_value"] = actual
        result["background_evidence_frame_time"] = current.frame.time
        result["background_control_rect"] = rectJSON(composer)
        return result
    }

    func read(_ request: [String: Any], target: Target, helper: DesktopHelper, background: Bool = false) throws -> [String: Any] {
        try validate(request)
        if backgroundReadOnly != background { stop(); backgroundReadOnly = background }
        backgroundCapture = background ? (try string(request, "background_capture", required: false) ?? "auto") : "visible_screen"
        diagnosticsRequested = request["debug_image_path"] != nil
        defer { diagnosticsRequested = false }
        selectedInput = nil // A read never establishes keyboard focus on a visual control.
        let requestedAnchors = try anchors(request)
        let confirm = try boolean(request, "confirm_target")
        let anchorWaitMS = try integer(request, "anchor_wait_timeout_ms", default: 3000, range: 0...3000)
        let requestedRegions = try readRegions(request)
        let explicitMultiple = request["regions"] != nil
        try helper.verify(target, focusedWindow: false)
        try helper.denySecure(target.window)
        let selected = try selectedIdentity(target)
        _ = try focusedWindow(target, identity: selected, helper: helper)
        if let requestedRegions, requestedRegions.contains(where: { !visualContains(selected.frame, $0) }) {
            throw fail("visual_region_outside_window", "Every requested OCR region must lie inside the target window")
        }
        let warm = identity == selected && captureReady
        let refreshStarted = ProcessInfo.processInfo.systemUptime
        try ensureCapture(target, helper: helper, identity: selected)
        let refreshMS = warm ? 0 : Int((ProcessInfo.processInfo.systemUptime - refreshStarted) * 1000)
        let frameRead = try readFrame(target, helper: helper, identity: selected, allowRefresh: warm)
        var frame = frameRead.frame
        var readRefreshed = frameRead.refreshed
        var readRefreshMS = frameRead.refreshMS
        let previous = snapshot
        let regionContinuation = warm && requestedRegions != nil && previous?.confirmed == true && previous?.identity == selected &&
            (requestedAnchors.isEmpty || requestedAnchors == previous?.anchors)
        let effectiveAnchors = regionContinuation ? previous!.anchors : requestedAnchors
        let proposedRegions: [CGRect]
        if explicitMultiple { proposedRegions = requestedRegions! }
        else if let requestedRegions { proposedRegions = visualReadAnchorBands(selected.frame) + requestedRegions }
        else { proposedRegions = (confirm ? visualReadAnchorBands(selected.frame) : []) + [selected.frame] }
        var scanRegions: [CGRect] = []
        for region in proposedRegions where !scanRegions.contains(region) { scanRegions.append(region) }
        var outputRows: [[String: Any]] = []
        func readSnapshot(_ frame: VisualFrame) throws -> VisualSnapshot {
            try helper.verify(target, focusedWindow: false)
            let beforeFocus = try focusedWindow(target, identity: selected, helper: helper)
            let recognized = try ocrRegions(frame, identity: selected, regions: scanRegions)
            try helper.verify(target, focusedWindow: false)
            let afterFocus = try focusedWindow(target, identity: selected, helper: helper)
            guard CFEqual(beforeFocus.0, afterFocus.0), beforeFocus.1 == afterFocus.1 else {
                throw fail("visual_target_changed", "Focused window changed during scoped OCR")
            }
            if explicitMultiple { outputRows = recognized.rows }
            else if let region = requestedRegions?.first, let index = scanRegions.firstIndex(of: region) {
                outputRows = recognized.regionRows[index]
            } else { outputRows = recognized.rows }
            return try makeSnapshot(frame, target: target, helper: helper, anchors: effectiveAnchors, confirmed: confirm,
                continuation: regionContinuation ? previous : nil, preparedRows: recognized.rows)
        }
        var snap = try readSnapshot(frame)
        // Wait for actual same-frame matching anchors, never capture API success.
        let anchorDeadline = ProcessInfo.processInfo.systemUptime + Double(anchorWaitMS) / 1000
        while confirm && effectiveAnchors.count >= 2 && !snap.confirmed && ProcessInfo.processInfo.systemUptime < anchorDeadline {
            do {
                let nextRead = try readFrame(target, helper: helper, identity: selected, allowRefresh: warm && !readRefreshed,
                    timeout: max(0.05, anchorDeadline - ProcessInfo.processInfo.systemUptime), after: frame.completeSerial)
                readRefreshed = readRefreshed || nextRead.refreshed
                readRefreshMS += nextRead.refreshMS
                frame = nextRead.frame
                snap = try readSnapshot(frame)
            } catch {
                // Missing anchors are useful read-only evidence. Only the lack of
                // another complete frame ends this observation wait; target,
                // permission, secure-field and takeover errors still propagate.
                guard (error as? HelperError)?.code == "visual_frame_timeout" else { throw error }
                break
            }
        }
        try helper.verify(target, focusedWindow: false)
        guard try selectedIdentity(target) == selected else { throw fail("visual_target_changed", "Target changed during read-only anchor observation") }
        let finalFocus = try focusedWindow(target, identity: selected, helper: helper)
        guard CFEqual(finalFocus.0, snap.focusedWindow), finalFocus.1 == snap.focusedFrame else {
            throw fail("visual_target_changed", "Focused window changed during read-only anchor observation")
        }
        let rowLimit = try integer(request, "max_text_rows", default: 100, range: 1...100)
        var result = json(snap, rows: Array(outputRows.prefix(rowLimit)))
        result["anchor_wait_timeout_ms"] = anchorWaitMS
        result["region_continuation"] = regionContinuation
        result["ocr_scope"] = explicitMultiple ? "requested_regions" :
            (requestedRegions != nil ? "requested_region_and_top_footer_anchor_bands" :
                (confirm ? "full_window_and_top_footer_anchor_bands" : "full_window"))
        result["ocr_regions"] = scanRegions.map { rectJSON($0) }
        result["ocr"] = Array(outputRows.prefix(rowLimit))
        result["text"] = String(outputRows.prefix(rowLimit).compactMap { $0["text"] as? String }.joined(separator: "\n").prefix(16000))
        result["ocr_truncated"] = outputRows.count > rowLimit
        result["stream_warm"] = frame.captureEvidence?["capture_pool_reused"] as? Bool == true
        result["capture_binding_warm"] = warm; result["capture_setup_ms"] = refreshMS
        result["read_filter_refreshed"] = readRefreshed
        result["read_filter_refresh_ms"] = 0; result["snapshot_capture_ms"] = readRefreshMS
        if let path = try string(request, "debug_image_path", required: false) {
            guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw fail("visual_image_write_failed", "Could not create one-frame debug PNG destination")
            }
            guard let raw = frame.debugRawImage, let diagnostic = frame.coverageDiagnostics else {
                throw fail("visual_diagnostic_unavailable", "No raw pre-mask frame diagnostics were bound to this exact returned frame")
            }
            CGImageDestinationAddImage(destination, raw, nil)
            guard CGImageDestinationFinalize(destination) else { throw fail("visual_image_write_failed", "Debug PNG write failed") }
            result["image_saved"] = true; result["debug_image_path"] = path
            result["debug_image_content"] = "exact_target_window_filter_pixels_before_visibility_and_UI_hint_masks"
            result["coverage_diagnostics"] = diagnostic
        }
        result["image_requested"] = try boolean(request, "include_image")
        if try boolean(request, "include_image") {
            result["image"] = try observationImage(frame, identity: selected, snapshotID: snap.id, background: background)
            result["image_available"] = true
        }
        if background { result["focus_context"] = observationSystemFocus(); result["focus_changed_by_helper"] = false; result["events_posted"] = 0 }
        return result
    }

    func verifyNavigationHintAnchors(_ snapshot: VisualSnapshot, frame: VisualFrame, transition: VisualNavigationHintTransition) throws {
        guard transition.acceptsFrames(snapshot.frame, frame) else {
            throw fail("visual_target_changed", "Navigation visibility changed beyond a previously pixel-verified input-source hint")
        }
        var rows: [[String: Any]] = []
        for region in snapshot.anchorRegions { rows += try ocr(frame, identity: snapshot.identity, region: region) }
        guard visualAnchorsVerified(snapshot.anchors, rows: rows, confirmed: snapshot.confirmed) else {
            throw fail("visual_target_unconfirmed", "Two visible target anchors must be recognized again after the input-source hint changed")
        }
    }

    func currentContinuousSubmitSceneMatches(_ snapshot: VisualSnapshot, helper: DesktopHelper) throws -> Bool {
        try helper.monitor.check()
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let windows = try visualScreenWindows(rows, identity: snapshot.identity,
            displays: try activeDisplays().displays.map { $0.bounds }, dockPID: dockPID)
        return visualContinuousSubmitSceneMatches(snapshot.frame, current: windows, identity: snapshot.identity)
    }

    func guardSnapshot(_ request: [String: Any], target: Target, helper: DesktopHelper,
                       continuousProof candidate: VisualContinuousSubmitProof? = nil) throws -> (snapshot: VisualSnapshot, frame: VisualFrame, navigationHintTransition: VisualNavigationHintTransition?, navigationSnapshot: VisualSnapshot?, continuousProof: VisualContinuousSubmitProof?) {
        let id = try string(request, "snapshot_id")!
        guard let current = snapshot, current.id == id else { throw fail("stale_visual_snapshot", "Unknown/consumed snapshot; read the target again") }
        guard !current.readOnlyBackground else { throw fail("background_snapshot_read_only", "Background-read snapshots cannot authorize any input; read and focus through the appropriate input route") }
        let maxAge = try integer(request, "max_age_ms", default: 5000, range: 1...5000)
        guard ProcessInfo.processInfo.systemUptime - current.created <= Double(maxAge) / 1000 else {
            throw fail("stale_visual_snapshot", "Snapshot age exceeded the permitted bound")
        }
        try helper.verify(target, focusedWindow: false)
        try helper.denySecure(target.window)
        let navigationHintTransition = VisualNavigationHintTransition(request: request, snapshot: current)
        guard identity == current.identity, captureReady else {
            throw fail("visual_capture_unavailable", "A new exact-window capture is required before input")
        }
        let visible: VisualFrame
        let continuousProof: VisualContinuousSubmitProof?
        if let candidate, candidate.matches(request, scope: nativeCommandScope, helperID: ObjectIdentifier(helper),
                snapshot: current, revision: helper.monitor.interactionRevision, now: ProcessInfo.processInfo.systemUptime),
           try currentContinuousSubmitSceneMatches(current, helper: helper) {
            visible = current.frame; continuousProof = candidate
        } else {
            guard let captured = try waitFrame(helper: helper, target: target, timeout: 3, after: current.frame.completeSerial,
                    navigationHintTransition: navigationHintTransition) else {
                throw fail("visual_capture_unavailable", "A new exact-window capture is required before input")
            }
            visible = captured; continuousProof = nil
        }
        let sameVisibility = (visible.capturedRegions == current.frame.capturedRegions &&
              visible.screenWindows == current.frame.screenWindows &&
              visible.excludedInputRegions == current.frame.excludedInputRegions &&
              visible.searchOverlay == current.frame.searchOverlay && visible.searchQuery == current.frame.searchQuery) ||
              visualNavigationCornerExclusionMigration(request, snapshot: current, after: visible) ||
              visualInputMaskedCornerReplacement(request, snapshot: current, after: visible)
        var navigationSnapshot: VisualSnapshot?
        if !sameVisibility {
            if visualTextNavigationCornerMaskChange(request, snapshot: current, after: visible) {
                var anchorRows: [[String: Any]] = []
                for region in current.anchorRegions { anchorRows += try ocr(visible, identity: current.identity, region: region) }
                guard visualAnchorsVerified(current.anchors, rows: anchorRows, confirmed: current.confirmed) else {
                    throw fail("visual_target_unconfirmed", "Two visible anchors must be recognized again after the corner exclusion changed")
                }
                let control = try visualRect(request["control_rect"])
                let rows = try ocr(visible, identity: current.identity, region: control)
                let point = request["x"] != nil ? try CGPoint(x: number(request, "x"), y: number(request, "y")) : nil
                guard visualLiteralNavigationProof(current.rows, freshRows: rows, label: try string(request, "target_text")!, control: control, point: point) else {
                    throw fail("visual_navigation_unconfirmed", "One complete observed navigation row must remain literally unchanged and uniquely match the fresh visible control")
                }
                navigationSnapshot = visualReboundNavigationSnapshot(current, frame: visible, rows: anchorRows + rows)
            } else if let navigationHintTransition {
                try verifyNavigationHintAnchors(current, frame: visible, transition: navigationHintTransition)
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                var details: [String: Any] = ["phase": "guard_snapshot_visibility", "events_posted": 0,
                    "visibility_difference": visualSnapshotVisibilityDiagnostic(current.frame, visible, now: now),
                    "snapshot_age_ms": (now - current.created) * 1000,
                    "capture_identity_matches_snapshot": identity == current.identity,
                    "search_activation_present": searchActivation != nil,
                    "search_activation_identity_matches": searchActivation?.identity == current.identity]
                let corner = CGRect(x: current.identity.frame.minX + 6, y: current.identity.frame.minY + 5, width: 52, height: 20)
                details["before_corner_exclusion_owner_verified"] = visualCornerExclusionHasOwnerProof(current.frame, identity: current.identity, corner: corner)
                details["after_corner_exclusion_owner_verified"] = visualCornerExclusionHasOwnerProof(visible, identity: current.identity, corner: corner)
                if let controlRect = try? visualRect(request["control_rect"], name: "control_rect") {
                    details["control_rect"] = rectJSON(controlRect)
                    if request["control_kind"] as? String == "search",
                       let lane = try? visualSearchTextRegion(window: current.identity.frame, control: controlRect) {
                        details["search_lane_rect"] = rectJSON(lane)
                        details["search_activation_control_matches"] = searchActivation?.control == controlRect
                        details["search_activation_lane_matches"] = searchActivation?.matches(current.identity, queryRegion: lane) == true
                        details["before_search_lane_covered"] = current.frame.capturedRegions.map { visualCovered(lane, by: $0) } ?? false
                        details["after_search_lane_covered"] = visible.capturedRegions.map { visualCovered(lane, by: $0) } ?? false
                    }
                    details["selected_input_control_bound"] = selectedInput.map {
                        $0.0 == current.identity && $0.1 == (request["control_kind"] as? String) && $0.2 == controlRect &&
                            CFEqual($0.3, current.focusedWindow)
                    } ?? false
                }
                snapshot = nil; selectedInput = nil
                throw fail("visual_target_changed", "Actual target visibility changed; read and select the control again", details)
            }
        }
        guard try selectedIdentity(target) == current.identity else { throw fail("visual_target_changed", "Snapshot no longer matches PID/window/frame/topology") }
        let focused = try focusedWindow(target, identity: current.identity, helper: helper)
        guard CFEqual(focused.0, current.focusedWindow), focused.1 == current.focusedFrame else {
            throw fail("window_mismatch", "Focused window differs from the snapshot; obtain a new snapshot")
        }
        if let element = axElement(target.axApplication, kAXFocusedUIElementAttribute) {
            try helper.denySecure(element)
            if ["AXTextArea", "AXTextField", "AXComboBox"].contains(axString(element, kAXRoleAttribute) ?? "") {
                throw fail("ax_input_available", "Use the existing AX input path for an accessible focused text control")
            }
        }
        guard current.confirmed else { throw fail("visual_target_unconfirmed", "Input requires caller confirmation and two matching visible OCR anchors") }
        return (current, visible, navigationHintTransition, navigationSnapshot, continuousProof)
    }

    func control(_ request: [String: Any], snapshot: VisualSnapshot, input: Bool) throws -> (String, CGRect) {
        let kind = try string(request, "control_kind")!
        guard ["search", "chat_composer", "navigation"].contains(kind), !input || kind != "navigation",
              try boolean(request, "confirm_control") else { throw fail("visual_control_unconfirmed", "Confirm a search/composer region or an OCR navigation target") }
        let rect = try visualRect(request["control_rect"], name: "control_rect")
        let window = snapshot.identity.frame
        guard visualContains(window, rect) else { throw fail("visual_region_outside_window", "Control region must lie inside the snapshot window") }
        let valueRegion = kind == "search" ? try visualSearchTextRegion(window: window, control: rect) : rect
        if request["navigation_target_kind"] as? String == "icon" {
            guard let coverage = snapshot.frame.capturedRegions, visualCovered(rect, by: coverage) else {
                throw fail("visual_control_not_fully_visible", "The entire model-confirmed icon rectangle must be visibly captured")
            }
        }
        if kind != "navigation", let coverage = snapshot.frame.capturedRegions, !visualCovered(valueRegion, by: coverage) {
            throw fail("visual_control_not_fully_visible", "Search/composer region includes an offscreen area or display gap; its full value cannot be verified")
        }
        if kind == "search" {
            guard rect.minX >= window.minX + window.width * 0.04, rect.maxX <= window.minX + window.width * 0.45,
                  rect.maxY <= window.minY + window.height * 0.15 else { throw fail("visual_control_unsupported", "Search input must occupy WeChat's upper-left search area") }
        } else if kind == "chat_composer" {
            guard snapshot.focusedFrame == window,
                  rect.minX >= window.minX + window.width * 0.25, rect.minY >= window.minY + window.height * 0.55,
                  snapshot.rows.contains(where: { row in
                    guard let text = row["text"] as? String, text.contains("发送"), let bounds = try? visualRect(row["bounds"]) else { return false }
                    return bounds.minY >= window.minY + window.height * 0.70 && bounds.minX >= window.minX + window.width * 0.40
                  }) else { throw fail("visual_control_unsupported", "Composer input requires the lower-right chat area and a visible Send control") }
        }
        try denySensitiveRows(snapshot.rows, region: rect)
        return (kind, rect)
    }

    func denySensitiveRows(_ rows: [[String: Any]], region: CGRect) throws {
        let sensitive = ["密码", "登录", "登入", "验证码", "扫码登录", "password", "sign in", "log in", "verification code"]
        for row in rows {
            guard let text = row["text"] as? String, let bounds = try? visualRect(row["bounds"]),
                  !bounds.intersection(region.insetBy(dx: -12, dy: -12)).isNull else { continue }
            guard !sensitive.contains(where: { text.lowercased().contains($0) }) else { throw fail("secure_field_denied", "Visual fallback refuses login/password/verification controls") }
        }
    }

    func guardPoint(_ point: CGPoint, snapshot: VisualSnapshot) throws {
        guard !snapshot.frame.excludedInputRegions.contains(where:{pointIsInsideRect(point,$0)}) else { throw fail("coordinate_target_mismatch", "Point is inside a visible input-source hint or untrusted overlay") }
        let observed = try visualCurrentSearchOverlay(snapshot.identity)
        guard observed == snapshot.frame.searchOverlay ||
              (snapshot.frame.searchOverlay == nil && observed.map { !pointIsInsideRect(point, $0.frame) } == true) else {
            throw fail("visual_target_changed", "Search popup changed before the input point check")
        }
        try guardDesktopPoint(point, identity: snapshot.identity, selectedWindow: selectedAXWindow, searchOverlay: snapshot.frame.searchOverlay)
    }

    func postKey(_ code: CGKeyCode, flags: CGEventFlags, helper: DesktopHelper, target: Target, count: inout Int,
                 beforePost: ((Int) throws -> Void)? = nil) throws {
        guard let down = CGEvent(keyboardEventSource: helper.source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: helper.source, virtualKey: code, keyDown: false) else { throw fail("event_creation_failed", "Could not construct visual keyboard events") }
        down.flags = flags; up.flags = []
        try visualPostCountedKeyPair(count: &count, beforePost: beforePost,
            down: { try helper.post(down, target: target) },
            up: {
                if beforePost != nil { try helper.post(up, target: target) }
                else {
                    up.setIntegerValueField(.eventSourceUserData, value: helper.monitor.marker)
                    up.post(tap: .cghidEventTap)
                }
            })
    }

    func action(_ request: [String: Any], target: Target, helper: DesktopHelper) throws -> [String: Any] {
        // Consume before validation/guards: no failure or retry can reuse it.
        let continuousCandidate = takeContinuousSubmitProof()
        try validate(request)
        let command = try string(request, "command")!
        let replaceSearch = command == "visual_type_text" ? try boolean(request, "replace_search") : false
        let actionStarted = ProcessInfo.processInfo.systemUptime
        var count = 0
        var submit = false
        var submitGuardFrameReused = false
        var continuousSubmitReused = false
        var continuousProofFrameAgeMS: Double?
        var submitPreinputMS: Double?
        var inputDispatchStarted: Double?
        var inputDispatchFinished: Double?
        var actionStageMS: [String: Double] = [:]
        func recordOCRStages(_ prefix: String, _ stages: [String: Double]) {
            for (key, value) in stages where key.hasSuffix("_fingerprint") || key.hasSuffix("_cache_hit") || key.hasSuffix("_recognition_and_rows") {
                actionStageMS[prefix + key, default: 0] += value
            }
        }
        var focusClickRevision: UInt64?
        var prefixPlan: VisualPrefixDeletion?
        var clearingDraft = false
        var clearPostObservationCount = 0
        var clearPostDiagnostic: [String: Any]?
        var deleteEvents = 0
        do {
            let validated = try guardSnapshot(request, target: target, helper: helper, continuousProof: continuousCandidate)
            continuousSubmitReused = validated.continuousProof != nil
            actionStageMS["guard_snapshot"] = (ProcessInfo.processInfo.systemUptime - actionStarted) * 1000
            let old = validated.snapshot
            let navigationSnapshot = validated.navigationSnapshot ?? old
            let guardFrame = validated.frame
            if !continuousSubmitReused, let stages = guardFrame.captureEvidence?["phase_ms"] as? [String: Double], let total = stages["total"] {
                actionStageMS["guard_frame_SC_capture"] = total
            }
            if !continuousSubmitReused, let stages = guardFrame.captureEvidence?["validation_phase_ms"] as? [String: Double], let owner = stages["AX_owner_coverage"] {
                actionStageMS["guard_frame_AX_ownership"] = owner
            }
            var inputEvidenceFrame = guardFrame
            var prefixEvidence: VisualPrefixEvidence?
            let controlled = try control(request, snapshot: navigationSnapshot, input: command == "visual_type_text" || command == "visual_key")
            let verificationRegion = replaceSearch ? try visualSearchTextRegion(window: old.identity.frame, control: controlled.1) : controlled.1
            try helper.requireEvents()
            // A changed control rectangle must be checked from current local
            // pixels even though the warm snapshot no longer OCRs the whole chat.
            // guardSnapshot just acquired and verified this new frame in this
            // RPC. A continuous submit alone may consume its immediately prior
            // native type proof instead; its current target/focus guards remain.
            let scrollPoint = command == "visual_scroll" ? try CGPoint(x: number(request, "x"), y: number(request, "y")) : nil
            let safetyRegion = try visualControlSafetyRegion(command: command, control: controlled.1, window: old.identity.frame, point: scrollPoint)
            let requestedKey = (request["key"] as? String)?.lowercased()
            let submitRequested = command == "visual_key" && ["return", "enter"].contains(requestedKey ?? "")
            // Submit scans security/value on its chosen complete frame below.
            // Do not OCR this editor once here and again before the same Return.
            let freshControlRows = submitRequested ? [] : try ocr(guardFrame, identity: old.identity, region: safetyRegion)
            if !submitRequested { try denySensitiveRows(freshControlRows, region: controlled.1) }
            if command == "visual_type_text" || (command == "visual_key" && !["escape", "f"].contains(requestedKey ?? "")) {
                guard let selectedInput, selectedInput.0 == old.identity, selectedInput.1 == controlled.0,
                      selectedInput.2 == controlled.1, CFEqual(selectedInput.3, old.focusedWindow),
                      selectedInputRevision == helper.monitor.interactionRevision else {
                    throw fail("visual_input_not_focused", "First visual_click the same confirmed search/composer rectangle; reads alone do not establish input focus")
                }
                try guardPoint(CGPoint(x: controlled.1.midX, y: controlled.1.midY), snapshot: old)
            }
            func guardCurrentTargetFocus() throws -> VisualIdentity {
                if command == "visual_type_text" || submitRequested {
                    guard selectedInputRevision == helper.monitor.interactionRevision else {
                        throw fail("visual_input_focus_changed", "External input invalidated the retained editor focus; read and select again before further input")
                    }
                }
                try helper.verify(target, focusedWindow: false)
                let focused = try helper.settledFocusedWindow(target)
                let currentIdentity = try selectedIdentity(target)
                guard currentIdentity == old.identity,
                      CFEqual(focused, old.focusedWindow),
                      axBounds(focused) == old.focusedFrame else { throw fail("visual_target_changed", "Visual target/focus changed during action") }
                try helper.denySecure(focused)
                if let element = axElement(target.axApplication, kAXFocusedUIElementAttribute) { try helper.denySecure(element) }
                return currentIdentity
            }
            func guardUnchangedFocus(_ postedCount: Int) throws {
                let now = ProcessInfo.processInfo.systemUptime
                guard prefixEvidence.map({ $0.current(at: now) }) ?? (now-old.created <= 5) else {
                    throw fail("stale_visual_snapshot", "Snapshot or verified prefix input evidence aged beyond 5000 ms during action")
                }
                _ = try guardCurrentTargetFocus()
                if postedCount == 0 {
                    if let proof = validated.continuousProof {
                        guard proof.matches(request, scope: nativeCommandScope, helperID: ObjectIdentifier(helper),
                            snapshot: old, revision: helper.monitor.interactionRevision, now: ProcessInfo.processInfo.systemUptime) else {
                            throw fail("stale_visual_snapshot", "Continuous native type proof expired or changed before Return; no submit events were posted")
                        }
                    } else if !visualFreshPreinputFrame(inputEvidenceFrame, after: old.frame.completeSerial, now: ProcessInfo.processInfo.systemUptime) {
                        throw fail("stale_visual_snapshot", "The same-RPC input evidence exceeded the two-second frame bound; no input was posted")
                    }
                }
            }
            var expected: String?
            let baselineSerial = latestWindowFrame?.completeSerial ?? old.frame.completeSerial
            if command == "visual_type_text" {
                let text = try string(request, "text")!
                let visible = try string(request, "expected_text")!
                guard text.count <= 4096, visible.count <= 4096, visible.contains(text),
                      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }),
                      !visible.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
                    throw fail("invalid_request", "Visual text/expected_text must be single-line, at most 4096 characters, and expected_text must contain the complete requested text")
                }
                let inputRows = controlled.0 == "chat_composer" ? visualRowsWithoutEmptyComposerHint(guardFrame,
                    window: old.identity.frame, rows: freshControlRows, now: ProcessInfo.processInfo.systemUptime) : freshControlRows
                let searchRows = replaceSearch ? try ocr(guardFrame, identity: old.identity, region: verificationRegion) : inputRows
                let beforeText = searchRows.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let alreadyVisible = replaceSearch ? visualNormalizedText(beforeText) == visualNormalizedText(visible) : matches(visible, rows: inputRows)
                if replaceSearch && alreadyVisible {
                    try guardUnchangedFocus(count)
                    guard text == visible, ProcessInfo.processInfo.systemUptime - guardFrame.time <= 2 else {
                        throw fail("stale_visual_snapshot", "A fresh complete search-region observation is required for the unchanged desired query")
                    }
                    var result = json(old, rows: Array(searchRows.prefix(100)))
                    result.removeValue(forKey: "anchor_matches")
                    result["ocr_region"] = rectJSON(verificationRegion)
                    result["value_ocr_region"] = rectJSON(verificationRegion)
                    result["ocr_truncated"] = searchRows.count > 100
                    result["events_posted"] = 0; result["action_accepted"] = false
                    result["search_replaced"] = false; result["value_verified"] = true
                    result["verification_source"] = "current_complete_frame_exact_search_region_OCR"
                    result["verification_frame_complete_serial"] = guardFrame.completeSerial
                    result["verification_frame_age_ms"] = Int((ProcessInfo.processInfo.systemUptime - guardFrame.time) * 1000)
                    result["verification_snapshot_id"] = old.id
                    result["automatic_replay_allowed"] = false
                    return result
                }
                guard !alreadyVisible else { throw fail("precondition_failed", "expected_text is already visible; unchanged OCR cannot verify new input") }
                expected = visible
                snapshot = nil
                if replaceSearch {
                    // Search replacement is one bounded action: no intermediate
                    // selection/deletion OCR, and no Return or automatic replay.
                    try postKey(0, flags: .maskCommand, helper: helper, target: target, count: &count, beforePost: guardUnchangedFocus)
                    try postKey(51, flags: [], helper: helper, target: target, count: &count, beforePost: guardUnchangedFocus)
                }
                inputDispatchStarted = ProcessInfo.processInfo.systemUptime
                let units = Array(text.utf16)
                var index = 0
                while index < units.count {
                    try guardUnchangedFocus(count)
                    var end = min(index + 20, units.count)
                    if end < units.count && units[end - 1] >= 0xD800 && units[end - 1] <= 0xDBFF { end -= 1 }
                    var chunk = Array(units[index..<end])
                    guard let down = CGEvent(keyboardEventSource: helper.source, virtualKey: 0, keyDown: true),
                          let up = CGEvent(keyboardEventSource: helper.source, virtualKey: 0, keyDown: false) else { throw fail("event_creation_failed", "Could not construct Unicode events") }
                    down.flags = []; up.flags = []
                    chunk.withUnsafeMutableBufferPointer {
                        down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
                        up.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
                    }
                    try helper.post(down, target: target); count += 1
                    if replaceSearch {
                        try guardUnchangedFocus(count)
                        try helper.post(up, target: target)
                    } else {
                        up.setIntegerValueField(.eventSourceUserData, value: helper.monitor.marker); up.post(tap: .cghidEventTap)
                    }
                    count += 1
                    index = end
                }
                inputDispatchFinished = ProcessInfo.processInfo.systemUptime
            } else if command == "visual_key", requestedKey == "clear_draft" {
                clearingDraft = true
                let draft = try string(request, "expected_draft")!, title = try string(request, "chat_title")!
                let composerRows = try ocr(guardFrame, identity: old.identity, region: controlled.1)
                let headerRows = try ocr(guardFrame, identity: old.identity, region: visualSubmitHeader(old.identity.frame))
                var anchorRows: [[String: Any]] = []
                for region in old.anchorRegions { anchorRows += try ocr(guardFrame, identity: old.identity, region: region) }
                guard visualAnchorsVerified(old.anchors, rows: anchorRows, confirmed: old.confirmed) else {
                    throw fail("visual_target_unconfirmed", "Whole-draft clear requires two freshly recognized visible anchors")
                }
                guard try visualClearDraftObservation(guardFrame, window: old.identity.frame, control: controlled.1,
                    composerRows: composerRows, headerRows: headerRows, expected: draft, title: title,
                    now: ProcessInfo.processInfo.systemUptime) else {
                    throw fail("clear_draft_mismatch", "Complete fresh composer differs from expected_draft; no clear events were posted")
                }
                snapshot = nil
                try visualClearDraftKeys { code, flags in
                    try postKey(code, flags: flags, helper: helper, target: target, count: &count, beforePost: guardUnchangedFocus)
                }
                expected = ""
            } else if command == "visual_key", requestedKey == "clear_prefix" {
                let draft=try string(request,"expected_draft")!,prefix=try string(request,"prefix")!,chatTitle=try string(request,"chat_title")!
                let plan=try visualPrefixDeletion(draft,prefix:prefix);prefixPlan=plan
                func exactDraft(_ frame:VisualFrame,_ expectedValue:String,allowReflow:Bool=false,requireCaret:Bool=false) throws -> [[String:Any]] {
                    guard visualCovered(controlled.1,by:frame.capturedRegions ?? []),ProcessInfo.processInfo.systemUptime-frame.time<=2 else{throw fail("visual_control_not_fully_visible","The complete fresh composer must be visible before prefix deletion")}
                    let rows=try ocr(frame,identity:old.identity,region:controlled.1)
                    let actual=rows.compactMap({$0["text"] as? String}).joined(separator:"\n")
                    let valueMatches = expectedValue.isEmpty ? visualPrefixFinalValueMatches(frame, window: old.identity.frame,
                        rows: rows, expected: "", now: ProcessInfo.processInfo.systemUptime) :
                        (allowReflow ? visualDraftSequence(actual)==visualDraftSequence(expectedValue) : actual==expectedValue)
                    guard rows.count<=100,valueMatches else{throw fail("prefix_draft_mismatch","Complete fresh composer OCR differs from expected_draft; no further deletion is allowed")}
                    let header=visualSubmitHeader(old.identity.frame)
                    guard visualCovered(header,by:frame.capturedRegions ?? []) else{throw fail("prefix_recipient_unverified","Complete recipient header is not visible")}
                    let titles=try ocr(frame,identity:old.identity,region:header)
                    guard titles.contains(where:{$0["text"] as? String == chatTitle}) else{throw fail("prefix_recipient_mismatch","Complete fresh recipient header differs from chat_title")}
                    if requireCaret {
                        guard let first = rows.first, let bounds = try? visualRect(first["bounds"]),
                              visualPrefixCaretAtStart(frame.image, window: old.identity.frame, control: controlled.1, firstText: bounds) else {
                            throw fail("prefix_caret_candidate_unverified", "Green candidate did not remain before the same frame's fully verified first draft glyph")
                        }
                    }
                    if frame.completeSerial > guardFrame.completeSerial {
                        let currentIdentity = try guardCurrentTargetFocus()
                        guard let renewed = visualPrefixEvidence(frame, identity: old.identity, currentIdentity: currentIdentity,
                            control: controlled.1, rows: rows, headerRows: titles, expected: expectedValue, title: chatTitle,
                            allowReflow: allowReflow, after: prefixEvidence?.serial ?? guardFrame.completeSerial,
                            now: ProcessInfo.processInfo.systemUptime) else {
                            throw fail("prefix_evidence_unverified", "A new complete fresh draft and exact recipient proof is required before continuing prefix deletion")
                        }
                        prefixEvidence = renewed
                        inputEvidenceFrame = frame
                    }
                    return rows
                }
                let initialRows = try exactDraft(guardFrame,draft)
                guard let first = initialRows.first, let priorFirstText = try? visualRect(first["bounds"]) else {
                    throw fail("prefix_start_unverified", "Complete draft has no first-glyph bounds; no selection or deletion events were posted")
                }
                try guardUnchangedFocus(count);snapshot=nil
                try postKey(0,flags:.maskCommand,helper:helper,target:target,count:&count,beforePost:guardUnchangedFocus)
                try postKey(123,flags:[],helper:helper,target:target,count:&count,beforePost:guardUnchangedFocus)
                var startVerified=false,observedSerial=guardFrame.completeSerial
                var caretDiagnostic: [String: Any] = ["available": false]
                var caretSamples = 0, caretCandidates = 0
                var previousCaretCaptureDuration: Double?
                // A new public warm capture takes 0.7–1.5s on this host.
                // The proof may wait up to the existing 3s observation bound;
                // no Delete is posted before the complete caret/draft proof.
                let caretDeadline=ProcessInfo.processInfo.systemUptime+3
                repeat {
                    try guardUnchangedFocus(count)
                    let captureStarted = ProcessInfo.processInfo.systemUptime
                    let remaining = caretDeadline-captureStarted
                    guard visualPrefixCaretCaptureBudget(remaining:remaining,previousDuration:previousCaretCaptureDuration) else {
                        caretDiagnostic["sampling_stopped"] = "insufficient_remaining_capture_budget"
                        caretDiagnostic["remaining_capture_budget_ms"] = max(0,remaining)*1000
                        break
                    }
                    let frame: VisualFrame
                    do {
                        guard let captured = try waitFrame(helper:helper,target:target,timeout:remaining,after:observedSerial) else { break }
                        frame = captured
                    } catch let error as HelperError where error.code == "visual_frame_timeout" {
                        caretDiagnostic["sampling_stopped"] = "capture_deadline"
                        caretDiagnostic["last_capture_error"] = error.code
                        break
                    }
                    previousCaretCaptureDuration = ProcessInfo.processInfo.systemUptime-captureStarted
                    observedSerial=frame.completeSerial
                    caretSamples += 1
                    caretDiagnostic = visualPrefixCaretDiagnostic(frame.image, window: old.identity.frame, control: controlled.1, firstText: priorFirstText)
                    caretDiagnostic["bounds_source"] = "prior_complete_draft_sampling_only"
                    do {
                        startVerified = try visualPrefixCaretCandidate(frame.image, window: old.identity.frame, control: controlled.1,
                            priorFirstText: priorFirstText) {
                            caretCandidates += 1
                            let rows = try exactDraft(frame, draft, requireCaret: true)
                            if let first = rows.first, let bounds = try? visualRect(first["bounds"]) {
                                caretDiagnostic = visualPrefixCaretDiagnostic(frame.image, window: old.identity.frame, control: controlled.1, firstText: bounds)
                                caretDiagnostic["bounds_source"] = "same_frame_verified_complete_draft"
                            }
                            return true
                        }
                    } catch let error as HelperError where ["prefix_draft_mismatch", "prefix_caret_candidate_unverified"].contains(error.code) {
                        startVerified = false
                    }
                    caretDiagnostic["sampled_frame_count"] = caretSamples
                    caretDiagnostic["green_candidate_frame_count"] = caretCandidates
                    if startVerified { break }
                }while ProcessInfo.processInfo.systemUptime<caretDeadline
                guard startVerified else{throw fail("prefix_start_unverified","Selection collapse did not visibly place the caret before the first draft character; no Delete events were posted", ["caret_diagnostic": caretDiagnostic, "delete_events_posted": 0])}
                // Verify the editor's actual ForwardDelete semantics after one
                // authorised prefix character before posting the remaining keys.
                let beforeFirst=count
                defer{deleteEvents=count-beforeFirst}
                try postKey(117,flags:[],helper:helper,target:target,count:&count,beforePost:guardUnchangedFocus)
                deleteEvents=count-beforeFirst
                let afterOne=String(draft.dropFirst()),firstDeadline=ProcessInfo.processInfo.systemUptime+3
                var firstVerified=false
                repeat {
                    try guardUnchangedFocus(count)
                    guard let frame=try waitFrame(helper:helper,target:target,timeout:max(0.05,firstDeadline-ProcessInfo.processInfo.systemUptime),after:observedSerial) else{break}
                    observedSerial=frame.completeSerial
                    if (try? exactDraft(frame,afterOne,allowReflow:true)) != nil {firstVerified=true;break}
                }while ProcessInfo.processInfo.systemUptime<firstDeadline
                guard firstVerified else{throw fail("prefix_delete_semantics_unverified","The first ForwardDelete did not produce the exact one-character-shorter draft; deletion stopped without replay")}
                for _ in 1..<plan.count {
                    try postKey(117,flags:[],helper:helper,target:target,count:&count,beforePost:guardUnchangedFocus)
                }
                deleteEvents=count-beforeFirst;expected=plan.suffix
            } else if command == "visual_key" {
                let key = try string(request, "key")!.lowercased()
                let modifiers = request["modifiers"] as? [String] ?? []
                let commandOnly = modifiers.count == 1 && ["cmd", "command"].contains(modifiers[0].lowercased())
                submit = ["return", "enter"].contains(key)
                let allowSubmit = try boolean(request, "allow_submit")
                guard (submit && modifiers.isEmpty && controlled.0 == "chat_composer" && allowSubmit) ||
                      (modifiers.isEmpty && ["escape", "backspace", "delete", "left", "right", "up", "down", "home", "end", "tab"].contains(key)) ||
                      (commandOnly && ["a", "f"].contains(key)), let code = helper.keyCodes[key] else {
                    throw fail("unsupported_visual_key", "Visual Return requires explicit submit fields; modified Return/Send shortcuts are denied")
                }
                if submit {
                    let chooseFrameStarted = ProcessInfo.processInfo.systemUptime
                    try guardUnchangedFocus(count)
                    let fresh: VisualFrame
                    if validated.continuousProof != nil {
                        fresh = guardFrame
                    } else if visualSubmitGuardFrameReusable(guardFrame, snapshot: old, control: controlled.1,
                                                       now: ProcessInfo.processInfo.systemUptime) {
                        fresh = guardFrame; submitGuardFrameReused = true
                    } else {
                        guard let captured = try waitFrame(helper: helper, target: target, timeout: 1,
                                after: guardFrame.completeSerial),
                              ProcessInfo.processInfo.systemUptime - captured.time <= 1 else {
                            throw fail("stale_visual_snapshot", "Fresh live composer pixels are required before submit")
                        }
                        fresh = captured
                    }
                    inputEvidenceFrame = fresh
                    actionStageMS["submit_choose_fresh_frame"] = (ProcessInfo.processInfo.systemUptime - chooseFrameStarted) * 1000
                    guard visualCovered(controlled.1, by: fresh.capturedRegions ?? []) else {
                        throw fail("submit_message_unverified", "The complete fresh composer must remain covered before submit; no submit events were posted")
                    }
                    let expectedMessage = try string(request, "expected_message")!
                    let chatTitle = try string(request, "chat_title")!
                    // This band stops above the message body. A same-named body
                    // message is never recipient evidence.
                    let header = visualSubmitHeader(old.identity.frame)
                    guard visualCovered(header, by: fresh.capturedRegions ?? []) else {
                        throw fail("submit_recipient_unverified", "The complete recipient header is not actually visible")
                    }
                    // Independent complete ROIs on this newly guarded frame;
                    // exact-current-pixel cache rules remain unchanged.
                    let ocrStarted = ProcessInfo.processInfo.systemUptime
                    if validated.continuousProof == nil {
                        let proof = try ocrRegions(fresh, identity: old.identity,
                            regions: [safetyRegion, controlled.1, header], measurePerformance: true)
                        recordOCRStages("submit_", proof.stageMS)
                        try denySensitiveRows(proof.regionRows[0], region: controlled.1)
                        let actualMessage = proof.regionRows[1].compactMap { $0["text"] as? String }.joined(separator: "\n")
                        guard visualNormalizedText(actualMessage) == visualNormalizedText(expectedMessage) else {
                            throw fail("submit_message_mismatch", "Complete fresh composer OCR does not exactly equal expected_message; no submit events were posted")
                        }
                        let titleRows = proof.regionRows[2]
                        guard titleRows.contains(where: { row in
                            (row["text"] as? String).map { visualNormalizedText($0) == visualNormalizedText(chatTitle) } ?? false
                        }) else { throw fail("submit_recipient_mismatch", "Expected chat_title was not exactly recognized in the right-side header; no submit events were posted") }
                    }
                    actionStageMS["submit_current_frame_OCR"] = (ProcessInfo.processInfo.systemUptime - ocrStarted) * 1000
                    let finalGuardStarted = ProcessInfo.processInfo.systemUptime
                    try guardUnchangedFocus(count)
                    try guardPoint(CGPoint(x: controlled.1.midX, y: controlled.1.midY), snapshot: old)
                    if validated.continuousProof != nil, try !currentContinuousSubmitSceneMatches(old, helper: helper) {
                        throw fail("visual_target_changed", "Current window scene changed before consuming the continuous native type proof")
                    }
                    actionStageMS["submit_final_focus_and_point"] = (ProcessInfo.processInfo.systemUptime - finalGuardStarted) * 1000
                }
                snapshot = nil
                try guardUnchangedFocus(count)
                if submit { submitPreinputMS = (ProcessInfo.processInfo.systemUptime - actionStarted) * 1000 }
                if let proof = validated.continuousProof { continuousProofFrameAgeMS = (ProcessInfo.processInfo.systemUptime - proof.frameTime) * 1000 }
                if submit { inputDispatchStarted = ProcessInfo.processInfo.systemUptime }
                try postKey(code, flags: commandOnly ? .maskCommand : [], helper: helper, target: target, count: &count)
                if submit { inputDispatchFinished = ProcessInfo.processInfo.systemUptime }
            } else {
                let point: CGPoint
                if command == "visual_click", controlled.0 == "navigation", request["x"] == nil {
                    let text = try string(request, "target_text")!
                    let timeout = try integer(request, "wait_timeout_ms", default: 0, range: 0...3000)
                    let deadline = ProcessInfo.processInfo.systemUptime + Double(timeout) / 1000
                    var lastSerial = -1
                    var selected: CGPoint?
                    repeat {
                        try guardUnchangedFocus(count)
                        let frame: VisualFrame
                        if lastSerial < 0 {
                            frame = guardFrame
                        } else {
                            guard let current = try waitFrame(helper: helper, target: target,
                                timeout: max(0.05, deadline - ProcessInfo.processInfo.systemUptime), after: lastSerial) else { break }
                            frame = current
                        }
                        lastSerial = frame.completeSerial; inputEvidenceFrame = frame
                        let rows = try ocr(frame, identity: old.identity, region: controlled.1)
                        if let point = try visualUniqueOCRPoint(rows, target: text, region: controlled.1) { selected = point; break }
                        if timeout == 0 || ProcessInfo.processInfo.systemUptime >= deadline { break }
                    } while true
                    guard let selected else { throw fail("visual_navigation_not_found", "No unique exact target_text OCR row appeared within the bounded wait") }
                    point = selected
                } else { point = try CGPoint(x: number(request, "x"), y: number(request, "y")) }
                guard pointIsInsideRect(point, controlled.1) else { throw fail("coordinate_outside_control", "Point must lie inside the confirmed control rectangle") }
                try guardPoint(point, snapshot: navigationSnapshot)
                if command == "visual_click" {
                    let sends = ["发送", "send"]
                    guard !(navigationSnapshot.rows + freshControlRows).contains(where: { row in
                        guard let text = row["text"] as? String, let bounds = try? visualRect(row["bounds"]),
                              pointIsInsideRect(point, bounds.insetBy(dx: -2, dy: -2)) else { return false }
                        return sends.contains { visualNormalizedText(text).lowercased().hasPrefix($0) }
                    }) else { throw fail("send_action_denied", "Visual fallback does not click Send controls in this unsent-draft workflow") }
                }
                if command == "visual_click", controlled.0 == "navigation", request["x"] != nil,
                   request["navigation_target_kind"] as? String != "icon" {
                    let expectedLabel = try string(request, "target_text")!
                    let currentRows = try ocr(guardFrame, identity: old.identity, region: controlled.1)
                    guard currentRows.contains(where: { row in
                        guard let text = row["text"] as? String, visualNormalizedText(text).contains(visualNormalizedText(expectedLabel)),
                              let bounds = try? visualRect(row["bounds"]) else { return false }
                        return pointIsInsideRect(point, bounds.insetBy(dx: -2, dy: -2))
                    }) else { throw fail("visual_navigation_unconfirmed", "Navigation point must match target_text in this snapshot's OCR bounds") }
                }
                var delta = 0
                if command == "visual_scroll" {
                    delta = try integer(request, "delta_y", default: 0, range: -100...100)
                    guard delta != 0, controlled.0 == "navigation" else { throw fail("invalid_request", "Scroll requires a navigation region and nonzero delta_y in -100...100") }
                }
                snapshot = nil
                try guardUnchangedFocus(count)
                if command == "visual_click" {
                    guard let down = CGEvent(mouseEventSource: helper.source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                          let up = CGEvent(mouseEventSource: helper.source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw fail("event_creation_failed", "Could not construct visual click") }
                    down.flags = []; up.flags = []
                    focusClickRevision = helper.monitor.interactionRevision
                    try helper.post(down, target: target); count += 1
                    up.setIntegerValueField(.eventSourceUserData, value: helper.monitor.marker); up.post(tap: .cghidEventTap); count += 1
                } else {
                    guard let wheel = visualScrollEvent(point: point, delta: Int32(delta), source: helper.source) else { throw fail("event_creation_failed", "Could not construct visual scroll") }
                    try helper.post(wheel, target: target); count += 1
                }
            }
            try helper.monitor.check()
            try helper.verify(target, focusedWindow: false)
            guard try selectedIdentity(target) == old.identity else { throw fail("visual_target_changed", "Target changed after visual events") }
            if command == "visual_click" {
                searchActivation = controlled.0 == "search" ? VisualSearchActivation(identity: old.identity, control: controlled.1) : nil
            } else if controlled.0 != "search" || requestedKey == "escape" { searchActivation = nil }
            let searchTransition: VisualSearchTransition? = controlled.0 == "search" &&
                (command == "visual_click" || command == "visual_type_text") && count > 0 ?
                VisualSearchTransition(activation: VisualSearchActivation(identity: old.identity, control: controlled.1),
                    windows: guardFrame.screenWindows, anchorRegions: old.anchorRegions,
                    baselineCoverage: guardFrame.capturedRegions) : nil
            var finalFrame: VisualFrame?
            var finalROIRows: [[String: Any]]?
            var finalPostEditProof: (serial: Int, headerRows: [[String: Any]], securityRows: [[String: Any]]?, rows: [[String: Any]])?
            let parallelComposerProof = command == "visual_type_text" && controlled.0 == "chat_composer" &&
                !replaceSearch && prefixPlan == nil && !clearingDraft && (request["chat_title"] as? String)?.isEmpty == false
            var verified = false
            if let expected {
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                var observedSerial = baselineSerial
                repeat {
                    // Prefix input has finished. Verification remains bounded
                    // and target-guarded, without expiring completed input.
                    if prefixPlan != nil { _ = try guardCurrentTargetFocus() }
                    else { try guardUnchangedFocus(count) }
                    let remaining = max(0.05, deadline - ProcessInfo.processInfo.systemUptime)
                    let postCaptureStarted = ProcessInfo.processInfo.systemUptime
                    if let frame = try waitFrame(helper: helper, target: target, timeout: remaining, after: observedSerial, searchTransition: searchTransition) {
                        actionStageMS["post_event_capture", default: 0] += (ProcessInfo.processInfo.systemUptime - postCaptureStarted) * 1000
                        observedSerial = frame.completeSerial
                        let postOCRStarted = ProcessInfo.processInfo.systemUptime
                        let postEditProof: (rows: [[String: Any]], regionRows: [[[String: Any]]], stageMS: [String: Double])?
                        if parallelComposerProof {
                            let window = old.identity.frame
                            let sendRegion = CGRect(x: window.minX + window.width * 0.70, y: window.minY + window.height * 0.85,
                                width: window.width * 0.30, height: window.height * 0.15)
                            // With a native operation binding, the short header
                            // shares a lane with Send; composer/security each
                            // keep their own complete ROI and worker lane.
                            let regions = nativeCommandScope != nil ?
                                [visualSubmitHeader(window), verificationRegion, safetyRegion, sendRegion] :
                                [verificationRegion, visualSubmitHeader(window), sendRegion]
                            postEditProof = try ocrRegions(frame, identity: old.identity, regions: regions, measurePerformance: true)
                            recordOCRStages("type_post_", postEditProof!.stageMS)
                        } else { postEditProof = nil }
                        let composerIndex = postEditProof?.regionRows.count == 4 ? 1 : 0
                        let rows = try postEditProof?.regionRows[composerIndex] ?? ocr(frame, identity: old.identity, region: verificationRegion)
                        if let proof = postEditProof, proof.regionRows.count == 4 {
                            try denySensitiveRows(proof.regionRows[2], region: controlled.1)
                        }
                        actionStageMS["post_event_OCR", default: 0] += (ProcessInfo.processInfo.systemUptime - postOCRStarted) * 1000
                        let completeText = rows.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        let textVerified: Bool
                        if clearingDraft {
                            let headerRows = try ocr(frame, identity: old.identity, region: visualSubmitHeader(old.identity.frame))
                            clearPostObservationCount += 1
                            clearPostDiagnostic = visualClearDraftPostDiagnostic(frame, window: old.identity.frame, control: controlled.1,
                                composerRows: rows, headerRows: headerRows, title: try string(request, "chat_title")!,
                                observationCount: clearPostObservationCount, now: ProcessInfo.processInfo.systemUptime)
                            textVerified = try visualClearDraftObservation(frame, window: old.identity.frame, control: controlled.1,
                                composerRows: rows, headerRows: headerRows, expected: "", title: try string(request, "chat_title")!,
                                now: ProcessInfo.processInfo.systemUptime)
                        } else {
                            let valueRows = prefixPlan == nil && controlled.0 == "chat_composer" ? visualRowsWithoutEmptyComposerHint(frame,
                                window: old.identity.frame, rows: rows, now: ProcessInfo.processInfo.systemUptime) : rows
                            textVerified = prefixPlan != nil ? visualPrefixFinalValueMatches(frame, window: old.identity.frame,
                                rows: rows, expected: expected, now: ProcessInfo.processInfo.systemUptime) :
                                (replaceSearch ? visualNormalizedText(completeText) == visualNormalizedText(expected) : matches(expected, rows: valueRows))
                        }
                        if textVerified {
                            if let postEditProof {
                                let complete = postEditProof.regionRows.count == 4
                                finalPostEditProof = (frame.completeSerial, postEditProof.regionRows[complete ? 0 : 1],
                                    complete ? postEditProof.regionRows[2] : nil, postEditProof.rows)
                            }
                            if prefixPlan != nil {
                                let header=visualSubmitHeader(old.identity.frame),title=try string(request,"chat_title")!
                                guard visualCovered(controlled.1,by:frame.capturedRegions ?? []),visualCovered(header,by:frame.capturedRegions ?? []) else{throw fail("prefix_postcondition_unverified","Complete composer and recipient must remain visible after prefix deletion")}
                                let titleRows=try ocr(frame,identity:old.identity,region:header)
                                guard titleRows.contains(where:{$0["text"] as? String == title}) else{throw fail("prefix_recipient_mismatch","Recipient changed during prefix deletion; do not replay")}
                                let currentIdentity = try guardCurrentTargetFocus()
                                guard visualPrefixEvidence(frame, identity: old.identity, currentIdentity: currentIdentity,
                                    control: controlled.1, rows: rows, headerRows: titleRows, expected: expected, title: title,
                                    allowReflow: true, after: prefixEvidence?.serial ?? guardFrame.completeSerial,
                                    now: ProcessInfo.processInfo.systemUptime) != nil else {
                                    throw fail("prefix_postcondition_unverified", "Final prefix observation requires new complete pixels, exact suffix and recipient within two seconds; do not replay")
                                }
                            }
                            finalFrame = frame; finalROIRows = rows; verified = true; break
                        }
                    }
                } while ProcessInfo.processInfo.systemUptime < deadline
                guard verified else { throw fail("postcondition_failed", clearingDraft ? "Clear events were posted but the complete fresh composer was not verified empty; do not replay" : (prefixPlan == nil ? "Unicode events were posted but new complete-frame local OCR did not contain the complete expected_text" : "Prefix deletion events were posted but complete fresh composer OCR did not equal the exact preserved suffix")) }
            } else { finalFrame = try waitFrame(helper: helper, target: target, timeout: 3, after: baselineSerial,
                searchTransition: searchTransition, navigationHintTransition: validated.navigationHintTransition) }
            guard let finalFrame else { throw fail("visual_frame_timeout", "No post-action frame") }
            if let transition = validated.navigationHintTransition {
                try verifyNavigationHintAnchors(old, frame: finalFrame, transition: transition)
            }
            let roiRows = try finalROIRows ?? ocr(finalFrame, identity: old.identity, region: verificationRegion)
            let next: VisualSnapshot
            let snapshotBindingStarted = ProcessInfo.processInfo.systemUptime
            if replaceSearch, verified, let expected {
                // The old chat header can now be covered by search results.
                // Confirm the new search state from the complete query and a
                // fresh spatially separate Send witness in this same image.
                let sendRegion = CGRect(x: old.identity.frame.minX + old.identity.frame.width * 0.70,
                    y: old.identity.frame.minY + old.identity.frame.height * 0.85,
                    width: old.identity.frame.width * 0.30, height: old.identity.frame.height * 0.15)
                let searchAnchors = [expected, "发送"]
                let searchRows = roiRows + (try ocr(finalFrame, identity: old.identity, region: sendRegion))
                guard visualAnchorsVerified(searchAnchors, rows: searchRows, confirmed: old.confirmed) else {
                    throw fail("visual_target_unconfirmed", "Complete query and a spatially separate Send witness were not both visible after search input")
                }
                next = try makeSnapshot(finalFrame, target: target, helper: helper, anchors: searchAnchors,
                    confirmed: old.confirmed, preparedRows: searchRows)
            } else {
                // The batch includes the complete header and Send witness.
                // Use its rows only if they also satisfy the existing spatial
                // continuation-anchor predicate; otherwise retain normal OCR.
                let preparedRows = finalPostEditProof.flatMap { proof -> [[String: Any]]? in
                    guard proof.serial == finalFrame.completeSerial,
                          preparedContinuationAnchorsVerified(old.anchors, regions: old.anchorRegions, rows: proof.rows) else { return nil }
                    return proof.rows
                }
                next = try makeSnapshot(finalFrame, target: target, helper: helper, anchors: old.anchors, confirmed: old.confirmed,
                    continuation: old, controlRegion: controlled.1, controlRows: roiRows, preparedRows: preparedRows)
            }
            actionStageMS["post_snapshot_binding"] = (ProcessInfo.processInfo.systemUptime - snapshotBindingStarted) * 1000
            if command == "visual_click", controlled.0 != "navigation" {
                selectedInput = (old.identity, controlled.0, controlled.1, next.focusedWindow)
                selectedInputRevision = focusClickRevision
            } else if controlled.0 == "navigation" || !CFEqual(old.focusedWindow, next.focusedWindow) {
                selectedInput = nil
            }
            var result = json(next, rows: Array(roiRows.prefix(100)))
            // The action already owns a new complete post-event frame. Read the
            // whole recipient from that frame, rather than forcing the bridge
            // to capture a second image merely to establish the business result.
            if verified, controlled.0 == "chat_composer", !submit,
               let title = request["chat_title"] as? String, !title.isEmpty {
                let proofStarted = ProcessInfo.processInfo.systemUptime
                let header = visualSubmitHeader(old.identity.frame)
                guard visualCovered(header, by: finalFrame.capturedRegions ?? []),
                      visualCovered(controlled.1, by: finalFrame.capturedRegions ?? []) else {
                    throw fail("edit_postcondition_unverified", "The complete recipient and composer are required after editing")
                }
                let titleRows = try (finalPostEditProof?.serial == finalFrame.completeSerial ? finalPostEditProof?.headerRows : nil) ??
                    ocr(finalFrame, identity: old.identity, region: header)
                guard titleRows.filter({ ($0["text"] as? String).map {
                    visualNormalizedText($0) == visualNormalizedText(title)
                } ?? false }).count == 1 else {
                    throw fail("edit_recipient_changed", "The whole recipient changed after editing; do not replay")
                }
                let proofRows = visualMergeOCRRows([roiRows, titleRows])
                try helper.monitor.check()
                try helper.verify(target, focusedWindow: false)
                let proofFocus = try focusedWindow(target, identity: old.identity, helper: helper)
                guard CFEqual(proofFocus.0, next.focusedWindow), proofFocus.1 == next.focusedFrame,
                      try selectedIdentity(target) == old.identity else {
                    throw fail("visual_target_changed", "Target or focused window changed during the post-edit proof")
                }
                result = json(next, rows: Array(proofRows.prefix(100)))
                result["ocr_scope"] = "post_action_recipient_and_complete_composer"
                result["ocr_regions"] = [header, controlled.1].map { rectJSON($0) }
                result["ocr_truncated"] = proofRows.count > 100
                result["edit_recipient_verified"] = true
                result["edit_recipient"] = title
                result["edit_proof_snapshot_id"] = next.id
                result["input_control_focus_retained"] = selectedInput.map {
                    $0.0 == old.identity && $0.1 == controlled.0 && $0.2 == controlled.1 &&
                        CFEqual($0.3, next.focusedWindow) && selectedInputRevision == helper.monitor.interactionRevision
                } ?? false
                let proofNow = ProcessInfo.processInfo.systemUptime
                if command == "visual_type_text", let scope = nativeCommandScope,
                   let prepared = finalPostEditProof, prepared.serial == finalFrame.completeSerial,
                   let securityRows = prepared.securityRows,
                   visualContinuousSubmitRowsComplete([roiRows, prepared.headerRows, securityRows]),
                   let finished = inputDispatchFinished, finalFrame.time >= finished,
                   finalFrame.completeTime >= finalFrame.time, finalFrame.completeTime <= proofNow,
                   proofNow - finalFrame.time <= 1, finalFrame.completeSerial > guardFrame.completeSerial,
                   finalFrame.searchOverlay == nil, finalFrame.searchQuery == nil,
                   visualCovered(safetyRegion, by: finalFrame.capturedRegions ?? []),
                   let revision = selectedInputRevision, revision == helper.monitor.interactionRevision,
                   result["input_control_focus_retained"] as? Bool == true,
                   let expected = request["expected_text"] as? String,
                   !visualNormalizedText(expected).isEmpty, title.count <= 128,
                   visualNormalizedText(roiRows.compactMap { $0["text"] as? String }.joined(separator: "\n")) == visualNormalizedText(expected) {
                    continuousSubmitProof = VisualContinuousSubmitProof(scope: scope, helperID: ObjectIdentifier(helper),
                        snapshotID: next.id, identity: old.identity, serial: finalFrame.completeSerial, frameTime: finalFrame.time,
                        inputFinishedAt: finished, verifiedAt: proofNow, control: controlled.1,
                        message: visualNormalizedText(expected), title: visualNormalizedText(title), revision: revision, securityVerified: true)
                }
                result["continuous_submit_proof_prepared"] = continuousSubmitProof != nil
                actionStageMS["post_complete_edit_proof"] = (ProcessInfo.processInfo.systemUptime - proofStarted) * 1000
            }
            result.removeValue(forKey: "anchor_matches")
            result["ocr_region"] = rectJSON(verificationRegion)
            if replaceSearch { result["value_ocr_region"] = rectJSON(verificationRegion) }
            if result["ocr_truncated"] == nil { result["ocr_truncated"] = roiRows.count > 100 }
            result["events_posted"] = count; result["action_accepted"] = count > 0
            if submit {
                result["submit_guard_frame_reused"] = submitGuardFrameReused
                result["continuous_submit_proof_reused"] = continuousSubmitReused
                result["continuous_submit_proof_frame_age_ms"] = continuousProofFrameAgeMS.map { $0 as Any } ?? NSNull()
                result["submit_preinput_ms"] = submitPreinputMS.map { $0 as Any } ?? NSNull()
                if let submitPreinputMS { result["native_stage_ms"] = ["submit_preinput": submitPreinputMS] }
            }
            result["value_verified"] = verified; result["verification_source"] = verified ? "new_complete_frame_visible_region_OCR" : "events_posted_only"
            if clearingDraft {
                result["draft_cleared"] = verified; result["expected_after"] = ""
                result["verification_source"] = "new_complete_frame_empty_composer_and_exact_recipient_OCR"
                result["clear_draft_postcondition"] = clearPostDiagnostic ?? ["observation_count": clearPostObservationCount]
            }
            if command == "visual_click", controlled.0 == "navigation" {
                result["navigation_target_kind"] = request["navigation_target_kind"] as? String ?? "text"
            }
            if let plan=prefixPlan {
                result["prefix_deleted"]=verified;result["expected_after"]=plan.suffix
                result["delete_events_posted"]=deleteEvents
                result["verification_source"]="new_complete_frame_preserved_suffix_OCR_ignoring_only_CR_LF_wrap"
                result["ocr_wrap_normalization"]="CR_LF_only_spaces_preserved"
                result["prefix_start_verified"]=true;result["forward_delete_semantics_verified"]=true
            }
            if replaceSearch {
                result["search_replaced"] = true
                result["verification_source"] = "new_complete_frame_exact_search_region_OCR"
            }
            result["automatic_replay_allowed"] = false
            result["verification_snapshot_id"] = next.id
            if submit {
                result["submit_events_posted"] = true; result["send_verified"] = false
                result["submit_preconditions_verified"] = true
            }
            // Diagnostic timestamps only: these never authorize reuse/input or
            // substitute a complete recipient/value/bubble proof.
            if let started = inputDispatchStarted, let finished = inputDispatchFinished {
                let observed = ProcessInfo.processInfo.systemUptime
                result["input_event_timing"] = ["clock": "system_uptime_ms",
                    "kind": submit ? "submit_return" : "unicode",
                    "dispatch_started_ms": started * 1000,
                    "dispatch_finished_ms": finished * 1000,
                    "complete_observation_ms": observed * 1000]
                var stages = result["native_stage_ms"] as? [String: Double] ?? [:]
                let prefix = submit ? "submit" : "type"
                stages[prefix + "_preinput"] = (started - actionStarted) * 1000
                stages[prefix + "_event_dispatch"] = (finished - started) * 1000
                stages[prefix + "_postinput"] = (observed - finished) * 1000
                result["native_stage_ms"] = stages
            }
            if !actionStageMS.isEmpty {
                var stages = result["native_stage_ms"] as? [String: Double] ?? [:]
                let prefix = submit ? "submit_" : (command == "visual_type_text" ? "type_" : "action_")
                for (key, value) in actionStageMS { stages[key.hasPrefix("submit_") || key.hasPrefix("type_") ? key : prefix + key] = value }
                result["native_stage_ms"] = stages
            }
            return result
        } catch {
            continuousSubmitProof = nil
            let underlying = error as? HelperError ?? fail("visual_operation_failed", error.localizedDescription)
            var details = underlying.details
            details["events_posted"] = count; details["input_may_be_partial"] = count > 0
            details["automatic_replay_allowed"] = false; details["value_verified"] = false
            if prefixPlan != nil {details["prefix_deleted"]=false;details["delete_events_posted"]=deleteEvents}
            if clearingDraft {
                details["draft_cleared"] = false
                details["clear_draft_postcondition"] = clearPostDiagnostic ?? ["observation_count": clearPostObservationCount]
            }
            if submit { details["submit_events_posted"] = count > 0; details["send_verified"] = false }
            if count > 0 { snapshot = nil; selectedInput = nil; searchActivation = nil }
            throw fail(underlying.code, underlying.message, details)
        }
    }

    func validate(_ request: [String: Any]) throws {
        let command = try string(request, "command")!
        let navigationTargetKind = try visualNavigationTargetKind(request)
        if ["visual_read", "background_visual_read"].contains(command) {
            _ = try anchors(request); _ = try boolean(request, "confirm_target")
            _ = try boolean(request, "include_image")
            if let mode = try string(request, "background_capture", required: false) {
                guard command == "background_visual_read", ["auto", "visible_screen", "exact_window"].contains(mode) else {
                    throw fail("invalid_request", "background_capture is auto, visible_screen or exact_window on background_visual_read only")
                }
            }
            _ = try integer(request, "max_text_rows", default: 100, range: 1...100)
            _ = try integer(request, "anchor_wait_timeout_ms", default: 3000, range: 0...3000)
            _ = try readRegions(request)
            if let path = try string(request, "debug_image_path", required: false) {
                guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else {
                    throw fail("invalid_request", "debug_image_path must be a new absolute filename")
                }
            }
            return
        }
        guard ["visual_click", "visual_type_text", "visual_key", "visual_scroll"].contains(command) else { throw fail("unknown_command", "Unknown visual command") }
        guard try string(request, "snapshot_id")!.count <= 128 else { throw fail("invalid_request", "snapshot_id is limited to 128 characters") }
        let kind = try string(request, "control_kind")!
        guard ["navigation", "search", "chat_composer"].contains(kind), try boolean(request, "confirm_control") else {
            throw fail("visual_control_unconfirmed", "A valid control_kind and confirm_control:true are required")
        }
        _ = try visualRect(request["control_rect"], name: "control_rect")
        _ = try integer(request, "max_age_ms", default: 5000, range: 1...5000)
        if command == "visual_type_text" {
            let replaceSearch = try boolean(request, "replace_search")
            guard !replaceSearch || kind == "search" else { throw fail("invalid_request", "replace_search:true is only allowed for a previously clicked search control") }
            let text = try string(request, "text")!; let expected = try string(request, "expected_text")!
            guard !replaceSearch || text == expected else { throw fail("invalid_request", "replace_search:true requires text equal to the complete expected_text query") }
            guard kind != "navigation", text.count <= 4096, expected.count <= 4096, expected.contains(text),
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }),
                  !expected.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
                throw fail("invalid_request", "Visual typing requires a confirmed search/composer and single-line text/expected_text <=4096 with expected_text containing text")
            }
        }
        if command == "visual_key" {
            let key = try string(request, "key")!.lowercased()
            let modifiers: [String]
            if let raw = request["modifiers"] {
                guard let array = raw as? [String], array.count <= 1 else { throw fail("invalid_request", "Visual modifiers must be zero or one strings") }
                modifiers = array
            } else { modifiers = [] }
            let commandOnly = modifiers.count == 1 && ["cmd", "command"].contains(modifiers[0].lowercased())
            _ = try boolean(request, "allow_submit")
            let submit = ["return", "enter"].contains(key)
            if key == "clear_draft" {
                guard kind == "chat_composer", modifiers.isEmpty, !(try boolean(request, "allow_submit")), request["prefix"] == nil,
                      let draft = try string(request, "expected_draft"), draft.utf16.count <= 8192,
                      let title = try string(request, "chat_title"), title.count <= 128,
                      !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
                    throw fail("invalid_request", "clear_draft requires an exact nonempty draft, chat_title, confirmed composer, no modifiers/prefix and allow_submit:false")
                }
            }
            if key == "clear_prefix" {
                guard kind == "chat_composer",modifiers.isEmpty,!(try boolean(request,"allow_submit")),
                      let title=try string(request,"chat_title"),!title.isEmpty,title.count<=128,
                      !title.unicodeScalars.contains(where:{CharacterSet.controlCharacters.union(.newlines).contains($0)}) else{throw fail("invalid_request","clear_prefix requires a confirmed composer, no modifiers, allow_submit:false and exact chat_title")}
                _ = try visualPrefixDeletion(string(request,"expected_draft")!,prefix:string(request,"prefix")!)
            }
            if submit {
                // These are UI preconditions, not message authorization. The caller
                // still needs current-user permission for this exact content/recipient.
                guard kind == "chat_composer", modifiers.isEmpty, try boolean(request, "allow_submit"),
                      let message = try string(request, "expected_message"), message.count <= 4096,
                      !visualNormalizedText(message).isEmpty,
                      let title = try string(request, "chat_title"), title.count <= 128,
                      !visualNormalizedText(title).isEmpty,
                      !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
                    throw fail("unsupported_visual_key", "Submit requires composer, plain Return, allow_submit:true, expected_message and chat_title")
                }
            }
            guard kind != "navigation", key == "clear_prefix" || key == "clear_draft" || submit || (modifiers.isEmpty && ["escape", "backspace", "delete", "left", "right", "up", "down", "home", "end", "tab"].contains(key)) ||
                  (commandOnly && ["a", "f"].contains(key)) else { throw fail("unsupported_visual_key", "Return/Send and unlisted visual shortcuts are denied") }
        }
        if command == "visual_click" {
            guard (request["x"] == nil) == (request["y"] == nil) else { throw fail("invalid_request", "Provide both x and y, or omit both for exact navigation OCR") }
            if request["x"] != nil { _ = try number(request, "x"); _ = try number(request, "y") }
            else { guard kind == "navigation" else { throw fail("invalid_request", "Search/composer clicks require x and y") } }
            _ = try integer(request, "wait_timeout_ms", default: 0, range: 0...3000)
        }
        if command == "visual_scroll" { _ = try number(request, "x"); _ = try number(request, "y") }
        if command == "visual_click" && kind == "navigation" && navigationTargetKind == "text" {
            guard try string(request, "target_text")!.count <= 1024 else { throw fail("invalid_request", "target_text is limited to 1024 characters") }
        }
        if command == "visual_scroll" {
            let delta = try integer(request, "delta_y", default: 0, range: -100...100)
            guard kind == "navigation", delta != 0 else { throw fail("invalid_request", "Scroll requires navigation control and nonzero delta_y") }
        }
    }
}

func visualSelfTests() -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ condition: Bool) { cases.append(["name": name, "passed": condition]) }
    let rect = CGRect(x: -1200, y: -900, width: 932, height: 1079)
    check("negative_display_coordinate_containment", visualContains(rect, CGRect(x: -1100, y: -800, width: 300, height: 200)))
    check("outside_region_denied", !visualContains(rect, CGRect(x: -1300, y: -800, width: 300, height: 200)))
    let mapped = visualOCRBounds(CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.1), region: rect)
    check("OCR_bottom_left_to_Quartz_top_left", abs(mapped.minX - (rect.minX + rect.width * 0.25)) < 0.001 && abs(mapped.minY - (rect.minY + rect.height * 0.15)) < 0.001)
    check("OCR_scale_is_not_applied_twice", mapped.width == rect.width * 0.5)
    let a = VisualIdentity(pid: 1, windowID: 2, frame: rect, topology: "one")
    check("PID_change_invalidates_identity", a != VisualIdentity(pid: 3, windowID: 2, frame: rect, topology: "one"))
    check("window_change_invalidates_identity", a != VisualIdentity(pid: 1, windowID: 3, frame: rect, topology: "one"))
    check("geometry_change_invalidates_identity", a != VisualIdentity(pid: 1, windowID: 2, frame: rect.offsetBy(dx: 1, dy: 0), topology: "one"))
    check("topology_change_invalidates_identity", a != VisualIdentity(pid: 1, windowID: 2, frame: rect, topology: "two"))
    check("OCR_only_whitespace_and_invisible_normalization", visualNormalizedText("中文 ABC\u{200b} 123") == "中文ABC123")
    check("OCR_does_not_fuzz_width_or_punctuation", visualNormalizedText("ＡＢＣ：") != "ABC:")
    let first = UUID().uuidString; let second = UUID().uuidString
    check("opaque_snapshot_ids_are_distinct", first != second)
    let visual = VisualDesktop()
    let icon: [String: Any] = ["command": "visual_click", "snapshot_id": "fresh-bound-fixture",
        "control_kind": "navigation", "navigation_target_kind": "icon", "confirm_control": true,
        "control_rect": rectJSON(CGRect(x: 850, y: 50, width: 40, height: 35)), "x": 870, "y": 68]
    func validates(_ request: [String: Any]) -> Bool { do { try visual.validate(request); return true } catch { return false } }
    check("explicit_model_confirmed_icon_without_OCR_text_accepted", validates(icon))
    for key in ["x", "y", "snapshot_id", "confirm_control", "control_rect"] {
        var missing = icon; missing.removeValue(forKey: key)
        check("icon_missing_" + key + "_denied", !validates(missing))
    }
    for (name, delta) in [
        ("point_outside", ["x": 890]), ("nonfinite_point", ["x": Double.nan]),
        ("boolean_point", ["x": true]), ("unconfirmed", ["confirm_control": false]),
        ("text_conflict", ["target_text": "标签"]), ("empty_text_conflict", ["target_text": ""]),
        ("search_control", ["control_kind": "search"]), ("composer_control", ["control_kind": "chat_composer"]),
        ("typing_command", ["command": "visual_type_text"]), ("key_command", ["command": "visual_key"]),
        ("scroll_command", ["command": "visual_scroll"]), ("unknown_kind", ["navigation_target_kind": "anything"]),
        ("expired_TTL", ["max_age_ms": 5001])
    ] as [(String, [String: Any])] {
        check("icon_" + name + "_denied", !validates(icon.merging(delta) { _, value in value }))
    }
    var textNav = icon; textNav.removeValue(forKey: "navigation_target_kind")
    check("default_text_navigation_still_needs_OCR_label", !validates(textNav))
    textNav["target_text"] = "群详情"
    check("existing_explicit_point_text_navigation_accepted", validates(textNav))
    textNav.removeValue(forKey: "x"); textNav.removeValue(forKey: "y")
    check("existing_unique_OCR_navigation_accepted", validates(textNav))
    check("icon_validation_has_no_capture", visual.stream == nil && visual.streams.isEmpty)
    let diagnosticImage = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let diagnosticWindow = CGRect(x: 50, y: 41, width: 855, height: 1079)
    var baseline = VisualFrame(image: diagnosticImage, completeSerial: 1, time: 10, completeTime: 10.1,
        idleConfirmed: false, capturedRegions: [diagnosticWindow],
        searchOverlay: VisualSearchOverlay(windowID: 35609, frame: CGRect(x: 98, y: 76, width: 368, height: 172)),
        searchQuery: "PRIVATE_QUERY_SENTINEL")
    func difference(_ after: VisualFrame) -> [String: Any] {
        visualSnapshotVisibilityDiagnostic(baseline, after, now: 11)
    }
    func equal(_ after: VisualFrame, _ key: String) -> Bool {
        (difference(after)["equal"] as? [String: Bool])?[key] == true
    }
    check("visibility_diagnostic_unchanged_predicates_equal", (difference(baseline)["equal"] as? [String: Bool])?.values.allSatisfy { $0 } == true)
    var revised = baseline
    revised.capturedRegions = [CGRect(x: 50, y: 41, width: 400, height: 1079), CGRect(x: 450, y: 41, width: 455, height: 1079)]
    check("visibility_diagnostic_distinguishes_partition_from_union", !equal(revised, "captured_regions") && equal(revised, "captured_region_union"))
    revised.capturedRegions = [CGRect(x: 51, y: 41, width: 854, height: 1079)]
    check("visibility_diagnostic_reports_actual_coverage_loss", !equal(revised, "captured_region_union"))
    revised = baseline; revised.capturedRegions = nil
    check("visibility_diagnostic_preserves_unknown_coverage", !equal(revised, "captured_regions") && !equal(revised, "captured_region_union") &&
        (difference(revised)["after_captured_regions"] as? [String: Any])?["present"] as? Bool == false)
    revised = baseline; revised.searchQuery = "OTHER_PRIVATE_QUERY_SENTINEL"
    check("visibility_diagnostic_reports_query_change_without_popup_change", !equal(revised, "search_query") && equal(revised, "search_overlay"))
    revised = baseline; revised.searchQuery = ""
    check("visibility_diagnostic_preserves_bound_empty_query", difference(revised)["after_query_present"] as? Bool == true && difference(revised)["after_query_nonempty"] as? Bool == false)
    revised.searchQuery = nil
    check("visibility_diagnostic_distinguishes_missing_from_empty_query", difference(revised)["after_query_present"] as? Bool == false)
    revised = baseline; revised.searchOverlay = VisualSearchOverlay(windowID: 35610, frame: baseline.searchOverlay!.frame)
    check("visibility_diagnostic_reports_popup_identity_change", !equal(revised, "search_overlay") && equal(revised, "search_query"))
    let hint = CGRect(x: 351, y: 964, width: 84, height: 77)
    revised = baseline; revised.screenWindows = [VisualScreenWindow(id: 33787, pid: 60682, frame: hint, layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)]
    revised.inputSourceHints = [hint]; revised.excludedInputRegions = [CGRect(x: 378, y: 991, width: 30, height: 23)]
    check("visibility_diagnostic_separates_hint_mask_and_CG_changes", !equal(revised, "screen_windows") && !equal(revised, "input_source_hints") && !equal(revised, "excluded_input_regions"))
    revised.captureAuxiliaryFrames = [hint]
    check("visibility_diagnostic_reports_auxiliary_union", !equal(revised, "capture_auxiliary_frames"))
    check("visibility_diagnostic_age_uses_supplied_uptime", difference(revised)["before_frame_age_ms"] as? Double == 1000)
    baseline.coverageDiagnostics = [["private": "PRIVATE_COVERAGE_SENTINEL"]]
    baseline.captureEvidence = ["private": "PRIVATE_CAPTURE_SENTINEL"]
    revised.searchQuery = "OTHER_PRIVATE_QUERY_SENTINEL"
    let diagnosticData = try? JSONSerialization.data(withJSONObject: difference(revised), options: [.sortedKeys])
    let diagnosticText = diagnosticData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check("visibility_diagnostic_JSON_has_no_query_or_capture_contents", diagnosticData != nil && !diagnosticText.contains("PRIVATE") && !diagnosticText.contains("image"))
    revised.capturedRegions = (0..<80).map { CGRect(x: $0, y: 0, width: 1, height: 1) }
    revised.screenWindows = (1...80).map { VisualScreenWindow(id: UInt32($0), pid: 60682, frame: hint, layer: 3, alpha: 1, emptyTitle: true, dockSurface: false) }
    let bounded = difference(revised)
    let boundedRegions = bounded["after_captured_regions"] as? [String: Any]
    let boundedWindows = bounded["windows"] as? [String: Any]
    check("visibility_diagnostic_region_list_is_bounded", boundedRegions?["count"] as? Int == 80 && (boundedRegions?["rects"] as? [[String: Double]])?.count == 32 && boundedRegions?["truncated"] as? Bool == true)
    check("visibility_diagnostic_window_list_is_bounded", boundedWindows?["window_changes_count"] as? Int == 80 && (boundedWindows?["window_changes"] as? [[String: Any]])?.count == 16 && (boundedWindows?["after_window_order"] as? [CGWindowID])?.count == 64)
    let navIdentity = VisualIdentity(pid: 60682, windowID: 33789, frame: diagnosticWindow, topology: "navigation-fixture")
    let corner = CGRect(x: 56, y: 46, width: 52, height: 20)
    let navControl = CGRect(x: 173, y: 135, width: 116, height: 26)
    let navAnchors = [CGRect(x: 141, y: 56, width: 156, height: 20), CGRect(x: 700, y: 1060, width: 100, height: 25)]
    let appRef = AXUIElementCreateApplication(1) // Object construction only; never queried.
    let clean = VisualFrame(image: diagnosticImage, completeSerial: 1, time: 10, completeTime: 10.1,
        idleConfirmed: false, capturedRegions: [diagnosticWindow], searchOverlay: baseline.searchOverlay, searchQuery: "bound query")
    let nav = VisualSnapshot(id: "original", identity: navIdentity, frame: clean, created: 9.5,
        focusedWindow: appRef, focusedFrame: diagnosticWindow, focusedTitle: "微信", rows: [],
        anchors: ["bound query", "发送"], confirmed: true, confirmationSource: "fixture", anchorRegions: navAnchors)
    var masked = VisualFrame(image: diagnosticImage, completeSerial: 2, time: 10.5, completeTime: 10.6,
        idleConfirmed: false, capturedRegions: visualSubtract(diagnosticWindow, corner),
        searchOverlay: clean.searchOverlay, searchQuery: clean.searchQuery, excludedInputRegions: [corner])
    let auxiliary = VisualScreenWindow(id: 35807, pid: 60682, frame: corner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    masked.captureEvidence = ["additional_own_auxiliary_exclusions": visualAuxiliaryExclusionMetadata([auxiliary])]
    let navRequest: [String: Any] = ["command": "visual_click", "control_kind": "navigation", "confirm_control": true,
        "control_rect": rectJSON(navControl), "target_text": "目标"]
    func acceptsCorner(_ after: VisualFrame, _ request: [String: Any]? = nil) -> Bool {
        visualTextNavigationCornerMaskChange(request ?? navRequest, snapshot: nav, after: after)
    }
    check("actual_corner_addition_allows_only_fresh_text_navigation", acceptsCorner(masked))
    let oldMasked = visualReboundNavigationSnapshot(nav, frame: masked, rows: [])
    var unmasked = clean
    unmasked = VisualFrame(image: clean.image, completeSerial: 3, time: 10.7, completeTime: 10.8,
        idleConfirmed: false, capturedRegions: clean.capturedRegions, searchOverlay: clean.searchOverlay, searchQuery: clean.searchQuery)
    check("proved_corner_removal_uses_old_owner_and_fresh_coverage", visualTextNavigationCornerMaskChange(navRequest, snapshot: oldMasked, after: unmasked))
    for (name, delta) in [("typing", ["command": "visual_type_text"]), ("key", ["command": "visual_key"]),
        ("scroll", ["command": "visual_scroll"]), ("icon", ["navigation_target_kind": "icon"]),
        ("search", ["control_kind": "search"]), ("composer", ["control_kind": "chat_composer"]),
        ("unconfirmed", ["confirm_control": false]), ("point_outside_control", ["x": 56, "y": 46])
    ] as [(String, [String: Any])] {
        check("corner_exception_denies_" + name, !acceptsCorner(masked, navRequest.merging(delta) { _, v in v }))
    }
    var wrong = masked; wrong.captureEvidence = nil
    check("corner_rect_without_owner_proof_is_denied", !acceptsCorner(wrong))
    wrong.captureEvidence = ["additional_own_auxiliary_exclusions": visualAuxiliaryExclusionMetadata([
        VisualScreenWindow(id: 35807, pid: 99, frame: corner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)])]
    check("foreign_corner_source_is_denied", !acceptsCorner(wrong))
    wrong = masked; wrong.captureEvidence = ["additional_own_auxiliary_exclusions": visualAuxiliaryExclusionMetadata([
        VisualScreenWindow(id: 35807, pid: 60682, frame: corner, layer: 3, alpha: 1, emptyTitle: false, dockSurface: false)])]
    check("wrong_layer_corner_source_is_denied", !acceptsCorner(wrong))
    wrong = masked; wrong.excludedInputRegions += [CGRect(x: 800, y: 800, width: 10, height: 10)]
    check("corner_change_with_other_exclusion_is_denied", !acceptsCorner(wrong))
    wrong = masked; wrong.capturedRegions = (masked.capturedRegions ?? []).flatMap { visualSubtract($0, CGRect(x: 500, y: 500, width: 10, height: 10)) }
    check("corner_change_with_other_coverage_loss_is_denied", !acceptsCorner(wrong))
    wrong = masked; wrong.capturedRegions = [diagnosticWindow]
    check("corner_exclusion_must_actually_mask_pixels", !acceptsCorner(wrong))
    wrong = masked; wrong.searchQuery = "changed"
    check("corner_change_cannot_hide_query_change", !acceptsCorner(wrong))
    wrong = masked; wrong.screenWindows = [auxiliary]
    check("corner_exception_does_not_accept_CG_scene_change", !acceptsCorner(wrong))
    let blockedAnchor = VisualSnapshot(id: nav.id, identity: nav.identity, frame: nav.frame, created: nav.created,
        focusedWindow: appRef, focusedFrame: nav.focusedFrame, focusedTitle: nav.focusedTitle, rows: [],
        anchors: nav.anchors, confirmed: true, confirmationSource: "fixture", anchorRegions: [corner])
    check("corner_over_bound_anchor_is_denied", !visualTextNavigationCornerMaskChange(navRequest, snapshot: blockedAnchor, after: masked))
    check("corner_over_full_control_is_denied", !acceptsCorner(masked, navRequest.merging(["control_rect": rectJSON(corner)]) { _, v in v }))
    // Actual failure shape: a same-PID 52x20 window moves from the capture's
    // additional-exclusion evidence into the next CG baseline; coverage is identical.
    let migrationScene = [
        VisualScreenWindow(id: 46, pid: 864, frame: CGRect(x: 0, y: 0, width: 1792, height: 1120), layer: 23, alpha: 1, emptyTitle: true, dockSurface: false),
        VisualScreenWindow(id: 23, pid: 766, frame: CGRect(x: 0, y: 0, width: 1792, height: 1120), layer: 20, alpha: 1, emptyTitle: false, dockSurface: true)]
    var migrating = masked; migrating.screenWindows = migrationScene
    let migrationSnapshot = visualReboundNavigationSnapshot(nav, frame: migrating, rows: [])
    var promoted = unmasked; promoted.capturedRegions = migrating.capturedRegions
    promoted.screenWindows = migrationScene + [auxiliary]
    let migrationScroll = navRequest.merging(["command": "visual_scroll", "x": navControl.midX,
        "y": navControl.midY, "delta_y": 100]) { _, value in value }
    func acceptsMigration(_ frame: VisualFrame, request: [String: Any]? = nil, snapshot: VisualSnapshot? = nil) -> Bool {
        visualNavigationCornerExclusionMigration(request ?? migrationScroll, snapshot: snapshot ?? migrationSnapshot, after: frame)
    }
    check("actual_corner_exclusion_to_CG_baseline_allows_navigation_scroll", acceptsMigration(promoted))
    check("actual_corner_exclusion_to_CG_baseline_allows_text_click", acceptsMigration(promoted, request: navRequest))
    // Actual pre-type failure: the same eight rectangles are emitted in a
    // different order as the owned corner moves into the baseline CG list.
    let permutationWindow = CGRect(x: 356, y: 25, width: 855, height: 1079)
    let permutationIdentity = VisualIdentity(pid: 60682, windowID: 33789, frame: permutationWindow, topology: "fixture")
    let permutationCorner = CGRect(x: 362, y: 30, width: 52, height: 20)
    let permutationAuxiliary = VisualScreenWindow(id: 47457, pid: 60682, frame: permutationCorner,
        layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    let permutationPopup = VisualSearchOverlay(windowID: 47456, frame: CGRect(x: 404, y: 60, width: 368, height: 170))
    let permutationRegions = [CGRect(x: 356, y: 25, width: 855, height: 5), CGRect(x: 356, y: 50, width: 855, height: 10),
        CGRect(x: 356, y: 30, width: 6, height: 20), CGRect(x: 414, y: 30, width: 797, height: 20),
        CGRect(x: 356, y: 230, width: 855, height: 874), CGRect(x: 356, y: 60, width: 48, height: 170),
        CGRect(x: 772, y: 60, width: 439, height: 170), permutationPopup.frame]
    let permutationScene = [VisualScreenWindow(id: 23, pid: 766, frame: CGRect(x: 0, y: 0, width: 1792, height: 1120),
        layer: 20, alpha: 1, emptyTitle: false, dockSurface: true),
        VisualScreenWindow(id: permutationPopup.windowID, pid: 60682, frame: permutationPopup.frame,
            layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)]
    let permutationBefore = VisualFrame(image: diagnosticImage, completeSerial: 1, time: 10, completeTime: 10.1,
        idleConfirmed: false, capturedRegions: permutationRegions, searchOverlay: permutationPopup, searchQuery: "",
        screenWindows: permutationScene, excludedInputRegions: [permutationCorner],
        captureEvidence: ["additional_own_auxiliary_exclusions": visualAuxiliaryExclusionMetadata([permutationAuxiliary])])
    let permutationSnapshot = VisualSnapshot(id: "permutation", identity: permutationIdentity, frame: permutationBefore, created: 10.1,
        focusedWindow: appRef, focusedFrame: permutationWindow, focusedTitle: "fixture", rows: [],
        anchors: ["search", "send"], confirmed: true, confirmationSource: "fixture",
        anchorRegions: [CGRect(x: 423.84, y: 38.35, width: 66.3, height: 29.8), CGRect(x: 1139, y: 1056, width: 48, height: 29)])
    let permutationControl = CGRect(x: 426, y: 40.106, width: 210, height: 26.975)
    let permutationRequest: [String: Any] = ["command": "visual_type_text", "control_kind": "search",
        "confirm_control": true, "control_rect": rectJSON(permutationControl)]
    let permutationAfter = VisualFrame(image: diagnosticImage, completeSerial: 2, time: 10.2, completeTime: 10.3,
        idleConfirmed: false, capturedRegions: [0, 1, 4, 5, 6, 2, 3, 7].map { permutationRegions[$0] },
        searchOverlay: permutationPopup, searchQuery: "", screenWindows: permutationScene + [permutationAuxiliary])
    func acceptsPermutation(_ frame: VisualFrame) -> Bool {
        visualNavigationCornerExclusionMigration(permutationRequest, snapshot: permutationSnapshot, after: frame)
    }
    check("actual_eight_region_permutation_allows_owned_corner_migration", acceptsPermutation(permutationAfter))
    var damagedPermutation = permutationAfter; damagedPermutation.capturedRegions?.removeFirst()
    check("permutation_migration_rejects_missing_coverage", !acceptsPermutation(damagedPermutation))
    damagedPermutation = permutationAfter; damagedPermutation.capturedRegions?.append(permutationCorner)
    check("permutation_migration_rejects_new_corner_pixels", !acceptsPermutation(damagedPermutation))
    damagedPermutation = permutationAfter; damagedPermutation.capturedRegions = permutationRegions.flatMap { visualSubtract($0, permutationControl) }
    check("permutation_migration_rejects_missing_control_pixels", !acceptsPermutation(damagedPermutation))
    damagedPermutation = permutationAfter; damagedPermutation.capturedRegions = Array(repeating: permutationRegions, count: 5).flatMap { $0 }
    check("permutation_migration_bounds_equivalent_coverage_arrays", !acceptsPermutation(damagedPermutation))
    check("migration_does_not_require_absent_additional_owner_row", !visualCornerExclusionHasOwnerProof(promoted, identity: navIdentity, corner: corner) && acceptsMigration(promoted))
    var lateAgain = migrating
    lateAgain = VisualFrame(image: migrating.image, completeSerial: 4, time: 10.9, completeTime: 11, idleConfirmed: false,
        capturedRegions: migrating.capturedRegions, searchOverlay: migrating.searchOverlay, searchQuery: migrating.searchQuery,
        screenWindows: migrating.screenWindows, excludedInputRegions: migrating.excludedInputRegions, captureEvidence: migrating.captureEvidence)
    check("same_corner_identity_can_return_to_late_exclusion", acceptsMigration(lateAgain,
        snapshot: visualReboundNavigationSnapshot(nav, frame: promoted, rows: [])))
    var changedMigration = promoted
    changedMigration.screenWindows = migrationScene + [VisualScreenWindow(id: 999, pid: auxiliary.pid, frame: corner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)]
    check("same_geometry_different_corner_window_ID_denied", !acceptsMigration(changedMigration))
    for (name, changed) in [
        ("foreign_PID", VisualScreenWindow(id: auxiliary.id, pid: 99, frame: corner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)),
        ("wrong_layer", VisualScreenWindow(id: auxiliary.id, pid: auxiliary.pid, frame: corner, layer: 3, alpha: 1, emptyTitle: false, dockSurface: false)),
        ("transparent", VisualScreenWindow(id: auxiliary.id, pid: auxiliary.pid, frame: corner, layer: 0, alpha: 0.5, emptyTitle: false, dockSurface: false)),
        ("empty_title", VisualScreenWindow(id: auxiliary.id, pid: auxiliary.pid, frame: corner, layer: 0, alpha: 1, emptyTitle: true, dockSurface: false)),
        ("system_surface", VisualScreenWindow(id: auxiliary.id, pid: auxiliary.pid, frame: corner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: true)),
        ("moved", VisualScreenWindow(id: auxiliary.id, pid: auxiliary.pid, frame: corner.offsetBy(dx: 1, dy: 0), layer: 0, alpha: 1, emptyTitle: false, dockSurface: false))] {
        changedMigration = promoted; changedMigration.screenWindows = migrationScene + [changed]
        check("corner_migration_denies_" + name, !acceptsMigration(changedMigration))
    }
    changedMigration = promoted; changedMigration.screenWindows = Array(migrationScene.reversed()) + [auxiliary]
    check("corner_migration_preserves_other_window_order", !acceptsMigration(changedMigration))
    changedMigration = promoted; changedMigration.screenWindows.append(auxiliary)
    check("corner_migration_denies_duplicate_ID", !acceptsMigration(changedMigration))
    changedMigration = promoted; changedMigration.capturedRegions = [diagnosticWindow]
    check("corner_migration_cannot_authorize_auxiliary_pixels", !acceptsMigration(changedMigration))
    changedMigration = promoted; changedMigration.capturedRegions = []
    check("corner_migration_cannot_hide_system_panel_coverage_loss", !acceptsMigration(changedMigration))
    changedMigration = promoted; changedMigration.searchQuery = "changed"
    check("corner_migration_preserves_exact_search_query", !acceptsMigration(changedMigration))
    changedMigration = promoted; changedMigration.excludedInputRegions.append(CGRect(x: 700, y: 800, width: 10, height: 10))
    check("corner_migration_denies_other_exclusion_change", !acceptsMigration(changedMigration))
    var unprovedMigration = migrating; unprovedMigration.captureEvidence = nil
    check("corner_migration_requires_original_owned_ID_metadata", !acceptsMigration(promoted,
        snapshot: visualReboundNavigationSnapshot(nav, frame: unprovedMigration, rows: [])))
    var readOnlyMigration = migrationSnapshot; readOnlyMigration.readOnlyBackground = true
    check("corner_migration_never_authorizes_background_snapshot", !acceptsMigration(promoted, snapshot: readOnlyMigration))
    check("corner_migration_never_authorizes_corner_input", !acceptsMigration(promoted,
        request: migrationScroll.merging(["control_rect": rectJSON(corner), "x": corner.midX, "y": corner.midY]) { _, value in value }))
    check("corner_migration_requires_scroll_point", !acceptsMigration(promoted,
        request: navRequest.merging(["command": "visual_scroll"]) { _, value in value }))
    for command in ["visual_type_text", "visual_key"] {
        check("corner_migration_does_not_expand_" + command, !acceptsMigration(promoted,
            request: migrationScroll.merging(["command": command]) { _, value in value }))
    }
    // Consumer /new preinput failure: identical corner ID enters the CG baseline
    // from additional exclusions. Count 1->2 alone does not authorize this route.
    let migratedComposer = CGRect(x: navIdentity.frame.minX + 330, y: navIdentity.frame.maxY - 162,
        width: 495, height: 113.295)
    let migratedAnchors = [CGRect(x: navIdentity.frame.minX + 350, y: navIdentity.frame.minY + 10, width: 160, height: 26),
        CGRect(x: navIdentity.frame.maxX - 105, y: navIdentity.frame.maxY - 44, width: 80, height: 25)]
    var migrationEditSnapshot = migrationSnapshot; migrationEditSnapshot.anchorRegions = migratedAnchors
    let migrationEdit: [String: Any] = ["command": "visual_type_text", "control_kind": "chat_composer",
        "confirm_control": true, "control_rect": rectJSON(migratedComposer)]
    check("consumer_corner_migration_allows_complete_composer_preinput", acceptsMigration(promoted,
        request: migrationEdit, snapshot: migrationEditSnapshot))
    let migrationSearch = CGRect(x: navIdentity.frame.minX + 70, y: navIdentity.frame.minY + 15, width: 210, height: 27)
    check("consumer_corner_migration_allows_complete_search_preinput", acceptsMigration(promoted,
        request: migrationEdit.merging(["control_kind": "search", "control_rect": rectJSON(migrationSearch)]) { _, v in v }, snapshot: migrationEditSnapshot))
    check("consumer_corner_migration_allows_owned_draft_clear_proof", acceptsMigration(promoted,
        request: migrationEdit.merging(["command": "visual_key", "key": "clear_draft"]) { _, v in v }, snapshot: migrationEditSnapshot))
    check("consumer_corner_migration_does_not_grant_submit", !acceptsMigration(promoted,
        request: migrationEdit.merging(["command": "visual_key", "key": "return"]) { _, v in v }, snapshot: migrationEditSnapshot))
    var incompleteEditAnchors = migrationEditSnapshot; incompleteEditAnchors.anchorRegions = [migratedAnchors[0]]
    check("consumer_edit_migration_requires_two_full_anchor_regions", !acceptsMigration(promoted,
        request: migrationEdit, snapshot: incompleteEditAnchors))
    check("consumer_edit_migration_rejects_corner_control", !acceptsMigration(promoted,
        request: migrationEdit.merging(["control_rect": rectJSON(corner)]) { _, v in v }, snapshot: migrationEditSnapshot))
    var partialEdit = promoted; partialEdit.capturedRegions = (promoted.capturedRegions ?? []).flatMap { visualSubtract($0, migratedComposer) }
    check("consumer_edit_migration_rejects_partial_composer", !acceptsMigration(partialEdit,
        request: migrationEdit, snapshot: migrationEditSnapshot))
    var unknownOwnerFrame = migrating; unknownOwnerFrame.captureEvidence = nil
    var unknownEditOwner = visualReboundNavigationSnapshot(migrationEditSnapshot, frame: unknownOwnerFrame, rows: [])
    unknownEditOwner.anchorRegions = migratedAnchors
    check("consumer_edit_migration_requires_original_owned_ID", !acceptsMigration(promoted,
        request: migrationEdit, snapshot: unknownEditOwner))
    var differentEditID = promoted; differentEditID.screenWindows = migrationScene + [VisualScreenWindow(id: 999,
        pid: auxiliary.pid, frame: corner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)]
    check("consumer_edit_migration_rejects_different_ID", !acceptsMigration(differentEditID,
        request: migrationEdit, snapshot: migrationEditSnapshot))
    check("submit_reuses_new_same_RPC_complete_frame", visualSubmitGuardFrameReusable(promoted,
        snapshot: migrationEditSnapshot, control: migratedComposer, now: promoted.completeTime + 0.1))
    check("submit_rejects_aged_guard_frame", !visualSubmitGuardFrameReusable(promoted,
        snapshot: migrationEditSnapshot, control: migratedComposer, now: promoted.time + 1.001))
    check("submit_rejects_future_guard_frame", !visualSubmitGuardFrameReusable(promoted,
        snapshot: migrationEditSnapshot, control: migratedComposer, now: promoted.time - 0.01))
    check("submit_rejects_prior_snapshot_frame", !visualSubmitGuardFrameReusable(migrating,
        snapshot: migrationEditSnapshot, control: migratedComposer, now: migrating.completeTime + 0.1))
    check("submit_rejects_guard_frame_partial_composer", !visualSubmitGuardFrameReusable(partialEdit,
        snapshot: migrationEditSnapshot, control: migratedComposer, now: partialEdit.completeTime + 0.1))
    var readOnlySubmitSnapshot = migrationEditSnapshot; readOnlySubmitSnapshot.readOnlyBackground = true
    check("submit_never_reuses_readonly_observation", !visualSubmitGuardFrameReusable(promoted,
        snapshot: readOnlySubmitSnapshot, control: migratedComposer, now: promoted.completeTime + 0.1))
    let migratingSubmit = migrationEdit.merging(["command": "visual_key", "key": "return", "allow_submit": true,
        "expected_message": "获授权的完整指令", "chat_title": "完整当前收件人"]) { _, v in v }
    check("complete_submit_request_may_reach_native_fresh_value_revalidation", acceptsMigration(promoted,
        request: migratingSubmit, snapshot: migrationEditSnapshot))
    check("corner_submit_field_preflight_is_not_sending_authority", visualCornerSubmitNeedsFreshRevalidation(migratingSubmit))
    for field in ["allow_submit", "expected_message", "chat_title"] {
        var missingSubmit = migratingSubmit; missingSubmit.removeValue(forKey: field)
        check("corner_submit_requires_" + field, !acceptsMigration(promoted, request: missingSubmit, snapshot: migrationEditSnapshot))
    }
    for (name, delta): (String, [String: Any]) in [
        ("modified_Return", ["modifiers": ["cmd"]]), ("false_submit", ["allow_submit": false]),
        ("empty_message", ["expected_message": " "]), ("empty_title", ["chat_title": " "]),
        ("search_composer", ["control_kind": "search"]), ("title_newline", ["chat_title": "收件人\n变化"])] {
        check("corner_submit_refuses_" + name, !acceptsMigration(promoted,
            request: migratingSubmit.merging(delta) { _, v in v }, snapshot: migrationEditSnapshot))
    }
    check("corner_submit_keeps_exact_ID_owner_proof", !acceptsMigration(differentEditID, request: migratingSubmit, snapshot: migrationEditSnapshot))
    check("corner_submit_keeps_full_coverage_proof", !acceptsMigration(partialEdit, request: migratingSubmit, snapshot: migrationEditSnapshot))
    // Actual external-display reincarnation during updating_exact_window_filter.
    let reincarnationIdentity = VisualIdentity(pid: 60682, windowID: 33789,
        frame: CGRect(x: 2325, y: 74, width: 855, height: 1079), topology: "external-1x-fixture")
    let reincarnationCorner = CGRect(x: 2331, y: 79, width: 52, height: 20)
    let oldCorner = VisualScreenWindow(id: 42364, pid: 60682, frame: reincarnationCorner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    let newCorner = VisualScreenWindow(id: 42373, pid: 60682, frame: reincarnationCorner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    check("actual_42364_to_42373_unique_owned_corner_capture_equivalence",
        visualMaskedCornerWindowReplacement([oldCorner], [newCorner], identity: reincarnationIdentity))
    let oldCornerCoverage = try? visualScreenCoverage([reincarnationIdentity.frame], windows: [oldCorner],
        identity: reincarnationIdentity, overlay: nil, dockRegions: nil)
    let newCornerCoverage = try? visualScreenCoverage([reincarnationIdentity.frame], windows: [newCorner],
        identity: reincarnationIdentity, overlay: nil, dockRegions: nil)
    check("production_coverage_masks_both_recreated_corner_IDs_identically", oldCornerCoverage != nil && oldCornerCoverage == newCornerCoverage)
    check("production_coverage_contains_no_recreated_corner_pixels", newCornerCoverage?.allSatisfy({ $0.intersection(reincarnationCorner).isEmpty }) == true)
    func replacementScene(_ windows: [VisualScreenWindow]) -> Bool {
        visualMaskedCornerWindowReplacement([oldCorner], windows, identity: reincarnationIdentity)
    }
    for (name, item) in [
        ("foreign_PID", VisualScreenWindow(id: 42373, pid: 99, frame: reincarnationCorner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)),
        ("main_ID", VisualScreenWindow(id: 33789, pid: 60682, frame: reincarnationCorner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)),
        ("larger", VisualScreenWindow(id: 42373, pid: 60682, frame: reincarnationCorner.insetBy(dx: -1, dy: 0), layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)),
        ("moved", VisualScreenWindow(id: 42373, pid: 60682, frame: reincarnationCorner.offsetBy(dx: 1, dy: 0), layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)),
        ("wrong_layer", VisualScreenWindow(id: 42373, pid: 60682, frame: reincarnationCorner, layer: 3, alpha: 1, emptyTitle: false, dockSurface: false)),
        ("alpha_change", VisualScreenWindow(id: 42373, pid: 60682, frame: reincarnationCorner, layer: 0, alpha: 0.999, emptyTitle: false, dockSurface: false)),
        ("untitled", VisualScreenWindow(id: 42373, pid: 60682, frame: reincarnationCorner, layer: 0, alpha: 1, emptyTitle: true, dockSurface: false)),
        ("Dock", VisualScreenWindow(id: 42373, pid: 60682, frame: reincarnationCorner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: true))] {
        check("reincarnated_corner_denies_" + name, !replacementScene([item]))
    }
    check("reincarnated_corner_denies_duplicate_geometry", !replacementScene([newCorner, oldCorner]))
    check("reincarnated_corner_denies_disappearance", !replacementScene([]))
    check("reincarnated_corner_denies_other_window_change", !replacementScene([newCorner, migrationScene[0]]))
    check("reincarnated_corner_keeps_foreign_scene_unchanged", visualMaskedCornerWindowReplacement(
        migrationScene + [oldCorner], migrationScene + [newCorner], identity: reincarnationIdentity))
    check("reincarnated_corner_keeps_other_window_order", !visualMaskedCornerWindowReplacement(
        migrationScene + [oldCorner], Array(migrationScene.reversed()) + [newCorner], identity: reincarnationIdentity))
    let reincarnationCoverage = visualSubtract(reincarnationIdentity.frame, reincarnationCorner)
    let reincarnationBefore = VisualFrame(image: diagnosticImage, completeSerial: 60, time: 20, completeTime: 20.1,
        idleConfirmed: false, capturedRegions: reincarnationCoverage, screenWindows: [oldCorner])
    let reincarnationAfter = VisualFrame(image: diagnosticImage, completeSerial: 61, time: 20.2, completeTime: 20.3,
        idleConfirmed: false, capturedRegions: reincarnationCoverage, screenWindows: [newCorner])
    let reincarnationAnchors = [CGRect(x: 2675, y: 84, width: 160, height: 26), CGRect(x: 3070, y: 1110, width: 80, height: 25)]
    let reincarnationSnapshot = VisualSnapshot(id: "actual-corner-replacement", identity: reincarnationIdentity,
        frame: reincarnationBefore, created: 20.1, focusedWindow: appRef, focusedFrame: reincarnationIdentity.frame,
        focusedTitle: "微信", rows: [], anchors: ["标题", "发送"], confirmed: true, confirmationSource: "fixture", anchorRegions: reincarnationAnchors)
    let reincarnationSearch = CGRect(x: 2395, y: 89, width: 210, height: 27)
    let reincarnationRequest: [String: Any] = ["command": "visual_click", "control_kind": "search", "confirm_control": true,
        "control_rect": rectJSON(reincarnationSearch), "x": reincarnationSearch.midX, "y": reincarnationSearch.midY]
    func acceptsReincarnation(_ frame: VisualFrame, request: [String: Any]? = nil, snapshot: VisualSnapshot? = nil) -> Bool {
        visualInputMaskedCornerReplacement(request ?? reincarnationRequest, snapshot: snapshot ?? reincarnationSnapshot, after: frame)
    }
    check("actual_search_click_accepts_fully_masked_corner_reincarnation", acceptsReincarnation(reincarnationAfter))
    check("search_typing_keeps_prior_selection_guard_after_reincarnation", acceptsReincarnation(reincarnationAfter,
        request: reincarnationRequest.merging(["command": "visual_type_text"]) { _, value in value }))
    let replacementNavigation = CGRect(x: 2393, y: 128, width: 245, height: 970)
    let replacementScroll = reincarnationRequest.merging(["command": "visual_scroll", "control_kind": "navigation",
        "control_rect": rectJSON(replacementNavigation), "x": 2517, "y": 423]) { _, value in value }
    check("navigation_scroll_accepts_complete_scene_equivalence", acceptsReincarnation(reincarnationAfter, request: replacementScroll))
    var brokenReplacement = reincarnationAfter; brokenReplacement.capturedRegions = [reincarnationIdentity.frame]
    check("replacement_never_exposes_corner_pixels", !acceptsReincarnation(brokenReplacement))
    brokenReplacement = reincarnationAfter
    brokenReplacement.capturedRegions = reincarnationCoverage.flatMap { visualSubtract($0, CGRect(x: 2500, y: 500, width: 1, height: 1)) }
    check("replacement_rejects_any_coverage_loss_even_outside_input", !acceptsReincarnation(brokenReplacement))
    brokenReplacement = reincarnationAfter; brokenReplacement.searchQuery = "changed"
    check("replacement_rejects_query_change", !acceptsReincarnation(brokenReplacement))
    brokenReplacement = reincarnationAfter; brokenReplacement.searchOverlay = VisualSearchOverlay(windowID: 700,
        frame: CGRect(x: 2373, y: 109, width: 368, height: 230))
    check("replacement_rejects_unbound_popup_change", !acceptsReincarnation(brokenReplacement))
    brokenReplacement = reincarnationAfter; brokenReplacement.excludedInputRegions = [reincarnationCorner]
    check("replacement_does_not_hide_other_mask_representation_change", !acceptsReincarnation(brokenReplacement))
    let overlappingSearch = reincarnationSearch.offsetBy(dx: -0.25, dy: 0)
    check("replacement_keeps_entire_input_safety_region_outside_corner", !acceptsReincarnation(reincarnationAfter,
        request: reincarnationRequest.merging(["control_rect": rectJSON(overlappingSearch)]) { _, value in value }))
    check("replacement_rejects_unconfirmed_control", !acceptsReincarnation(reincarnationAfter,
        request: reincarnationRequest.merging(["confirm_control": false]) { _, value in value }))
    var readonlyReplacement = reincarnationSnapshot; readonlyReplacement.readOnlyBackground = true
    check("replacement_never_promotes_readonly_evidence", !acceptsReincarnation(reincarnationAfter, snapshot: readonlyReplacement))
    var oneAnchorReplacement = reincarnationSnapshot; oneAnchorReplacement.anchorRegions = [reincarnationAnchors[0]]
    check("replacement_requires_two_complete_anchor_regions", !acceptsReincarnation(reincarnationAfter, snapshot: oneAnchorReplacement))
    var cornerAnchorReplacement = reincarnationSnapshot; cornerAnchorReplacement.anchorRegions = [reincarnationAnchors[0], reincarnationCorner]
    check("replacement_denies_an_anchor_inside_exclusion", !acceptsReincarnation(reincarnationAfter, snapshot: cornerAnchorReplacement))
    check("replacement_adds_no_submit_exception", !acceptsReincarnation(reincarnationAfter,
        request: reincarnationRequest.merging(["command": "visual_key", "key": "return"]) { _, value in value }))
    let replacementComposer = CGRect(x: reincarnationIdentity.frame.minX + 330, y: reincarnationIdentity.frame.maxY - 162, width: 495, height: 113)
    check("exact_masked_ID_replacement_submit_may_reach_fresh_revalidation", acceptsReincarnation(reincarnationAfter,
        request: migratingSubmit.merging(["control_rect": rectJSON(replacementComposer)]) { _, v in v }))
    let replacementActivation = VisualSearchActivation(identity: reincarnationIdentity, control: reincarnationSearch)
    let replacementTransition = VisualSearchTransition(activation: replacementActivation, windows: [oldCorner], anchorRegions: reincarnationAnchors)
    check("posted_search_click_readonly_transition_accepts_same_mask_reincarnation", replacementTransition.accepts([newCorner], identity: reincarnationIdentity))
    let replacementPopup = VisualScreenWindow(id: 700, pid: 60682, frame: CGRect(x: 2373, y: 109, width: 368, height: 230),
        layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)
    check("posted_search_transition_preserves_existing_bound_popup_rule", replacementTransition.accepts([replacementPopup, newCorner], identity: reincarnationIdentity))
    check("posted_search_transition_does_not_admit_unknown_popup", !replacementTransition.accepts([newCorner,
        VisualScreenWindow(id: 700, pid: 60682, frame: CGRect(x: 2373, y: 109, width: 400, height: 230),
            layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)], identity: reincarnationIdentity))
    // Source line 1229 supplies these IDs and unchanged popup identity.
    // The popup dimensions below are a valid fixture, not logged pixel coverage.
    let actualStablePopup = VisualScreenWindow(id: 42346, pid: 60682, frame: replacementPopup.frame,
        layer: 3, alpha: 1, emptyTitle: true, dockSurface: false)
    let searchCornerBefore = VisualScreenWindow(id: 42341, pid: 60682, frame: reincarnationCorner,
        layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    let searchCornerAfter = VisualScreenWindow(id: 42348, pid: 60682, frame: reincarnationCorner,
        layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    let actualSearchSceneBefore = [actualStablePopup, searchCornerBefore], actualSearchSceneAfter = [actualStablePopup, searchCornerAfter]
    check("actual_search_ID_chain_42346_42341_to_42346_42348_capture",
        visualMaskedCornerWindowReplacement(actualSearchSceneBefore, actualSearchSceneAfter, identity: reincarnationIdentity))
    let actualSearchTransition = VisualSearchTransition(activation: replacementActivation, windows: actualSearchSceneBefore, anchorRegions: reincarnationAnchors)
    check("actual_search_ID_chain_postclick_readonly_transition", actualSearchTransition.accepts(actualSearchSceneAfter, identity: reincarnationIdentity))
    var actualSearchFrameBefore = reincarnationBefore, actualSearchFrameAfter = reincarnationAfter
    actualSearchFrameBefore.screenWindows = actualSearchSceneBefore; actualSearchFrameAfter.screenWindows = actualSearchSceneAfter
    actualSearchFrameBefore.searchOverlay = VisualSearchOverlay(windowID: 42346, frame: actualStablePopup.frame)
    actualSearchFrameAfter.searchOverlay = actualSearchFrameBefore.searchOverlay
    actualSearchFrameBefore.searchQuery = ""; actualSearchFrameAfter.searchQuery = ""
    let actualSearchSnapshot = visualReboundNavigationSnapshot(reincarnationSnapshot, frame: actualSearchFrameBefore, rows: [])
    check("actual_search_ID_chain_allows_next_fully_proved_search_action", acceptsReincarnation(actualSearchFrameAfter,
        request: reincarnationRequest.merging(["command": "visual_type_text"]) { _, value in value }, snapshot: actualSearchSnapshot))
    var changedActualSearch = actualSearchFrameAfter; changedActualSearch.searchQuery = "changed"
    check("actual_search_ID_chain_rejects_changed_complete_query", !acceptsReincarnation(changedActualSearch, snapshot: actualSearchSnapshot))
    changedActualSearch = actualSearchFrameAfter
    changedActualSearch.searchOverlay = VisualSearchOverlay(windowID: 42347, frame: actualStablePopup.frame)
    check("actual_search_ID_chain_rejects_changed_popup_identity", !acceptsReincarnation(changedActualSearch, snapshot: actualSearchSnapshot))
    changedActualSearch = actualSearchFrameAfter; changedActualSearch.capturedRegions = []
    check("actual_search_ID_chain_rejects_missing_complete_coverage", !acceptsReincarnation(changedActualSearch, snapshot: actualSearchSnapshot))
    let labelRows: [[String: Any]] = [["text": "目标", "bounds": rectJSON(navControl.insetBy(dx: 4, dy: 4))]]
    check("corner_navigation_requires_unchanged_complete_literal_row", visualLiteralNavigationProof(labelRows, freshRows: labelRows, label: "目标", control: navControl, point: nil) &&
        !visualLiteralNavigationProof(labelRows, freshRows: labelRows, label: "目", control: navControl, point: nil) &&
        !visualLiteralNavigationProof(labelRows, freshRows: [["text": "目 标", "bounds": labelRows[0]["bounds"]!]], label: "目标", control: navControl, point: nil))
    check("corner_navigation_requires_unique_literal_label", !visualLiteralNavigationProof(labelRows + labelRows, freshRows: labelRows, label: "目标", control: navControl, point: nil))
    check("corner_navigation_explicit_point_must_hit_fresh_label", !visualLiteralNavigationProof(labelRows, freshRows: labelRows, label: "目标", control: navControl, point: CGPoint(x: 56, y: 46)))
    let truncatedControl = CGRect(x: 170, y: 1030, width: 170, height: 32), truncatedPoint = CGPoint(x: 221, y: 1046)
    let truncatedBounds = CGRect(x: 180, y: 1038, width: 140, height: 16)
    func truncatedRow(_ text: String, _ bounds: CGRect? = nil) -> [[String: Any]] {
        [["text": text, "bounds": rectJSON(bounds ?? truncatedBounds)]]
    }
    let truncatedRows = truncatedRow("保利上城（东区⋯.")
    func provesTruncated(_ before: [[String: Any]], _ fresh: [[String: Any]], _ point: CGPoint? = truncatedPoint) -> Bool {
        visualLiteralNavigationProof(before, freshRows: fresh, label: "保利上城（东区", control: truncatedControl, point: point)
    }
    check("actual_truncated_prefix_point_preserves_complete_observed_row", provesTruncated(truncatedRows, truncatedRows))
    check("truncated_prefix_without_point_does_not_become_full_row", !provesTruncated(truncatedRows, truncatedRows, nil))
    check("changed_ellipsis_is_not_unchanged_complete_row", !provesTruncated(truncatedRows, truncatedRow("保利上城（东区…")))
    check("changed_full_row_with_same_prefix_is_denied", !provesTruncated(truncatedRows, truncatedRow("保利上城（东区另一群")))
    check("ambiguous_old_prefix_point_is_denied", !provesTruncated(truncatedRows + truncatedRow("保利上城（东区另一群"), truncatedRows))
    check("ambiguous_fresh_prefix_point_is_denied", !provesTruncated(truncatedRows, truncatedRows + truncatedRow("保利上城（东区另一群")))
    check("truncated_same_row_wrong_point_is_denied", !provesTruncated(truncatedRows, truncatedRows, CGPoint(x: 335, y: 1046)))
    check("truncated_fresh_row_must_remain_inside_control", !provesTruncated(truncatedRows, truncatedRow("保利上城（东区⋯.", truncatedBounds.offsetBy(dx: 30, dy: 0))))
    check("truncated_navigation_requires_old_complete_row", !provesTruncated([], truncatedRows))
    let rebound = visualReboundNavigationSnapshot(nav, frame: masked, rows: labelRows)
    check("navigation_rebind_uses_new_frame_without_renewing_TTL", rebound.frame.completeSerial == 2 && rebound.frame.excludedInputRegions == [corner] &&
        rebound.created == nav.created && rebound.id == nav.id && rebound.identity == nav.identity && CFEqual(rebound.focusedWindow, appRef))
    check("original_serial_still_guards_first_event_freshness", visualFreshPreinputFrame(masked, after: nav.frame.completeSerial, now: 11) &&
        !visualFreshPreinputFrame(masked, after: nav.frame.completeSerial, now: 13))
    cases += visualContinuousSubmitSelfTests()
    cases += visualOCRPreparationSelfTests()
    cases += visualClearDraftSelfTests()
    cases += visualVoicePlaceholderSelfTests()
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count,
            "cases": cases, "capture_executed": false, "events_posted": 0]
}

// No capture, AX reads or events: exercise exact proof binding and lifecycle.
extension VisualDesktop {
    fileprivate func continuousSubmitLifecycleSelfTests(_ proof: VisualContinuousSubmitProof) -> [[String: Any]] {
        var cases: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { cases.append(["name": "continuous_submit_" + name, "passed": value]) }
        func seed() { nativeCommandScope = proof.scope; continuousSubmitProof = proof }
        seed()
        beginNativeCommand(taskID: proof.scope.taskID, operationID: proof.scope.operationID, command: "status")
        check("same_operation_status_keeps_proof", continuousSubmitProof != nil)
        for _ in 0..<2 { beginNativeCommand(taskID: proof.scope.taskID, operationID: proof.scope.operationID, command: "visual_key") }
        check("duplicate_return_dispatch_hook_does_not_consume", continuousSubmitProof != nil)
        check("action_takes_proof_once", takeContinuousSubmitProof() != nil && takeContinuousSubmitProof() == nil)
        for command in ["visual_type_text", "visual_click", "visual_read", "background_visual_read", "batch", "focus", "key", "invalid"] {
            seed(); beginNativeCommand(taskID: proof.scope.taskID, operationID: proof.scope.operationID, command: command)
            check("other_command_\(command)_invalidates", continuousSubmitProof == nil)
        }
        seed(); beginNativeCommand(taskID: proof.scope.taskID, operationID: nil, command: "status")
        check("missing_operation_invalidates", continuousSubmitProof == nil && nativeCommandScope == nil)
        seed(); beginNativeCommand(taskID: "other", operationID: proof.scope.operationID, command: "status")
        check("other_task_status_invalidates", continuousSubmitProof == nil)
        seed(); beginNativeCommand(taskID: proof.scope.taskID, operationID: "other", command: "visual_key")
        check("other_operation_return_invalidates", continuousSubmitProof == nil)
        seed(); beginNativeCommand(taskID: proof.scope.taskID, operationID: "invalid\n", command: "visual_key")
        check("invalid_operation_invalidates", continuousSubmitProof == nil && nativeCommandScope == nil)
        return cases
    }
}

func visualContinuousSubmitSelfTests() -> [[String: Any]] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { cases.append(["name": "continuous_submit_" + name, "passed": value]) }
    let window = CGRect(x: 356, y: 25, width: 855, height: 1079)
    let control = CGRect(x: 686, y: 943, width: 495, height: 113)
    let identity = VisualIdentity(pid: 7, windowID: 9, frame: window, topology: "offline")
    let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let frame = VisualFrame(image: image, completeSerial: 2, time: 10, completeTime: 10.1,
        idleConfirmed: false, capturedRegions: [window])
    let appRef = AXUIElementCreateApplication(7)
    func snap(_ frame: VisualFrame = frame, identity: VisualIdentity = identity, confirmed: Bool = true) -> VisualSnapshot {
        VisualSnapshot(id: "typed-proof", identity: identity, frame: frame, created: 10.7,
            focusedWindow: appRef, focusedFrame: window, focusedTitle: "", rows: [], anchors: ["recipient", "Send"],
            confirmed: confirmed, confirmationSource: "offline")
    }
    let scope = VisualNativeCommandScope(taskID: "task", operationID: "op")
    let owner = NSObject(), otherOwner = NSObject()
    let ownerID = ObjectIdentifier(owner)
    func proof(frameTime: Double = 10, finished: Double = 9.99, verified: Double = 10.7,
               security: Bool = true) -> VisualContinuousSubmitProof {
        VisualContinuousSubmitProof(scope: scope, helperID: ownerID, snapshotID: "typed-proof", identity: identity,
            serial: 2, frameTime: frameTime, inputFinishedAt: finished, verifiedAt: verified, control: control,
            message: "完整消息", title: "文件助手", revision: 4, securityVerified: security)
    }
    let request: [String: Any] = ["command": "visual_key", "key": "return", "snapshot_id": "typed-proof",
        "control_kind": "chat_composer", "control_rect": rectJSON(control), "confirm_control": true,
        "allow_submit": true, "expected_message": "完整消息", "chat_title": "文件助手"]
    func accepts(_ request: [String: Any] = request, _ proof: VisualContinuousSubmitProof = proof(),
                 snapshot: VisualSnapshot = snap(), scope candidateScope: VisualNativeCommandScope? = scope,
                 helperID: ObjectIdentifier = ownerID, revision: UInt64 = 4, now: Double = 10.8) -> Bool {
        proof.matches(request, scope: candidateScope, helperID: helperID, snapshot: snapshot, revision: revision, now: now)
    }
    let row: [String: Any] = ["text": "complete", "bounds": rectJSON(control)]
    check("three_complete_same_frame_ROIs_eligible", visualContinuousSubmitRowsComplete([[row], [row], [row]]))
    check("missing_security_rows_ineligible", !visualContinuousSubmitRowsComplete([[row], [row], []]))
    check("row_budget_boundary_ineligible", !visualContinuousSubmitRowsComplete([Array(repeating: row, count: 128), [row], [row]]))
    var truncatedRow = row; truncatedRow["text"] = String(repeating: "x", count: 1000)
    check("truncated_value_or_security_ineligible", !visualContinuousSubmitRowsComplete([[row], [row], [truncatedRow]]))
    var unknownRow = row; unknownRow.removeValue(forKey: "bounds")
    check("unknown_security_geometry_ineligible", !visualContinuousSubmitRowsComplete([[row], [row], [unknownRow]]))
    check("complete_immediate_type_proof_matches", accepts())
    check("complete_proof_expiry_denies", !accepts(now: 10.91))
    check("frame_age_expiry_denies", !accepts(request, proof(verified: 11.01), now: 11.02))
    check("future_proof_denies", !accepts(now: 10.6))
    check("frame_must_follow_last_input_event", !accepts(request, proof(finished: 10.01)))
    check("unknown_security_denies", !accepts(request, proof(security: false)))
    check("other_task_denies", !accepts(scope: VisualNativeCommandScope(taskID: "other", operationID: "op")))
    check("other_operation_denies", !accepts(scope: VisualNativeCommandScope(taskID: "task", operationID: "other")))
    check("missing_operation_denies", !accepts(scope: nil))
    check("other_helper_denies", !accepts(helperID: ObjectIdentifier(otherOwner)))
    check("external_input_revision_denies", !accepts(revision: 5))
    for (key, value) in [("expected_message", "different" as Any), ("chat_title", "different" as Any),
                         ("snapshot_id", "other" as Any), ("key", "escape" as Any), ("allow_submit", false as Any),
                         ("confirm_control", false as Any), ("modifiers", ["command"] as Any),
                         ("control_rect", rectJSON(control.offsetBy(dx: 1, dy: 0)) as Any)] {
        var changed = request; changed[key] = value
        check("mismatched_\(key)_denies", !accepts(changed))
    }
    check("unconfirmed_snapshot_denies", !accepts(snapshot: snap(confirmed: false)))
    var background = snap(); background.readOnlyBackground = true
    check("background_snapshot_denies", !accepts(snapshot: background))
    var changedFrame = frame; changedFrame.capturedRegions = [control, visualSubmitHeader(window)]
    check("missing_padded_security_coverage_denies", !accepts(snapshot: snap(changedFrame)))
    changedFrame = frame; changedFrame.capturedRegions = nil
    check("unknown_coverage_denies", !accepts(snapshot: snap(changedFrame)))
    changedFrame = frame; changedFrame.searchQuery = ""
    check("search_state_denies", !accepts(snapshot: snap(changedFrame)))
    let idle = VisualFrame(image: image, completeSerial: 2, time: 10, completeTime: 10.1,
        idleConfirmed: true, capturedRegions: [window])
    check("idle_frame_denies", !accepts(snapshot: snap(idle)))
    let otherIdentity = VisualIdentity(pid: 8, windowID: 9, frame: window, topology: "offline")
    check("identity_change_denies", !accepts(snapshot: snap(identity: otherIdentity)))
    let corner = CGRect(x: 362, y: 30, width: 52, height: 20)
    let aux = VisualScreenWindow(id: 10, pid: 7, frame: corner, layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    var masked = frame; masked.capturedRegions = visualSubtract(window, corner)
    masked.captureEvidence = ["additional_own_auxiliary_exclusions": visualAuxiliaryExclusionMetadata([aux])]
    check("same_current_masked_auxiliary_scene_matches", visualContinuousSubmitSceneMatches(masked, current: [aux], identity: identity))
    check("missing_auxiliary_scene_denies", !visualContinuousSubmitSceneMatches(masked, current: [], identity: identity))
    check("new_foreign_scene_denies", !visualContinuousSubmitSceneMatches(frame, current: [aux], identity: identity))
    var unmasked = masked; unmasked.capturedRegions = [window]
    check("auxiliary_pixels_must_remain_excluded", !visualContinuousSubmitSceneMatches(unmasked, current: [aux], identity: identity))
    var malformed = frame; malformed.captureEvidence = ["additional_own_auxiliary_exclusions": "unknown"]
    check("unknown_scene_metadata_denies", !visualContinuousSubmitSceneMatches(malformed, current: [], identity: identity))
    let moved = VisualScreenWindow(id: 10, pid: 7, frame: corner.offsetBy(dx: 1, dy: 0), layer: 0, alpha: 1, emptyTitle: false, dockSurface: false)
    check("moved_auxiliary_scene_denies", !visualContinuousSubmitSceneMatches(masked, current: [moved], identity: identity))
    cases += VisualDesktop().continuousSubmitLifecycleSelfTests(proof())
    return cases
}

func visualOCRPreparationSelfTests() -> [[String: Any]] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
    let window = CGRect(x: -400, y: -33, width: 16, height: 8)
    let identity = VisualIdentity(pid: 1, windowID: 8, frame: window, topology: "offline-mixed-scale")
    let context = CGContext(data: nil, width: 32, height: 12, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 12))
    let image = context.makeImage()!
    var frame = VisualFrame(image: image, completeSerial: 1, time: 100, completeTime: 100.1,
        idleConfirmed: false, capturedRegions: [window])
    let roi = CGRect(x: window.minX+3.2, y: window.minY+2.2, width: 4.1, height: 2.1)
    let other = CGRect(x: window.minX+7, y: window.minY+2, width: 4, height: 3)
    let desktop = VisualDesktop(), regions = [roi, other, roi, window, other]
    let completeProofRows: [[String: Any]] = [["text": "完整收件人", "bounds": rectJSON(roi)], ["text": "发送", "bounds": rectJSON(other)]]
    check("complete_post_edit_ROIs_preserve_observed_anchor_binding", desktop.preparedContinuationAnchorsVerified(
        ["完整收件人", "发送"], regions: [roi, other], rows: completeProofRows))
    check("post_edit_body_text_cannot_replace_spatial_anchor", !desktop.preparedContinuationAnchorsVerified(
        ["完整收件人"], regions: [roi], rows: [["text": "完整收件人", "bounds": rectJSON(other)]]))
    check("post_edit_unknown_bounds_require_original_anchor_OCR", !desktop.preparedContinuationAnchorsVerified(
        ["完整收件人"], regions: [roi], rows: [["text": "完整收件人"]]))
    check("fresh_complete_batch_reuses_only_identical_ROIs_with_original_indices",
        desktop.ocrRegionSources(frame, identity: identity, regions: regions, now: 101) == [0,1,0,3,1])
    check("containing_and_overlapping_ROIs_keep_independent_observation_budgets",
        desktop.ocrRegionSources(frame, identity: identity, regions: [window, roi, other], now: 101) == [0,1,2])
    check("stale_batch_cannot_share_region_results",
        desktop.ocrRegionSources(frame, identity: identity, regions: regions, now: 105) == Array(regions.indices))
    check("future_batch_cannot_share_region_results",
        desktop.ocrRegionSources(frame, identity: identity, regions: regions, now: 99) == Array(regions.indices))
    let idle = VisualFrame(image: image, completeSerial: 1, time: 100, completeTime: 100.1,
        idleConfirmed: true, capturedRegions: [window])
    check("idle_batch_cannot_share_region_results",
        desktop.ocrRegionSources(idle, identity: identity, regions: regions, now: 101) == Array(regions.indices))
    frame.capturedRegions = [roi]
    check("integral_pixel_expansion_coverage_is_required_for_batch_reuse",
        desktop.ocrRegionSources(frame, identity: identity, regions: [roi,roi], now: 101) == [0,1] &&
        desktop.ocrReuseFingerprint(frame, identity: identity, region: roi, now: 101) == nil)
    frame.capturedRegions = nil
    check("unknown_coverage_cannot_share_region_results",
        desktop.ocrRegionSources(frame, identity: identity, regions: regions, now: 101) == Array(regions.indices))
    frame.capturedRegions = [window]
    if let direct = desktop.ocrReuseFingerprint(frame, identity: identity, region: roi, now: 101),
       let shared = desktop.ocrReuseFingerprint(frame, identity: identity, region: roi, now: 101,
            colorProfile: VisualDesktop.OCRColorProfile(image)) {
        check("shared_color_profile_preserves_the_entire_exact_reuse_key", direct.key == shared.key && direct.digest == shared.digest)
        let pixels = CGRect(x: 3.2*2, y: 2.2*1.5, width: 4.1*2, height: 2.1*1.5).integral
        let actual = CGRect(x: window.minX+pixels.minX/2, y: window.minY+pixels.minY/1.5,
            width: pixels.width/2, height: pixels.height/1.5)
        check("prepared_mixed_scale_crop_keeps_negative_Quartz_mapping",
            shared.key.pixels == pixels && shared.raster.actual == actual && shared.raster.scaleX == 2 && shared.raster.scaleY == 1.5 &&
            shared.raster.image.width == Int(pixels.width) && shared.raster.image.height == Int(pixels.height))
        let alien = CGContext(data: nil, width: 32, height: 12, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let fallback = desktop.ocrReuseFingerprint(frame, identity: identity, region: roi, now: 101,
            colorProfile: VisualDesktop.OCRColorProfile(alien))
        check("different_color_profile_cannot_replace_current_crop_metadata", fallback?.key == direct.key && fallback?.digest == direct.digest)
    } else { check("offline_mixed_scale_fingerprint_fixture_available", false) }
    check("OCR_preparation_self_test_never_starts_capture", desktop.stream == nil && desktop.streams.isEmpty)
    return cases
}

func visualClearDraftSelfTests() -> [[String: Any]] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { cases.append(["name": "clear_draft_" + name, "passed": value]) }
    let desktop = VisualDesktop()
    let window = CGRect(x: 1900, y: 33, width: 855, height: 1079)
    let control = CGRect(x: 2230, y: 950, width: 495, height: 110)
    let request: [String: Any] = ["command": "visual_key", "snapshot_id": "fixture", "control_kind": "chat_composer",
        "confirm_control": true, "control_rect": rectJSON(control), "key": "clear_draft",
        "expected_draft": "完整 自有草稿\n第二行🙂", "chat_title": "完整聊天标题", "allow_submit": false]
    func valid(_ value: [String: Any]) -> Bool { do { try desktop.validate(value); return true } catch { return false } }
    check("valid_full_multiline_unicode_contract", valid(request))
    for key in ["expected_draft", "chat_title", "snapshot_id", "confirm_control", "control_rect"] {
        var value = request; value.removeValue(forKey: key)
        check("missing_" + key + "_denied", !valid(value))
    }
    for (name, delta) in [
        ("search", ["control_kind": "search"]), ("navigation", ["control_kind": "navigation"]),
        ("empty_draft", ["expected_draft": ""]), ("oversized_draft", ["expected_draft": String(repeating: "字", count: 8193)]),
        ("empty_title", ["chat_title": ""]), ("title_newline", ["chat_title": "标题\n其他"]),
        ("unconfirmed", ["confirm_control": false]), ("modifiers", ["modifiers": ["cmd"]]),
        ("submit_permission", ["allow_submit": true]), ("prefix_semantics", ["prefix": "完整"])
    ] as [(String, [String: Any])] {
        check(name + "_denied", !valid(request.merging(delta) { _, new in new }))
    }
    let image = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let frame = VisualFrame(image: image, completeSerial: 2, time: 10, completeTime: 10.1,
        idleConfirmed: false, capturedRegions: [window])
    let rows: [[String: Any]] = [["text": "完整 自有草稿"], ["text": "第二行🙂"]]
    let titles: [[String: Any]] = [["text": "完整聊天标题"]]
    func proves(_ candidate: VisualFrame = frame, _ observed: [[String: Any]] = rows,
                expected: String = "完整 自有草稿\n第二行🙂", header: [[String: Any]] = titles, now: Double = 11) -> Bool {
        (try? visualClearDraftObservation(candidate, window: window, control: control,
            composerRows: observed, headerRows: header, expected: expected, title: "完整聊天标题", now: now)) == true
    }
    check("whole_value_and_header_proven", proves())
    check("changed_character_denied", !proves(expected: "完整 自有草稿\n第二行😀"))
    check("spaces_not_normalized", !proves(expected: "完整自有草稿\n第二行🙂"))
    check("wrap_not_normalized", !proves(expected: "完整 自有草稿第二行🙂"))
    check("unicode_code_units_not_normalized", !proves(frame, [["text": "e\u{301}"]], expected: "é"))
    check("empty_requires_no_OCR_rows", proves(frame, [], expected: ""))
    check("remaining_text_not_empty", !proves(frame, [["text": "余"]], expected: ""))
    check("caret_or_unknown_glyph_not_discarded", !proves(frame, [["text": ")"]], expected: ""))
    check("blank_row_not_empty_evidence", !proves(frame, [["text": ""]], expected: ""))
    check("missing_text_not_empty_evidence", !proves(frame, [["confidence": 1]], expected: ""))
    check("row_cap_cannot_claim_complete", !proves(frame, Array(repeating: ["text": "字"], count: 101)))
    check("single_row_cap_cannot_claim_complete", !proves(frame, [["text": String(repeating: "字", count: 1000)]], expected: String(repeating: "字", count: 1000)))
    check("different_recipient_denied", !proves(header: [["text": "其他聊天标题"]]))
    check("missing_recipient_denied", !proves(header: []))
    check("ambiguous_recipient_denied", !proves(header: titles + titles))
    check("preclear_header_whitespace_and_known_invisibles_accepted", proves(header: [["text": " 完整\u{200B}聊天\u{FEFF} 标题 "]]))
    check("postclear_header_uses_same_normalization", proves(frame, [], expected: "", header: [["text": "完整 聊天 标题"]]))
    check("normalized_duplicate_whole_headers_denied", !proves(header: titles + [["text": "完整 聊天标题"]]))
    func headerMatches(_ actual: String, _ expected: String = "2026实施管理部 （5）") -> Bool {
        visualClearDraftHeaderMatchCount([["text": actual]], title: expected) == 1
    }
    check("actual_group_count_spacing_variation_accepted", headerMatches("2026实施管理部（5）"))
    let pythonWhitespace: [UInt32] = [9,10,11,12,13,28,29,30,31,32,0x85,0xA0,0x1680] + Array(0x2000...0x200A) + [0x2028,0x2029,0x202F,0x205F,0x3000]
    check("Python_Unicode_whitespace_set_matches", pythonWhitespace.allSatisfy {
        headerMatches("2026实施管理部" + String(Unicode.Scalar($0)!) + "（5）")
    })
    check("U200B_and_FEFF_only_explicit_format_removals", headerMatches("2026\u{200B}实施管理部\u{FEFF}（5）"))
    for (name, actual) in [
        ("changed_name", "2026实施管埋部（5）"), ("changed_count", "2026实施管理部（6）"),
        ("missing_count", "2026实施管理部"), ("changed_punctuation", "2026实施管理部(5)"),
        ("extra_punctuation", "2026实施管理部（5）·"), ("unknown_suffix", "2026实施管理部（5）D>"),
        ("ZWJ", "2026实施\u{200D}管理部（5）"), ("ZWNJ", "2026实施\u{200C}管理部（5）"),
        ("word_joiner", "2026实施\u{2060}管理部（5）"), ("variation_selector", "2026实施管理部\u{FE0F}（5）")
    ] { check("header_" + name + "_denied", !headerMatches(actual)) }
    check("header_case_not_normalized", !headerMatches("Alice", "alice"))
    check("header_unicode_composition_not_normalized", !headerMatches("e\u{301}", "é"))
    check("empty_normalized_header_is_never_identity", !headerMatches(" \u{200B}", "\u{FEFF} "))
    let diagnostic = visualClearDraftPostDiagnostic(frame, window: window, control: control,
        composerRows: [["text": "PRIVATE_DRAFT_SENTINEL"]], headerRows: [["text": "PRIVATE_TITLE_SENTINEL"]],
        title: "PRIVATE_TITLE_SENTINEL", observationCount: 2, now: 11)
    check("postdiagnostic_counts_without_values", diagnostic["composer_row_count"] as? Int == 1 &&
        diagnostic["header_normalized_match_count"] as? Int == 1 && diagnostic["composer_empty"] as? Bool == false &&
        diagnostic["observation_count"] as? Int == 2 && diagnostic["complete_composer_coverage"] as? Bool == true)
    let diagnosticJSON = (try? JSONSerialization.data(withJSONObject: diagnostic)).flatMap { String(data: $0, encoding: .utf8) }
    check("postdiagnostic_never_contains_draft_or_title", diagnosticJSON != nil && !(diagnosticJSON?.contains("PRIVATE") ?? true))
    check("two_second_freshness_retained", !proves(now: 12.001))
    check("future_or_nonfinite_clock_denied", !proves(now: 9.99) && !proves(now: .nan))
    var changed = frame; changed.capturedRegions = nil
    check("unknown_coverage_denied", !proves(changed))
    changed.capturedRegions = visualSubtract(window, CGRect(x: control.minX + 10, y: control.minY + 10, width: 1, height: 1))
    check("partial_composer_denied", !proves(changed, [], expected: ""))
    changed.capturedRegions = [control]
    check("partial_header_denied", !proves(changed))
    let idle = VisualFrame(image: image, completeSerial: 2, time: 10, completeTime: 10.1, idleConfirmed: true, capturedRegions: [window])
    check("idle_pixels_denied", !proves(idle))
    for stopAt in 0...4 {
        var count = 0, checks: [Int] = [], keys: [Int] = [], downFlags: [UInt64] = [], threw = false
        do {
            try visualClearDraftKeys { code, flags in
                try visualPostCountedKeyPair(count: &count, beforePost: { posted in
                    checks.append(posted)
                    if posted == stopAt { throw fail("user_interrupted", "fixture") }
                }, down: { keys.append(Int(code)); downFlags.append(flags.rawValue) }, up: { keys.append(Int(code)) })
            }
        } catch { threw = true }
        check("event_guard_\(stopAt)_count_no_replay", count == min(stopAt, 4) && keys == Array([0, 0, 51, 51].prefix(min(stopAt, 4))) && threw == (stopAt < 4))
        check("event_guard_\(stopAt)_runs_before_every_post", checks == Array(0...min(stopAt, 3)))
        if stopAt == 4 { check("only_select_all_then_backspace_no_return", downFlags == [CGEventFlags.maskCommand.rawValue, 0]) }
    }
    var count = 0, attempts = 0
    do {
        try visualClearDraftKeys { _, _ in
            func post() throws { attempts += 1; if attempts == 3 { throw fail("event_failed", "fixture") } }
            try visualPostCountedKeyPair(count: &count, beforePost: { _ in }, down: post, up: post)
        }
        check("post_failure_stops", false)
    } catch { check("post_failure_stops_without_counting_failed_event", count == 2 && attempts == 3) }
    check("tests_never_start_capture", desktop.stream == nil && desktop.streams.isEmpty && desktop.latestWindowFrame == nil)
    return cases
}

func visualVoicePlaceholderSelfTests() -> [[String: Any]] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { cases.append(["name": "voice_placeholder_" + name, "passed": passed]) }
    func bitmap(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    let window = CGRect(x: -600, y: 30, width: 600, height: 400)
    let composer = visualVoiceComposerRegion(window)
    let bounds = CGRect(x: composer.minX+8, y: composer.minY+14, width: 146, height: 16)
    let row: [String: Any] = ["text": "按住鼠标 语音输入文字", "bounds": rectJSON(bounds)]
    func fixture(_ scale: Int = 2, ink: UInt8 = 159, caret: Bool = true, badPixel: Bool = false, caretOffset: Int = 0) -> VisualFrame {
        let width = Int(window.width)*scale, height = Int(window.height)*scale
        var bytes = [UInt8](repeating: 250, count: width*height*4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        let x0 = Int(bounds.minX-window.minX)*scale, y0 = Int(bounds.minY-window.minY)*scale
        func pixel(_ x: Int, _ y: Int, _ rgb: [UInt8]) {
            let i = ((y0+y)*width+x0+x)*4
            bytes[i]=rgb[0]; bytes[i+1]=rgb[1]; bytes[i+2]=rgb[2]
        }
        for y in (2*scale)..<(14*scale) { for x in (5*scale)..<(140*scale) where (x/scale)%6 < 2 {
            pixel(x,y,[ink,ink,ink])
        } }
        if caret { for y in 0..<(15*scale) { for x in 0..<scale { pixel(x+caretOffset*scale,y,[7,195,118]) } } }
        if badPixel { pixel(80*scale,8*scale,[20,20,20]) }
        return VisualFrame(image: bitmap(bytes, width: width, height: height), completeSerial: 7, time: 10,
            completeTime: 10.1, idleConfirmed: false, capturedRegions: [window])
    }
    let frame = fixture()
    func hint(_ candidate: VisualFrame = frame, _ rows: [[String: Any]] = [row], now: Double = 11,
              maximumAge: Double = 2) -> [String: Any]? {
        visualEmptyComposerHint(candidate, window: window, rows: rows, now: now, maximumAge: maximumAge)
    }
    check("gray_light_theme_at_2x", hint() != nil)
    check("gray_light_theme_at_1x_and_negative_origin", hint(fixture(1)) != nil)
    check("caret_blink_off_allowed", hint(fixture(caret: false)) != nil)
    check("observed_caret_four_points_inside_Vision_box", hint(fixture(caretOffset: 4)) != nil)
    check("unrecognized_green_mark_inside_words_denied", hint(fixture(caretOffset: 20)) == nil)
    check("black_identical_words_are_user_text", hint(fixture(ink: 40)) == nil)
    check("one_unknown_dark_glyph_denies_hint", hint(fixture(badPixel: true)) == nil)
    check("unknown_pale_theme_denied", hint(fixture(ink: 225)) == nil)
    check("actual_raw_row_preserved", hint()?["text"] as? String == row["text"] as? String)
    check("serial_bound_to_same_frame", hint()?["frame_complete_serial"] as? Int == 7)
    var altered = row; altered["text"] = "按住鼠标\u{3000}语音输入文字"
    check("only_OCR_whitespace_normalized", hint(frame,[altered]) != nil)
    for text in ["输入文字", "输入消息", "按住鼠标语音输入文字。", "按住鼠标\u{200B}语音输入文字", "按住鼠标\u{200D}语音输入文字"] {
        altered["text"] = text
        check("unknown_text_" + String(cases.count) + "_retained", hint(frame,[altered]) == nil)
    }
    altered = row; altered["bounds"] = rectJSON(bounds.offsetBy(dx: 25, dy: 0))
    check("outside_observed_left_geometry_denied", hint(frame,[altered]) == nil)
    altered["bounds"] = rectJSON(bounds.offsetBy(dx: 0, dy: 25))
    check("outside_observed_top_geometry_denied", hint(frame,[altered]) == nil)
    check("duplicate_phrase_not_unique", hint(frame,[row,row]) == nil)
    check("stale_frame_denied", hint(now: 12.001) == nil)
    check("semantic_2_5_second_frame_allowed", hint(now: 12.5, maximumAge: 5) != nil)
    check("input_2_5_second_frame_still_denied", hint(now: 12.5) == nil)
    check("semantic_five_second_boundary_denied", hint(now: 15, maximumAge: 5) == nil && hint(now: 15.001, maximumAge: 5) == nil)
    check("semantic_proof_reports_age_and_readonly_scope", hint(now: 12.5, maximumAge: 5)?["proof_scope"] as? String == "snapshot_semantics_only" &&
        hint(now: 12.5, maximumAge: 5)?["proof_frame_age_ms"] as? Double == 2500 &&
        hint(now: 12.5, maximumAge: 5)?["proof_max_age_ms"] as? Double == 5000)
    check("input_proof_retains_two_second_scope", hint()?["proof_scope"] as? String == "input_value_observation" &&
        hint()?["proof_max_age_ms"] as? Double == 2000)
    check("unsupported_proof_age_denied", hint(maximumAge: 10) == nil)
    check("future_frame_denied", hint(now: 9.99) == nil)
    var partial = frame; partial.capturedRegions = visualSubtract(window, CGRect(x: composer.maxX-2,y: composer.maxY-2,width: 1,height: 1))
    check("whole_composer_coverage_required", hint(partial) == nil)
    let unknown: [String: Any] = ["text": ")", "bounds": rectJSON(bounds.offsetBy(dx: 0,dy: 22))]
    let kept = visualRowsWithoutEmptyComposerHint(frame, window: window, rows: [row,unknown], now: 11)
    check("unknown_other_row_never_discarded", kept.count == 1 && kept[0]["text"] as? String == ")")
    let black = fixture(ink: 40)
    check("typed_black_identical_phrase_retained_for_value_verification",
        visualRowsWithoutEmptyComposerHint(black, window: window, rows: [row], now: 11).count == 1)
    check("gray_phrase_cannot_satisfy_already_visible_or_post_value",
        visualRowsWithoutEmptyComposerHint(frame, window: window, rows: [row], now: 11).isEmpty)
    func clear(_ candidate: VisualFrame, _ rows: [[String: Any]], expected: String) -> Bool {
        (try? visualClearDraftObservation(candidate, window: window, control: composer, composerRows: rows,
            headerRows: [["text":"完整标题"]], expected: expected, title: "完整标题", now: 11)) == true
    }
    check("gray_only_is_empty", clear(frame,[row],expected:""))
    check("gray_hint_cannot_authorize_nonempty_draft", !clear(frame,[row],expected:row["text"] as! String))
    check("black_same_words_are_not_empty", !clear(black,[row],expected:""))
    check("black_same_words_are_exact_draft", clear(black,[row],expected:row["text"] as! String))
    check("hint_plus_unknown_is_not_empty", !clear(frame,[row,unknown],expected:""))
    check("prefix_final_empty_gray_hint_allowed", visualPrefixFinalValueMatches(frame,window:window,rows:[row],expected:"",now:11))
    check("prefix_final_empty_black_same_words_denied", !visualPrefixFinalValueMatches(black,window:window,rows:[row],expected:"",now:11))
    check("prefix_final_empty_unknown_row_denied", !visualPrefixFinalValueMatches(frame,window:window,rows:[row,unknown],expected:"",now:11))
    check("one_character_prefix_empty_first_delete_uses_same_proof", (try? visualPrefixDeletion("字",prefix:"字").suffix) == "" &&
        visualPrefixFinalValueMatches(frame,window:window,rows:[row],expected:"",now:11))
    check("prefix_nonempty_suffix_stays_literal", !visualPrefixFinalValueMatches(frame,window:window,rows:[row],expected:"按住鼠标语音输入文字",now:11))
    check("prefix_nonempty_suffix_keeps_spaces", visualPrefixFinalValueMatches(frame,window:window,rows:[["text":"保留 空格"]],expected:"保留 空格",now:11) &&
        !visualPrefixFinalValueMatches(frame,window:window,rows:[["text":"保留 空格"]],expected:"保留空格",now:11))

    // Optional, authorized offline fixture. No capture, OCR or input occurs.
    if let path = ProcessInfo.processInfo.environment["INTEL_DESKTOP_EMPTY_HINT_FIXTURE"] {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let metadata = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let imagePath = metadata["image_path"] as! String
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let actualWindow = try visualRect(metadata["window_frame"])
            let actualRows = metadata["ocr"] as! [[String: Any]]
            let coverage = try (metadata["captured_regions"] as! [[String: Any]]).map { try visualRect($0) }
            let actual = VisualFrame(image: image, completeSerial: 51, time: 10, completeTime: 10.1,
                idleConfirmed: false, capturedRegions: coverage)
            let proof = visualEmptyComposerHint(actual, window: actualWindow, rows: actualRows, now: 11)
            check("actual_authorized_2x_PNG_proves_gray_placeholder", proof != nil)
            if let proof { cases.append(["name":"voice_placeholder_actual_pixel_evidence", "passed":true,
                "pixel_evidence":proof["pixel_evidence"]!]) }
            let raw = try visualRGBA(image)
            let pixels = raw.dataProvider!.data!
            var darkBytes = Array(UnsafeBufferPointer(start: CFDataGetBytePtr(pixels), count: CFDataGetLength(pixels)))
            let box = try visualRect(actualRows.first { visualVoiceHintText($0["text"] as? String ?? "") == "按住鼠标语音输入文字" }!["bounds"])
            let sx = Double(raw.width)/actualWindow.width, sy = Double(raw.height)/actualWindow.height
            let region = CGRect(x:(box.minX-actualWindow.minX)*sx,y:(box.minY-actualWindow.minY)*sy,width:box.width*sx,height:box.height*sy).integral
            for y in Int(region.minY)..<Int(region.maxY) { for x in Int(region.minX)..<Int(region.maxX) {
                let i = y*raw.bytesPerRow+x*4
                let rgb = darkBytes[i...i+2]
                if Int(rgb.max()!)-Int(rgb.min()!) <= 18 && rgb.min()! < 220 {
                    darkBytes[i]=32; darkBytes[i+1]=32; darkBytes[i+2]=32
                }
            } }
            let darkImage = CGImage(width:raw.width,height:raw.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:raw.bytesPerRow,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                provider:CGDataProvider(data:Data(darkBytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            let changed = VisualFrame(image:darkImage,completeSerial:52,time:10,completeTime:10.1,idleConfirmed:false,capturedRegions:coverage)
            check("actual_PNG_same_text_black_ink_counterexample_denied",
                visualEmptyComposerHint(changed,window:actualWindow,rows:actualRows,now:11) == nil)
        } catch { check("actual_fixture_readable", false) }
    }
    return cases
}

func visualMultiDisplaySelfTests() -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]) }
    func code(_ body: () throws -> Void) -> String { do { try body(); return "none" } catch { return (error as? HelperError)?.code ?? "other" } }
    func image(_ w: Int, _ h: Int, _ red: CGFloat, _ blue: CGFloat) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Green is the visual top half, detecting accidental vertical inversion.
        c.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
        return c.makeImage()!
    }
    func pixel(_ im: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = im.dataProvider!.data!; let p = CFDataGetBytePtr(data)!
        let offset = y * im.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: p + offset, count: 4))
    }
    do {
        let left = DisplayGeometry(id: 2, bounds: CGRect(x: -200, y: 0, width: 200, height: 200), pixelWidth: 200, pixelHeight: 200)
        let right = DisplayGeometry(id: 1, bounds: CGRect(x: 0, y: 0, width: 200, height: 200), pixelWidth: 400, pixelHeight: 400, main: true)
        let topology = DisplaySnapshot(displays: [left, right])
        let rect = CGRect(x: -100, y: 20, width: 200, height: 100)
        let plan = try VisualCapturePlan(window: rect, topology: topology)
        check("mixed_scale_negative_origin_has_two_fragments", plan.fragments.count == 2 && plan.width == 400 && plan.height == 200)
        check("native_fragment_scales_preserved", plan.fragments[0].pixelWidth == 200 && plan.fragments[1].pixelWidth == 100)
        check("display_local_source_rect_negative_origin", plan.fragments[1].sourceRect == CGRect(x: 100, y: 20, width: 100, height: 100))
        check("adjacent_seam_has_no_point_gap", visualCovered(rect, by: plan.coverage))
        let images = plan.fragments.map { image($0.pixelWidth, $0.pixelHeight, $0.displayID == 2 ? 1 : 0, $0.displayID == 1 ? 1 : 0) }
        let composite = try plan.composite(images)
        check("mixed_scale_composite_seam_correct", pixel(composite, 199, 150)[0] > 240 && pixel(composite, 200, 150)[2] > 240)
        check("fragment_vertical_orientation_preserved", pixel(composite, 50, 20)[1] > 240 && pixel(composite, 300, 20)[1] > 240)
        check("seam_crossing_OCR_maps_once_to_Quartz", visualOCRBounds(CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.1), region: rect).minX == -20)
        check("seam_crossing_control_fully_observable", visualCovered(CGRect(x: -20, y: 30, width: 40, height: 20), by: plan.coverage))
        let reordered = try VisualCapturePlan(window: rect, topology: DisplaySnapshot(displays: [right, left]))
        check("display_enumeration_order_deterministic", reordered.fragments.map { $0.displayID } == plan.fragments.map { $0.displayID })
        let mirror = DisplayGeometry(id: 3, bounds: right.bounds, pixelWidth: 400, pixelHeight: 400)
        check("mirrored_overlap_not_double_captured", try VisualCapturePlan(window: rect, topology: DisplaySnapshot(displays: [mirror, left, right])).fragments.count == 2)
        let above = DisplayGeometry(id: 4, bounds: CGRect(x: 0, y: -200, width: 200, height: 200), pixelWidth: 300, pixelHeight: 300)
        let vertical = try VisualCapturePlan(window: CGRect(x: 10, y: -50, width: 100, height: 100), topology: DisplaySnapshot(displays: [above, right]))
        check("negative_y_vertical_mixed_scale", vertical.fragments.count == 2 && visualCovered(vertical.window, by: vertical.coverage))
        let gapRight = DisplayGeometry(id: 1, bounds: right.bounds.offsetBy(dx: 100, dy: 0), pixelWidth: 400, pixelHeight: 400, main: true)
        let gap = try VisualCapturePlan(window: CGRect(x: -100, y: 20, width: 300, height: 100), topology: DisplaySnapshot(displays: [left, gapRight]))
        let gapImage = try gap.composite(gap.fragments.map { image($0.pixelWidth, $0.pixelHeight, 1, 0) })
        check("display_gap_is_transparent_unobservable", pixel(gapImage, 300, 150)[3] == 0 && !visualCovered(gap.window, by: gap.coverage))
        check("control_spanning_gap_is_rejected", !visualCovered(CGRect(x: -10, y: 30, width: 120, height: 10), by: gap.coverage))
        check("offscreen_window_portion_still_reads_visible_fragment", try VisualCapturePlan(window: CGRect(x: -250, y: 20, width: 100, height: 100), topology: topology).fragments.count == 1)
        check("entirely_offscreen_target_fails", code { _ = try VisualCapturePlan(window: CGRect(x: 500, y: 500, width: 50, height: 50), topology: topology) } == "visual_region_unavailable")
        check("pixel_budget_rejected_before_allocation", code { _ = try VisualCapturePlan(window: CGRect(x: -100, y: 20, width: 100_000, height: 100_000), topology: topology) } == "visual_image_too_large")
        check("fragment_dimension_change_fails_closed", code { _ = try plan.composite([image(2, 2, 1, 0), images[1]]) } == "visual_target_changed")
        check("unplug_changes_identity_topology", topology.signature != DisplaySnapshot(displays: [right]).signature)
        let rescaled = DisplayGeometry(id: 2, bounds: left.bounds, pixelWidth: 400, pixelHeight: 400)
        check("scale_hotplug_changes_identity_topology", topology.signature != DisplaySnapshot(displays: [rescaled, right]).signature)
        let search: [String: Any] = ["text": "搜索", "bounds": rectJSON(CGRect(x: -70, y: 35, width: 30, height: 10))]
        let send: [String: Any] = ["text": "发送", "bounds": rectJSON(CGRect(x: 60, y: 90, width: 30, height: 10))]
        for width in [855.0, 932.0] {
            let window = CGRect(x: -500, y: -100, width: width, height: 1000)
            let band = visualSubmitHeader(window)
            check("recipient_band_fixed_sidebar_\(Int(width))", band.minX == window.minX + 326 && band.minY == window.minY + 5 && band.maxY == window.minY + 50)
            check("recipient_band_excludes_body_\(Int(width))", !pointIsInsideRect(CGPoint(x: band.midX, y: window.minY + 55), band))
        }
        check("recipient_band_rejects_too_narrow_window", visualSubmitHeader(CGRect(x: 0, y: 0, width: 342, height: 500)).isNull)
        check("two_anchors_on_different_screens_verify", visualAnchorsVerified(["搜索", "发送"], rows: [search, send], confirmed: true))
        let gapFiltered = [search, send].filter { visualCovered(try! visualRect($0["bounds"]), by: gap.coverage) }
        check("gap_anchor_never_fabricates_target_verified", !visualAnchorsVerified(["搜索", "发送"], rows: gapFiltered, confirmed: true))
        func frame(_ index: Int, _ serial: Int, _ time: Double, _ complete: Double? = nil, _ idle: Bool = false) -> VisualFrame {
            VisualFrame(image: images[index], completeSerial: serial, time: time, completeTime: complete ?? time, idleConfirmed: idle)
        }
        let group = VisualFrameGroup(outputs: [], plan: plan)
        let first = group.combine([(1, 1, frame(0, 1, 10), nil), (1, 1, frame(1, 1, 10), nil)], now: 10)
        check("all_fragments_make_first_composite", first.2?.completeSerial == 2 && first.2?.capturedRegions?.count == 2)
        let idle = group.combine([(2, 1, frame(0, 1, 11, 10, true), nil), (2, 1, frame(1, 1, 11, 10, true), nil)], now: 11)
        check("idle_liveness_never_new_complete_serial", idle.2?.completeSerial == 2 && idle.2?.time == 11)
        let partial = group.combine([(3, 2, frame(0, 2, 12), nil), (2, 1, frame(1, 1, 11, 10, true), nil)], now: 12)
        check("new_component_waits_other_component_liveness", partial.2?.completeSerial == 2)
        let fresh = group.combine([(3, 2, frame(0, 2, 12), nil), (3, 1, frame(1, 1, 12.1, 10, true), nil)], now: 12.1)
        check("complete_plus_confirmed_unchanged_fragment_advances", fresh.2?.completeSerial == 3 && fresh.2?.time == 12)
        let stale = group.combine([(4, 2, frame(0, 2, 15, 12, true), nil), (3, 1, frame(1, 1, 12.1, 10, true), nil)], now: 15)
        check("one_stale_fragment_does_not_renew_composite", stale.2.map { 15 - $0.time > 2 } == true)
        group.requireComplete(after: [2, 1])
        check("refresh_requires_every_fragment_new_complete", group.combine([(5, 3, frame(0, 3, 16), nil), (4, 1, frame(1, 1, 16, 10, true), nil)], now: 16).2 == nil)
        check("all_new_complete_after_refresh_accepted", group.combine([(5, 3, frame(0, 3, 16), nil), (5, 2, frame(1, 2, 16), nil)], now: 16).2?.completeSerial == 5)
        let invalid = group.combine([(6, 3, nil, "topology changed"), (6, 2, frame(1, 2, 16), nil)], now: 16)
        check("one_fragment_failure_invalidates_whole_frame", invalid.2 == nil && invalid.3 != nil)
        let visual = VisualDesktop(), ax = AXUIElementCreateApplication(getpid())
        let id = VisualIdentity(pid: getpid(), windowID: 1, frame: gap.window, topology: gap.topology.signature)
        let gapFrame = VisualFrame(image: gapImage, completeSerial: 1, time: 16, completeTime: 16, idleConfirmed: false, capturedRegions: gap.coverage)
        let snap = VisualSnapshot(id: "test", identity: id, frame: gapFrame, created: 16, focusedWindow: ax, focusedFrame: gap.window, focusedTitle: "微信", rows: [], anchors: [], confirmed: true, confirmationSource: "synthetic")
        let control: [String: Any] = ["control_kind": "chat_composer", "control_rect": rectJSON(CGRect(x: -20, y: 23, width: 40, height: 10)), "confirm_control": true]
        check("actual_input_control_guard_denies_partial_visibility", code { _ = try visual.control(control, snapshot: snap, input: true) } == "visual_control_not_fully_visible")
        var icon = control.merging(["command": "visual_click", "control_kind": "navigation", "navigation_target_kind": "icon"]) { _, new in new }
        check("icon_control_gap_coverage_denied", code { _ = try visual.control(icon, snapshot: snap, input: false) } == "visual_control_not_fully_visible")
        icon["control_rect"] = rectJSON(CGRect(x: -90, y: 23, width: 20, height: 10))
        check("icon_control_visible_region_accepted", code { _ = try visual.control(icon, snapshot: snap, input: false) } == "none")
        check("icon_cannot_be_used_for_typing", code { _ = try visual.control(icon, snapshot: snap, input: true) } == "visual_control_unconfirmed")
        icon["control_rect"] = rectJSON(CGRect(x: -150, y: 23, width: 20, height: 10))
        check("icon_control_outside_window_denied", code { _ = try visual.control(icon, snapshot: snap, input: false) } == "visual_region_outside_window")
        check("no_synthetic_test_starts_capture", visual.stream == nil && visual.streams.isEmpty)
    } catch { cases.append(["name": "unexpected_error", "passed": false, "error": String(describing: error)]) }
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count, "cases": cases, "capture_executed": false, "events_posted": 0]
}

func visualVisibilitySelfTests(_ fixture: String?) -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]) }
    func rgba(_ image: CGImage) -> CGImage {
        let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return c.makeImage()!
    }
    func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let d = image.dataProvider!.data!; return CFDataGetBytePtr(d)![y * image.bytesPerRow + x * 4 + 3]
    }
    let window = CGRect(x: 1350, y: 33, width: 855, height: 1079)
    let regions = [CGRect(x: 1350, y: 33, width: 442, height: 1079), CGRect(x: 1792, y: 33, width: 413, height: 1079)]
    let id = VisualIdentity(pid: 83927, windowID: 26955, frame: window, topology: "saved-two-display-case")
    let c = CGContext(data: nil, width: 1710, height: 2158, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1710, height: 2158))
    let solid = VisualFrame(image: c.makeImage()!, completeSerial: 10, time: 20, completeTime: 19, idleConfirmed: true, capturedRegions: regions)
    let clipped = visualVerifiedCoverage(solid, identity: id) { $0.x >= 1792 ? .foreign : .notImplemented }
    check("actual_AX_foreign_right_overrides_misleading_CG_bounds", clipped == [regions[0]])
    check("Qt_left_notImplemented_preserves_isolated_opaque_target", clipped.contains(regions[0]))
    check("both_actual_target_fragments_supported", visualVerifiedCoverage(solid, identity: id, hit: { _ in .target }) == regions)
    check("unavailable_hit_does_not_become_positive_coverage", visualVerifiedCoverage(solid, identity: id, hit: { _ in .unavailable }).isEmpty)
    check("foreign_hit_denies_click_despite_CG_front_PID", !visualOwnershipAllowsPoint(.foreign))
    check("AX_failure_denies_click", !visualOwnershipAllowsPoint(.unavailable))
    var coverageDiagnostic: [[String: Any]] = []
    let diagnosed = visualVerifiedCoverage(solid, identity: id, diagnostic: { coverageDiagnostic.append($0) }) { $0.x >= 1792 ? .foreign : .notImplemented }
    check("diagnostics_do_not_relax_coverage", diagnosed == clipped)
    check("explicit_diagnostics_report_format_and_all_ten_samples", coverageDiagnostic.count == 11 && coverageDiagnostic[0]["format_supported"] as? Bool == true)
    check("diagnostics_identify_AX_foreign_rejections", coverageDiagnostic.filter { $0["reason"] as? String == "AX_foreign" }.count == 5)
    var coverageSummary: [String: Any] = [:], summaryHitCalls = 0
    let summarized = visualVerifiedObservedCoverage(solid, identity: id, summary: { coverageSummary = $0 }) { point in
        summaryHitCalls += 1
        return (point.x >= 1792 ? .foreign : .notImplemented,
            ["ax_hit_result": 0, "hit_pid": 123, "ownership_proof": "no_public_relation_to_selected_main",
             "nodes": [["text": "PRIVATE_AX_TEXT"]], "title": "PRIVATE_TITLE"])
    }
    check("metadata_summary_preserves_coverage_and_short_circuit", summarized == clipped && summaryHitCalls == 6 && coverageSummary["sample_count"] as? Int == 6 && coverageSummary["AX_hit_count"] as? Int == 6)
    let failedSample = coverageSummary["first_failed_sample"] as? [String: Any] ?? [:]
    check("metadata_summary_identifies_first_failed_sample", failedSample["hit_ownership"] as? String == "foreign" && failedSample["alpha"] as? Int == 255 && failedSample["hit_pid"] as? Int == 123 && failedSample["point"] != nil)
    check("metadata_summary_excludes_AX_graph_and_text", failedSample["nodes"] == nil && failedSample["title"] == nil && failedSample["ownership_proof"] as? String == "no_public_relation_to_selected_main")
    let pointMetadata = visualPointRejectionDiagnostic("CG_point_coverage", point: CGPoint(x: 1400, y: 45), identity: id,
        screenWindows: [], dockRegions: nil, searchOverlay: nil)
    check("point_failure_metadata_binds_CG_branch_and_target", pointMetadata["branch"] as? String == "CG_point_coverage" && pointMetadata["target_pid"] as? Int32 == id.pid && pointMetadata["window_id"] as? UInt32 == id.windowID && pointMetadata["point"] != nil && pointMetadata["AX_observation"] == nil && pointMetadata["dock_regions"] is NSNull)
    let pointAXMetadata = visualPointRejectionDiagnostic("AX_hit_ownership", point: CGPoint(x: 1400, y: 45), identity: id,
        screenWindows: [], dockRegions: Array(repeating: window, count: 65), searchOverlay: nil,
        observation: (.foreign, ["ax_hit_result": 0, "hit_pid": 99, "ownership_proof": "no_public_relation_to_selected_main",
            "title": "PRIVATE_POINT_TITLE", "nodes": Array(repeating: ["role": "AXWindow", "pid": 99, "bounds": rectJSON(window),
                "accepted": "CFEqual_selected_main_AXCloseButton", "title": "PRIVATE_POINT_TITLE", "text": "PRIVATE_POINT_TEXT", "links": ["PRIVATE_POINT_LINK"]] as [String: Any], count: 9)]))
    let pointAX = pointAXMetadata["AX_observation"] as? [String: Any] ?? [:]
    let pointJSON = String(data: try! JSONSerialization.data(withJSONObject: pointAXMetadata), encoding: .utf8)!
    check("point_failure_metadata_bounds_geometry_and_nodes", (pointAXMetadata["dock_regions"] as? [[String: Double]])?.count == 64 && pointAXMetadata["dock_regions_truncated"] as? Bool == true && (pointAX["ownership_nodes"] as? [[String: Any]])?.count == 8 && pointAX["nodes_truncated"] as? Bool == true)
    check("point_failure_metadata_keeps_proof_without_text_or_links", pointAX["hit_ownership"] as? String == "foreign" && pointAX["hit_pid"] as? Int == 99 && pointJSON.contains("CFEqual_selected_main_AXCloseButton") && !pointJSON.contains("PRIVATE_POINT") && pointAX["nodes"] == nil)
    let pointMainCG: [String: Any] = [kCGWindowNumber as String: id.windowID, kCGWindowOwnerPID as String: id.pid,
        kCGWindowBounds as String: window.dictionaryRepresentation, kCGWindowAlpha as String: 1]
    let pointCursorCG: [String: Any] = [kCGWindowNumber as String: 91, kCGWindowOwnerPID as String: 88,
        kCGWindowOwnerName as String: "Window Server", kCGWindowLayer as String: Int(CGWindowLevelForKey(.cursorWindow)),
        kCGWindowBounds as String: window.dictionaryRepresentation, kCGWindowAlpha as String: 1]
    func pointCGMatches(_ blockers: [[String: Any]]) -> Bool {
        visualPointTargetMatches(CGPoint(x: 1400, y: 45), identity: id, rows: blockers + [pointMainCG],
            dockPID: nil, dockRegions: nil, displays: [window])
    }
    check("point_guard_ignores_same_system_cursor_as_capture", pointCGMatches([pointCursorCG]))
    var pointWrongNameCG = pointCursorCG; pointWrongNameCG[kCGWindowOwnerName as String] = "Other application"
    var pointWrongLayerCG = pointCursorCG; pointWrongLayerCG[kCGWindowLayer as String] = 0
    check("point_guard_rejects_cursor_signature_impostors", !pointCGMatches([pointWrongNameCG]) && !pointCGMatches([pointWrongLayerCG]))
    check("point_guard_cursor_does_not_hide_other_occluder", !pointCGMatches([pointCursorCG, pointWrongLayerCG]))
    var emptyCoverage = solid; emptyCoverage.capturedRegions = []
    var emptySummary: [String: Any] = [:], emptyHits = 0
    let emptyResult = visualVerifiedObservedCoverage(emptyCoverage, identity: id, summary: { emptySummary = $0 }) { _ in emptyHits += 1; return (.target, [:]) }
    check("metadata_summary_distinguishes_empty_CG_coverage_without_AX", emptyResult.isEmpty && emptyHits == 0 && emptySummary["input_region_count"] as? Int == 0 && emptySummary["sample_count"] as? Int == 0 && emptySummary["AX_hit_count"] as? Int == 0 && emptySummary["first_failed_sample"] is NSNull)

    check("Qt_known_unsupported_not_equal_foreign", visualOwnershipAllowsPoint(.notImplemented))
    do {
        let emptyMask = try visualMaskImage(solid.image, window: window, coverage: [])
        check("unknown_visibility_masks_every_pixel", alpha(emptyMask, 300, 1000) == 0 && alpha(emptyMask, 1200, 1000) == 0)
        let masked = try visualMaskImage(solid.image, window: window, coverage: clipped)
        check("right_fragment_pixels_removed_before_OCR", alpha(masked, 1200, 1000) == 0 && alpha(masked, 300, 1000) == 255)
        let isolated = VisualFrame(image: masked, completeSerial: 10, time: 20, completeTime: 19, idleConfirmed: true, capturedRegions: regions)
        check("transparent_target_capture_not_accepted_on_Qt_unknown", visualVerifiedCoverage(isolated, identity: id, hit: { _ in .notImplemented }) == [regions[0]])
        check("transparent_pixels_not_resurrected_by_target_hit", visualVerifiedCoverage(isolated, identity: id, hit: { _ in .target }) == [regions[0]])
        var alphaDiagnostic: [[String: Any]] = [], alphaHitCalls = 0
        let alphaCoverage = visualVerifiedCoverage(isolated, identity: id, diagnostic: { alphaDiagnostic.append($0) }) { _ in alphaHitCalls += 1; return .target }
        check("raw_alpha_diagnostics_distinguish_transparency_from_AX", alphaCoverage == [regions[0]] && alphaDiagnostic.filter { $0["reason"] as? String == "transparent_pixel" }.count == 5)
        check("transparent_diagnostic_samples_do_not_hit_other_apps", alphaHitCalls == 5)
        var alphaSummary: [String: Any] = [:], alphaSummaryHits = 0
        let summarizedAlpha = visualVerifiedObservedCoverage(isolated, identity: id, summary: { alphaSummary = $0 }) { _ in alphaSummaryHits += 1; return (.target, [:]) }
        check("metadata_summary_counts_transparent_sample_without_AX", summarizedAlpha == [regions[0]] && alphaSummaryHits == 5 && alphaSummary["sample_count"] as? Int == 6 && alphaSummary["AX_hit_count"] as? Int == 5 && (alphaSummary["first_failed_sample"] as? [String: Any])?["hit_ownership"] as? String == "not_queried_transparent_pixel")
        let opaque = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        let wrongFormat = VisualFrame(image: opaque, completeSerial: 1, time: 1, completeTime: 1, idleConfirmed: false, capturedRegions: regions)
        var formatDiagnostic: [[String: Any]] = [], formatHits = 0
        check("unsupported_format_has_explicit_diagnostic", visualVerifiedCoverage(wrongFormat, identity: id, diagnostic: { formatDiagnostic.append($0) }) { _ in formatHits += 1; return .target }.isEmpty && formatDiagnostic.first?["reason"] as? String == "unsupported_pixel_format" && formatHits == 0)
        var formatSummary: [String: Any] = [:]
        _ = visualVerifiedObservedCoverage(wrongFormat, identity: id, summary: { formatSummary = $0 }) { _ in formatHits += 1; return (.target, [:]) }
        check("metadata_summary_reports_format_rejection_without_AX", formatSummary["rejection_reason"] as? String == "unsupported_pixel_format" && formatSummary["AX_hit_count"] as? Int == 0 && formatHits == 0)

        check("complete_header_not_claimed_from_clipped_prefix", !visualCovered(visualSubmitHeader(window), by: clipped))
        check("complete_composer_not_claimed_from_left_fragment", !visualCovered(CGRect(x: 1676, y: 900, width: 513, height: 180), by: clipped))
        check("complete_left_search_remains_readable", visualCovered(CGRect(x: 1420, y: 40, width: 180, height: 35), by: clipped))
        check("cross_seam_rect_is_partial", !visualCovered(CGRect(x: 1775, y: 300, width: 50, height: 40), by: clipped))
        let visual = VisualDesktop()
        let frame = VisualFrame(image: masked, completeSerial: 10, time: 20, completeTime: 19, idleConfirmed: true, capturedRegions: clipped)
        check("masked_frames_preserve_serial_age_and_idle_proof", frame.completeSerial == solid.completeSerial && frame.time == solid.time && frame.completeTime == solid.completeTime && frame.idleConfirmed == solid.idleConfirmed)
        check("entire_invisible_ROI_returns_no_OCR", try visual.ocrUncached(frame, identity: id, region: regions[1]).isEmpty)
        let native = AXUIElementCreateApplication(getpid())
        let snap = VisualSnapshot(id: "test", identity: id, frame: frame, created: 20, focusedWindow: native, focusedFrame: window, focusedTitle: "微信",
            rows: [], anchors: [], confirmed: true, confirmationSource: "synthetic")
        do {
            _ = try visual.control(["control_kind": "chat_composer", "confirm_control": true,
                "control_rect": rectJSON(CGRect(x: 1676, y: 900, width: 513, height: 180))], snapshot: snap, input: true)
            check("partial_composer_input_refused_before_events", false)
        } catch { check("partial_composer_input_refused_before_events", (error as? HelperError)?.code == "visual_control_not_fully_visible") }
        let topology = DisplaySnapshot(displays: [
            DisplayGeometry(id: 69734662, bounds: CGRect(x: 0, y: 0, width: 1792, height: 1120), pixelWidth: 3584, pixelHeight: 2240, main: true),
            DisplayGeometry(id: 487616619, bounds: CGRect(x: 1792, y: 0, width: 1920, height: 1200), pixelWidth: 1920, pixelHeight: 1200)])
        visual.capturePlan = try VisualCapturePlan(window: window, topology: topology)
        let metadata = visual.json(snap)
        check("partial_window_reported_explicitly", metadata["window_fully_visible"] as? Bool == false)
        check("captured_regions_only_contains_actual_side", (metadata["captured_regions"] as? [[String: Double]])?.count == 1)
        check("visible_fragment_count_excludes_zero_area_seam", metadata["display_fragment_count"] as? Int == 1 && metadata["capture_stream_count"] as? Int == 0)
        if let fixture {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: fixture) as CFURL, nil),
                  let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw fail("fixture_unavailable", "Saved seam PNG not available") }
            let saved = VisualFrame(image: rgba(raw), completeSerial: 11, time: 21, completeTime: 21, idleConfirmed: false, capturedRegions: regions)
            let savedCoverage = visualVerifiedCoverage(saved, identity: id) { $0.x >= 1792 ? .foreign : .notImplemented }
            let savedMask = try visualMaskImage(saved.image, window: window, coverage: savedCoverage)
            let safe = VisualFrame(image: savedMask, completeSerial: 11, time: 21, completeTime: 21, idleConfirmed: false, capturedRegions: savedCoverage)
            let rows = try visual.ocrUncached(safe, identity: id, region: window)
            check("saved_real_failure_left_side_retained", savedCoverage == [regions[0]] && !rows.isEmpty)
            check("saved_real_failure_no_Codex_text_returned", !rows.contains { ($0["text"] as? String ?? "").lowercased().contains("codex") })
            check("saved_real_failure_no_right_app_rows", rows.allSatisfy { (try? visualRect($0["bounds"]).maxX).map { $0 <= 1792 } ?? false })
            check("saved_real_failure_clipped_chat_header_suppressed", rows.allSatisfy { (try? visualRect($0["bounds"])).map { $0.intersection(visualSubmitHeader(window)).isNull } ?? false })
            let path = URL(fileURLWithPath: fixture).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dual-display-native-fix/masked-seam-fixture.png")
            // Save only the regression mask in this package's owned directory.
            if let dest = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, savedMask, nil); check("saved_regression_mask_written", CGImageDestinationFinalize(dest))
            }
        }
        check("pure_validation_never_started_a_capture_stream", visual.stream == nil && visual.streams.isEmpty)
    } catch { cases.append(["name": "unexpected_error", "passed": false, "error": String(describing: error)]) }
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count, "cases": cases,
        "capture_executed": false, "events_posted": 0, "live_AX_probe_executed": false, "saved_PNG_fixture_used": fixture != nil]
}


func visualWindowSnapshotSelfTests() -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]) }
    func code(_ operation: () throws -> Void) -> String? {
        do { try operation(); return nil } catch { return (error as? HelperError)?.code ?? "unexpected" }
    }
    func image(_ width: Int, _ height: Int, blue: Bool) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [blue ? 0 : 1, 0, blue ? 1 : 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height)); return context.makeImage()!
    }
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data!, offset = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data)! + offset, count: 4))
    }
    do {
        let layout = DisplaySnapshot(displays: [
            DisplayGeometry(id: 1, bounds: CGRect(x: -900, y: 0, width: 900, height: 700), pixelWidth: 1800, pixelHeight: 1400, main: true),
            DisplayGeometry(id: 2, bounds: CGRect(x: 0, y: 0, width: 800, height: 700), pixelWidth: 800, pixelHeight: 700)])
        let window = CGRect(x: -100, y: 20, width: 300, height: 400)
        let plan = try VisualCapturePlan(window: window, topology: layout)
        let red = image(plan.width, plan.height, blue: false), blue = image(plan.width, plan.height, blue: true)
        let first = try visualExactWindowFrame(red, plan: plan, previousSerial: 0, after: -1, requestStarted: 20, completed: 20.1)
        let second = try visualExactWindowFrame(blue, plan: plan, previousSerial: first.completeSerial, after: first.completeSerial, requestStarted: 21, completed: 21.1)
        check("mixed_scale_negative_global_bounds_keep_exact_pixel_mapping", plan.width == 600 && plan.height == 800 && first.capturedRegions == plan.coverage && plan.fragments.count == 2)
        check("new_request_uses_new_image_not_previous_pixels", pixel(first.image, 10, 10) == [255, 0, 0, 255] && pixel(second.image, 10, 10) == [0, 0, 255, 255])
        check("completed_request_advances_serial", first.completeSerial == 1 && second.completeSerial == 2)
        check("age_starts_at_request_not_completion_or_guard", second.time == 21 && second.completeTime == 21.1)
        check("snapshot_never_claims_idle_stream_liveness", !second.idleConfirmed)
        check("window_pixels_normalised_RGBA_without_resizing", second.image.alphaInfo == .premultipliedLast && second.image.width == blue.width && second.image.height == blue.height)
        check("stale_request_rejected", code { _ = try visualExactWindowFrame(blue, plan: plan, previousSerial: 2, after: 2, requestStarted: 20, completed: 22.001) } == "visual_frame_timeout")
        check("backwards_clock_rejected", code { _ = try visualExactWindowFrame(blue, plan: plan, previousSerial: 2, after: 2, requestStarted: 22, completed: 21) } == "visual_frame_timeout")
        check("nonfinite_time_rejected", code { _ = try visualExactWindowFrame(blue, plan: plan, previousSerial: 2, after: 2, requestStarted: .nan, completed: 21) } == "visual_frame_timeout")
        check("nonadvancing_serial_rejected", code { _ = try visualExactWindowFrame(blue, plan: plan, previousSerial: 2, after: 3, requestStarted: 20, completed: 20.1) } == "visual_frame_timeout")
        check("serial_overflow_rejected", code { _ = try visualExactWindowFrame(blue, plan: plan, previousSerial: Int.max, after: -1, requestStarted: 20, completed: 20.1) } == "visual_frame_timeout")
        check("different_dimensions_rejected", code { _ = try visualExactWindowFrame(image(10, 10, blue: false), plan: plan, previousSerial: 2, after: 2, requestStarted: 20, completed: 20.1) } == "visual_target_changed")
        let id = VisualIdentity(pid: 83927, windowID: 26955, frame: window, topology: layout.signature)
        let visible = visualVerifiedCoverage(second, identity: id) { $0.x >= 0 ? .foreign : .notImplemented }
        check("exact_window_pixels_still_require_actual_display_visibility", visible.count == 1 && visible[0].maxX == 0)
        check("foreign_display_does_not_authorize_complete_composer", !visualCovered(CGRect(x: -10, y: 300, width: 100, height: 100), by: visible))
        let gapLayout = DisplaySnapshot(displays: [
            DisplayGeometry(id: 1, bounds: CGRect(x: -900, y: 0, width: 900, height: 700), pixelWidth: 1800, pixelHeight: 1400, main: true),
            DisplayGeometry(id: 2, bounds: CGRect(x: 100, y: 0, width: 800, height: 700), pixelWidth: 800, pixelHeight: 700)])
        let gapPlan = try VisualCapturePlan(window: window, topology: gapLayout)
        let gapFrame = try visualExactWindowFrame(blue, plan: gapPlan, previousSerial: 2, after: 2, requestStarted: 23, completed: 23.1)
        let masked = try visualMaskImage(gapFrame.image, window: window, coverage: gapFrame.capturedRegions!)
        check("display_gap_remains_transparent", pixel(masked, 300, 200)[3] == 0 && !visualCovered(window, by: gapFrame.capturedRegions!))
        let rightWindow = CGRect(x: 150, y: 20, width: 300, height: 400)
        let rightPlan = try VisualCapturePlan(window: rightWindow, topology: layout)
        check("single_1x_display_remains_1x", rightPlan.width == 300 && rightPlan.height == 400)
        let visual = VisualDesktop()
        check("pure_constructor_starts_no_capture", visual.stream == nil && visual.streams.isEmpty && !visual.captureReady)
    } catch { cases.append(["name": "unexpected_error", "passed": false, "error": String(describing: error)]) }
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count, "cases": cases,
        "capture_executed": false, "events_posted": 0, "live_AX_probe_executed": false]
}


func visualSearchTextSelfTests(_ fixture: String?) -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]) }
    func code(_ operation: () throws -> Void) -> String? {
        do { try operation(); return nil } catch { return (error as? HelperError)?.code ?? "unexpected" }
    }
    do {
        let window = CGRect(x: 65, y: 33, width: 855, height: 1079)
        let control = CGRect(x: 135, y: 48.106, width: 210, height: 26.975)
        let text = try visualSearchTextRegion(window: window, control: control)
        check("observed_complete_text_lane", text == CGRect(x: 156, y: 48.106, width: 156, height: 68 - 48.106))
        check("magnifier_outside_text_lane", !pointIsInsideRect(CGPoint(x: 146, y: 61), text))
        check("clear_button_outside_text_lane", !pointIsInsideRect(CGPoint(x: 324, y: 61), text))
        check("complete_observed_query_inside_lane", visualContains(text, CGRect(x: 163, y: 55, width: 144, height: 13)))
        let negativeWindow = window.offsetBy(dx: -1000, dy: -600), negativeControl = control.offsetBy(dx: -1000, dy: -600)
        let moved = try visualSearchTextRegion(window: negativeWindow, control: negativeControl)
        let translated = text.offsetBy(dx: -1000, dy: -600)
        check("negative_global_coordinates_preserved", abs(moved.minX - translated.minX) < 0.000001 && abs(moved.minY - translated.minY) < 0.000001 && abs(moved.width - translated.width) < 0.000001 && abs(moved.height - translated.height) < 0.000001)
        let wider = CGRect(x: 65, y: 33, width: 932, height: 1079)
        check("fixed_sidebar_preserved_for_other_observed_width", try visualSearchTextRegion(window: wider, control: control) == text)
        check("partial_caller_control_refused", code { _ = try visualSearchTextRegion(window: window, control: CGRect(x: 180, y: 48, width: 100, height: 27)) } == "visual_search_value_region_unavailable")
        check("old_global_control_after_window_move_refused", code { _ = try visualSearchTextRegion(window: window.offsetBy(dx: 1000, dy: 0), control: control) } == "visual_search_value_region_unavailable")
        check("literal_Q_x_ampersand_preserved", visualNormalizedText("Q查询x&") == "Q查询x&")
        check("extra_real_query_character_still_fails_exact_match", visualNormalizedText("查询x") != visualNormalizedText("查询"))
        if let fixture {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: fixture) as CFURL, nil),
                  let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw fail("fixture_unavailable", "Saved search PNG not available") }
            let layout = DisplaySnapshot(displays: [DisplayGeometry(id: 69734662, bounds: CGRect(x: 0, y: 0, width: 1792, height: 1120), pixelWidth: 3584, pixelHeight: 2240, main: true)])
            let plan = try VisualCapturePlan(window: window, topology: layout)
            let frame = try visualExactWindowFrame(raw, plan: plan, previousSerial: 0, after: -1, requestStarted: 20, completed: 20.1)
            let id = VisualIdentity(pid: 83927, windowID: 26955, frame: window, topology: layout.signature)
            let visual = VisualDesktop()
            let before = try visual.ocrUncached(frame, identity: id, region: control)
            let after = try visual.ocrUncached(frame, identity: id, region: text)
            let complete = "保利上城（东区）10-2单元"
            check("saved_original_control_reproduces_icon_contamination", visualNormalizedText(before.compactMap { $0["text"] as? String }.joined(separator: "\n")) != visualNormalizedText(complete))
            check("saved_text_lane_verifies_complete_query_without_string_trimming", visualNormalizedText(after.compactMap { $0["text"] as? String }.joined(separator: "\n")) == visualNormalizedText(complete))
            check("saved_text_glyph_bounds_fully_inside_lane", after.allSatisfy { (try? visualRect($0["bounds"])).map { visualContains(text.insetBy(dx: -0.5, dy: -0.5), $0) } ?? false })
            check("offline_test_never_starts_capture", !visual.captureReady && visual.stream == nil)
        }
    } catch { cases.append(["name": "unexpected_error", "passed": false, "error": String(describing: error)]) }
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count, "cases": cases,
        "capture_executed": false, "events_posted": 0, "live_AX_probe_executed": false, "saved_PNG_fixture_used": fixture != nil]
}

func visual34SelfTests(_ fixture: String?) -> [String:Any] {
    var cases:[[String:Any]]=[]
    func check(_ name:String,_ passed:Bool){cases.append(["name":name,"passed":passed])}
    let window=CGRect(x:65,y:33,width:855,height:1079),identity=VisualIdentity(pid:83927,windowID:26955,frame:CGRect(x:65,y:33,width:855,height:1079),topology:"pure")
    func row(_ id:UInt32,_ pid:Int32,_ box:CGRect,_ layer:Int,_ title:String="")->[String:Any]{[kCGWindowNumber as String:NSNumber(value:id),kCGWindowOwnerPID as String:NSNumber(value:pid),kCGWindowBounds as String:box.dictionaryRepresentation,kCGWindowLayer as String:layer,kCGWindowName as String:title,kCGWindowAlpha as String:1,kCGWindowIsOnscreen as String:true]}
    do {
        let main=row(26955,83927,window,0,"微信"),hint=CGRect(x:527,y:956,width:84,height:77),popup=CGRect(x:113,y:68,width:368,height:430)
        let unknown=row(26951,83927,hint,3),pop=row(30825,83927,popup,3)
        check("unknown_indicator_does_not_globally_reject_read",try visualSearchOverlay([unknown,main],identity:identity)==nil)
        let selected=try visualSearchOverlay([pop,unknown,main],identity:identity)
        check("known_popup_remains_unique_with_other_layer3",selected?.windowID==30825)
        let list=try visualScreenWindows([pop,unknown,main],identity:identity,displays:[CGRect(x:0,y:0,width:1792,height:1120)],dockPID:nil)
        check("two_same_pid_front_windows_identity_bound",list.count==2 && list[1].inputHintCandidate)
        let coverage=try visualScreenCoverage([window],windows:list,identity:identity,overlay:selected,dockRegions:nil)
        check("hint_pixel_candidate_requires_separate_recognition",coverage==[window])
        let foreign=VisualScreenWindow(id:99,pid:770,frame:CGRect(x:400,y:300,width:200,height:100),layer:3,alpha:1,emptyTitle:true,dockSurface:false)
        let blocked=try visualScreenCoverage([window],windows:[foreign]+list,identity:identity,overlay:selected,dockRegions:nil)
        check("foreign_window_subtracted_even_inside_popup",!visualCovered(foreign.frame,by:blocked))
        let alias=VisualScreenWindow(id:98,pid:83927,frame:CGRect(x:400,y:300,width:700,height:500),layer:0,alpha:1,emptyTitle:false,dockSurface:false)
        let preview=try visualScreenCoverage([window],windows:[alias],identity:identity,overlay:nil,dockRegions:nil)
        check("own_file_preview_is_never_main_capture",!visualCovered(alias.frame.intersection(window),by:preview))
        let small=VisualScreenWindow(id:97,pid:83927,frame:CGRect(x:71,y:38,width:52,height:20),layer:3,alpha:1,emptyTitle:true,dockSurface:false)
        let smallCoverage=try visualScreenCoverage([window],windows:[small],identity:identity,overlay:nil,dockRegions:nil)
        check("same_pid_untrusted_dialog_only_excludes_local_bounds",smallCoverage.count==4 && visualCovered(CGRect(x:400,y:900,width:400,height:150),by:smallCoverage))
        check("small_dialog_never_claimed_visible",!visualCovered(small.frame,by:smallCoverage))
        let hidden=VisualScreenWindow(id:96,pid:83927,frame:CGRect(x:264,y:45,width:84,height:77),layer:3,alpha:1,emptyTitle:false,dockSurface:false)
        let popWindow=list[0]
        let behind=try visualScreenCoverage([window],windows:[popWindow,hidden],identity:identity,overlay:selected,dockRegions:nil)
        check("popup_global_alpha_does_not_prove_opaque_interior",!visualCovered(popup,by:behind))
        check("unknown_visible_portion_above_popup_remains_excluded",!visualCovered(CGRect(x:264,y:45,width:84,height:20),by:behind))
        let dock=VisualScreenWindow(id:95,pid:55,frame:CGRect(x:0,y:0,width:1792,height:1120),layer:20,alpha:1,emptyTitle:false,dockSurface:true)
        do{_ = try visualScreenCoverage([window],windows:[dock],identity:identity,overlay:nil,dockRegions:nil);check("unknown_dock_geometry_rejected",false)}catch{check("unknown_dock_geometry_rejected",true)}
        let dockCoverage=try visualScreenCoverage([window],windows:[dock],identity:identity,overlay:nil,dockRegions:[CGRect(x:0,y:400,width:70,height:200)])
        check("known_dock_interactive_area_subtracted",!visualCovered(CGRect(x:65,y:410,width:10,height:10),by:dockCoverage))
        if let fixture,let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:fixture) as CFURL,nil),let full=CGImageSourceCreateImageAtIndex(source,0,nil) {
            let found=try visualInputHint(full,window:window,auxiliary:hint)
            check("real_84x77_alias_metadata_identifies_only_actual_blue_pill",found==CGRect(x:554,y:983,width:30,height:23))
            check("wrong_auxiliary_geometry_never_identifies_hint",try visualInputHint(full,window:window,auxiliary:hint.offsetBy(dx:10,dy:0))==nil)
            check("non_84x77_unknown_window_not_special_cased",try visualInputHint(full,window:window,auxiliary:hint.insetBy(dx:1,dy:0))==nil)
            if let found {
                let sx=Double(full.width)/window.width,sy=Double(full.height)/window.height
                let cleaned=try visualPaintNeutral(full,boxes:[CGRect(x:(found.minX-window.minX)*sx,y:(found.minY-window.minY)*sy,width:found.width*sx,height:found.height*sy)])
                let frame=VisualFrame(image:cleaned,completeSerial:1,time:0,completeTime:0,idleConfirmed:false,capturedRegions:[window])
                let visual=VisualDesktop(),composer=CGRect(x:395,y:959,width:500,height:140)
                let rows=try visual.ocrUncached(frame,identity:identity,region:composer),texts=rows.compactMap{$0["text"] as? String}
                check("real_marker_and_additional_year_preserved",texts.contains(where:{visualNormalizedText($0)=="双屏微信验收20261012年"}))
                check("only_verified_white_hint_glyph_removed",!texts.contains("拼"))
                let before=try visualRGBA(full),after=try visualRGBA(cleaned)
                let beforeData=before.dataProvider!.data!,afterData=after.dataProvider!.data!
                let a=CFDataGetBytePtr(beforeData)!,b=CFDataGetBytePtr(afterData)!
                let marker=CGRect(x:340*sx,y:930*sy,width:165*sx,height:20*sy)
                var same=true
                for y in Int(marker.minY)..<Int(marker.maxY){for x in Int(marker.minX)..<Int(marker.maxX){let i=y*before.bytesPerRow+x*4;if max(a[i],a[i+1],a[i+2])<150 {for k in 0..<4{if a[i+k] != b[i+k]{same=false}}}}}
                check("marker_black_ink_pixels_unchanged",same)
            }
            for scale in [2,1] {
                let sourceImage:CGImage
                if scale==2{sourceImage=full}else{let c=CGContext(data:nil,width:855,height:1079,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.interpolationQuality = .high;c.draw(full,in:CGRect(x:0,y:0,width:855,height:1079));sourceImage=c.makeImage()!}
                let frame=VisualFrame(image:sourceImage,completeSerial:1,time:0,completeTime:0,idleConfirmed:false,capturedRegions:[window])
                let rows=try VisualDesktop().ocrUncached(frame,identity:identity,region:CGRect(x:391,y:38,width:513,height:34))
                let title=rows.first{($0["text"] as? String ?? "").contains("业主群")}
                check("actual_badge_removed_and_full_count_preserved_\(scale)x",(scale==2 || title?["header_badge_removed"] as? Bool == true) && visualNormalizedText(title?["text"] as? String ?? "")=="保利上城（东区）10-2单元业主群（178）")
            }
            if let oldSource=CGImageSourceCreateWithURL(URL(fileURLWithPath:"/tmp/wechat33-group-live.png") as CFURL,nil),let old=CGImageSourceCreateImageAtIndex(oldSource,0,nil) {
                let oldWindow=window.offsetBy(dx:2,dy:0),oldID=VisualIdentity(pid:83927,windowID:26955,frame:oldWindow,topology:"pure")
                let f=VisualFrame(image:old,completeSerial:1,time:0,completeTime:0,idleConfirmed:false,capturedRegions:[oldWindow])
                let rows=try VisualDesktop().ocrUncached(f,identity:oldID,region:CGRect(x:393,y:38,width:513,height:34))
                let title=rows.first{($0["text"] as? String ?? "").contains("业主群")}
                check("polluted_real_2x_D_suffix_removed_by_pixel_signature",title?["header_badge_removed"] as? Bool == true && visualNormalizedText(title?["text"] as? String ?? "")=="保利上城（东区）10-2单元业主群（178）")
            }
            if let topSource=CGImageSourceCreateWithURL(URL(fileURLWithPath:"/tmp/wechat33-overlay-top.png") as CFURL,nil),let top=CGImageSourceCreateImageAtIndex(topSource,0,nil) {
                let topWindow=CGRect(x:65,y:33,width:500,height:180),smallHint=CGRect(x:264,y:45,width:84,height:77)
                let cap=try visualInputHint(top,window:topWindow,auxiliary:smallHint,frontPopup:popup)
                check("real_popup_visible_blue_cap_proven_without_alias_alpha",cap != nil && cap!.height<=6)
                check("partial_blue_cap_without_front_popup_not_recognised",try visualInputHint(top,window:topWindow,auxiliary:smallHint)==nil)
                if let cap {
                    let c=try visualPaintNeutral(top,boxes:[CGRect(x:(cap.minX-65)*2,y:(cap.minY-33)*2,width:cap.width*2,height:cap.height*2)],allowSearchFocusRing:true)
                    let id=VisualIdentity(pid:83927,windowID:26955,frame:topWindow,topology:"pure")
                    let f=VisualFrame(image:c,completeSerial:1,time:0,completeTime:0,idleConfirmed:false,capturedRegions:[topWindow])
                    let query=try VisualDesktop().ocrUncached(f,identity:id,region:CGRect(x:156,y:48.106,width:156,height:19.894))
                    check("visible_cap_mask_preserves_complete_query",query.contains{visualNormalizedText($0["text"] as? String ?? "")=="保利上城（东区）10-2单元"})
                }
            }
        }else{check("real_saved_fixture_available",false)}
    }catch{cases.append(["name":"unexpected_error","passed":false,"error":String(describing:error)])}
    return ["ok":cases.allSatisfy{$0["passed"] as? Bool == true},"case_count":cases.count,"cases":cases,"events_posted":0,"capture_executed":false,"live_AX_probe_executed":false]
}

func visualPrefixCaretInkSelfTests() -> [[String:Any]] {
    var cases:[[String:Any]]=[]
    func check(_ name:String,_ passed:Bool){cases.append(["name":"prefix_caret_ink_"+name,"passed":passed])}
    let window=CGRect(x:-300,y:100,width:500,height:300),control=CGRect(x:-250,y:140,width:400,height:100)
    let first=CGRect(x:-239.332,y:150.7897,width:149.353,height:16.079)
    let caret=CGRect(x:-239,y:150,width:2,height:16.5),right=CGRect(x:-235,y:152,width:7,height:12)
    func pixels(_ left:[CGRect]=[],rightInk:Bool=true,background:CGFloat=1,extraGreen:Bool=false)->CGImage {
        let c=CGContext(data:nil,width:1000,height:600,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setShouldAntialias(false)
        c.setFillColor(CGColor(gray:background,alpha:1));c.fill(CGRect(x:0,y:0,width:1000,height:600))
        func fill(_ r:CGRect,_ color:CGColor){c.setFillColor(color);c.fill(CGRect(x:(r.minX-window.minX)*2,y:600-(r.maxY-window.minY)*2,width:r.width*2,height:r.height*2))}
        for r in left {fill(r,CGColor(gray:0.1,alpha:1))}
        if rightInk {fill(right,CGColor(gray:0.1,alpha:1))}
        fill(caret,CGColor(red:0,green:0.65,blue:0.25,alpha:1))
        if extraGreen {fill(CGRect(x:-243,y:151,width:1,height:14),CGColor(red:0,green:0.65,blue:0.25,alpha:1))}
        return c.makeImage()!
    }
    func accepted(_ image:CGImage,_ bounds:CGRect?=nil)->Bool {visualPrefixCaretAtStart(image,window:window,control:control,firstText:bounds ?? first)}
    check("observed_OCR_overlap_needs_and_passes_same_frame_ink_proof",accepted(pixels()))
    for (name,ink) in [("I",CGRect(x:-241,y:152,width:1,height:12)),("l",CGRect(x:-240.5,y:152,width:0.5,height:12)),("dot",CGRect(x:-240.5,y:163.5,width:0.5,height:0.5))] {
        check("caret_after_narrow_\(name)_rejected",!accepted(pixels([ink])))
    }
    check("overlap_without_right_glyphs_rejected",!accepted(pixels(rightInk:false)))
    check("unknown_gray_or_dark_background_rejected",!accepted(pixels(background:0.7)))
    check("second_green_component_rejected",!accepted(pixels(extraGreen:true)))
    check("overlap_beyond_observed_near_left_bound_rejected",!accepted(pixels(),first.offsetBy(dx:-2,dy:0)))
    check("same_green_pixels_cannot_replace_full_value_proof",!visualPrefixCaretCandidate(pixels(),window:window,control:control,priorFirstText:first){false})
    check("fresh_capture_initial_budget",visualPrefixCaretCaptureBudget(remaining:3,previousDuration:nil))
    check("insufficient_warmup_budget_rejected",!visualPrefixCaretCaptureBudget(remaining:0.2,previousDuration:nil))
    check("insufficient_observed_capture_budget_rejected",!visualPrefixCaretCaptureBudget(remaining:0.8,previousDuration:1.1))
    check("remaining_budget_can_cover_previous_capture",visualPrefixCaretCaptureBudget(remaining:1.2,previousDuration:1.1))
    check("invalid_budget_rejected",!visualPrefixCaretCaptureBudget(remaining:.nan,previousDuration:nil))
    return cases
}

func visualPrefixDeletionSelfTests() -> [String:Any] {
    var cases:[[String:Any]]=[]
    func check(_ name:String,_ value:Bool){cases.append(["name":name,"passed":value])}
    func rejected(_ prefix:String,_ draft:String? = nil)->Bool{(try? visualPrefixDeletion(draft ?? prefix+"业务",prefix:prefix))==nil}
    let marker="双屏微信验收20261012年",business="业务文字，保留空格 A\n第二行🙂"
    do {
        let plan=try visualPrefixDeletion(marker+business,prefix:marker)
        check("authorised_marker_only_suffix_preserved_verbatim",plan.suffix==business && plan.count==15)
        check("full_prefix_is_complete_BMP_key_count",plan.count==marker.utf16.count)
        check("newline_emoji_and_spaces_in_suffix_are_not_rewritten",plan.suffix.utf16.elementsEqual(business.utf16))
        check("only_CR_LF_wrap_reflow_is_ignored",visualDraftSequence("业务一\n业务二\r\n尾")=="业务一业务二尾")
        check("spaces_in_business_suffix_are_preserved",visualDraftSequence("业 务") != visualDraftSequence("业务"))
        check("NBSP_is_not_discarded",visualDraftSequence("业\u{A0}务") != "业务")
        check("changed_business_character_cannot_pass_reflow",visualDraftSequence("业务一\n二") != visualDraftSequence("业务一\n三"))
        check("empty_prefix_rejected",rejected(""))
        check("sixty_five_char_prefix_rejected",rejected(String(repeating:"字",count:65)))
        check("sixty_four_char_prefix_allowed",try visualPrefixDeletion(String(repeating:"字",count:64)+"后",prefix:String(repeating:"字",count:64)).count==64)
        check("prefix_must_be_at_actual_start",rejected(marker,"业务"+marker))
        check("fullwidth_digit_not_equal_ASCII_marker",rejected(marker,"双屏微信验收２０２６１０１２年业务"))
        check("empty_suffix_is_explicitly_supported",try visualPrefixDeletion(marker,prefix:marker).suffix.isEmpty)
        for (name,prefix) in [("newline","前\n"),("space","前 "),("tab","前\t"),("surrogate_emoji","🙂"),("combining","e\u{301}"),("variation","字\u{FE0F}"),("ZWJ","字\u{200D}"),("BMP_symbol","☀"),("paragraph","字\u{2029}"),("format","字\u{200B}")] {
            check("unsafe_prefix_\(name)_rejected",rejected(prefix))
        }
        check("combining_suffix_cannot_join_last_prefix_grapheme",rejected("前","前\u{301}业务"))
        check("draft_limit_rejected",rejected("前","前"+String(repeating:"字",count:8192)))
        let visual=VisualDesktop()
        let request:[String:Any]=["command":"visual_key","snapshot_id":"test","control_kind":"chat_composer","confirm_control":true,"control_rect":["x":350,"y":800,"width":400,"height":100],"key":"clear_prefix","expected_draft":marker+business,"prefix":marker,"chat_title":"完整聊天标题","allow_submit":false]
        try visual.validate(request);check("valid_request_needs_no_capture_or_events",true)
        for (name,field,value) in [("search_control","control_kind","search" as Any),("Return_permission","allow_submit",true as Any),("modifier","modifiers",["cmd"] as Any),("empty_recipient","chat_title","" as Any)] {
            var changed=request;changed[field]=value
            do{try visual.validate(changed);check("invalid_\(name)_denied",false)}catch{check("invalid_\(name)_denied",true)}
        }
        let window=CGRect(x:-300,y:100,width:500,height:300),control=CGRect(x:-250,y:140,width:400,height:100),first=CGRect(x:-240,y:150,width:160,height:16)
        func image(_ rects:[CGRect],_ green:Bool=true)->CGImage {
            let c=CGContext(data:nil,width:1000,height:600,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:1000,height:600))
            c.setFillColor(green ? CGColor(red:0,green:0.65,blue:0.25,alpha:1):CGColor(gray:0,alpha:1))
            for r in rects{c.fill(CGRect(x:(r.minX-window.minX)*2,y:600-(r.maxY-window.minY)*2,width:r.width*2,height:r.height*2))};return c.makeImage()!
        }
        let start=CGRect(x:-242,y:149,width:1.5,height:18)
        check("real_style_green_caret_at_first_character_accepted",visualPrefixCaretAtStart(image([start]),window:window,control:control,firstText:first))
        check("caret_at_end_cannot_authorize_prefix_delete",!visualPrefixCaretAtStart(image([start.offsetBy(dx:160,dy:0)]),window:window,control:control,firstText:first))
        check("missing_caret_blocks_all_delete_events",!visualPrefixCaretAtStart(image([]),window:window,control:control,firstText:first))
        check("black_text_stroke_is_not_green_caret",!visualPrefixCaretAtStart(image([start],false),window:window,control:control,firstText:first))
        check("selection_highlight_is_not_thin_collapsed_caret",!visualPrefixCaretAtStart(image([CGRect(x:-245,y:149,width:180,height:18)]),window:window,control:control,firstText:first))
        check("two_possible_carets_are_not_unambiguous",!visualPrefixCaretAtStart(image([start,CGRect(x:-239.5,y:149,width:0.5,height:18)]),window:window,control:control,firstText:first))
        var fullProofCalls = 0
        let noCaret = visualPrefixCaretCandidate(image([]),window:window,control:control,priorFirstText:first) { fullProofCalls += 1; return true }
        check("caret_prefilter_missing_green_skips_all_OCR_proof", !noCaret && fullProofCalls == 0)
        let blackOnly = visualPrefixCaretCandidate(image([start],false),window:window,control:control,priorFirstText:first) { fullProofCalls += 1; return true }
        check("caret_prefilter_black_does_not_trigger_OCR_or_authority", !blackOnly && fullProofCalls == 0)
        var confirmed = false, sampled = 0
        for pixels in [image([]),image([]),image([start])] {
            sampled += 1
            confirmed = visualPrefixCaretCandidate(pixels,window:window,control:control,priorFirstText:first) {
                fullProofCalls += 1
                return visualPrefixCaretAtStart(pixels,window:window,control:control,firstText:first)
            }
            if confirmed { break }
        }
        check("blink_off_frames_skip_OCR_until_same_frame_green_candidate", confirmed && sampled == 3 && fullProofCalls == 1)
        let shifted = visualPrefixCaretCandidate(image([start]),window:window,control:control,priorFirstText:first) {
            visualPrefixCaretAtStart(image([start]),window:window,control:control,firstText:first.offsetBy(dx:20,dy:0))
        }
        check("old_bounds_candidate_cannot_replace_new_first_glyph_proof", !shifted)
        check("green_alone_never_authorizes_failed_full_proof", !visualPrefixCaretCandidate(image([start]),window:window,control:control,priorFirstText:first) { false })
        do {
            _ = try visualPrefixCaretCandidate(image([start]),window:window,control:control,priorFirstText:first) { throw fail("prefix_recipient_mismatch","fixture") }
            check("candidate_recipient_or_focus_failure_propagates", false)
        } catch let error as HelperError { check("candidate_recipient_or_focus_failure_propagates", error.code == "prefix_recipient_mismatch") }
        check("prefix_caret_tests_did_not_start_capture",visual.stream == nil && visual.streams.isEmpty)
    }catch{cases.append(["name":"unexpected_error","passed":false,"error":String(describing:error)])}
    cases += visualPrefixEvidenceSelfTests()
    cases += visualPrefixCaretInkSelfTests()
    return ["ok":cases.allSatisfy{$0["passed"] as? Bool==true},"case_count":cases.count,"cases":cases,"capture_executed":false,"events_posted":0]
}

func visualPrefixEvidenceSelfTests() -> [[String: Any]] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { cases.append(["name":"prefix_evidence_"+name,"passed":passed]) }
    let window = CGRect(x:50,y:41,width:855,height:1079), control = visualVoiceComposerRegion(CGRect(x:50,y:41,width:855,height:1079))
    let identity = VisualIdentity(pid:60682,windowID:33789,frame:window,topology:"single")
    let image = CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let frame = VisualFrame(image:image,completeSerial:3,time:4.9,completeTime:5,idleConfirmed:false,capturedRegions:[window])
    let rows: [[String: Any]] = [["text":"收20261013"]], titles: [[String: Any]] = [["text":"完整标题（5）"]]
    func proof(_ candidate: VisualFrame = frame, current: VisualIdentity = identity, observed: [[String: Any]] = rows,
               header: [[String: Any]] = titles, expected: String = "收20261013", after: Int = 2, now: Double = 5.1,
               reflow: Bool = true) -> VisualPrefixEvidence? {
        visualPrefixEvidence(candidate,identity:identity,currentIdentity:current,control:control,rows:observed,headerRows:header,
            expected:expected,title:"完整标题（5）",allowReflow:reflow,after:after,now:now)
    }
    let renewed = proof()
    check("afterOne_proof_crosses_original_five_seconds", renewed != nil && renewed!.current(at:5.1) && 5.1 > 5)
    check("renewal_uses_capture_time_not_proof_time", renewed?.time == 4.9 && renewed?.serial == 3)
    check("renewed_evidence_itself_expires", renewed?.current(at:10) == false)
    let caret = VisualFrame(image:image,completeSerial:2,time:2.6,completeTime:2.7,idleConfirmed:false,capturedRegions:[window])
    check("complete_unchanged_caret_stage_can_renew", proof(caret,observed:[["text":"验收20261013"]],expected:"验收20261013",after:1,now:2.8,reflow:false) != nil)
    check("same_frame_cannot_renew", proof(after:3) == nil)
    check("older_serial_cannot_renew", proof(after:4) == nil)
    check("proof_must_finish_within_two_seconds", proof(now:6.901) == nil)
    check("future_capture_time_denied", proof(now:4.8) == nil)
    for changed in [VisualIdentity(pid:1,windowID:identity.windowID,frame:window,topology:identity.topology),
        VisualIdentity(pid:identity.pid,windowID:1,frame:window,topology:identity.topology),
        VisualIdentity(pid:identity.pid,windowID:identity.windowID,frame:window.offsetBy(dx:1,dy:0),topology:identity.topology),
        VisualIdentity(pid:identity.pid,windowID:identity.windowID,frame:window,topology:"changed")] {
        check("changed_identity_"+String(cases.count)+"_denied", proof(current:changed) == nil)
    }
    check("changed_draft_denied", proof(observed:[["text":"收20261014"]]) == nil)
    check("wrong_first_delete_result_denied", proof(observed:[["text":"验收20261013"]]) == nil)
    check("changed_title_denied", proof(header:[["text":"完整标题（6）"]]) == nil)
    check("literal_title_spacing_not_relaxed", proof(header:[["text":"完整标题 （5）"]]) == nil)
    check("ambiguous_title_denied", proof(header:titles+titles) == nil)
    check("only_existing_CR_LF_reflow_allowed", proof(observed:[["text":"收2026"],["text":"1013"]]) != nil &&
        proof(observed:[["text":"收2026"],["text":"1013"]],reflow:false) == nil)
    check("suffix_spaces_retained", proof(observed:[["text":"收 20261013"]]) == nil)
    var changed = frame; changed.capturedRegions = [control]
    check("missing_header_coverage_denied", proof(changed) == nil)
    changed.capturedRegions = visualSubtract(window,CGRect(x:control.minX+10,y:control.minY+10,width:1,height:1))
    check("partial_composer_denied", proof(changed) == nil)
    let idle = VisualFrame(image:image,completeSerial:3,time:4.9,completeTime:5,idleConfirmed:true,capturedRegions:[window])
    check("idle_frame_denied", proof(idle) == nil)
    check("final_readonly_uses_its_new_frame_not_old_lease", proof(VisualFrame(image:image,completeSerial:4,time:10.1,
        completeTime:10.2,idleConfirmed:false,capturedRegions:[window]),observed:[],expected:"",after:3,now:10.3) != nil && renewed?.current(at:10.3) == false)
    for stop in [Int.max,14] {
        var count = 6, now = 5.1, threw = false
        do {
            for _ in 1..<10 {
                try visualPostCountedKeyPair(count:&count,beforePost:{ posted in
                    if posted == stop { throw fail("user_interrupted","fixture") }
                    guard renewed!.current(at:now) else { throw fail("stale_visual_snapshot","fixture") }
                },down:{now += 0.1},up:{now += 0.1})
            }
        } catch { threw = true }
        check(stop == Int.max ? "ten_character_prefix_continues_past_old_TTL" : "takeover_still_stops_at_exact_post_count",
            count == (stop == Int.max ? 24 : 14) && threw == (stop == 14) && now > 5)
    }
    return cases
}


func visualSearchTransitionSelfTests() -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ value: Bool) { cases.append(["name": name, "passed": value]) }
    func code(_ body: () throws -> Void) -> String? { do { try body(); return nil } catch let error as HelperError { return error.code } catch { return "unexpected" } }
    let identity = VisualIdentity(pid: 83927, windowID: 26955, frame: CGRect(x: 1900, y: 33, width: 855, height: 1079), topology: "two-displays")
    let control = CGRect(x: 1965, y: 45, width: 270, height: 40)
    let query = CGRect(x: 1991, y: 48.106, width: 156, height: 19.894)
    let activation = VisualSearchActivation(identity: identity, control: control)
    func window(_ id: UInt32, _ pid: Int32, _ frame: CGRect, layer: Int = 3, alpha: Double = 1, empty: Bool = true) -> VisualScreenWindow {
        VisualScreenWindow(id: id, pid: pid, frame: frame, layer: layer, alpha: alpha, emptyTitle: empty, dockSurface: false)
    }
    let popup170 = window(30825, 83927, CGRect(x: 1948, y: 68, width: 368, height: 170))
    let popup430 = window(30825, 83927, CGRect(x: 1948, y: 68, width: 368, height: 430))
    let hintBefore = window(26951, 83927, CGRect(x: 2362, y: 956, width: 84, height: 77))
    let hintAfter = window(26951, 83927, CGRect(x: 2099, y: 45, width: 84, height: 77))
    let foreign = window(1308, 8187, CGRect(x: 2100, y: 100, width: 300, height: 400), layer: 0, empty: false)
    let unknown = window(45000, 83927, CGRect(x: 1949, y: 68, width: 368, height: 170))
    let transition = VisualSearchTransition(activation: activation, windows: [hintBefore])
    func row(_ value: VisualScreenWindow) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: value.id), kCGWindowOwnerPID as String: NSNumber(value: value.pid),
         kCGWindowLayer as String: value.layer, kCGWindowName as String: value.emptyTitle ? "" : "other",
         kCGWindowBounds as String: value.frame.dictionaryRepresentation, kCGWindowIsOnscreen as String: true,
         kCGWindowAlpha as String: value.alpha]
    }
    do {
        check("actual_right_display_empty_popup_170_recognized", try visualSearchOverlay([row(popup170)], identity: identity)?.frame == popup170.frame)
        check("filled_popup_430_same_geometry_contract", try visualSearchOverlay([row(popup430)], identity: identity)?.frame == popup430.frame)
        check("one_point_offset_is_unknown_not_search", try visualSearchOverlay([row(unknown)], identity: identity) == nil)
        check("foreign_PID_identical_geometry_not_search", try visualSearchOverlay([row(window(1, 8187, popup170.frame))], identity: identity) == nil)
        check("nonempty_title_identical_geometry_not_search", try visualSearchOverlay([row(window(1, 83927, popup170.frame, empty: false))], identity: identity) == nil)
        check("partial_alpha_identical_geometry_not_search", try visualSearchOverlay([row(window(1, 83927, popup170.frame, alpha: 0.5))], identity: identity) == nil)
        check("duplicate_search_popup_rejected", code { _ = try visualSearchOverlay([row(popup170), row(window(30826, 83927, popup430.frame))], identity: identity) } == "visual_search_overlay_ambiguous")
        check("posted_search_may_show_popup_and_move_hint", transition.accepts([popup170, hintAfter], identity: identity))
        check("dynamic_popup_height_may_settle", VisualSearchTransition(activation: activation, windows: [popup170]).accepts([popup430], identity: identity))
        let actualMain = VisualIdentity(pid: 60682, windowID: 33789, frame: CGRect(x: 50, y: 41, width: 855, height: 1079), topology: "actual-fixture")
        let actualControl = CGRect(x: 120, y: 56.106, width: 210, height: 26.975)
        let actualActivation = VisualSearchActivation(identity: actualMain, control: actualControl)
        let actualPopup230 = window(35770, 60682, CGRect(x: 98, y: 76, width: 368, height: 230))
        let actualPopup602 = window(35770, 60682, CGRect(x: 98, y: 76, width: 368, height: 602))
        let actualPopup354 = window(35976, 60682, CGRect(x: 98, y: 76, width: 368, height: 354))
        let actualPopup1016 = window(35976, 60682, CGRect(x: 98, y: 76, width: 368, height: 1016))
        check("actual_long_results_popup_1016_keeps_main_bottom_margin28", try visualSearchOverlay([row(actualPopup1016)], identity: actualMain)?.frame == actualPopup1016.frame &&
            actualMain.frame.maxY - actualPopup1016.frame.maxY == 28)
        check("actual_same_popup_354_to_1016_can_reobserve", VisualSearchTransition(activation: actualActivation,
            windows: [actualPopup354]).accepts([actualPopup1016], identity: actualMain))
        check("popup_cannot_cross_verified_bottom_margin", !visualSearchPopupBounds(CGRect(x: 98, y: 76, width: 368, height: 1017), identity: actualMain))
        check("popup_cannot_extend_beyond_main", !visualSearchPopupBounds(CGRect(x: 98, y: 76, width: 368, height: 1079), identity: actualMain))
        let shorterMain = VisualIdentity(pid: actualMain.pid, windowID: actualMain.windowID,
            frame: CGRect(x: 50, y: 41, width: 855, height: 800), topology: actualMain.topology)
        check("popup_height_limit_tracks_verified_main_height", visualSearchPopupBounds(CGRect(x: 98, y: 76, width: 368, height: 737), identity: shorterMain) &&
            !visualSearchPopupBounds(CGRect(x: 98, y: 76, width: 368, height: 738), identity: shorterMain))
        check("tall_foreign_popup_is_still_not_owned_search", try visualSearchOverlay([
            row(window(35976, 8187, actualPopup1016.frame))], identity: actualMain) == nil)
        check("tall_popup_wrong_width_or_offset_denied", !visualSearchPopupBounds(CGRect(x: 98, y: 76, width: 369, height: 1016), identity: actualMain) &&
            !visualSearchPopupBounds(actualPopup1016.frame.offsetBy(dx: 1, dy: 0), identity: actualMain))
        let actualNewAux = window(35807, 60682, CGRect(x: 56, y: 46, width: 52, height: 20), layer: 0, empty: false)
        let actualTransition = VisualSearchTransition(activation: actualActivation, windows: [actualPopup230])
        check("actual_postinput_popup_growth_plus_new_aux_can_reobserve", actualTransition.accepts([actualPopup602, actualNewAux], identity: actualMain))
        let actualCoverage = try visualScreenCoverage([actualMain.frame], windows: [actualPopup602, actualNewAux], identity: actualMain,
            overlay: VisualSearchOverlay(windowID: actualPopup602.id, frame: actualPopup602.frame), dockRegions: nil)
        check("reobserved_aux_is_full_frame_mask_not_an_input_target", !visualCovered(actualNewAux.frame, by: actualCoverage) && visualCovered(actualControl, by: actualCoverage))
        check("new_aux_over_search_control_cannot_settle", !actualTransition.accepts([actualPopup602,
            window(35807, 60682, actualNewAux.frame.offsetBy(dx: 70, dy: 0), layer: 0, empty: false)], identity: actualMain))
        check("new_aux_foreign_PID_cannot_settle", !actualTransition.accepts([actualPopup602,
            window(35807, 8187, actualNewAux.frame, layer: 0, empty: false)], identity: actualMain))
        check("new_aux_outside_main_cannot_settle", !actualTransition.accepts([actualPopup602,
            window(35807, 60682, actualNewAux.frame.offsetBy(dx: -10, dy: 0), layer: 0, empty: false)], identity: actualMain))
        check("new_unknown_layer3_cannot_use_layer0_reobservation", !actualTransition.accepts([actualPopup602,
            window(35807, 60682, actualNewAux.frame, layer: 3, empty: false)], identity: actualMain))
        check("new_unnamed_layer0_cannot_use_observed_named_aux_case", !actualTransition.accepts([actualPopup602,
            window(35807, 60682, actualNewAux.frame, layer: 0, empty: true)], identity: actualMain))
        check("other_far_layer0_size_cannot_use_small_aux_case", !actualTransition.accepts([actualPopup602,
            window(35807, 60682, CGRect(x: 56, y: 46, width: 53, height: 20), layer: 0, empty: false)], identity: actualMain))
        check("other_far_layer0_position_cannot_use_small_aux_case", !actualTransition.accepts([actualPopup602,
            window(35807, 60682, actualNewAux.frame.offsetBy(dx: 1, dy: 0), layer: 0, empty: false)], identity: actualMain))
        check("new_aux_over_bound_anchor_cannot_settle", !VisualSearchTransition(activation: actualActivation,
            windows: [actualPopup230], anchorRegions: [actualNewAux.frame]).accepts([actualPopup602, actualNewAux], identity: actualMain))
        check("new_aux_away_from_bound_anchors_can_only_reobserve", VisualSearchTransition(activation: actualActivation,
            windows: [actualPopup230], anchorRegions: [actualControl, CGRect(x: 380, y: 50, width: 200, height: 30)])
                .accepts([actualPopup602, actualNewAux], identity: actualMain))
        let cgPopup130 = VisualSearchOverlay(windowID: 35929, frame: CGRect(x: 98, y: 76, width: 368, height: 130))
        func scHeightDetails(id: CGWindowID = 35929, pid: pid_t? = 60682,
                             frame: CGRect = CGRect(x: 98, y: 76, width: 368, height: 230),
                             empty: Bool = true, layer: Int = 3, visible: Bool = true) -> [String: Any] {
            let candidate = VisualPopupShareableCandidate(id: id, pid: pid, bundle: "com.tencent.xinWeChat",
                frame: frame, titlePresent: false, titleEmpty: empty, layer: layer, onScreen: visible)
            var details = visualPopupShareableDiagnostic(selected: actualMain, overlay: cgPopup130, candidates: [candidate])
            details["sc_exact_match_count"] = 0
            return details
        }
        func acceptsHeight(_ details: [String: Any]) -> Bool {
            visualSearchPopupHeightRace(details, identity: actualMain, overlay: cgPopup130,
                transition: actualTransition, activation: actualActivation)
        }
        check("actual_same_ID_CG130_SC230_height_race_can_reobserve", acceptsHeight(scHeightDetails()))
        check("same_ID_SC_tall1016_height_race_can_reobserve", acceptsHeight(scHeightDetails(frame: actualPopup1016.frame)))
        let tallCGPopup = VisualSearchOverlay(windowID: 35929, frame: actualPopup1016.frame)
        var shrinkingPopupDetails = visualPopupShareableDiagnostic(selected: actualMain, overlay: tallCGPopup,
            candidates: [VisualPopupShareableCandidate(id: 35929, pid: 60682, bundle: "com.tencent.xinWeChat",
                frame: actualPopup354.frame, titlePresent: false, titleEmpty: true, layer: 3, onScreen: true)])
        shrinkingPopupDetails["sc_exact_match_count"] = 0
        check("same_ID_tall_CG_to_short_SC_height_race_can_reobserve", visualSearchPopupHeightRace(shrinkingPopupDetails,
            identity: actualMain, overlay: tallCGPopup, transition: actualTransition, activation: actualActivation))
        for (name, details) in [
            ("id", scHeightDetails(id: 35930)), ("PID", scHeightDetails(pid: 8187)),
            ("missing_owner", scHeightDetails(pid: nil)), ("title", scHeightDetails(empty: false)),
            ("layer", scHeightDetails(layer: 0)), ("offscreen", scHeightDetails(visible: false)),
            ("x", scHeightDetails(frame: CGRect(x: 99, y: 76, width: 368, height: 230))),
            ("width", scHeightDetails(frame: CGRect(x: 98, y: 76, width: 369, height: 230))),
            ("unknown_height", scHeightDetails(frame: CGRect(x: 98, y: 76, width: 368, height: actualMain.frame.height - 62))),
            ("same_frame", scHeightDetails(frame: cgPopup130.frame))
        ] { check("SC_height_retry_denies_other_" + name + "_case", !acceptsHeight(details)) }
        var duplicateSC = scHeightDetails(); duplicateSC["sc_exact_id_count"] = 2
        check("SC_height_retry_denies_ambiguous_exact_ID", !acceptsHeight(duplicateSC))
        check("SC_height_retry_requires_posted_search_transition", !visualSearchPopupHeightRace(scHeightDetails(), identity: actualMain,
            overlay: cgPopup130, transition: nil, activation: actualActivation))
        check("SC_height_retry_requires_actual_clicked_activation", !visualSearchPopupHeightRace(scHeightDetails(), identity: actualMain,
            overlay: cgPopup130, transition: actualTransition, activation: nil))
        check("SC_height_retry_rejects_other_control_binding", !visualSearchPopupHeightRace(scHeightDetails(), identity: actualMain,
            overlay: cgPopup130, transition: actualTransition, activation: VisualSearchActivation(identity: actualMain, control: actualControl.offsetBy(dx: 1, dy: 0))))
        check("preinput_aux_disappearance_is_not_reobservation", !VisualSearchTransition(activation: actualActivation,
            windows: [actualPopup230, actualNewAux]).accepts([actualPopup602], identity: actualMain))
        // Exact changed geometry from current-function-4a415252213f407ab8129b9902cf50af.
        // The unchanged ID 23's metadata is synthetic; the live diff proves only its equality.
        let disappearedMain = VisualIdentity(pid: 60682, windowID: 33789,
            frame: CGRect(x: 356, y: 25, width: 855, height: 1079), topology: "corner-disappearance-fixture")
        let disappearedControl = CGRect(x: 426, y: 40.106, width: 210, height: 26.975)
        let disappearedActivation = VisualSearchActivation(identity: disappearedMain, control: disappearedControl)
        let disappearedAnchors = [CGRect(x: 1138.99999994, y: 1056.00000013, width: 48, height: 29),
            CGRect(x: 423.8423370757932, y: 38.35545126420936, width: 66.31532669067383, height: 29.806955005441388)]
        let removedCorner = window(46906, 60682, CGRect(x: 362, y: 30, width: 52, height: 20), layer: 0, empty: false)
        let openedPopup = window(46914, 60682, CGRect(x: 404, y: 60, width: 368, height: 170))
        let unchangedWindow = window(23, 8187, CGRect(x: 0, y: 0, width: 2000, height: 24), layer: 0, empty: false)
        let disappearanceCoverage = try visualScreenCoverage([disappearedMain.frame], windows: [unchangedWindow, removedCorner],
            identity: disappearedMain, overlay: nil, dockRegions: nil)
        let disappearanceTransition = VisualSearchTransition(activation: disappearedActivation,
            windows: [unchangedWindow, removedCorner], anchorRegions: disappearedAnchors, baselineCoverage: disappearanceCoverage)
        check("actual_masked_corner46906_disappears_as_known_popup46914_opens", disappearanceTransition.accepts([unchangedWindow, openedPopup], identity: disappearedMain))
        check("disappeared_corner_was_fully_masked_before_search", disappearanceCoverage.allSatisfy { $0.intersection(removedCorner.frame).isEmpty })
        check("corner_disappearance_requires_existing_frame_mask", !VisualSearchTransition(activation: disappearedActivation,
            windows: [unchangedWindow, removedCorner], anchorRegions: disappearedAnchors, baselineCoverage: [disappearedMain.frame])
                .accepts([unchangedWindow, openedPopup], identity: disappearedMain))
        check("corner_disappearance_cannot_remove_another_window", !disappearanceTransition.accepts([openedPopup], identity: disappearedMain))
        check("corner_disappearance_does_not_allow_corner_movement", !disappearanceTransition.accepts([unchangedWindow, openedPopup,
            window(46906, 60682, removedCorner.frame.offsetBy(dx: 1, dy: 0), layer: 0, empty: false)], identity: disappearedMain))
        check("corner_disappearance_preserves_input_and_anchor_coverage", !VisualSearchTransition(activation: disappearedActivation,
            windows: [unchangedWindow, removedCorner], anchorRegions: disappearedAnchors,
            baselineCoverage: disappearanceCoverage.flatMap { visualSubtract($0, disappearedAnchors[0]) })
                .accepts([unchangedWindow, openedPopup], identity: disappearedMain))
        check("corner_disappearance_rejects_anchor_intersection", !VisualSearchTransition(activation: disappearedActivation,
            windows: [unchangedWindow, removedCorner], anchorRegions: [removedCorner.frame, disappearedAnchors[0]], baselineCoverage: disappearanceCoverage)
                .accepts([unchangedWindow, openedPopup], identity: disappearedMain))
        let disappearedCornerDiagnostic = VisualSearchTransition(activation: actualActivation,
            windows: [actualPopup230, actualNewAux]).diagnostic([actualPopup602], identity: actualMain)
        check("search_initial_diagnostic_reports_real_rejection", disappearedCornerDiagnostic["phase"] as? String == "search_transition_initial" &&
            disappearedCornerDiagnostic["transition_accepted"] as? Bool == false &&
            disappearedCornerDiagnostic["transition_rejection_reason"] as? String == "baseline_window_changed_or_unrecognized_auxiliary")
        let nonSearchDifference = disappearedCornerDiagnostic["non_search_window_difference"] as? [String: Any]
        check("search_diagnostic_separates_expected_popup_resize_from_corner", nonSearchDifference?["before_count"] as? Int == 1 &&
            nonSearchDifference?["after_count"] as? Int == 0 && nonSearchDifference?["window_changes_count"] as? Int == 1)
        let acceptedSearchDiagnostic = actualTransition.diagnostic([actualPopup602, actualNewAux], identity: actualMain)
        check("search_diagnostic_does_not_invent_window_failure_for_valid_popup", acceptedSearchDiagnostic["transition_accepted"] as? Bool == true &&
            acceptedSearchDiagnostic["transition_rejection_reason"] is NSNull)
        check("search_diagnostic_retains_foreign_window_rejection", transition.rejectionReason([foreign, popup170, hintAfter], identity: identity) ==
            "baseline_window_changed_or_unrecognized_auxiliary")
        check("foreign_occluder_appearance_never_transition", !transition.accepts([foreign, popup170, hintAfter], identity: identity))
        check("unknown_same_PID_window_never_transition", !transition.accepts([unknown, popup170, hintAfter], identity: identity))
        check("unknown_occluder_disappearance_never_transition", !VisualSearchTransition(activation: activation, windows: [unknown]).accepts([popup170], identity: identity))
        check("other_window_identity_invalidates_search_binding", !transition.accepts([popup170], identity: VisualIdentity(pid: 83927, windowID: 99, frame: identity.frame, topology: identity.topology)))
        check("actual_clicked_control_contains_full_text_lane", activation.matches(identity, queryRegion: query))
        check("moved_query_lane_not_bound_by_previous_click", !activation.matches(identity, queryRegion: query.offsetBy(dx: 1, dy: 0)))
        check("empty_lane_kept_only_after_confirmed_search_click", visualBoundSearchQuery([], fullyVisible: true, activated: true) == "")
        check("readonly_empty_lane_does_not_invent_click_binding", visualBoundSearchQuery([], fullyVisible: true, activated: false) == nil)
        check("placeholder_after_click_is_empty_not_query", visualBoundSearchQuery([["text": "搜索"]], fullyVisible: true, activated: true) == "")
        check("partial_lane_cannot_authorize_empty_popup", visualBoundSearchQuery([], fullyVisible: false, activated: true) == nil)
        check("malformed_OCR_row_not_empty_proof", visualBoundSearchQuery([[:]], fullyVisible: true, activated: true) == nil)
        check("multiple_query_rows_still_unverified", visualBoundSearchQuery([["text": "a"], ["text": "b"]], fullyVisible: true, activated: true) == nil)
        check("full_nonempty_query_still_readable_without_action", visualBoundSearchQuery([["text": "完整搜索词"]], fullyVisible: true, activated: false) == "完整搜索词")
        var captures = 0, guards = 0, events = 0
        let result: Int = try visualSettleSearchObservation(enabled: true, deadline: ProcessInfo.processInfo.systemUptime + 1,
            check: { guards += 1 }, capture: { captures += 1; if captures == 1 { throw VisualSearchObservationChanged() }; return 7 })
        check("post_click_reacquires_pixels_without_replaying_input", result == 7 && captures == 2 && guards == 2 && events == 0)
        captures = 0
        check("unknown_change_is_not_retried", code {
            let _: Int = try visualSettleSearchObservation(enabled: true, deadline: ProcessInfo.processInfo.systemUptime + 1, check: {}, capture: { captures += 1; throw fail("visual_target_changed", "foreign") })
        } == "visual_target_changed" && captures == 1)
        captures = 0
        check("capture_retry_is_bounded_to_four_attempts", code {
            let _: Int = try visualSettleSearchObservation(enabled: true, deadline: ProcessInfo.processInfo.systemUptime + 1, check: {}, capture: { captures += 1; throw VisualSearchObservationChanged() })
        } == "visual_target_changed" && captures == 4)
        captures = 0
        check("interruption_prevents_next_capture", code {
            let _: Int = try visualSettleSearchObservation(enabled: true, deadline: ProcessInfo.processInfo.systemUptime + 1, check: { throw fail("user_interrupted", "manual") }, capture: { captures += 1; return 0 })
        } == "user_interrupted" && captures == 0)
        check("existing_foreign_mask_policy_is_unchanged", try visualScreenCoverage([identity.frame], windows: [foreign, popup170], identity: identity, overlay: VisualSearchOverlay(windowID: popup170.id, frame: popup170.frame), dockRegions: nil).allSatisfy { $0.intersection(foreign.frame).isEmpty })
    } catch { cases.append(["name": "unexpected_error", "passed": false, "error": String(describing: error)]) }
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "case_count": cases.count, "cases": cases,
            "capture_executed": false, "events_posted": 0, "live_AX_probe_executed": false]
}

func visualOneXSearchOCRSelfTests(_ fixture: String?) -> [String: Any] {
    var cases: [[String: Any]] = []
    func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]) }
    let window = CGRect(x: 1900, y: 33, width: 855, height: 1079)
    let control = CGRect(x: 1970, y: 48.106, width: 210, height: 26.975)
    let actual = CGRect(x: 1970, y: 48, width: 210, height: 28)
    let query = CGRect(x: 1991, y: 48.106, width: 156, height: 19.894)
    check("actual_1x_full_control_is_selected", visualSearchControlNeedsOCRUpsample(actual: actual, window: window, scaleX: 1, scaleY: 1))
    check("Retina_control_is_unchanged", !visualSearchControlNeedsOCRUpsample(actual: actual, window: window, scaleX: 2, scaleY: 2))
    check("query_lane_is_never_upsampled", !visualSearchControlNeedsOCRUpsample(actual: query.integral, window: window, scaleX: 1, scaleY: 1))
    check("recent_header_and_body_are_unchanged", !visualSearchControlNeedsOCRUpsample(actual: CGRect(x: 2010, y: 150, width: 180, height: 60), window: window, scaleX: 1, scaleY: 1) && !visualSearchControlNeedsOCRUpsample(actual: window, window: window, scaleX: 1, scaleY: 1))
    let negative = window.offsetBy(dx: -3000, dy: -100)
    check("negative_display_origin_keeps_same_local_policy", visualSearchControlNeedsOCRUpsample(actual: actual.offsetBy(dx: -3000, dy: -100), window: negative, scaleX: 1, scaleY: 1))
    if let fixture, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: fixture) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 855, image.height == 1079 {
        let identity = VisualIdentity(pid: 1, windowID: 1, frame: window, topology: "offline")
        let frame = VisualFrame(image: image, completeSerial: 1, time: 0, completeTime: 0, idleConfirmed: false, capturedRegions: [window])
        do {
            let desktop = VisualDesktop()
            let rows = try desktop.ocrUncached(frame, identity: identity, region: control)
            check("real_saved_1x_search_control_reads_exact_search", rows.count == 1 && visualNormalizedText(rows[0]["text"] as? String ?? "") == "Q搜索")
            check("search_row_declares_OCR_only_resampling", rows.first?["ocr_preprocessing"] as? String == "full_search_control_1x_to_2x_high_quality")
            check("search_bounds_remain_Quartz_points", rows.allSatisfy { (try? visualRect($0["bounds"])).map { visualContains(actual, $0) } == true })
            let queryRows = try desktop.ocrUncached(frame, identity: identity, region: query)
            check("real_query_lane_keeps_complete_native_search", queryRows.count == 1 && queryRows[0]["text"] as? String == "搜索" && queryRows[0]["ocr_preprocessing"] == nil)
            let recentRows = try desktop.ocrUncached(frame, identity: identity, region: CGRect(x: 2010, y: 150, width: 180, height: 60))
            check("recent_fixture_keeps_original_rows_without_extra_star", recentRows.count == 2 && recentRows.contains { $0["text"] as? String == "2026实施管理部" } && recentRows.allSatisfy { $0["ocr_preprocessing"] == nil })
            check("capture_and_model_image_dimensions_unchanged", frame.image === image && frame.image.width == 855 && frame.image.height == 1079)
        } catch { check("actual_native_OCR_fixture_completed", false) }
    } else { check("actual_1x_fixture_available", false) }
    return ["ok": cases.allSatisfy { $0["passed"] as? Bool == true }, "count": cases.count, "cases": cases, "capture_executed": false, "events_posted": 0]
}
