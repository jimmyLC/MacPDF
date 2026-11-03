import AppKit
import PDFKit

/// Gets the text out of pages (reading the PDF's own text, or recognising it on scans), turns it into Markdown,
/// and writes corrected text back into scanned pages. Everything runs on this Mac.
enum TextExtraction {
    struct Line: Equatable {
        var text: String
        /// Normalised to the page, origin at the bottom left (same convention as OCR output).
        var box: CGRect
        /// Text height in points, the font size for real text.
        var size: CGFloat
        var bold = false
    }

    struct PageText {
        let index: Int
        var lines: [Line]
        /// The page had to be recognised (it is a picture); only such pages can take corrected text back.
        let recognised: Bool
        let pageHeight: CGFloat
    }

    // MARK: Reading

    /// The page's text lines in reading order. `fromPicture` forces recognition.
    @MainActor static func extract(page: PDFPage, index: Int, languages: [String], hasEmbeddedText: Bool) async -> PageText {
        let box = page.bounds(for: .cropBox)
        let height = page.rotation % 180 != 0 ? box.width : box.height
        if hasEmbeddedText, let lines = embeddedLines(of: page), !lines.isEmpty {
            return PageText(index: index, lines: lines, recognised: false, pageHeight: height)
        }
        guard let image = PDFProcessing.renderImage(of: page, scale: PDFProcessing.ocrScale),
              let found = try? await Task.detached(priority: .userInitiated, operation: { try PDFProcessing.recognize(image, languages: languages) }).value else {
            return PageText(index: index, lines: [], recognised: true, pageHeight: height)
        }
        let lines = sorted(found.map { Line(text: $0.text, box: $0.box, size: $0.box.height * height) })
        return PageText(index: index, lines: lines, recognised: true, pageHeight: height)
    }

