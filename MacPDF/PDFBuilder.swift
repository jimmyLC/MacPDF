import AppKit
import PDFKit

/// Builds a document from pictures, other PDFs and blank pages, in the order given.
enum PDFBuilder {
    enum Item {
        case image(URL)
        /// `ranges` such as "1-3, 5"; empty means every page.
        case pdf(URL, ranges: String)
        case blank
        case clipboard(CGImage)
    }

    enum BuildError: LocalizedError {
        case nothing, unreadable(String), locked(String), badRange(String)
        var errorDescription: String? {
            switch self {
            case .nothing: L("請先加入至少一個項目。")
            case .unreadable(let name): String(format: L("無法讀取「%@」。"), name)
            case .locked(let name): String(format: L("「%@」是加密的 PDF，請先儲存無密碼副本。"), name)
            case .badRange(let name): String(format: L("「%@」的頁碼範圍不正確。"), name)
            }
        }
    }

    static func blankPage(sheet: PDFProcessing.PageSheet) -> PDFPage {
        blankPage(size: sheet.portrait ?? PDFProcessing.PageSheet.a4.portrait!)
    }

    static func blankPage(size: CGSize) -> PDFPage {
        let page = PDFPage()
        let area = CGRect(origin: .zero, size: size)
        page.setBounds(area, for: .mediaBox); page.setBounds(area, for: .cropBox)
        return page
    }

    /// Reads every item now, so security-scoped files only have to stay open for this call.
    @MainActor static func build(_ items: [Item], sheet: PDFProcessing.PageSheet) throws -> PDFDocument {
        guard !items.isEmpty else { throw BuildError.nothing }
        let output = PDFDocument()
        for item in items {
            switch item {
            case .blank:
                output.insert(blankPage(sheet: sheet), at: output.pageCount)
            case .clipboard(let image):
                guard let page = PDFProcessing.page(fromImage: image, sheet: sheet) else { throw BuildError.unreadable(L("剪貼簿的圖片")) }
                output.insert(page, at: output.pageCount)
            case .image(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let page = PDFProcessing.page(fromImageAt: url, sheet: sheet) else { throw BuildError.unreadable(url.lastPathComponent) }
                output.insert(page, at: output.pageCount)
            case .pdf(let url, let ranges):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let source = PDFDocument(url: url), source.pageCount > 0 else { throw BuildError.unreadable(url.lastPathComponent) }
                guard !source.isLocked, !source.isEncrypted else { throw BuildError.locked(url.lastPathComponent) }
                let chosen: [ClosedRange<Int>]
                if ranges.trimmingCharacters(in: .whitespaces).isEmpty { chosen = [1...source.pageCount] }
                else {
                    guard let parsed = try? PDFEditing.parseRanges(ranges, pageCount: source.pageCount) else { throw BuildError.badRange(url.lastPathComponent) }
                    chosen = parsed
                }
                for range in chosen { try PDFEditing.copyPages(from: source, range: (range.lowerBound - 1)..<range.upperBound, into: output) }
            }
        }
        // A round trip gives the new document clean page labels.
        guard let data = output.dataRepresentation(), let clean = PDFDocument(data: data) else { throw BuildError.nothing }
        return clean
    }
}

extension PDFEditing {
    /// Puts copies of every page of `other` at `index` (nil = the end), keeping links and bookmarks inside the new pages.
    func insert(_ other: PDFDocument, before index: Int?) throws {
        guard other.pageCount > 0 else { throw EditError.invalidPage }
        try mutate { doc in
            let old = doc.pageCount
            try Self.copyPages(from: other, range: 0..<other.pageCount, into: doc)
            let at = min(max(index ?? old, 0), old)
            guard at < old else { return }
            // The new pages were appended; move them in front of the requested page.
            let added = (old..<doc.pageCount).compactMap { doc.page(at: $0) }
            for position in (old..<doc.pageCount).reversed() { doc.removePage(at: position) }
            for (offset, page) in added.enumerated() { doc.insert(page, at: at + offset) }
        }
        reparse()
    }

    func rotate(pages: [Int], by degrees: Int) throws {
        try mutate { doc in
            for index in try Self.cleanPages(pages, count: doc.pageCount) {
                guard let page = doc.page(at: index) else { throw EditError.invalidPage }
                page.rotation = (((page.rotation + degrees) % 360) + 360) % 360
            }
        }
    }

    /// An empty page of the given size (points) before `index`.
    func insertBlankPage(before index: Int, size: CGSize) throws {
        try mutate { doc in
            guard index >= 0, index <= doc.pageCount else { throw EditError.invalidPage }
            doc.insert(PDFBuilder.blankPage(size: size), at: index)
        }
        reparse()
    }
}
