import XCTest
import PDFKit
@testable import MacPDF

@MainActor
final class M4Tests: XCTestCase {
    func textDocument(_ pages: [[String]]) throws -> PDFDocument {
        try M3Tests().textDocument(pages)
    }

    func testIdenticalDocumentsHaveNoDifferences() throws {
        let a = try textDocument([["The quick brown fox", "jumps over"], ["second page text here"]])
        let b = try textDocument([["The quick brown fox", "jumps over"], ["second page text here"]])
        let result = PDFCompare.compare(old: a, new: b)
        XCTAssertTrue(result.isIdentical, "\(result.changes.map(\.newText))")
        XCTAssertEqual(result.matchedPages, 2)
    }

    func testChangedWordIsReportedWithPositions() throws {
        let a = try textDocument([["Payment is due within thirty days of invoice"]])
        let b = try textDocument([["Payment is due within sixty days of invoice"]])
        let result = PDFCompare.compare(old: a, new: b)
        XCTAssertEqual(result.changes.count, 1)
        let change = try XCTUnwrap(result.changes.first)
        XCTAssertEqual(change.kind, .modified)
        XCTAssertEqual(change.oldText, "thirty"); XCTAssertEqual(change.newText, "sixty")
        XCTAssertFalse(change.oldRects.isEmpty); XCTAssertFalse(change.newRects.isEmpty)
    }

    func testAddedAndRemovedWords() throws {
        let a = try textDocument([["alpha beta gamma delta"]])
        let b = try textDocument([["alpha gamma delta epsilon"]])
        let kinds = PDFCompare.compare(old: a, new: b).changes.map(\.kind)
        XCTAssertEqual(kinds.sorted { "\($0)" < "\($1)" }, [.added, .removed])
    }

    func testInsertedAndDeletedPages() throws {
        let a = try textDocument([["first page about apples and pears"], ["old appendix that goes away entirely"]])
        let b = try textDocument([["first page about apples and pears"], ["brand new chapter nobody has seen before"]])
        let changes = PDFCompare.compare(old: a, new: b).changes
        XCTAssertTrue(changes.contains { $0.wholePage && $0.kind == .removed && $0.oldPage == 1 })
        XCTAssertTrue(changes.contains { $0.wholePage && $0.kind == .added && $0.newPage == 1 })
    }

    func testMovedPageStillMatches() throws {
        let a = try textDocument([["chapter one introduction words"], ["chapter two methods and data"], ["chapter three results shown"]])
        let b = try textDocument([["chapter one introduction words"], ["chapter three results shown"], ["chapter two methods and data"]])
        let result = PDFCompare.compare(old: a, new: b)
        XCTAssertGreaterThanOrEqual(result.matchedPages, 2)
    }

    func testChineseTextIsCompared() throws {
        let a = try textDocument([["付款期限為三十天"]]), b = try textDocument([["付款期限為六十天"]])
        let result = PDFCompare.compare(old: a, new: b)
        XCTAssertEqual(result.changes.count, 1, "\(result.changes.map { ($0.oldText, $0.newText) })")
    }

    func testPaintingLeavesSourceFilesAlone() throws {
        let a = try textDocument([["one two three"]]), b = try textDocument([["one two four"]])
        let result = PDFCompare.compare(old: a, new: b)
        PDFCompare.paint(result, old: a, new: b)
        XCTAssertEqual(try XCTUnwrap(a.page(at: 0)).annotations.count, 1)
        XCTAssertEqual(try XCTUnwrap(b.page(at: 0)).annotations.count, 1)
    }
}
