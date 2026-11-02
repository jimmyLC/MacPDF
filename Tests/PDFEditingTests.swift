import XCTest
import PDFKit
import Security
@testable import MacPDF

@MainActor
final class PDFEditingTests: XCTestCase {
    func makeDocument(_ pages: Int) throws -> PDFDocument {
        let doc = PDFDocument()
        let image = NSImage(size: NSSize(width: 100, height: 120))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 120).fill(); image.unlockFocus()
        for index in 0..<pages { doc.insert(try XCTUnwrap(PDFPage(image: image)), at: index) }
        return doc
    }
    func testRotateDeleteUndoRedo() throws {
        let edit = PDFEditing(document: try makeDocument(2))
        try edit.rotate(page: 0)
        XCTAssertEqual(edit.document.page(at: 0)?.rotation, 90)
        try edit.delete(page: 1)
        XCTAssertEqual(edit.document.pageCount, 1)
        XCTAssertThrowsError(try edit.delete(page: 0))
        try edit.undo()
        XCTAssertEqual(edit.document.pageCount, 2)
        try edit.undo()
        XCTAssertEqual(edit.document.page(at: 0)?.rotation, 0)
        try edit.redo()
        XCTAssertEqual(edit.document.page(at: 0)?.rotation, 90)
    }
    func testPageReorderAndUndoPreserveOrder() throws {
        let doc = try makeDocument(3)
        doc.page(at: 0)?.rotation = 0
        doc.page(at: 1)?.rotation = 90
        doc.page(at: 2)?.rotation = 180
        let edit = PDFEditing(document: doc)
        try edit.move(page: 0, to: 2)
        XCTAssertEqual((0..<3).map { edit.document.page(at: $0)?.rotation }, [90, 180, 0])
        try edit.undo()
        XCTAssertEqual((0..<3).map { edit.document.page(at: $0)?.rotation }, [0, 90, 180])
    }
    func testSignatureFieldPreventsEditing() throws {
        let doc = try makeDocument(1)
        let widget = PDFAnnotation(bounds: CGRect(x: 5, y: 5, width: 40, height: 20), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .signature
        try XCTUnwrap(doc.page(at: 0)).addAnnotation(widget)
        let edit = PDFEditing(document: doc)
        XCTAssertThrowsError(try edit.rotate(page: 0))
        XCTAssertEqual(edit.document.page(at: 0)?.rotation, 0)
    }
    func testExportNeverOverwritesExistingFile() throws {
        let edit = PDFEditing(document: try makeDocument(1))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: path) }
        let sentinel = Data("keep original".utf8)
        try sentinel.write(to: path)
        XCTAssertThrowsError(try edit.export(to: path))
        XCTAssertEqual(try Data(contentsOf: path), sentinel)
        try FileManager.default.removeItem(at: path)
        try edit.export(to: path)
        XCTAssertEqual(PDFDocument(url: path)?.pageCount, 1)
    }
    func testCrossVolumeExportCreatesCompleteFileWithoutOverwrite() throws {
        if let task = SecTaskCreateFromSelf(nil),
           (SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool) == true {
            throw XCTSkip("Requires a user-selected destination to test a sandboxed app")
        }
        let directory = ProcessInfo.processInfo.environment["MACPDF_TEST_EXTERNAL"] ?? "/private/tmp/macpdf-test-volume"
        guard FileManager.default.fileExists(atPath: directory) else { throw XCTSkip("Requires an isolated mounted test volume") }
        let manager = FileManager.default
        let externalID = try manager.attributesOfFileSystem(forPath: directory)[.systemNumber] as? NSNumber
        let temporaryID = try manager.attributesOfFileSystem(forPath: manager.temporaryDirectory.path)[.systemNumber] as? NSNumber
        guard let externalID, let temporaryID, externalID != temporaryID else { throw XCTSkip("Test volume is not mounted on a different file system") }
        let edit = PDFEditing(document: try makeDocument(1))
        let output = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try edit.export(to: output)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 1)
        let initial = try Data(contentsOf: output)
        XCTAssertThrowsError(try edit.export(to: output))
        XCTAssertEqual(try Data(contentsOf: output), initial)
    }
    func testExtractAndInkPersistWithoutChangingSource() throws {
        let edit = PDFEditing(document: try makeDocument(3))
        try edit.ink(page: 1, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40)])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: path) }
        try edit.extract(pages: 2...3, to: path)
        let extracted = try XCTUnwrap(PDFDocument(url: path))
        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertEqual(extracted.page(at: 0)?.annotations.first?.type, "Ink")
        XCTAssertEqual(edit.document.pageCount, 3)
        XCTAssertTrue(edit.dirty)
        XCTAssertThrowsError(try edit.extract(pages: 1...3, to: path))
        XCTAssertEqual(PDFDocument(url: path)?.pageCount, 2)
    }
    func testRecoveryStoreRoundTripAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        let id = UUID()
        let data = try XCTUnwrap(makeDocument(1).dataRepresentation())
        try store.save(id: id, title: "sample.pdf", data: data)
        XCTAssertEqual(store.entries().first?.id, id)
        XCTAssertEqual(PDFDocument(url: store.url(for: id))?.pageCount, 1)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json"))
        XCTAssertEqual(store.entries().first?.id, id)
        try store.remove(id)
        XCTAssertTrue(store.entries().isEmpty)
    }
    func testAppendAndAnnotationPersist() throws {
        let edit = PDFEditing(document: try makeDocument(1))
        try edit.append(makeDocument(2))
        try edit.annotate(page: 1, bounds: CGRect(x: 10, y: 10, width: 40, height: 30), text: "example", freeText: false)
        let data = try XCTUnwrap(edit.document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(reopened.pageCount, 3)
        XCTAssertEqual(reopened.page(at: 1)?.annotations.first?.contents, "example")
    }
}

