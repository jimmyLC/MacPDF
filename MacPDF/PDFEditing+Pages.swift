import AppKit
import PDFKit

/// Blank pages and splitting into several files.
extension PDFEditing {
    /// Adds an empty page the size of `reference` as seen on screen. `after` false puts it in front.
    func insertBlankPage(relativeTo reference: Int, after: Bool) throws {
        try mutate { doc in
            guard let page = doc.page(at: reference) else { throw EditError.invalidPage }
            let box = page.bounds(for: .cropBox)
            let sideways = page.rotation % 180 != 0
            let size = CGSize(width: sideways ? box.height : box.width, height: sideways ? box.width : box.height)
            let blank = PDFPage()
            let area = CGRect(origin: .zero, size: size)
            blank.setBounds(area, for: .mediaBox)
            blank.setBounds(area, for: .cropBox)
            doc.insert(blank, at: after ? reference + 1 : reference)
        }
        reparse()
    }

    /// "1-3, 5, 8-10" (also full-width commas and dashes) as page ranges, in the order written.
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let folded = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let normalized = folded.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "－", with: "-")
        var ranges: [ClosedRange<Int>] = []
        for piece in normalized.split(separator: ",") {
            let parts = piece.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count <= 2, let first = Int(parts[0]) else { throw EditError.invalidPage }
            let last = parts.count == 2 ? Int(parts[1]) : first
            guard let last, first >= 1, last >= first, last <= pageCount else { throw EditError.invalidPage }
            ranges.append(first...last)
        }
        guard !ranges.isEmpty else { throw EditError.invalidPage }
        return ranges
    }

    /// Writes each range as its own new file in `folder`, named `base-001.pdf` or `base-001-003.pdf`.
    /// Existing files are never replaced; a number is added instead. Returns the files written.
    @discardableResult
    func split(ranges: [ClosedRange<Int>], into folder: URL, baseName: String) throws -> [URL] {
        guard !document.isEncrypted else { throw EditError.encryptedInput }
        guard !Self.containsSignatureField(document) else { throw EditError.signatureField }
        guard ranges.allSatisfy({ $0.lowerBound >= 1 && $0.upperBound <= document.pageCount }) else { throw EditError.invalidPage }
        let width = max(3, String(document.pageCount).count)
        func number(_ n: Int) -> String { String(format: "%0\(width)d", n) }
        var written: [URL] = []
        for range in ranges {
            let output = PDFDocument()
            try Self.copyPages(from: document, range: (range.lowerBound - 1)..<range.upperBound, into: output)
            let stem = range.count == 1 ? "\(baseName)-\(number(range.lowerBound))" : "\(baseName)-\(number(range.lowerBound))-\(number(range.upperBound))"
            var target = folder.appendingPathComponent(stem + ".pdf")
            var counter = 2
            while FileManager.default.fileExists(atPath: target.path) && counter < 1000 {
                target = folder.appendingPathComponent("\(stem) \(counter).pdf"); counter += 1
            }
            guard let data = output.dataRepresentation() else { throw EditError.cannotSerialize }
            try Self.writeNew(data: data, to: target)
            written.append(target)
        }
        return written
    }
}
