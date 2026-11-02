import XCTest
import PDFKit
@testable import MacPDF

@MainActor final class PDFWindowsTests: XCTestCase {
    func testColdBatchDuplicateAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 100, height: 120))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 120).fill(); image.unlockFocus()
        let doc = PDFDocument(); doc.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let a = directory.appendingPathComponent("a.pdf"), b = directory.appendingPathComponent("b.pdf")
        XCTAssertTrue(doc.write(to: a)); XCTAssertTrue(doc.write(to: b))
        let windows = PDFWindows(present: false)
        windows.open([a, b])
        windows.showWelcomeIfNeeded()
        XCTAssertEqual(windows.controllers.count, 2, "Cold batch must not create a welcome window")
        XCTAssertEqual(Set(windows.controllers.compactMap { $0.window?.title }), ["a.pdf", "b.pdf"])
        windows.open([a, b])
        XCTAssertEqual(windows.controllers.count, 2, "Repeated opens reuse document windows")
        for controller in windows.controllers { controller.window?.close() }
        XCTAssertTrue(windows.controllers.isEmpty)
        windows.open([b])
        XCTAssertEqual(windows.controllers.count, 1)
        windows.controllers.first?.window?.close()
    }
    func testWelcomeIsReusedAndFailedOpenIsVisible() {
        let windows = PDFWindows(present: false)
        windows.showWelcomeIfNeeded()
        XCTAssertEqual(windows.controllers.count, 1)
        windows.open([URL(fileURLWithPath: "/not-present.pdf")])
        XCTAssertEqual(windows.controllers.count, 1)
        windows.controllers.first?.window?.close()
    }
}
