import AppKit
import PDFKit

struct RedactionMark: Identifiable, Equatable {
    enum Source: Equatable { case manual, keyword, pii(PIIKind), regex }
    let id = UUID()
    let page: Int
    /// In PDF page space (the page's crop box origin included).
    let rect: CGRect
    let text: String
    let source: Source
}

enum PIIKind: String, CaseIterable, Identifiable {
    case email, card, phone, ssn, iban, ip, date, taiwanID
    var id: String { rawValue }
    var label: String {
        switch self {
        case .email: L("Email")
        case .card: L("信用卡號")
        case .phone: L("電話")
        case .ssn: L("SSN")
        case .iban: L("IBAN")
        case .ip: L("IP 位址")
        case .date: L("日期（可能是生日）")
        case .taiwanID: L("身分證字號")
        }
    }
    var pattern: String {
        switch self {
        case .email: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        case .card: #"(?<![\d])(?:\d[ -]?){12,18}\d(?![\d])"#
        case .phone: #"(?<![\d])(?:\+\d{1,3}[ -]?\d[\d -]{7,12}\d|09\d{2}[- ]?\d{3}[- ]?\d{3}|\(?0\d{1,2}\)?[- ]?\d{3,4}[- ]?\d{4})(?![\d])"#
        case .ssn: #"(?<![\d])\d{3}-\d{2}-\d{4}(?![\d])"#
        case .iban: #"(?<![A-Za-z0-9])[A-Z]{2}\d{2}[A-Z0-9]{11,30}(?![A-Za-z0-9])"#
        case .ip: #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"#
        case .date: #"(?<![\d])(?:19|20)\d{2}[-/.](?:0?[1-9]|1[0-2])[-/.](?:0?[1-9]|[12]\d|3[01])(?![\d])"#
        case .taiwanID: #"(?<![A-Za-z0-9])[A-Z][12]\d{8}(?![A-Za-z0-9])"#
        }
    }

    /// Cuts false positives for the kinds that have a check digit.
    func accepts(_ text: String) -> Bool {
        switch self {
        case .card:
            let digits = text.filter(\.isNumber).compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count) else { return false }
            var sum = 0
            for (offset, digit) in digits.reversed().enumerated() {
                var value = digit
                if offset % 2 == 1 { value *= 2; if value > 9 { value -= 9 } }
                sum += value
            }
            return sum % 10 == 0
        case .iban:
            let compact = text.uppercased()
            guard compact.count >= 15 else { return false }
            let rearranged = compact.dropFirst(4) + compact.prefix(4)
            var remainder = 0
            for character in rearranged {
                guard let value = character.isNumber ? character.wholeNumberValue.map(String.init) : character.asciiValue.map({ String(Int($0) - 55) }) else { return false }
                for digit in value { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
            }
            return remainder == 1
        case .taiwanID:
            let letters = Array("ABCDEFGHJKLMNPQRSTUVXYWZIO")
            let chars = Array(text)
            guard chars.count == 10, let index = letters.firstIndex(of: chars[0]) else { return false }
            let code = index + 10
            let digits = chars.dropFirst().compactMap(\.wholeNumberValue)
            guard digits.count == 9 else { return false }
            var sum = code / 10 + (code % 10) * 9
            for (position, digit) in digits.prefix(8).enumerated() { sum += digit * (8 - position) }
            sum += digits[8]
            return sum % 10 == 0
        default: return true
        }
    }
}

enum Redaction {
    static let ocrDPI: CGFloat = 200
    static let annotationName = "macpdf.redaction.mark"

    // MARK: Finding candidates

