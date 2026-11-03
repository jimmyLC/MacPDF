import XCTest
import PDFKit
@testable import MacPDF

@MainActor
final class M8Tests: XCTestCase {
    func line(_ text: String, size: CGFloat = 12, y: CGFloat, bold: Bool = false) -> TextExtraction.Line {
        TextExtraction.Line(text: text, box: CGRect(x: 0.1, y: y, width: 0.6, height: size / 800), size: size, bold: bold)
    }
    func page(_ lines: [TextExtraction.Line], index: Int = 0, recognised: Bool = false) -> TextExtraction.PageText {
        TextExtraction.PageText(index: index, lines: lines, recognised: recognised, pageHeight: 800)
    }

    // MARK: Markdown

    func testHeadingsParagraphsAndLists() {
        let md = TextExtraction.markdown([page([
            line("Annual Report", size: 24, y: 0.90),
            line("Overview", size: 16, y: 0.84),
            line("This is the first", y: 0.80), line("paragraph of text.", y: 0.78),
            line("Second paragraph starts here.", y: 0.70),
            line("• apples", y: 0.64), line("• pears", y: 0.62),
            line("1. first step", y: 0.56), line("2. second step", y: 0.54),
        ])])
        XCTAssertTrue(md.contains("# Annual Report"), md)
        XCTAssertTrue(md.contains("## Overview"), md)
        XCTAssertTrue(md.contains("This is the first paragraph of text."), md)
        XCTAssertTrue(md.contains("\n\nSecond paragraph starts here."), md)
        XCTAssertTrue(md.contains("- apples\n- pears"), md)
        XCTAssertTrue(md.contains("1. first step\n2. second step"), md)
    }

    func testChineseLinesJoinWithoutSpacesAndPagesAreSeparated() {
        let md = TextExtraction.markdown([
            page([line("付款期限為", y: 0.9), line("三十天內付清。", y: 0.88)], index: 0),
            page([line("第二頁的內容", y: 0.9)], index: 1),
        ])
        XCTAssertTrue(md.contains("付款期限為三十天內付清。"), md)
        XCTAssertTrue(md.contains("\n---\n"), md)
        XCTAssertFalse(TextExtraction.markdown([page([line("a", y: 0.9)])]).contains("---"))
        XCTAssertEqual(TextExtraction.markdown([page([])]), "\n")
    }

    func testPlainTextKeepsLinesAndSeparatesPages() {
        let text = TextExtraction.plainText([page([line("one", y: 0.9), line("two", y: 0.8)]), page([line("three", y: 0.9)], index: 1)])
        XCTAssertEqual(text, "one\ntwo\n\nthree\n")
    }

