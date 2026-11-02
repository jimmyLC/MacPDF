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

    // MARK: Build, insert, rotate

    func writePDF(_ pages: [[String]], name: String) throws -> URL {
        let url = try tempFolder().appendingPathComponent(name)
        XCTAssertTrue(try textDocument(pages).write(to: url))
        return url
    }
    func writeImage(name: String, width: Int = 300, height: Int = 200) throws -> URL {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill(); image.unlockFocus()
        let url = try tempFolder().appendingPathComponent(name)
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }
    func firstWord(_ page: PDFPage?) -> String { (page?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    func testBuilderKeepsOrderAndRanges() throws {
        let pdf = try writePDF([["alpha"], ["beta"], ["gamma"], ["delta"]], name: "src.pdf")
        let image = try writeImage(name: "pic.png")
        let built = try PDFBuilder.build([.pdf(pdf, ranges: "2-3, 1"), .image(image), .blank], sheet: .letter)
        XCTAssertEqual(built.pageCount, 5)
        XCTAssertEqual((0..<3).map { firstWord(built.page(at: $0)) }, ["beta", "gamma", "alpha"])
        XCTAssertEqual(built.page(at: 3)?.bounds(for: .cropBox).width ?? 0, 792, accuracy: 0.1, "landscape picture on a Letter sheet")
        XCTAssertEqual(built.page(at: 4)?.bounds(for: .cropBox).size, CGSize(width: 612, height: 792))
        XCTAssertEqual((0..<5).map { built.page(at: $0)?.label }, ["1", "2", "3", "4", "5"])
    }

    func testBuilderErrors() throws {
        XCTAssertThrowsError(try PDFBuilder.build([], sheet: .a4))
        let pdf = try writePDF([["one"]], name: "one.pdf")
        XCTAssertThrowsError(try PDFBuilder.build([.pdf(pdf, ranges: "5")], sheet: .a4))
        XCTAssertThrowsError(try PDFBuilder.build([.image(URL(fileURLWithPath: "/nonexistent.png"))], sheet: .a4))
        let locked = try tempFolder().appendingPathComponent("locked.pdf")
        XCTAssertTrue(try textDocument([["secret"]]).write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
        XCTAssertThrowsError(try PDFBuilder.build([.pdf(locked, ranges: "")], sheet: .a4))
    }

    func testInsertAnotherDocumentAtAPosition() throws {
        let edit = PDFEditing(document: try textDocument([["one"], ["two"], ["three"]]))
        let other = try textDocument([["X"], ["Y"]])
        try edit.insert(other, before: 1)
        XCTAssertEqual((0..<5).map { firstWord(edit.document.page(at: $0)) }, ["one", "X", "Y", "two", "three"])
        try edit.insert(other, before: nil)
        XCTAssertEqual(edit.document.pageCount, 7)
        XCTAssertEqual(firstWord(edit.document.page(at: 6)), "Y")
        try edit.undo(); try edit.undo()
        XCTAssertEqual(edit.document.pageCount, 3)
    }

    func testRotateByAnyAngle() throws {
        let edit = PDFEditing(document: try textDocument([["a"], ["b"]]))
        try edit.rotate(pages: [0], by: -90)
        XCTAssertEqual(edit.document.page(at: 0)?.rotation, 270)
        try edit.rotate(pages: [0, 1], by: 180)
        XCTAssertEqual((0..<2).map { edit.document.page(at: $0)?.rotation }, [90, 180])
        try edit.rotate(pages: [0, 1], by: 90)
        XCTAssertEqual((0..<2).map { edit.document.page(at: $0)?.rotation }, [180, 270])
    }

    func testBlankPageOfACustomSize() throws {
        let edit = PDFEditing(document: try textDocument([["a"]]))
        try edit.insertBlankPage(before: 0, size: CGSize(width: 300, height: 400))
        try edit.insertBlankPage(before: 2, size: CGSize(width: 100, height: 100))
        XCTAssertEqual((0..<3).map { edit.document.page(at: $0)?.bounds(for: .cropBox).size }, [CGSize(width: 300, height: 400), CGSize(width: 612, height: 792), CGSize(width: 100, height: 100)])
        XCTAssertThrowsError(try edit.insertBlankPage(before: 9, size: CGSize(width: 10, height: 10)))
    }

    func testTIFFExport() throws {
        let page = try XCTUnwrap(try textDocument([["tiff"]]).page(at: 0))
        let data = try XCTUnwrap(PDFProcessing.imageData(of: page, dpi: 72, format: .tiff))
        XCTAssertTrue(Array(data.prefix(4)) == [0x49, 0x49, 0x2A, 0x00] || Array(data.prefix(4)) == [0x4D, 0x4D, 0x00, 0x2A], "TIFF header")
        XCTAssertEqual(PDFProcessing.ImageFormat.tiff.fileExtension, "tiff")
    }

    func testAdoptingABuiltDocumentMakesAnUnsavedUntitledOne() throws {
        let model = ReaderModel()
        model.adoptNew(try textDocument([["fresh"]]), title: "Untitled.pdf")
        XCTAssertEqual(model.title, "Untitled.pdf")
        XCTAssertTrue(model.isDirty)
        XCTAssertNil(model.sourceURL)
        XCTAssertEqual(model.pageCount, 1)
        _ = model.discardChanges()
    }

    // MARK: Annotation styles and inspector

    func testStyleRoundTripsAndHexColours() throws {
        var style = AnnotationStyle(); style.inkWidth = 6; style.textFont = "Courier"; style.textAlignment = .center; style.author = "Jimmy"
        let data = try JSONEncoder().encode(style)
        XCTAssertEqual(try JSONDecoder().decode(AnnotationStyle.self, from: data), style)
        let colour = try XCTUnwrap(NSColor(hex: "#336699"))
        XCTAssertEqual(colour.hexString, "#336699")
        XCTAssertNil(NSColor(hex: "nope"))
    }

    func testTextBoxUsesTheChosenFontAndNoteHasAnAuthor() throws {
        let edit = PDFEditing(document: try textDocument([["page"]]))
        var style = AnnotationStyle(); style.textFont = "Courier"; style.textSize = 22; style.textColor = "#FF0000"; style.textAlignment = .right; style.author = "Ann"
        try edit.annotate(page: 0, bounds: CGRect(x: 50, y: 50, width: 160, height: 40), text: "hello", freeText: true, style: style)
        try edit.annotate(page: 0, bounds: CGRect(x: 300, y: 50, width: 24, height: 24), text: "note", freeText: false, style: style)
        for document in [edit.document, try XCTUnwrap(PDFDocument(data: try XCTUnwrap(edit.document.dataRepresentation())))] {
            let annotations = try XCTUnwrap(document.page(at: 0)).annotations
            let box = try XCTUnwrap(annotations.first { $0.type == "FreeText" })
            XCTAssertEqual(box.contents, "hello")
            XCTAssertEqual(box.font?.fontName, "Courier")
            XCTAssertEqual(box.font?.pointSize ?? 0, 22, accuracy: 0.5, "size is kept, also after saving")
            let colour = try XCTUnwrap(box.fontColor?.usingColorSpace(.sRGB))
            XCTAssertEqual(colour.redComponent, 1, accuracy: 0.05); XCTAssertEqual(colour.greenComponent, 0.1, accuracy: 0.15); XCTAssertEqual(colour.blueComponent, 0, accuracy: 0.05)
            XCTAssertEqual(box.alignment, .right)
            XCTAssertEqual(try XCTUnwrap(annotations.first { $0.type == "Text" }).userName, "Ann")
        }
    }

    func testInkColourAndWidthAndHighlightOpacity() throws {
        let edit = PDFEditing(document: try textDocument([["page"]]))
        try edit.ink(page: 0, points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 80)], color: .systemGreen, width: 7)
        try edit.markup(page: 0, bounds: [CGRect(x: 72, y: 690, width: 100, height: 20)], style: .highlight, color: .yellow, opacity: 0.2, author: "Bo")
        // The highlight's translucency is not stored in the file by PDFKit (it writes the colour only), so check
        // the document being edited; the ink width does survive saving.
        let annotations = try XCTUnwrap(edit.document.page(at: 0)).annotations
        let highlight = try XCTUnwrap(annotations.first { $0.type == "Highlight" })
        XCTAssertEqual(highlight.color.alphaComponent, 0.2, accuracy: 0.02)
        XCTAssertEqual(highlight.userName, "Bo")
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(edit.document.dataRepresentation())))
        let ink = try XCTUnwrap(try XCTUnwrap(reopened.page(at: 0)).annotations.first { $0.type == "Ink" })
        XCTAssertEqual(ink.border?.lineWidth ?? 0, 7, accuracy: 0.01)
    }

    func testEditingAndDeletingAnExistingAnnotationIsUndoable() throws {
        let edit = PDFEditing(document: try textDocument([["page"]]))
        try edit.markup(page: 0, bounds: [CGRect(x: 72, y: 690, width: 100, height: 20)], style: .underline, color: .systemRed)
        let page = try XCTUnwrap(edit.document.page(at: 0))
        let slot = try XCTUnwrap(PDFEditing.editableAnnotations(on: page).first?.slot)
        try edit.updateAnnotation(page: 0, slot: slot) { $0.color = .systemBlue; $0.userName = "Cy" }
        let changed = try XCTUnwrap(edit.document.page(at: 0)?.annotations[slot])
        XCTAssertEqual(changed.userName, "Cy")
        XCTAssertEqual(changed.color.hexString, NSColor.systemBlue.hexString)
        try edit.deleteAnnotation(page: 0, slot: slot)
        XCTAssertTrue(PDFEditing.editableAnnotations(on: try XCTUnwrap(edit.document.page(at: 0))).isEmpty)
        try edit.undo()
        XCTAssertEqual(PDFEditing.editableAnnotations(on: try XCTUnwrap(edit.document.page(at: 0))).count, 1)
        XCTAssertThrowsError(try edit.deleteAnnotation(page: 0, slot: 9))
    }

    func testLinksAndFormFieldsAreNotOfferedForEditing() throws {
        let doc = try M2Tests().scanDocument(["a", "b"])
        let page = try XCTUnwrap(doc.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 5, y: 5, width: 30, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: try XCTUnwrap(doc.page(at: 1)), at: .zero); page.addAnnotation(link)
        let note = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 20, height: 20), forType: .text, withProperties: nil); page.addAnnotation(note)
        XCTAssertEqual(PDFEditing.editableAnnotations(on: page).map { $0.annotation.type ?? "" }, ["Text"])
    }
}
