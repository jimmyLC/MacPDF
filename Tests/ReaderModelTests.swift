import XCTest
import PDFKit
@testable import MacPDF

@MainActor
final class ReaderModelTests: XCTestCase {
    private func fixture(password: String? = nil, pages: Int = 1) throws -> URL {
        let pdf = PDFDocument()
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill(); image.unlockFocus()
        for index in 0..<pages { pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: index) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let options: [PDFDocumentWriteOption: Any] = password.map { [.userPasswordOption: $0, .ownerPasswordOption: "owner-password"] } ?? [:]
        XCTAssertTrue(pdf.write(to: url, withOptions: options))
        return url
    }

    func testInvalidFileDoesNotReplaceOpenDocument() throws {
        let model = ReaderModel()
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        model.open(url)
        XCTAssertEqual(model.document?.pageCount, 1)
        model.open(url.appendingPathExtension("missing"))
        XCTAssertEqual(model.document?.pageCount, 1)
        XCTAssertNotNil(model.error)
    }

    func testEncryptedFileRequiresCorrectPassword() throws {
        let url = try fixture(password: "test-password")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = ReaderModel()
        model.open(url)
        XCTAssertTrue(model.needsPassword)
        XCTAssertNil(model.document)
        model.unlock("wrong")
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.document)
        model.error = nil
        model.open(url)
        model.unlock("test-password")
        XCTAssertFalse(model.needsPassword)
        XCTAssertEqual(model.document?.pageCount, 1)
    }

    func testPageNavigationRespectsDocumentBounds() throws {
        let url = try fixture(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = ReaderModel()
        model.open(url)
        XCTAssertEqual(model.pageCount, 3)
        XCTAssertEqual(model.currentPage, 1)
        model.goToPage(3)
        XCTAssertEqual(model.currentPage, 3)
        model.goToPage(4)
        XCTAssertEqual(model.currentPage, 3)
        model.goToPage(0)
        XCTAssertEqual(model.currentPage, 3)
        model.goToPage(1)
        XCTAssertEqual(model.currentPage, 1)
    }

    func testEndToEndEditRecoveryAndNewFile() throws {
        let input = try fixture(pages: 2)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        let original = try Data(contentsOf: input)
        let model = ReaderModel()
        model.open(input)
        model.rotateCurrentPage()
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.recoveryEntries.contains { $0.title == input.lastPathComponent })
        model.saveCopy(to: output)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 0)?.rotation, 90)
        XCTAssertFalse(model.recoveryEntries.contains { $0.title == input.lastPathComponent })
    }




}