    /// Reading order: top to bottom, left to right within a row.
    static func sorted(_ lines: [Line]) -> [Line] {
        lines.sorted { a, b in
            let rowTolerance = max(min(a.box.height, b.box.height) * 0.5, 0.004)
            if abs(a.box.midY - b.box.midY) > rowTolerance { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
    }

    @MainActor private static func embeddedLines(of page: PDFPage) -> [Line]? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0, let selection = page.selection(for: box) else { return nil }
        let lines: [Line] = selection.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            var size = bounds.height, bold = false
            if let attributed = line.attributedString, attributed.length > 0,
               let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                size = font.pointSize
                bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            }
            return Line(text: text, box: CGRect(x: (bounds.minX - box.minX) / box.width, y: (bounds.minY - box.minY) / box.height,
                                                width: bounds.width / box.width, height: bounds.height / box.height), size: size, bold: bold)
        }
        return sorted(lines)
    }

    // MARK: Markdown

    private static let bulletMarks = Set("•·●▪◦‣∙")

    /// Headings from relative size, lists from leading marks, paragraphs from line spacing. Pages are separated by `---`.
    static func markdown(_ pages: [PageText], pageBreaks: Bool = true) -> String {
        var output: [String] = []
        for (position, page) in pages.enumerated() {
            let body = markdownBody(page)
            if body.isEmpty { continue }
            if pageBreaks, position > 0, !output.isEmpty { output.append("---") }
            output.append(body)
        }
        return output.joined(separator: "\n\n") + "\n"
    }

    static func markdownBody(_ page: PageText) -> String {
        let lines = page.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return "" }
        let sizes = lines.map(\.size).sorted()
        let body = sizes[sizes.count / 2]
        var blocks: [String] = []
        var paragraph: [String] = []
        var previous: Line?
        func flush() { if !paragraph.isEmpty { blocks.append(join(paragraph)); paragraph = [] } }
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let ratio = body > 0 ? line.size / body : 1
            if ratio >= 1.5 { flush(); blocks.append("# " + text); previous = nil; continue }
            if ratio >= 1.25 { flush(); blocks.append("## " + text); previous = nil; continue }
            if ratio >= 1.1 || (line.bold && text.count <= 60 && ratio >= 1.0 && isStandalone(line, previous: previous, page: page)) {
                flush(); blocks.append("### " + text); previous = nil; continue
            }
            if let item = listItem(text) {
                flush()
                // Consecutive items belong to one list.
                if let last = blocks.last, last.hasPrefix("- ") || last.range(of: #"^\d+\. "#, options: .regularExpression) != nil, previous != nil, isListText(previous!.text) {
                    blocks[blocks.count - 1] = last + "\n" + item
                } else { blocks.append(item) }
                previous = line; continue
            }
            if let previous, gap(between: previous, line, pageHeight: page.pageHeight) > 0.9 * max(line.size, 1) { flush() }
            paragraph.append(text)
            previous = line
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }

    private static func isListText(_ text: String) -> Bool { listItem(text.trimmingCharacters(in: .whitespaces)) != nil }

    private static func isStandalone(_ line: Line, previous: Line?, page: PageText) -> Bool {
        guard let previous else { return true }
        return gap(between: previous, line, pageHeight: page.pageHeight) > 0.6 * max(line.size, 1)
    }

    /// Blank space between two lines, in points.
    private static func gap(between upper: Line, _ lower: Line, pageHeight: CGFloat) -> CGFloat {
        (upper.box.minY - lower.box.maxY) * pageHeight
    }

    private static func listItem(_ text: String) -> String? {
        if let first = text.first, bulletMarks.contains(first) { return "- " + text.dropFirst().trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("– ") || text.hasPrefix("— ") { return "- " + text.dropFirst(2).trimmingCharacters(in: .whitespaces) }
        if let range = text.range(of: #"^\d{1,3}[.)、]\s*"#, options: .regularExpression) {
            let number = text[range].filter(\.isNumber)
            return "\(number). " + text[range.upperBound...]
        }
        return nil
    }

    /// Joins wrapped lines: no space between Chinese/Japanese characters, a space otherwise.
    private static func join(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            guard let last = result.last, let first = line.first else { result = line; continue }
            if last == "-" , result.count > 1, result.dropLast().last?.isLetter == true { result.removeLast(); result += line; continue }
            result += (isCJK(last) || isCJK(first)) ? line : " " + line
        }
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) || (0x3000...0x303F).contains($0.value) }
    }

    /// Plain text, one line per row, pages separated by a blank line.
    static func plainText(_ pages: [PageText]) -> String {
        pages.map { $0.lines.map(\.text).joined(separator: "\n") }.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    // MARK: Writing corrections back

    /// Rebuilds a scanned page: the picture as it is, with `lines` as its searchable text. Page size is kept.
    @MainActor static func correctedPage(from page: PDFPage, lines: [Line]) -> PDFPage? {
        let ocrLines = lines.map { PDFProcessing.TextLine(text: $0.text, box: $0.box) }
        return PDFProcessing.pictureWithText(from: page, lines: ocrLines)
    }
}

extension PDFProcessing {
    /// The page as a picture (detail kept up to 300 dpi) with `lines` laid over it as invisible text.
    @MainActor static func pictureWithText(from page: PDFPage, lines: [TextLine]) -> PDFPage? {
        let box = page.bounds(for: .cropBox)
        guard page.rotation == 0 else { return nil }
        let target = min(300, max(effectiveDPI(of: page) ?? 200, 100))
        let scale = target / 72
        guard let rendered = renderImage(of: page, scale: scale), let jpeg = jpegImage(from: rendered, quality: 0.88) else { return nil }
        let size = CGSize(width: CGFloat(rendered.width) / scale, height: CGFloat(rendered.height) / scale)
        guard let data = pdfData(size: size, draw: { context in
            context.draw(jpeg, in: CGRect(origin: .zero, size: size))
            drawInvisibleText(lines, in: context, size: size)
        }) else { return nil }
        return finish(data, carrying: page, cropOrigin: box.origin, rotation: page.rotation)
    }
}
