import AppKit
import PDFKit

enum ViewMode: String, CaseIterable, Identifiable {
    case single, continuous, twoUp, twoUpContinuous
    var id: String { rawValue }
    var label: String {
        switch self {
        case .single: L("單頁")
        case .continuous: L("連續捲動")
        case .twoUp: L("雙頁")
        case .twoUpContinuous: L("雙頁連續")
        }
    }
    var displayMode: PDFDisplayMode {
        switch self {
        case .single: .singlePage
        case .continuous: .singlePageContinuous
        case .twoUp: .twoUp
        case .twoUpContinuous: .twoUpContinuous
        }
    }
}

/// View modes, zoom presets, clipboard and sharing.
extension ReaderModel {
    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        pdfView.displayMode = mode.displayMode
        pdfView.displayDirection = .vertical
        pdfView.displaysAsBook = false
        pdfView.autoScales = true
    }

    func fitPage() { pdfView.autoScales = true }

    func fitWidth() {
        guard let page = pdfView.currentPage ?? document?.page(at: 0) else { return }
        let width = page.bounds(for: pdfView.displayBox).width
        guard width > 0 else { return }
        let columns: CGFloat = (viewMode == .twoUp || viewMode == .twoUpContinuous) ? 2 : 1
        pdfView.autoScales = false
        pdfView.scaleFactor = max((pdfView.bounds.width - 56) / (width * columns), 0.1)
    }

    func actualSize() { pdfView.autoScales = false; pdfView.scaleFactor = 1 }

    // MARK: Clipboard

    /// Puts the page on screen on the pasteboard as a picture.
    func copyCurrentPageAsImage() {
        guard let page = document?.page(at: max(currentPage - 1, 0)), let data = PDFProcessing.imageData(of: page, dpi: 150, format: .png),
              let image = NSImage(data: data) else { error = L("無法複製這一頁。"); return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([image])
        notice = L("已把這一頁拷貝為圖片。")
    }

    var pasteboardHasImage: Bool { NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) }

    /// Adds the picture on the pasteboard as a new last page.
    func pasteImageAsPage() {
        guard let image = (NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
              var rect = Optional(CGRect(origin: .zero, size: image.size)),
              let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil), let page = PDFProcessing.page(fromImage: cg) else {
            error = L("剪貼簿裡沒有圖片。"); return
        }
        appendPages([page])
        if error == nil { notice = L("已把剪貼簿的圖片貼成新頁。") }
    }

    // MARK: Share

    /// Shares a copy of the document as it is now (including unsaved edits) through the system share sheet.
    func share(from view: NSView) {
        guard let document, let data = document.dataRepresentation() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacPDF-share-\(UUID().uuidString)", isDirectory: true)
        let name = title.hasSuffix(".pdf") ? title : title + ".pdf"
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch { self.error = error.localizedDescription; return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        // The temporary copy goes away shortly after the share sheet has had time to read it.
        Task { try? await Task.sleep(for: .seconds(600)); try? FileManager.default.removeItem(at: folder) }
    }
}
