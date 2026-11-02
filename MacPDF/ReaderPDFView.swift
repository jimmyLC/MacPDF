import AppKit
import PDFKit

final class ReaderPDFView: PDFView {
    var inkMode = false
    var redactDrawing = false
    var inspectMode = false
    var onInspect: ((Int, Int)?) -> Void = { _ in }
    var onRedactRect: ((Int, CGRect) -> Void)?
    private var redactStart: (PDFPage, CGPoint)?
    var onPlacement: ((Int, CGPoint) -> Void)?
    var placingAnnotation = false
    var onInk: ((Int, [CGPoint]) -> Void)?
    private var stroke: [CGPoint] = []
    private var strokePage: PDFPage?

    /// Room reserved for the floating glass bars so pages scroll underneath them.
    var contentInsets = NSEdgeInsets() { didSet { needsLayout = true } }
    private var appliedInsets = NSEdgeInsets()

    override func layout() {
        super.layout()
        applyInsets()
    }

    private func applyInsets() {
        guard let scroll = scrollView(in: self) else { return }
        let same = appliedInsets.top == contentInsets.top && appliedInsets.bottom == contentInsets.bottom
            && appliedInsets.left == contentInsets.left && appliedInsets.right == contentInsets.right
        if same && !scroll.automaticallyAdjustsContentInsets { return }
        let wasAtTop = scroll.contentView.bounds.origin.y <= -appliedInsets.top + 1
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = contentInsets
        scroll.scrollerInsets = NSEdgeInsets(top: contentInsets.top, left: 0, bottom: contentInsets.bottom, right: 0)
        appliedInsets = contentInsets
        if wasAtTop { scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: -contentInsets.top)); scroll.reflectScrolledClipView(scroll.contentView) }
    }

    /// Show the first page's top edge below the floating top bar (used when a document is installed).
    func scrollToTopSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let scroll = self.scrollView(in: self) else { return }
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: -self.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    // PDFKit aligns a page to the clip view's origin; shift it below the floating top bar.
    override func go(to page: PDFPage) { super.go(to: page); nudgeForInsets() }
    override func go(to destination: PDFDestination) { super.go(to: destination); nudgeForInsets() }
    private func nudgeForInsets() {
        guard contentInsets.top > 0, let scroll = scrollView(in: self) else { return }
        var origin = scroll.contentView.bounds.origin
        origin.y -= contentInsets.top
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? NSScrollView { return scroll }
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if placingAnnotation {
            guard let page = page(for: location, nearest: false), let document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            onPlacement?(index, convert(location, to: page))
            return
        }
        if inspectMode {
            guard let page = page(for: location, nearest: false), let document else { onInspect(nil); return }
            let point = convert(location, to: page)
            let hit = PDFEditing.editableAnnotations(on: page).last { $0.annotation.bounds.insetBy(dx: -3, dy: -3).contains(point) }
            let index = document.index(for: page)
            onInspect(hit.flatMap { index == NSNotFound ? nil : (index, $0.slot) })
            return
        }
        if redactDrawing {
            guard let page = page(for: location, nearest: false) else { return }
            redactStart = (page, convert(location, to: page)); return
        }
        guard inkMode else { super.mouseDown(with: event); return }
        guard let page = page(for: location, nearest: false) else { return }
        strokePage = page
        stroke = [convert(location, to: page)]
    }
    override func mouseDragged(with event: NSEvent) {
        if redactDrawing { return }
        guard inkMode else { super.mouseDragged(with: event); return }
        guard let page = strokePage else { return }
        let location = convert(event.locationInWindow, from: nil)
        stroke.append(convert(location, to: page))
    }
    override func mouseUp(with event: NSEvent) {
        if redactDrawing {
            defer { redactStart = nil }
            guard let (page, start) = redactStart, let document else { return }
            let end = convert(convert(event.locationInWindow, from: nil), to: page)
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
            let index = document.index(for: page)
            if rect.width >= 4, rect.height >= 4, index != NSNotFound { onRedactRect?(index, rect) }
            return
        }
        guard inkMode else { super.mouseUp(with: event); return }
        defer { stroke = []; strokePage = nil }
        guard let page = strokePage, let document, stroke.count > 1 else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        onInk?(index, stroke)
    }
}
