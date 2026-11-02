import XCTest
import PDFKit
@testable import MacPDF

@MainActor
final class BatchTests: XCTestCase {
    func testOCRStepMakesAScanSearchable() async throws {
        let scan = try M2Tests().scanDocument(["Quarterly invoice 2026 total"])
        var options = BatchProcessor.Options(); options.ocr = true
        let data = try await BatchProcessor.process(scan, options: options)
        let result = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertFalse(result.findString("invoice", withOptions: .caseInsensitive).isEmpty, result.string ?? "nil")
    }

    func testCompressStepKeepsPageCountAndTextLayer() async throws {
        let scan = try M2Tests().scanDocument(["Annual report summary words", "second page"])
        var options = BatchProcessor.Options(); options.ocr = true; options.compress = true; options.preset = .small
        let data = try await BatchProcessor.process(scan, options: options)
        let result = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertFalse(result.findString("report", withOptions: .caseInsensitive).isEmpty)
    }

    func testEncryptedInputIsRefused() async throws {
        let plain = try M2Tests().scanDocument(["secret"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(plain.write(to: url, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
        let locked = try XCTUnwrap(PDFDocument(url: url))
        var options = BatchProcessor.Options(); options.ocr = true
        do { _ = try await BatchProcessor.process(locked, options: options); XCTFail("should refuse") }
        catch let error as PDFEditing.EditError { if case .encryptedInput = error {} else { XCTFail("\(error)") } }
    }

    func testOutputNamesNeverCollide() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let input = URL(fileURLWithPath: "/somewhere/report.pdf")
        let first = BatchProcessor.outputURL(for: input, in: folder)
        XCTAssertEqual(first.lastPathComponent, "report-批次.pdf")
        try Data("x".utf8).write(to: first)
        XCTAssertEqual(BatchProcessor.outputURL(for: input, in: folder).lastPathComponent, "report-批次 2.pdf")
    }

    func testEmptyOptionsCannotStart() {
        let model = BatchModel()
        model.add([URL(fileURLWithPath: "/a.pdf")]); model.folder = URL(fileURLWithPath: "/tmp")
        XCTAssertFalse(model.canStart)
        model.options.ocr = true
        XCTAssertTrue(model.canStart)
        model.add([URL(fileURLWithPath: "/notes.txt")])
        XCTAssertEqual(model.files.count, 1, "non-PDF files are ignored")
    }
}
