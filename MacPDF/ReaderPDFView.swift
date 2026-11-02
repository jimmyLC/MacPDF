import AppKit
import PDFKit

final class ReaderPDFView: PDFView {
    var inkMode = false
    var onPlacement: ((Int, CGPoint) -> Void)?
    var placingAnnotation = false
    var onInk: ((Int, [CGPoint]) -> Void)?
    private var stroke: [CGPoint] = []
    private var strokePage: PDFPage?

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if placingAnnotation {
            guard let page = page(for: location, nearest: false), let document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            onPlacement?(index, convert(location, to: page))
            return
        }
        guard inkMode else { super.mouseDown(with: event); return }
        guard let page = page(for: location, nearest: false) else { return }
        strokePage = page
        stroke = [convert(location, to: page)]
    }
    override func mouseDragged(with event: NSEvent) {
        guard inkMode else { super.mouseDragged(with: event); return }
        guard let page = strokePage else { return }
        let location = convert(event.locationInWindow, from: nil)
        stroke.append(convert(location, to: page))
    }
    override func mouseUp(with event: NSEvent) {
        guard inkMode else { super.mouseUp(with: event); return }
        defer { stroke = []; strokePage = nil }
        guard let page = strokePage, let document, stroke.count > 1 else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        onInk?(index, stroke)
    }
}
