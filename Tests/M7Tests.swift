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

    // MARK: Decorations

    func darkAtCentre(_ page: PDFPage) -> Bool {
        if page.document == nil { let holder = PDFDocument(); holder.insert(page, at: 0); return darkAtCentre(holder.page(at: 0)!) }
        guard let image = PDFProcessing.renderImage(of: page, scale: 1) else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        }
        return (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3 < 120
    }

    func testTokensAndNumbering() {
        var spec = Decoration.HeaderFooter(); spec.startNumber = 5
        let info = Decoration.Info(title: "T", author: "A", filename: "f.pdf")
        XCTAssertEqual(Decoration.expand("{page}/{pages} {title} {author} {filename}", page: 0, count: 3, spec: spec, info: info), "5/7 T A f.pdf")
        spec.startNumber = 1; spec.skipFirst = true
        XCTAssertEqual(Decoration.expand("{page} of {pages}", page: 1, count: 4, spec: spec, info: info), "1 of 3", "numbering starts after the cover")
    }

    func testWatermarkSitsOverTheCentreAndTextStaysReal() throws {
        let doc = try textDocument([["Body text stays selectable"]])
        var mark = Decoration.Watermark(); mark.text = "CONFIDENTIAL"; mark.color = .black; mark.opacity = 1; mark.fontSize = 120; mark.rotation = 0
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertFalse(darkAtCentre(page))
        let rebuilt = try XCTUnwrap(PDFProcessing.decoratedPage(from: page) { Decoration.draw(mark, in: $0, size: $1) })
        XCTAssertTrue(darkAtCentre(rebuilt), "the watermark reaches the middle of the page")
        XCTAssertTrue((rebuilt.string ?? "").contains("selectable"))
        XCTAssertEqual(rebuilt.bounds(for: .cropBox).size, page.bounds(for: .cropBox).size)
    }

    func testFooterPageNumbersAndSkipFirst() throws {
        let doc = try textDocument([["cover"], ["body"], ["end"]])
        var spec = Decoration.HeaderFooter(); spec.footer = ["", "Page {page} of {pages}", ""]; spec.skipFirst = true
        let info = Decoration.Info(title: "T", author: "", filename: "f")
        var texts: [String] = []
        for index in 0..<3 {
            let rebuilt = try XCTUnwrap(PDFProcessing.decoratedPage(from: try XCTUnwrap(doc.page(at: index))) {
                Decoration.draw(spec, page: index, count: 3, info: info, in: $0, size: $1)
            })
            texts.append(rebuilt.string ?? "")
        }
        XCTAssertFalse(texts[0].contains("Page"), "first page skipped")
        XCTAssertTrue(texts[1].contains("Page 1 of 2"), texts[1])
        XCTAssertTrue(texts[2].contains("Page 2 of 2"), texts[2])
    }

    func testRotatedPageKeepsRotationAndWatermarkIsUpright() throws {
        let doc = try textDocument([["rotated body"]])
        let page = try XCTUnwrap(doc.page(at: 0)); page.rotation = 90
        var mark = Decoration.Watermark(); mark.text = "DRAFT"; mark.color = .black; mark.opacity = 1; mark.fontSize = 120; mark.rotation = 0
        let loose = try XCTUnwrap(PDFProcessing.decoratedPage(from: page) { Decoration.draw(mark, in: $0, size: $1) })
        let holder = PDFDocument(); holder.insert(loose, at: 0)
        let rebuilt = try XCTUnwrap(holder.page(at: 0))
        XCTAssertEqual(rebuilt.rotation, 0, "the turn is baked in")
        XCTAssertEqual(rebuilt.bounds(for: .cropBox).size, CGSize(width: 792, height: 612), "viewed landscape after a 90 degree turn")
        XCTAssertTrue(darkAtCentre(rebuilt))
        XCTAssertTrue((rebuilt.string ?? "").contains("rotated"), "body text survives: \(rebuilt.string ?? "nil")")
    }

    func testLinksSurviveRebuildingThePage() throws {
        // PDFKit cannot save link targets in pages made by drawing text with CoreGraphics, so use picture pages here.
        let doc = try M2Tests().scanDocument(["first", "second"])
        let first = try XCTUnwrap(doc.page(at: 0)), second = try XCTUnwrap(doc.page(at: 1))
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: second, at: CGPoint(x: 0, y: 300)); first.addAnnotation(link)
        let edit = PDFEditing(document: doc)
        var mark = Decoration.Watermark(); mark.text = "X"
        let rebuilt0 = try XCTUnwrap(PDFProcessing.decoratedPage(from: try XCTUnwrap(edit.document.page(at: 0))) { Decoration.draw(mark, in: $0, size: $1) })
        let rebuilt1 = try XCTUnwrap(PDFProcessing.decoratedPage(from: try XCTUnwrap(edit.document.page(at: 1))) { Decoration.draw(mark, in: $0, size: $1) })
        try edit.replace(pages: [0: rebuilt0, 1: rebuilt1])
        let moved = try XCTUnwrap(edit.document.page(at: 0)?.annotations.first(where: { $0.type == "Link" }))
        let target = try XCTUnwrap((moved.destination ?? (moved.action as? PDFActionGoTo)?.destination)?.page, "link has no target at all")
        XCTAssertEqual(edit.document.index(for: target), 1, "the link still goes to page 2")
    }
}