@MainActor
final class PDFFidelityTests: XCTestCase {
    func testEditPreservesCropAnnotationLinkAndOutline() throws {
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 400, height: 500))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 400, height: 500).fill(); image.unlockFocus()
        let first = try XCTUnwrap(PDFPage(image: image))
        let second = try XCTUnwrap(PDFPage(image: image))
        first.setBounds(CGRect(x: 20, y: 30, width: 300, height: 350), for: .cropBox)
        let note = PDFAnnotation(bounds: CGRect(x: 40, y: 60, width: 30, height: 30), forType: .text, withProperties: nil)
        note.contents = "existing annotation"
        first.addAnnotation(note)
        let link = PDFAnnotation(bounds: CGRect(x: 80, y: 90, width: 60, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.org/test")
        first.addAnnotation(link)
        document.insert(first, at: 0); document.insert(second, at: 1)
        let root = PDFOutline(); let chapter = PDFOutline(); chapter.label = "Chapter"
        chapter.destination = PDFDestination(page: second, at: CGPoint(x: 0, y: 300))
        root.insertChild(chapter, at: 0); document.outlineRoot = root
        let editing = PDFEditing(document: document)
        try editing.rotate(page: 1)
        let data = try XCTUnwrap(editing.document.dataRepresentation())
        let result = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(result.page(at: 0))
        XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 20, y: 30, width: 300, height: 350))
        XCTAssertTrue(page.annotations.contains { $0.contents == "existing annotation" })
        XCTAssertTrue(page.annotations.contains { $0.url?.absoluteString == "https://example.org/test" })
        let savedChapter = try XCTUnwrap(result.outlineRoot?.child(at: 0))
        XCTAssertEqual(savedChapter.label, "Chapter")
        let destinationPage = try XCTUnwrap(savedChapter.destination?.page)
        XCTAssertEqual(result.index(for: destinationPage), 1)
        try editing.move(page: 1, to: 0)
        let reorderedData = try XCTUnwrap(editing.document.dataRepresentation())
        let reordered = try XCTUnwrap(PDFDocument(data: reorderedData))
        let reorderedDestination = try XCTUnwrap(reordered.outlineRoot?.child(at: 0)?.destination?.page)
        XCTAssertEqual(reordered.index(for: reorderedDestination), 0)
    }
}

