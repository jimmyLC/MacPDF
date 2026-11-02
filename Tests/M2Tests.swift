import XCTest
import PDFKit
@testable import MacPDF

@MainActor
final class M2Tests: XCTestCase {
    func scanImage(_ text: String, size: NSSize = NSSize(width: 900, height: 400)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: size.height / 2),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return image
    }
    func scanDocument(_ lines: [String]) throws -> PDFDocument {
        let doc = PDFDocument()
        for (index, text) in lines.enumerated() { doc.insert(try XCTUnwrap(PDFPage(image: scanImage(text))), at: index) }
        return doc
    }
    func temp(_ ext: String = "pdf") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func reopen(_ edit: PDFEditing) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: try XCTUnwrap(edit.document.dataRepresentation())))
    }

    // MARK: OCR

    func testOCRProducesSearchableTextAtTheRightPlace() throws {
        let doc = try scanDocument(["Invoice 2026 hello world", "second page"])
        XCTAssertFalse(PDFProcessing.hasText(try XCTUnwrap(doc.page(at: 0))))
        let page = try XCTUnwrap(doc.page(at: 0))
        let image = try XCTUnwrap(PDFProcessing.renderImage(of: page, scale: PDFProcessing.ocrScale))
        let lines = try PDFProcessing.recognize(image)
        XCTAssertFalse(lines.isEmpty, "Vision returned nothing")
        let rebuilt = try XCTUnwrap(PDFProcessing.searchablePage(from: page, lines: lines))
        let edit = PDFEditing(document: doc)
        try edit.replace(pages: [0: rebuilt])
        let reopened = try reopen(edit)
        XCTAssertEqual(reopened.pageCount, 2)
        let matches = reopened.findString("Invoice", withOptions: .caseInsensitive)
        let match = try XCTUnwrap(matches.first, "text layer not searchable: \(reopened.string ?? "nil")")
        let bounds = match.bounds(for: try XCTUnwrap(reopened.page(at: 0)))
        // The words were drawn near x=40 and mid-height of a 900x400 page.
        XCTAssertLessThan(bounds.minX, 200)
        XCTAssertTrue((150...300).contains(bounds.midY), "unexpected y \(bounds)")
        XCTAssertTrue(edit.canUndo)
        XCTAssertEqual((0..<2).map { edit.document.page(at: $0)?.label }, ["1", "2"])
    }

    func testOCRRecognisesTraditionalChinese() throws {
        let doc = try scanDocument(["繁體中文測試 發票"])
        let page = try XCTUnwrap(doc.page(at: 0))
        let lines = try PDFProcessing.recognize(try XCTUnwrap(PDFProcessing.renderImage(of: page, scale: PDFProcessing.ocrScale)))
        let joined = lines.map(\.text).joined()
        XCTAssertTrue(joined.contains("中文") || joined.contains("測試"), "recognised: \(joined)")
    }

    func testReplacingPagesKeepsBookmarksAndLinks() throws {
        let doc = try scanDocument(["one", "two"])
        let first = try XCTUnwrap(doc.page(at: 0)), second = try XCTUnwrap(doc.page(at: 1))
        let link = PDFAnnotation(bounds: CGRect(x: 5, y: 5, width: 30, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: 100)); second.addAnnotation(link)
        let root = PDFOutline(); let entry = PDFOutline(); entry.label = "Start"
        entry.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: 100)); root.insertChild(entry, at: 0); doc.outlineRoot = root
        let edit = PDFEditing(document: doc)
        try edit.replace(pages: [0: try XCTUnwrap(first.copy() as? PDFPage)])
        let result = try reopen(edit)
        XCTAssertEqual(result.index(for: try XCTUnwrap(result.outlineRoot?.child(at: 0)?.destination?.page)), 0)
        let linkTarget = try XCTUnwrap(result.page(at: 1)?.annotations.first?.destination?.page)
        XCTAssertEqual(result.index(for: linkTarget), 0)
    }

    // MARK: Compression

    func testCompressionShrinksScansAndKeepsPageSize() throws {
        let size = NSSize(width: 1200, height: 1600)
        let image = NSImage(size: size)
        image.lockFocus()
        for _ in 0..<2500 {
            NSColor(calibratedRed: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1).setFill()
            NSRect(x: .random(in: 0...1150), y: .random(in: 0...1550), width: 60, height: 60).fill()
        }
        image.unlockFocus()
        let doc = PDFDocument(); doc.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let before = try XCTUnwrap(doc.dataRepresentation()).count
        let page = try XCTUnwrap(doc.page(at: 0))
        let small = try XCTUnwrap(PDFProcessing.compressedPage(from: page, preset: .small))
        let edit = PDFEditing(document: doc)
        try edit.replace(pages: [0: small])
        let after = try XCTUnwrap(edit.document.dataRepresentation()).count
        XCTAssertLessThan(after, before)
        let bounds = try XCTUnwrap(edit.document.page(at: 0)).bounds(for: .cropBox)
        XCTAssertEqual(bounds.width, 1200, accuracy: 1); XCTAssertEqual(bounds.height, 1600, accuracy: 1)
    }

    func testCompressionKeepsTheTextLayerOfRecognisedScans() throws {
        let doc = try scanDocument(["Invoice 2026 hello world"])
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertTrue(PDFProcessing.isImageDominant(page))
        let lines = try PDFProcessing.recognize(try XCTUnwrap(PDFProcessing.renderImage(of: page, scale: PDFProcessing.ocrScale)))
        let edit = PDFEditing(document: doc)
        try edit.replace(pages: [0: try XCTUnwrap(PDFProcessing.searchablePage(from: page, lines: lines))])
        let recognised = try XCTUnwrap(edit.document.page(at: 0))
        XCTAssertTrue(PDFProcessing.isImageDominant(recognised))
        try edit.replace(pages: [0: try XCTUnwrap(PDFProcessing.compressedPage(from: recognised, preset: .standard))])
        let result = try reopen(edit)
        XCTAssertFalse(result.findString("Invoice", withOptions: .caseInsensitive).isEmpty, "text layer lost: \(result.string ?? "nil")")
    }

    func testVectorTextPageIsNotTreatedAsAScan() throws {
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let data = NSMutableData()
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Plain vector text page", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        context.textPosition = CGPoint(x: 40, y: 700); CTLineDraw(line, context)
        context.endPDFPage(); context.closePDF()
        let page = try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
        XCTAssertFalse(PDFProcessing.isImageDominant(page))
    }

    // MARK: Forms

    func formDocument() throws -> PDFDocument {
        let doc = try scanDocument(["Form"])
        let page = try XCTUnwrap(doc.page(at: 0))
        let field = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 220, height: 30), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "name"; field.widgetStringValue = "FILLED VALUE"
        page.addAnnotation(field)
        let note = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "keep me"; page.addAnnotation(note)
        return doc
    }
    func testFlattenFormsBurnsFieldsButKeepsOtherAnnotations() throws {
        let edit = PDFEditing(document: try formDocument())
        XCTAssertEqual(PDFEditing.widgets(in: edit.document).count, 1)
        try edit.flattenForms()
        let result = try reopen(edit)
        XCTAssertTrue(PDFEditing.widgets(in: result).isEmpty)
        XCTAssertTrue((result.string ?? "").contains("FILLED VALUE"))
        XCTAssertTrue(try XCTUnwrap(result.page(at: 0)).annotations.contains { $0.contents == "keep me" })
        try edit.undo()
        XCTAssertEqual(PDFEditing.widgets(in: edit.document).count, 1)
    }
    func testResetFormClearsValuesAndCanUndo() throws {
        let edit = PDFEditing(document: try formDocument())
        try edit.resetFormFields()
        XCTAssertEqual(PDFEditing.widgets(in: edit.document).first?.widgetStringValue ?? "", "")
        try edit.undo()
        XCTAssertEqual(PDFEditing.widgets(in: edit.document).first?.widgetStringValue, "FILLED VALUE")
    }

    // MARK: Metadata, images

    func testMetadataRoundTrip() throws {
        let edit = PDFEditing(document: try scanDocument(["x"]))
        try edit.setMetadata([.titleAttribute: "Quarterly", .authorAttribute: "Jimmy", .keywordsAttribute: ["a", "b"]])
        let result = try reopen(edit)
        XCTAssertEqual(result.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Quarterly")
        XCTAssertEqual(result.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Jimmy")
        try edit.setMetadata([:])
        let cleared = try reopen(edit)
        XCTAssertNil(cleared.documentAttributes?[PDFDocumentAttribute.titleAttribute])
        XCTAssertNil(cleared.documentAttributes?[PDFDocumentAttribute.authorAttribute])
    }
    func testAppendImagesFitsAnA4Page() throws {
        let png = temp("png")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(scanImage("pic", size: NSSize(width: 3000, height: 2000)).tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let edit = PDFEditing(document: try scanDocument(["base"]))
        try edit.appendImages([png])
        XCTAssertEqual(edit.document.pageCount, 2)
        let bounds = try XCTUnwrap(edit.document.page(at: 1)).bounds(for: .cropBox)
        XCTAssertEqual(bounds.width, 841.89, accuracy: 1)   // landscape A4
        XCTAssertEqual(bounds.height, 595.28, accuracy: 1)
        XCTAssertThrowsError(try edit.appendImages([temp("png")]))
    }

    // MARK: Protection

    func testEncryptedCopyNeedsPasswordAndUnlockedCopyDoesNot() throws {
        let edit = PDFEditing(document: try scanDocument(["secret"]))
        let locked = temp()
        try edit.exportEncrypted(to: locked, userPassword: "open-sesame", ownerPassword: "owner-pw", permissions: .init(printing: true, copying: false, editing: false))
        let encrypted = try XCTUnwrap(PDFDocument(url: locked))
        XCTAssertTrue(encrypted.isLocked)
        XCTAssertFalse(encrypted.unlock(withPassword: "wrong"))
        XCTAssertTrue(encrypted.unlock(withPassword: "open-sesame"))
        XCTAssertFalse(encrypted.allowsCopying)
        XCTAssertThrowsError(try edit.exportEncrypted(to: locked, userPassword: "x", ownerPassword: nil, permissions: .init()))

        let unlockedEdit = PDFEditing(document: encrypted)
        let open = temp()
        try unlockedEdit.exportUnlocked(to: open)
        let plain = try XCTUnwrap(PDFDocument(url: open))
        XCTAssertFalse(plain.isEncrypted)
        XCTAssertFalse(plain.isLocked)
        XCTAssertEqual(plain.pageCount, 1)
    }
}
