import XCTest
import PDFKit
@testable import MacPDF

@MainActor
final class M5Tests: XCTestCase {
    func textDocument(_ pages: [[String]]) throws -> PDFDocument { try M3Tests().textDocument(pages) }
    func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testBlankPageMatchesNeighbourAndCanBeUndone() throws {
        let edit = PDFEditing(document: try textDocument([["one"], ["two"]]))
        try edit.insertBlankPage(relativeTo: 0, after: true)
        XCTAssertEqual(edit.document.pageCount, 3)
        let blank = try XCTUnwrap(edit.document.page(at: 1))
        XCTAssertEqual(blank.bounds(for: .cropBox).size, CGSize(width: 612, height: 792))
        XCTAssertTrue((blank.string ?? "").isEmpty)
        XCTAssertTrue((edit.document.page(at: 2)?.string ?? "").contains("two"))
        XCTAssertEqual((0..<3).map { edit.document.page(at: $0)?.label }, ["1", "2", "3"])
        try edit.undo()
        XCTAssertEqual(edit.document.pageCount, 2)
        try edit.insertBlankPage(relativeTo: 0, after: false)
        XCTAssertTrue((edit.document.page(at: 1)?.string ?? "").contains("one"), "inserted in front of page 1")
    }

    func testBlankPageAfterARotatedPageKeepsTheOnScreenShape() throws {
        let doc = try textDocument([["one"]])
        try XCTUnwrap(doc.page(at: 0)).rotation = 90
        let edit = PDFEditing(document: doc)
        try edit.insertBlankPage(relativeTo: 0, after: true)
        let size = try XCTUnwrap(edit.document.page(at: 1)).bounds(for: .cropBox).size
        XCTAssertEqual(size, CGSize(width: 792, height: 612))
    }

    func testRangeParsing() throws {
        XCTAssertEqual(try PDFEditing.parseRanges("1-3, 5, 8-10", pageCount: 10), [1...3, 5...5, 8...10])
        XCTAssertEqual(try PDFEditing.parseRanges("２", pageCount: 3).count, 1, "full-width digits are accepted by Int")
        XCTAssertEqual(try PDFEditing.parseRanges("1，3－4", pageCount: 5), [1...1, 3...4])
        for bad in ["", "0", "4-2", "1-11", "a", "1-2-3", ",,"] {
            XCTAssertThrowsError(try PDFEditing.parseRanges(bad, pageCount: 10), bad)
        }
    }

    func testSplitWritesOneFilePerRangeAndNeverOverwrites() throws {
        let edit = PDFEditing(document: try textDocument([["alpha"], ["beta"], ["gamma"], ["delta"]]))
        let folder = try tempFolder()
        let files = try edit.split(ranges: [1...2, 4...4], into: folder, baseName: "doc")
        XCTAssertEqual(files.map(\.lastPathComponent), ["doc-001-002.pdf", "doc-004.pdf"])
        let first = try XCTUnwrap(PDFDocument(url: files[0])), second = try XCTUnwrap(PDFDocument(url: files[1]))
        XCTAssertEqual(first.pageCount, 2); XCTAssertTrue((first.string ?? "").contains("beta"))
        XCTAssertEqual(second.pageCount, 1); XCTAssertTrue((second.string ?? "").contains("delta"))
        // A second run must not replace the first files.
        let again = try edit.split(ranges: [1...2], into: folder, baseName: "doc")
        XCTAssertEqual(again.first?.lastPathComponent, "doc-001-002 2.pdf")
        XCTAssertEqual(PDFDocument(url: files[0])?.pageCount, 2)
    }

