import XCTest
import PDFKit
@testable import MacPDF

@MainActor
final class M3Tests: XCTestCase {
    /// A PDF whose pages carry real, extractable vector text.
    func textDocument(_ pages: [[String]]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 72, y: 700 - CGFloat(index) * 40),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    func find(_ doc: PDFDocument, keywords: [String] = [], kinds: Set<PIIKind> = [], regex: String? = nil) throws -> [RedactionMark] {
        try Redaction.find(in: doc, keywords: keywords, kinds: kinds, regex: regex)
    }

    func testFindsPIIAndRejectsFalsePositives() throws {
        let doc = try textDocument([[
            "Mail alice@example.com now", "Card 4111 1111 1111 1111 ok", "Bad card 1234 5678 9012 3456",
            "Server 192.168.1.20 up", "ID A123456789 here", "SSN 123-45-6789 end", "Phone 0912-345-678 call",
        ]])
        let marks = try find(doc, kinds: Set(PIIKind.allCases))
        let texts = marks.map(\.text)
        XCTAssertTrue(texts.contains("alice@example.com"), "\(texts)")
        XCTAssertTrue(texts.contains { $0.hasPrefix("4111") }, "\(texts)")
        XCTAssertFalse(texts.contains { $0.hasPrefix("1234 5678") }, "Luhn should reject: \(texts)")
        XCTAssertTrue(texts.contains("192.168.1.20"))
        XCTAssertTrue(texts.contains("A123456789"))
        XCTAssertTrue(texts.contains("123-45-6789"))
        XCTAssertTrue(texts.contains { $0.hasPrefix("0912") })
        XCTAssertTrue(marks.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
    }

    func testKeywordAndRegexAreCaseInsensitiveAndValidated() throws {
        let doc = try textDocument([["Project Falcon is secret", "falcon again"]])
        XCTAssertEqual(try find(doc, keywords: ["FALCON"]).count, 2)
        XCTAssertEqual(try find(doc, regex: "sec\\w+").count, 1)
        XCTAssertThrowsError(try find(doc, regex: "(unclosed"))
    }

    func testRedactedPageHasNoTextAnnotationsOrMetadata() throws {
        let doc = try textDocument([["Contact alice@example.com", "keep this line"], ["page two stays selectable"]])
        doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "SECRET-TITLE-XYZ"]
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 40, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://secret.example/path")
        try XCTUnwrap(doc.page(at: 0)).addAnnotation(link)
        let root = PDFOutline(); let entry = PDFOutline(); entry.label = "SECRET-OUTLINE"
        entry.destination = PDFDestination(page: try XCTUnwrap(doc.page(at: 0)), at: .zero); root.insertChild(entry, at: 0); doc.outlineRoot = root

        let marks = try find(doc, kinds: [.email])
        XCTAssertEqual(marks.count, 1)
        let built = try XCTUnwrap(awaitBuild(doc, marks))
        let report = Redaction.verify(built, source: doc, marks: marks)
        XCTAssertTrue(report.passed, "failed pages \(report.failedPages)")
        XCTAssertEqual(built.pageCount, 2)
        XCTAssertFalse((built.page(at: 0)?.string ?? "").contains("alice"))
        XCTAssertFalse((built.page(at: 0)?.string ?? "").contains("keep this"), "the whole page is rebuilt as a picture")
        XCTAssertTrue((built.page(at: 1)?.string ?? "").contains("page two"), "untouched pages keep their text")
        XCTAssertTrue(try XCTUnwrap(built.page(at: 0)).annotations.isEmpty)

        let bytes = try XCTUnwrap(built.dataRepresentation())
        for secret in ["alice@example.com", "SECRET-TITLE-XYZ", "SECRET-OUTLINE", "secret.example"] {
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), "\(secret) is still in the file")
        }
        XCTAssertNil(built.outlineRoot?.child(at: 0))
        // Source untouched.
        XCTAssertTrue((doc.page(at: 0)?.string ?? "").contains("alice"))
    }

    func testVerifyCatchesAnUnredactedPage() throws {
        let doc = try textDocument([["alice@example.com"]])
        let marks = try find(doc, kinds: [.email])
        // Pretending the original is the output must fail: text is still there and the region is not black.
        let report = Redaction.verify(doc, source: doc, marks: marks)
        XCTAssertEqual(report.failedPages, [1])
    }

    func testRotatedPageIsPaintedWhereTheMarkIs() throws {
        let doc = try textDocument([["rotated secret@example.org line"]])
        let page = try XCTUnwrap(doc.page(at: 0))
        page.rotation = 90
        let marks = try find(doc, kinds: [.email])
        XCTAssertEqual(marks.count, 1)
        let built = try XCTUnwrap(awaitBuild(doc, marks))
        let size = try XCTUnwrap(built.page(at: 0)).bounds(for: .cropBox).size
        XCTAssertEqual(size.width, 792, accuracy: 1); XCTAssertEqual(size.height, 612, accuracy: 1)
        XCTAssertTrue(Redaction.verify(built, source: doc, marks: marks).passed)
    }

    func testManualBoxOnAPictureIsBurnedIn() throws {
        let image = NSImage(size: NSSize(width: 600, height: 400))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 400).fill()
        NSColor.black.setFill(); NSRect(x: 100, y: 100, width: 50, height: 50).fill()
        image.unlockFocus()
        let doc = PDFDocument(); doc.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        // A box over white paper must come out black.
        let mark = RedactionMark(page: 0, rect: CGRect(x: 300, y: 200, width: 80, height: 40), text: "manual", source: .manual)
        let built = try XCTUnwrap(awaitBuild(doc, [mark]))
        XCTAssertTrue(Redaction.verify(built, source: doc, marks: [mark]).passed)
    }

    func testOverlaysCanBeAddedAndFullyRemoved() throws {
        let doc = try textDocument([["a@b.co"]])
        let mark = RedactionMark(page: 0, rect: CGRect(x: 10, y: 10, width: 50, height: 20), text: "x", source: .manual)
        Redaction.show(mark, on: doc)
        XCTAssertEqual(try XCTUnwrap(doc.page(at: 0)).annotations.count, 1)
        Redaction.removeOverlay(for: mark.id, in: doc)
        XCTAssertTrue(try XCTUnwrap(doc.page(at: 0)).annotations.isEmpty)
        Redaction.show(mark, on: doc); Redaction.clearOverlays(in: doc)
        XCTAssertTrue(try XCTUnwrap(doc.page(at: 0)).annotations.isEmpty)
    }

    /// `Redaction.build` is async only to yield between pages; tests run it to completion.
    func awaitBuild(_ doc: PDFDocument, _ marks: [RedactionMark]) -> PDFDocument? {
        let done = expectation(description: "build")
        var result: PDFDocument?
        Task { @MainActor in result = await Redaction.build(from: doc, marks: marks); done.fulfill() }
        wait(for: [done], timeout: 30)
        return result
    }
}