    func testReadingOrderIsTopToBottomThenLeftToRight() {
        let lines = [
            TextExtraction.Line(text: "bottom", box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.02), size: 12),
            TextExtraction.Line(text: "right", box: CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.02), size: 12),
            TextExtraction.Line(text: "left", box: CGRect(x: 0.1, y: 0.801, width: 0.3, height: 0.02), size: 12),
        ]
        XCTAssertEqual(TextExtraction.sorted(lines).map(\.text), ["left", "right", "bottom"])
    }

    // MARK: Reading real pages

    func testEmbeddedTextKeepsFontSizeForHeadings() async throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Big Title" as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 30)])
        for (i, text) in ["Body line one here", "Body line two here", "Body line three here"].enumerated() {
            (text as NSString).draw(at: NSPoint(x: 72, y: 640 - CGFloat(i) * 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        let doc = try XCTUnwrap(PDFDocument(data: data as Data))
        let result = await TextExtraction.extract(page: try XCTUnwrap(doc.page(at: 0)), index: 0, languages: ["en-US"], hasEmbeddedText: true)
        XCTAssertFalse(result.recognised)
        XCTAssertGreaterThanOrEqual(result.lines.count, 4)
        XCTAssertEqual(result.lines.first?.text, "Big Title", "reading order: title first")
        let md = TextExtraction.markdown([result])
        XCTAssertTrue(md.hasPrefix("# Big Title"), md)
        XCTAssertTrue(md.contains("Body line one here Body line two here Body line three here"), md)
    }

    func testScannedPageIsRecognised() async throws {
        let scan = try M2Tests().scanDocument(["Invoice number 2026 total"])
        let result = await TextExtraction.extract(page: try XCTUnwrap(scan.page(at: 0)), index: 0, languages: ["en-US"], hasEmbeddedText: false)
        XCTAssertTrue(result.recognised)
        XCTAssertTrue(result.lines.map(\.text).joined(separator: " ").lowercased().contains("invoice"), "\(result.lines.map(\.text))")
    }

    func testCorrectedTextIsWrittenBackAndTheScanStaysAPicture() async throws {
        let scan = try M2Tests().scanDocument(["Invoice number 2026 total"])
        let original = try XCTUnwrap(scan.page(at: 0))
        let found = await TextExtraction.extract(page: original, index: 0, languages: ["en-US"], hasEmbeddedText: false)
        XCTAssertFalse(found.lines.isEmpty)
        var lines = found.lines
        lines[0].text = "Receipt CORRECTED words"
        let fixed = try XCTUnwrap(TextExtraction.correctedPage(from: original, lines: lines))
        let edit = PDFEditing(document: scan)
        try edit.replace(pages: [0: fixed])
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(edit.document.dataRepresentation())))
        XCTAssertFalse(reopened.findString("CORRECTED", withOptions: .caseInsensitive).isEmpty, "searchable with the corrected text")
        XCTAssertEqual(reopened.page(at: 0)?.bounds(for: .cropBox).size.width ?? 0, original.bounds(for: .cropBox).size.width, accuracy: 1)
        XCTAssertTrue(PDFProcessing.isImageDominant(try XCTUnwrap(reopened.page(at: 0))), "still a picture page")
    }

    func testSessionAppliesEditsByLineOrAsParagraphs() {
        let session = TextSession()
        session.pages = [page([line("one", y: 0.9), line("two", y: 0.8)], recognised: true)]
        XCTAssertFalse(session.isEdited(session.pages[0]))
        session.edits[0] = "uno\ntwo"
        XCTAssertTrue(session.isEdited(session.pages[0]))
        XCTAssertEqual(session.current[0].lines.map(\.text), ["uno", "two"])
        XCTAssertEqual(session.current[0].lines[0].box, session.pages[0].lines[0].box, "same line count keeps positions")
        session.edits[0] = "uno\ndos\ntres"
        XCTAssertEqual(session.current[0].lines.count, 3)
        XCTAssertEqual(session.current[0].lines[0].box, .zero, "line count changed, positions are gone")
        session.edits[0] = "one\ntwo"
        XCTAssertFalse(session.isEdited(session.pages[0]), "typing the original back is not an edit")
    }

    // MARK: Compression

    func testCompressNeverUpscalesAndOffersFourLevels() throws {
        XCTAssertEqual(PDFProcessing.Preset.allCases.map(\.dpi), [100, 150, 200, 300])
        let scan = try M2Tests().scanDocument(["Compress me please"])
        let page = try XCTUnwrap(scan.page(at: 0))
        XCTAssertTrue(PDFProcessing.shouldCompress(page, preset: .small))
        let effective = try XCTUnwrap(PDFProcessing.effectiveDPI(of: page))
        let rebuilt = try XCTUnwrap(PDFProcessing.compressedPage(from: page, preset: .best))
        let holder = PDFDocument(); holder.insert(rebuilt, at: 0)
        let after = try XCTUnwrap(PDFProcessing.largestImage(on: try XCTUnwrap(holder.page(at: 0))))
        let longSide = max(rebuilt.bounds(for: .cropBox).width, rebuilt.bounds(for: .cropBox).height)
        XCTAssertLessThanOrEqual(CGFloat(max(after.width, after.height)) / (longSide / 72), effective + 8, "no more detail than the scan had")
    }

    func testDuplicatingPages() throws {
        let edit = PDFEditing(document: try M3Tests().textDocument([["one"], ["two"], ["three"]]))
        let placed = try edit.duplicate(pages: [0, 1])
        XCTAssertEqual(placed, [2, 3])
        XCTAssertEqual((0..<5).map { (edit.document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }, ["one", "two", "one", "two", "three"])
        try edit.undo(); XCTAssertEqual(edit.document.pageCount, 3)
        XCTAssertThrowsError(try edit.duplicate(pages: [7]))
    }
}