    /// Text that matches is only a candidate: it is shown for review and nothing is removed until the user applies.
    @MainActor static func find(in document: PDFDocument, keywords: [String], kinds: Set<PIIKind>, regex: String?) throws -> [RedactionMark] {
        var matchers: [(NSRegularExpression, RedactionMark.Source, PIIKind?)] = []
        for keyword in keywords where !keyword.isEmpty {
            matchers.append((try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: keyword), options: .caseInsensitive), .keyword, nil))
        }
        for kind in PIIKind.allCases where kinds.contains(kind) {
            matchers.append((try NSRegularExpression(pattern: kind.pattern, options: kind == .email ? .caseInsensitive : []), .pii(kind), kind))
        }
        if let regex, !regex.isEmpty { matchers.append((try NSRegularExpression(pattern: regex, options: []), .regex, nil)) }

        var marks: [RedactionMark] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string, !text.isEmpty else { continue }
            let whole = NSRange(location: 0, length: (text as NSString).length)
            for (expression, source, kind) in matchers {
                for match in expression.matches(in: text, range: whole) where match.range.length > 0 {
                    let matched = (text as NSString).substring(with: match.range)
                    if let kind, !kind.accepts(matched) { continue }
                    guard let selection = page.selection(for: match.range) else { continue }
                    for line in selection.selectionsByLine() {
                        let bounds = line.bounds(for: page)
                        guard bounds.width > 0, bounds.height > 0 else { continue }
                        marks.append(RedactionMark(page: index, rect: bounds, text: matched, source: source))
                    }
                }
            }
        }
        return marks
    }

    // MARK: Review overlay

    @MainActor static func show(_ mark: RedactionMark, on document: PDFDocument) {
        guard let page = document.page(at: mark.page) else { return }
        let annotation = PDFAnnotation(bounds: mark.rect, forType: .square, withProperties: nil)
        annotation.color = NSColor.systemRed.withAlphaComponent(0.9)
        annotation.interiorColor = NSColor.systemRed.withAlphaComponent(0.28)
        let border = PDFBorder(); border.lineWidth = 1.5; annotation.border = border
        annotation.userName = annotationName
        annotation.contents = mark.id.uuidString
        page.addAnnotation(annotation)
    }

    @MainActor static func clearOverlays(in document: PDFDocument) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.userName == annotationName { page.removeAnnotation(annotation) }
        }
    }

    @MainActor static func removeOverlay(for id: UUID, in document: PDFDocument) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.userName == annotationName && annotation.contents == id.uuidString {
                page.removeAnnotation(annotation)
            }
        }
    }

    // MARK: Applying

    struct Report {
        var pages = 0
        var regions = 0
        /// 1-based pages where text or a visible region could still be found.
        var failedPages: [Int] = []
        var passed: Bool { failedPages.isEmpty }
    }

    /// Where a point of the page's crop box lands on the upright rendering of the page.
    private static func upright(_ rect: CGRect, box: CGRect, rotation: Int) -> CGRect {
        let w = box.width, h = box.height
        func map(_ p: CGPoint) -> CGPoint {
            let lx = p.x - box.minX, ly = p.y - box.minY
            switch ((rotation % 360) + 360) % 360 {
            case 90: return CGPoint(x: ly, y: w - lx)
            case 180: return CGPoint(x: w - lx, y: h - ly)
            case 270: return CGPoint(x: h - ly, y: lx)
            default: return CGPoint(x: lx, y: ly)
            }
        }
        let a = map(rect.origin), b = map(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Rebuilds a page as a flat picture with the marked regions painted over *before* the image is embedded,
    /// so the original pixels and text are not in the output at all.
    @MainActor static func flattenedPage(from page: PDFPage, marks: [RedactionMark]) -> PDFPage? {
        let box = page.bounds(for: .cropBox)
        let scale = ocrDPI / 72
        guard let rendered = PDFProcessing.renderImage(of: page, scale: scale, includeAnnotations: true) else { return nil }
        let size = CGSize(width: CGFloat(rendered.width) / scale, height: CGFloat(rendered.height) / scale)
        guard let bitmap = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(full)
        bitmap.draw(rendered, in: full)
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        for mark in marks {
            let area = upright(mark.rect, box: box, rotation: page.rotation).insetBy(dx: -1.5, dy: -1.5)
            bitmap.fill(CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale))
        }
        guard let burned = bitmap.makeImage() else { return nil }

        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        context.draw(burned, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
        // Only the flat picture is carried over: no annotations, links, form fields or text.
        return PDFDocument(data: data as Data)?.page(at: 0)?.copy() as? PDFPage
    }

    /// Builds the redacted document. The source document is not modified.
    @MainActor static func build(from document: PDFDocument, marks: [RedactionMark], progress: (Int, Int) -> Void = { _, _ in }) async -> PDFDocument? {
        let affected = Set(marks.map(\.page)).sorted()
        let output = PDFDocument()
        var done = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { return nil }
            if affected.contains(index) {
                guard let flat = flattenedPage(from: page, marks: marks.filter { $0.page == index }) else { return nil }
                output.insert(flat, at: output.pageCount)
                done += 1; progress(done, affected.count)
                await Task.yield()
            } else {
                guard let copy = page.copy() as? PDFPage else { return nil }
                output.insert(copy, at: output.pageCount)
            }
        }
        // Document info, outline entries, attachments and scripts of the source are not carried over.
        // A round trip rebuilds page labels, which splicing leaves stale.
        guard let data = output.dataRepresentation() else { return nil }
        return PDFDocument(data: data)
    }

    /// Re-opens the output and checks every redacted page, as docs/05 section 5.4 describes.
    @MainActor static func verify(_ redacted: PDFDocument, source: PDFDocument, marks: [RedactionMark]) -> Report {
        var report = Report()
        let pages = Set(marks.map(\.page))
        report.pages = pages.count; report.regions = marks.count
        for index in pages.sorted() {
            guard let page = redacted.page(at: index), let original = source.page(at: index) else { report.failedPages.append(index + 1); continue }
            var failed = false
            // 1. A rebuilt page must carry no text and no annotations at all.
            if !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failed = true }
            if !page.annotations.isEmpty { failed = true }
            // 2. Each region must really be dark in the render.
            if let image = PDFProcessing.renderImage(of: page, scale: 1) {
                let box = original.bounds(for: .cropBox)
                for mark in marks where mark.page == index {
                    let centre = upright(CGRect(x: mark.rect.midX, y: mark.rect.midY, width: 0, height: 0), box: box, rotation: original.rotation)
                    if !isDark(image, atX: centre.minX, y: centre.minY) { failed = true }
                }
            } else { failed = true }
            if failed { report.failedPages.append(index + 1) }
        }
        return report
    }

    /// `x`, `y` are in points from the bottom left of the rendered page (scale 1 means one pixel per point).
    private static func isDark(_ image: CGImage, atX x: CGFloat, y: CGFloat) -> Bool {
        guard x >= 0, y >= 0, Int(x) < image.width, Int(y) < image.height else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // The image's bottom-left pixel grid is shifted so the probed pixel lands on the context's only pixel.
            context.draw(image, in: CGRect(x: -CGFloat(Int(x)), y: -CGFloat(Int(y)), width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        return drawn && (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3 < 40
    }
}
