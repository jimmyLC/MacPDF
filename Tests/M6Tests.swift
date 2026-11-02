import XCTest
import PDFKit
@testable import MacPDF

@MainActor
final class M6Tests: XCTestCase {
    func numbered(_ count: Int) throws -> PDFDocument {
        try M3Tests().textDocument((1...count).map { ["page marker \($0)"] })
    }
    func order(_ doc: PDFDocument) -> [Int] {
        (0..<doc.pageCount).map { index in
            let text = doc.page(at: index)?.string ?? ""
            return Int(text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? -1
        }
    }
    func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testMovingAGroupKeepsItsOrder() throws {
        let edit = PDFEditing(document: try numbered(6))
        let placed = try edit.move(pages: [1, 3], before: 5)
        XCTAssertEqual(order(edit.document), [1, 3, 5, 2, 4, 6])
        XCTAssertEqual(placed, [3, 4])
        try edit.undo()
        XCTAssertEqual(order(edit.document), [1, 2, 3, 4, 5, 6])
    }

    func testMoveToFrontAndToEnd() throws {
        let edit = PDFEditing(document: try numbered(5))
        try edit.move(pages: [3, 4], before: 0)
        XCTAssertEqual(order(edit.document), [4, 5, 1, 2, 3])
        try edit.move(pages: [0], before: 5)
        XCTAssertEqual(order(edit.document), [5, 1, 2, 3, 4])
        XCTAssertEqual((0..<5).map { edit.document.page(at: $0)?.label }, ["1", "2", "3", "4", "5"])
    }

    func testBadMovesAreRejectedWithoutChange() throws {
        let edit = PDFEditing(document: try numbered(3))
        XCTAssertThrowsError(try edit.move(pages: [7], before: 0))
        XCTAssertThrowsError(try edit.move(pages: [0], before: 9))
        XCTAssertThrowsError(try edit.move(pages: [], before: 0))
        XCTAssertEqual(order(edit.document), [1, 2, 3])
        XCTAssertFalse(edit.canUndo)
    }

    func testDeleteAndRotateSeveralPages() throws {
        let edit = PDFEditing(document: try numbered(5))
        try edit.rotate(pages: [0, 2, 2])
        XCTAssertEqual((0..<5).map { edit.document.page(at: $0)?.rotation }, [90, 0, 90, 0, 0])
        try edit.delete(pages: [1, 3])
        XCTAssertEqual(order(edit.document), [1, 3, 5])
        XCTAssertThrowsError(try edit.delete(pages: [0, 1, 2]), "cannot delete every page")
        XCTAssertEqual(edit.document.pageCount, 3)
    }

    func testExtractingASelectionKeepsDocumentOrder() throws {
        let edit = PDFEditing(document: try numbered(6))
        let url = try tempFolder().appendingPathComponent("picked.pdf")
        try edit.extract(pageList: [4, 0, 1], to: url)
        XCTAssertEqual(order(try XCTUnwrap(PDFDocument(url: url))), [1, 2, 5])
    }

    func testImageExportSizeFormatAndCap() throws {
        let doc = try numbered(1)
        let page = try XCTUnwrap(doc.page(at: 0))
        let png = try XCTUnwrap(PDFProcessing.imageData(of: page, dpi: 144, format: .png))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 1224); XCTAssertEqual(rep.pixelsHigh, 1584)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let jpeg = try XCTUnwrap(PDFProcessing.imageData(of: page, dpi: 72, format: .jpeg))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        let huge = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(PDFProcessing.imageData(of: page, dpi: 2400, format: .png))))
        XCTAssertLessThanOrEqual(max(huge.pixelsWide, huge.pixelsHigh), 10_000)
    }

    func testImageNamesNeverCollide() throws {
        let folder = try tempFolder()
        let first = PDFProcessing.imageURL(base: "doc", number: 2, width: 3, format: .png, in: folder)
        XCTAssertEqual(first.lastPathComponent, "doc-002.png")
        try Data("x".utf8).write(to: first)
        XCTAssertEqual(PDFProcessing.imageURL(base: "doc", number: 2, width: 3, format: .png, in: folder).lastPathComponent, "doc-002 2.png")
        XCTAssertEqual(PDFProcessing.imageURL(base: "doc", number: 2, width: 3, format: .jpeg, in: folder).lastPathComponent, "doc-002.jpg")
    }

    func testSelectionRulesAndMoveUpdatesSelection() throws {
        let doc = try numbered(6)
        let url = try tempFolder().appendingPathComponent("six.pdf")
        XCTAssertTrue(doc.write(to: url))
        let model = ReaderModel()
        model.open(url)
        XCTAssertEqual(model.pageCount, 6)
        XCTAssertEqual(model.targetPages, [0], "with no selection commands act on the page on screen")
        model.selectPage(1, extend: false, toggle: false)
        model.selectPage(3, extend: true, toggle: false)
        XCTAssertEqual(model.selectedPages, [1, 2, 3])
        model.selectPage(5, extend: false, toggle: true)
        XCTAssertEqual(model.selectedPages, [1, 2, 3, 5])
        model.selectPage(2, extend: false, toggle: true)
        XCTAssertEqual(model.selectedPages, [1, 3, 5])
        model.movePages([1, 3], before: 6)
        XCTAssertEqual(order(try XCTUnwrap(model.document)), [1, 3, 5, 6, 2, 4])
        XCTAssertEqual(model.selectedPages, [4, 5])
        model.deleteCurrentPage()
        XCTAssertEqual(model.pageCount, 4)
        XCTAssertTrue(model.selectedPages.isEmpty)
        _ = model.discardChanges()
    }
}
