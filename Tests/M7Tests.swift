import XCTest
import PDFKit
@testable import MacPDF

@MainActor
final class M7Tests: XCTestCase {
    func textDocument(_ pages: [[String]]) throws -> PDFDocument { try M3Tests().textDocument(pages) }
    func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    func openModel(_ pages: [[String]]) throws -> ReaderModel {
        let url = try tempFolder().appendingPathComponent("doc.pdf")
        XCTAssertTrue(try textDocument(pages).write(to: url))
        let model = ReaderModel(); model.open(url)
        return model
    }
    func finishSearch(_ model: ReaderModel) async {
        for _ in 0..<200 where model.isSearching { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Search

    func testSearchOptionsCaseAndWholeWord() async throws {
        let model = try openModel([["Cat concatenate CAT category", "a cat sat"]])
        model.find("cat"); await finishSearch(model)
        XCTAssertEqual(model.results.count, 5, "case-insensitive substring: Cat, conCATenate, CAT, CATegory, cat on page 2")
        model.searchCaseSensitive = true
        model.find("cat"); await finishSearch(model)
        XCTAssertEqual(model.results.map { $0.string ?? "" }.filter { $0 == "cat" }.count, model.results.count)
        XCTAssertLessThan(model.results.count, 5)
        model.searchCaseSensitive = false; model.searchWholeWord = true
        model.find("cat"); await finishSearch(model)
        XCTAssertEqual(model.results.count, 3, "Cat, CAT and cat as whole words")
        _ = model.discardChanges()
    }

    func testResultStepping() async throws {
        let model = try openModel([["one two one", "one"]])
        model.find("one"); await finishSearch(model)
        XCTAssertEqual(model.results.count, 3)
        model.nextResult(); XCTAssertEqual(model.resultIndex, 0)
        model.nextResult(); model.nextResult(); XCTAssertEqual(model.resultIndex, 2)
        model.nextResult(); XCTAssertEqual(model.resultIndex, 0, "wraps")
        model.previousResult(); XCTAssertEqual(model.resultIndex, 2, "wraps backwards")
        model.find(""); XCTAssertTrue(model.results.isEmpty); XCTAssertNil(model.resultIndex)
    }

    func testCJKWholeWordSearch() async throws {
        let model = try openModel([["付款期限 付款"]])
        model.find("付款"); await finishSearch(model)
        XCTAssertEqual(model.results.count, 2)
    }

    // MARK: View modes

    func testViewModesMapToPDFKit() throws {
        let model = try openModel([["a"], ["b"]])
        for (mode, expected) in [(ViewMode.single, PDFDisplayMode.singlePage), (.continuous, .singlePageContinuous), (.twoUp, .twoUp), (.twoUpContinuous, .twoUpContinuous)] {
            model.setViewMode(mode)
            XCTAssertEqual(model.pdfView.displayMode, expected)
            XCTAssertEqual(model.viewMode, mode)
        }
        model.actualSize()
        XCTAssertEqual(model.pdfView.scaleFactor, 1, accuracy: 0.001)
        XCTAssertFalse(model.pdfView.autoScales)
        model.fitPage(); XCTAssertTrue(model.pdfView.autoScales)
    }

    // MARK: Image pages

    func testImagePageSheets() throws {
        let image = NSImage(size: NSSize(width: 400, height: 200))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 400, height: 200).fill(); image.unlockFocus()
        var rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let a4 = try XCTUnwrap(PDFProcessing.page(fromImage: cg, sheet: .a4)).bounds(for: .cropBox).size
        XCTAssertEqual(a4.width, 841.89, accuracy: 0.1); XCTAssertEqual(a4.height, 595.28, accuracy: 0.1, "landscape picture gets a landscape sheet")
        let letter = try XCTUnwrap(PDFProcessing.page(fromImage: cg, sheet: .letter)).bounds(for: .cropBox).size
        XCTAssertEqual(letter.width, 792, accuracy: 0.1)
        let own = try XCTUnwrap(PDFProcessing.page(fromImage: cg, sheet: .image)).bounds(for: .cropBox).size
        XCTAssertEqual(own.width / own.height, 2, accuracy: 0.01, "page takes the picture's own shape")
    }

    func testAppendPagesAtAPosition() throws {
        let edit = PDFEditing(document: try textDocument([["one"], ["two"]]))
        let extra = try XCTUnwrap(try textDocument([["extra"]]).page(at: 0)?.copy() as? PDFPage)
        try edit.appendPages([extra], before: 1)
        XCTAssertEqual((0..<3).map { (edit.document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }, ["one", "extra", "two"])
        try edit.undo(); XCTAssertEqual(edit.document.pageCount, 2)
    }
}