    func testSplitEachPageAndBounds() throws {
        let edit = PDFEditing(document: try textDocument([["a"], ["b"], ["c"]]))
        let folder = try tempFolder()
        let files = try edit.split(ranges: (1...3).map { $0...$0 }, into: folder, baseName: "x")
        XCTAssertEqual(files.count, 3)
        XCTAssertThrowsError(try edit.split(ranges: [1...9], into: folder, baseName: "x"))
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: folder.path)).count, 3, "nothing written for an invalid range")
    }

    func testUnderlineAndStrikeoutAreRealAnnotationsThatSurviveSaving() throws {
        let doc = try textDocument([["underline me and strike me"]])
        let edit = PDFEditing(document: doc)
        let line = CGRect(x: 72, y: 690, width: 160, height: 22)
        try edit.markup(page: 0, bounds: [line], style: .underline, color: .systemRed)
        try edit.markup(page: 0, bounds: [line.offsetBy(dx: 0, dy: -40)], style: .strikeOut, color: .systemRed)
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(edit.document.dataRepresentation())))
        let kinds = try XCTUnwrap(reopened.page(at: 0)).annotations.map(\.type)
        XCTAssertEqual(Set(kinds), ["Underline", "StrikeOut"])
        XCTAssertTrue(edit.canUndo)
        try edit.undo(); try edit.undo()
        XCTAssertTrue(try XCTUnwrap(edit.document.page(at: 0)).annotations.isEmpty)
    }

    // MARK: Signature

    func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return pixel[3]
    }

    func testDrawnAndTypedSignaturesAreTransparentPictures() throws {
        let drawn = try XCTUnwrap(Signature.drawn(strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 50), CGPoint(x: 120, y: 12)]]))
        XCTAssertGreaterThan(drawn.width, 100)
        XCTAssertEqual(alpha(of: drawn, x: 1, y: drawn.height - 2), 0, "corner is empty")
        XCTAssertNil(Signature.drawn(strokes: []))
        let typed = try XCTUnwrap(Signature.typed("Jimmy Lin", fontName: "Snell Roundhand"))
        XCTAssertGreaterThan(typed.width, 50)
        XCTAssertNil(Signature.typed("   ", fontName: "Snell Roundhand"))
    }

    func testPaperBackgroundBecomesTransparentAndImageIsCropped() throws {
        let image = NSImage(size: NSSize(width: 300, height: 200))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 300, height: 200).fill()
        NSColor.black.setFill(); NSRect(x: 100, y: 80, width: 60, height: 20).fill(); image.unlockFocus()
        var rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        let source = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let result = try XCTUnwrap(Signature.removeBackground(source))
        // The picture may be 2x on a retina machine, so compare with the source size.
        XCTAssertLessThan(result.width * 3, source.width); XCTAssertLessThan(result.height * 4, source.height)
        XCTAssertGreaterThan(alpha(of: result, x: result.width / 2, y: result.height / 2), 200, "ink stays")
    }

    func testStampingPutsInkWhereRequestedAndKeepsTextSelectable() throws {
        let doc = try textDocument([["Agreement text stays selectable"]])
        let ink = try XCTUnwrap(Signature.drawn(strokes: [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]], lineWidth: 12))
        let page = try XCTUnwrap(doc.page(at: 0))
        let target = CGRect(x: 300, y: 300, width: 160, height: 40)
        let stamped = try XCTUnwrap(PDFProcessing.stampedPage(from: page, image: ink, rect: target))
        let edit = PDFEditing(document: doc)
        try edit.replace(pages: [0: stamped])
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(edit.document.dataRepresentation())))
        XCTAssertTrue((reopened.page(at: 0)?.string ?? "").contains("selectable"), "page text must stay real text")
        // Ink sits at the centre of the requested rectangle and nowhere else nearby.
        let render = try XCTUnwrap(PDFProcessing.renderImage(of: try XCTUnwrap(reopened.page(at: 0)), scale: 1))
        func dark(_ x: Int, _ y: Int) -> Bool { alpha(of: render, x: x, y: render.height - 1 - y) > 0 && luminance(render, x, render.height - 1 - y) < 60 }
        XCTAssertTrue(dark(380, 320))
        XCTAssertFalse(dark(380, 500))
        try edit.undo()
        XCTAssertTrue(edit.canRedo)
    }

    func luminance(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
    }

    func testRotatedPagesRefuseStamping() throws {
        let doc = try textDocument([["x"]])
        let page = try XCTUnwrap(doc.page(at: 0)); page.rotation = 90
        let ink = try XCTUnwrap(Signature.drawn(strokes: [[.zero, CGPoint(x: 50, y: 0)]]))
        XCTAssertNil(PDFProcessing.stampedPage(from: page, image: ink, rect: CGRect(x: 0, y: 0, width: 50, height: 20)))
    }

    func testSavedSignaturesRoundTripAndCanBeDeleted() throws {
        let store = SignatureStore(folder: try tempFolder())
        XCTAssertTrue(store.items().isEmpty)
        let ink = try XCTUnwrap(Signature.drawn(strokes: [[.zero, CGPoint(x: 60, y: 20)]]))
        let first = try store.save(ink), second = try store.save(ink)
        XCTAssertEqual(store.items().count, 2)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.image(first)?.width, ink.width)
        store.delete(first)
        XCTAssertEqual(store.items().map(\.id), [second.id])
    }
}
