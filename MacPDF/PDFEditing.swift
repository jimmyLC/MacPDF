import AppKit
import PDFKit
import Darwin

/// Edits only the in-memory document. The source is never written by this type.
@MainActor
final class PDFEditing {
    private(set) var document: PDFDocument
    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private let maximumHistory = 20
    private let maximumHistoryBytes = 200 * 1024 * 1024
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private(set) var dirty = false

    init(document: PDFDocument, dirty: Bool = false) { self.document = document; self.dirty = dirty }
    func markDiscarded() { dirty = false }
    func markDirty() { dirty = true }
    /// Pages spliced in from another document keep that document's page labels; a round trip resets them.
    func reparse() {
        if let data = document.dataRepresentation(), let fresh = PDFDocument(data: data) { document = fresh }
    }

    enum EditError: LocalizedError {
        case cannotSerialize, historyTooLarge, signatureField, invalidPage, lastPage, noSelection, encryptedInput, outputExists, writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .cannotSerialize: return L("無法建立文件快照，未進行修改。")
            case .historyTooLarge: return L("文件過大，無法安全建立復原快照；未進行修改。")
            case .signatureField: return L("文件包含數位簽章欄位；為避免破壞簽章，目前無法編輯。")
            case .invalidPage: return L("頁碼超出範圍。")
            case .lastPage: return L("文件必須保留至少一頁。")
            case .noSelection: return L("請先選取文件中的文字。")
            case .encryptedInput: return L("加密文件目前不支援編輯，請先另存未加密的副本。")
            case .outputExists: return L("目的檔案已存在，請選擇新的檔名。")
            case .writeFailed(let message): return String(format: L("儲存失敗：%@"), message)
            }
        }
    }

    static func containsSignatureField(_ doc: PDFDocument) -> Bool {
        (0..<doc.pageCount).contains { index in
            doc.page(at: index)?.annotations.contains(where: { $0.widgetFieldType == .signature }) == true
        }
    }
    func mutate(_ action: (PDFDocument) throws -> Void) throws {
        guard !document.isEncrypted else { throw EditError.encryptedInput }
        guard !Self.containsSignatureField(document) else { throw EditError.signatureField }
        guard let before = document.dataRepresentation(), let working = PDFDocument(data: before) else { throw EditError.cannotSerialize }
        guard before.count <= maximumHistoryBytes else { throw EditError.historyTooLarge }
        try action(working)
        undoStack.append(before)
        while undoStack.count > maximumHistory || undoStack.reduce(0, { $0 + $1.count }) > maximumHistoryBytes { undoStack.removeFirst() }
        redoStack.removeAll()
        document = working
        dirty = true
    }

    func rotate(page index: Int) throws {
        try mutate { doc in
            guard let page = doc.page(at: index) else { throw EditError.invalidPage }
            page.rotation = (page.rotation + 90) % 360
        }
    }
    func delete(page index: Int) throws {
        try mutate { doc in
            guard doc.pageCount > 1 else { throw EditError.lastPage }
            guard doc.page(at: index) != nil else { throw EditError.invalidPage }
            doc.removePage(at: index)
        }
    }
    func move(page index: Int, to destination: Int) throws {
        try mutate { doc in
            guard index >= 0, index < doc.pageCount, destination >= 0, destination < doc.pageCount,
                  let page = doc.page(at: index) else { throw EditError.invalidPage }
            doc.removePage(at: index)
            doc.insert(page, at: destination)
        }
    }
    func append(_ other: PDFDocument) throws {
        guard !other.isLocked && !other.isEncrypted else { throw EditError.encryptedInput }
        guard !Self.containsSignatureField(other) else { throw EditError.signatureField }
        try mutate { doc in
            try Self.copyPages(from: other, range: 0..<other.pageCount, into: doc)
        }
    }

    /// PDFKit page copies keep destinations tied to the source document.
    /// Rebind each local destination after all target pages have been inserted.
    static func copyPages(from source: PDFDocument, range: Range<Int>, into target: PDFDocument) throws {
        var mapping: [Int: PDFPage] = [:]
        for index in range {
            guard let original = source.page(at: index), let copy = original.copy() as? PDFPage else { throw EditError.cannotSerialize }
            target.insert(copy, at: target.pageCount)
            mapping[index] = copy
        }
        func mapped(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let page = destination.page else { return nil }
            let index = source.index(for: page)
            guard let targetPage = mapping[index] else { return nil }
            let result = PDFDestination(page: targetPage, at: destination.point)
            result.zoom = destination.zoom
            return result
        }
        for index in range {
            guard let original = source.page(at: index), let copy = mapping[index] else { throw EditError.cannotSerialize }
            let originalAnnotations = original.annotations
            let copiedAnnotations = copy.annotations
            guard originalAnnotations.count == copiedAnnotations.count else { throw EditError.cannotSerialize }
            for (old, new) in zip(originalAnnotations, copiedAnnotations) {
                // Do not silently attach a destination to the wrong annotation.
                guard old.type == new.type, old.bounds == new.bounds else { throw EditError.cannotSerialize }
                if let oldDestination = old.destination {
                    // A target outside an extracted range must never point at an unrelated page.
                    new.destination = mapped(oldDestination)
                    if new.destination == nil { new.action = nil }
                }
            }
        }
        if let sourceRoot = source.outlineRoot {
            func clone(_ outline: PDFOutline) -> PDFOutline? {
                let result = PDFOutline()
                result.label = outline.label
                if let destination = outline.destination { result.destination = mapped(destination) }
                else if let action = outline.action, let copiedAction = action.copy() as? PDFAction { result.action = copiedAction }
                for index in 0..<outline.numberOfChildren {
                    if let child = outline.child(at: index), let copied = clone(child) { result.insertChild(copied, at: result.numberOfChildren) }
                }
                result.isOpen = outline.isOpen
                return result.destination != nil || result.action != nil || result.numberOfChildren > 0 ? result : nil
            }
            let root = target.outlineRoot ?? PDFOutline()
            for index in 0..<sourceRoot.numberOfChildren {
                if let child = sourceRoot.child(at: index), let copied = clone(child) { root.insertChild(copied, at: root.numberOfChildren) }
            }
            if root.numberOfChildren > 0 { target.outlineRoot = root }
        }
    }
    func annotate(page index: Int, bounds: CGRect, text: String, freeText: Bool) throws {
        try mutate { doc in
            guard let page = doc.page(at: index) else { throw EditError.invalidPage }
            let annotation = PDFAnnotation(bounds: bounds, forType: freeText ? .freeText : .text, withProperties: nil)
            annotation.contents = text
            annotation.color = freeText ? .clear : .yellow
            if freeText { annotation.font = NSFont.systemFont(ofSize: 14); annotation.fontColor = .black }
            page.addAnnotation(annotation)
        }
    }
    func highlight(page index: Int, bounds: [CGRect]) throws {
        try markup(page: index, bounds: bounds, style: .highlight, color: .yellow)
    }
    /// Highlight, underline or strike-through over text lines. Highlights are translucent; lines are solid.
    func markup(page index: Int, bounds: [CGRect], style: PDFAnnotationSubtype, color: NSColor) throws {
        guard !bounds.isEmpty else { throw EditError.noSelection }
        try mutate { doc in
            guard let page = doc.page(at: index) else { throw EditError.invalidPage }
            for rect in bounds where !rect.isEmpty {
                let annotation = PDFAnnotation(bounds: rect, forType: style, withProperties: nil)
                annotation.color = style == .highlight ? color.withAlphaComponent(0.5) : color
                annotation.quadrilateralPoints = [NSValue(point: NSPoint(x: 0, y: rect.height)), NSValue(point: NSPoint(x: rect.width, y: rect.height)), NSValue(point: .zero), NSValue(point: NSPoint(x: rect.width, y: 0))]
                page.addAnnotation(annotation)
            }
        }
    }
    func ink(page index: Int, points: [CGPoint]) throws {
        guard points.count > 1 else { return }
        try mutate { doc in
            guard let page = doc.page(at: index) else { throw EditError.invalidPage }
            let pageBounds = page.bounds(for: .cropBox)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: points[0].x - pageBounds.minX, y: points[0].y - pageBounds.minY))
            for point in points.dropFirst() { path.line(to: NSPoint(x: point.x - pageBounds.minX, y: point.y - pageBounds.minY)) }
            let annotation = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
            annotation.color = .systemBlue
            let border = PDFBorder(); border.lineWidth = 2; annotation.border = border
            annotation.add(path)
            page.addAnnotation(annotation)
        }
    }
    func undo() throws { try restore(from: &undoStack, to: &redoStack) }
    func redo() throws { try restore(from: &redoStack, to: &undoStack) }
    private func restore(from source: inout [Data], to target: inout [Data]) throws {
        guard let snapshot = source.last, let old = document.dataRepresentation(), let restored = PDFDocument(data: snapshot) else { throw EditError.cannotSerialize }
        source.removeLast(); target.append(old); document = restored; dirty = true
    }

    func extract(pages: ClosedRange<Int>, to url: URL) throws {
        guard !document.isEncrypted else { throw EditError.encryptedInput }
        guard !Self.containsSignatureField(document) else { throw EditError.signatureField }
        guard pages.lowerBound >= 1, pages.upperBound <= document.pageCount else { throw EditError.invalidPage }
        let output = PDFDocument()
        try Self.copyPages(from: document, range: (pages.lowerBound - 1)..<pages.upperBound, into: output)
        try Self.writeNew(output, to: url)
    }

    /// Exclusive creation ensures an existing file, including the source, cannot be overwritten.
    func export(to url: URL) throws {
        guard !document.isEncrypted else { throw EditError.encryptedInput }
        guard !Self.containsSignatureField(document) else { throw EditError.signatureField }
        try Self.writeNew(document, to: url)
        dirty = false
    }
    static func writeNew(_ document: PDFDocument, to url: URL) throws {
        guard let data = document.dataRepresentation() else { throw EditError.cannotSerialize }
        try writeNew(data: data, to: url)
    }
    static func writeNew(data: Data, to url: URL) throws {
        guard PDFDocument(data: data) != nil else { throw EditError.cannotSerialize }
        // The final name is created exclusively only after the full PDF is flushed.
        // For another volume, request an item-replacement directory on that volume.
        func stage(in directory: URL) throws -> URL {
            let temporary = directory.appendingPathComponent("MacPDF-\(UUID().uuidString).tmp")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw EditError.writeFailed(String(cString: strerror(errno))) }
            var failure: Int32 = 0
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count < 0 { if errno == EINTR { continue }; failure = errno; break }
                    if count == 0 { failure = EIO; break }
                    offset += count
                }
            }
            if failure == 0 && fsync(fd) != 0 { failure = errno }
            if close(fd) != 0 && failure == 0 { failure = errno }
            if failure != 0 {
                _ = unlink(temporary.path)
                throw EditError.writeFailed(String(cString: strerror(failure)))
            }
            return temporary
        }
        func createDestination(from staged: URL) throws {
            guard link(staged.path, url.path) == 0 else {
                let reason = errno
                if reason == EEXIST { throw EditError.outputExists }
                throw EditError.writeFailed(String(cString: strerror(reason)))
            }
        }
        let initial = try stage(in: FileManager.default.temporaryDirectory)
        defer { _ = unlink(initial.path) }
        if link(initial.path, url.path) == 0 { return }
        let reason = errno
        if reason == EEXIST { throw EditError.outputExists }
        guard reason == EXDEV else { throw EditError.writeFailed(String(cString: strerror(reason))) }
        let replacementDirectory: URL
        do {
            replacementDirectory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url.deletingLastPathComponent(), create: true)
        } catch { throw EditError.writeFailed(L("此儲存位置不支援安全建立檔案，請選擇其他磁碟。")) }
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        let replacement = try stage(in: replacementDirectory)
        try createDestination(from: replacement)
    }
}