@MainActor
final class PDFMergeFidelityTests: XCTestCase {
    func testAppendedPagesPreserveInternalLinksAndBookmarks() throws {
        let image = NSImage(size: NSSize(width: 100, height: 120))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 120).fill(); image.unlockFocus()
        let base = PDFDocument(); base.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let baseRoot = PDFOutline(); let baseEntry = PDFOutline(); baseEntry.label = "Original chapter"
        baseEntry.destination = PDFDestination(page: try XCTUnwrap(base.page(at: 0)), at: CGPoint(x: 0, y: 100))
        baseRoot.insertChild(baseEntry, at: 0); base.outlineRoot = baseRoot
        let source = PDFDocument()
        let first = try XCTUnwrap(PDFPage(image: image)); let second = try XCTUnwrap(PDFPage(image: image))
        source.insert(first, at: 0); source.insert(second, at: 1)
        let link = PDFAnnotation(bounds: CGRect(x: 5, y: 5, width: 30, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: second, at: CGPoint(x: 0, y: 100))); first.addAnnotation(link)
        let root = PDFOutline(); let entry = PDFOutline(); entry.label = "Appended chapter"
        entry.destination = PDFDestination(page: second, at: CGPoint(x: 0, y: 100)); root.insertChild(entry, at: 0); source.outlineRoot = root
        let edit = PDFEditing(document: base); try edit.append(source)
        let data = try XCTUnwrap(edit.document.dataRepresentation()); let result = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(result.pageCount, 3)
        let found = try XCTUnwrap(result.page(at: 1)?.annotations.first?.destination?.page)
        XCTAssertEqual(result.index(for: found), 2)
        XCTAssertEqual(result.outlineRoot?.child(at: 0)?.label, "Original chapter")
        let bookmark = try XCTUnwrap(result.outlineRoot?.child(at: 1))
        XCTAssertEqual(bookmark.label, "Appended chapter")
        XCTAssertEqual(result.index(for: try XCTUnwrap(bookmark.destination?.page)), 2)
    }
    func testExtractRebindsLinksAndRemovesTargetsOutsideRange() throws {
        let image = NSImage(size: NSSize(width: 100, height: 120))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 120).fill(); image.unlockFocus()
        let source = PDFDocument()
        for index in 0..<3 { source.insert(try XCTUnwrap(PDFPage(image: image)), at: index) }
        let first = try XCTUnwrap(source.page(at: 0))
        let included = PDFAnnotation(bounds: CGRect(x: 1, y: 1, width: 15, height: 15), forType: .link, withProperties: nil)
        included.destination = PDFDestination(page: try XCTUnwrap(source.page(at: 1)), at: CGPoint(x: 0, y: 90)); first.addAnnotation(included)
        let excluded = PDFAnnotation(bounds: CGRect(x: 20, y: 1, width: 15, height: 15), forType: .link, withProperties: nil)
        excluded.destination = PDFDestination(page: try XCTUnwrap(source.page(at: 2)), at: CGPoint(x: 0, y: 90)); first.addAnnotation(excluded)
        let root = PDFOutline(); let entry = PDFOutline(); entry.label = "Included"
        entry.destination = PDFDestination(page: try XCTUnwrap(source.page(at: 1)), at: CGPoint(x: 0, y: 90)); root.insertChild(entry, at: 0); source.outlineRoot = root
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFEditing(document: source).extract(pages: 1...2, to: output)
        let result = try XCTUnwrap(PDFDocument(url: output)); let annotations = try XCTUnwrap(result.page(at: 0)).annotations
        XCTAssertEqual(result.index(for: try XCTUnwrap(annotations[0].destination?.page)), 1)
        XCTAssertNil(annotations[1].destination)
        XCTAssertNil(annotations[1].action)
        let destination = try XCTUnwrap(result.outlineRoot?.child(at: 0)?.destination?.page)
        XCTAssertEqual(result.index(for: destination), 1)
    }

}
