import AppKit
import PDFKit

/// Watermarks, headers/footers and page numbers drawn over (or under) the existing page content.
enum Decoration {
    enum Position: String, CaseIterable, Identifiable {
        case center, topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .center: L("中央"); case .topLeft: L("左上"); case .topCenter: L("上方置中"); case .topRight: L("右上")
            case .bottomLeft: L("左下"); case .bottomCenter: L("下方置中"); case .bottomRight: L("右下")
            }
        }
    }

    struct Watermark {
        var text = ""
        var image: CGImage?
        var fontName = "Helvetica-Bold"
        var fontSize: CGFloat = 64
        var color = NSColor.systemGray
        var opacity: CGFloat = 0.3
        /// Degrees, counter-clockwise.
        var rotation: CGFloat = 45
        var position = Position.center
        var tiled = false
        /// Picture width as a fraction of the page width.
        var imageScale: CGFloat = 0.4
        var behind = false
        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil }
    }

    struct HeaderFooter {
        /// Left, centre, right.
        var header = ["", "", ""]
        var footer = ["", "", ""]
        var fontName = "Helvetica"
        var fontSize: CGFloat = 10
        var color = NSColor.black
        var margin: CGFloat = 28
        /// The first page gets nothing and numbering starts on the second page.
        var skipFirst = false
        /// On even pages left and right swap, as in a printed book.
        var mirrorEvenPages = false
        var startNumber = 1
        var isEmpty: Bool { (header + footer).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    struct Info {
        var title = ""
        var author = ""
        var filename = ""
        var date = Date()
    }

    /// {page} {pages} {title} {author} {filename} {date}
    static func expand(_ template: String, page index: Int, count: Int, spec: HeaderFooter, info: Info) -> String {
        let skip = spec.skipFirst ? 1 : 0
        let number = index + spec.startNumber - skip
        let total = count - skip + spec.startNumber - 1
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        return template
            .replacingOccurrences(of: "{page}", with: String(number))
            .replacingOccurrences(of: "{pages}", with: String(total))
            .replacingOccurrences(of: "{title}", with: info.title)
            .replacingOccurrences(of: "{author}", with: info.author)
            .replacingOccurrences(of: "{filename}", with: info.filename)
            .replacingOccurrences(of: "{date}", with: formatter.string(from: info.date))
    }

    // MARK: Drawing (in the page as it is seen: origin bottom left, upright)

    private static func line(_ text: String, fontName: String, size: CGFloat, color: NSColor) -> CTLine {
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }

    static func draw(_ mark: Watermark, in context: CGContext, size: CGSize) {
        guard !mark.isEmpty else { return }
        context.saveGState()
        context.setAlpha(mark.opacity)
        // What is drawn, measured around its own centre.
        let content: (CGSize, (CGContext) -> Void)
        if let image = mark.image {
            let width = size.width * mark.imageScale
            let height = width * CGFloat(image.height) / CGFloat(image.width)
            content = (CGSize(width: width, height: height), { $0.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height)) })
        } else {
            let ct = line(mark.text, fontName: mark.fontName, size: mark.fontSize, color: mark.color)
            let bounds = CTLineGetImageBounds(ct, nil)
            content = (bounds.size, { context in
                context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
                CTLineDraw(ct, context)
            })
        }
        let box = content.0
        func place(at centre: CGPoint) {
            context.saveGState()
            context.translateBy(x: centre.x, y: centre.y)
            context.rotate(by: mark.rotation * .pi / 180)
            content.1(context)
            context.restoreGState()
        }
        if mark.tiled {
            let stepX = max(box.width, 1) * 1.6, stepY = max(box.height, 1) * 3
            var y: CGFloat = -size.height, row = 0
            while y < size.height * 2 {
                var x: CGFloat = -size.width + (row % 2 == 0 ? 0 : stepX / 2)
                while x < size.width * 2 { place(at: CGPoint(x: x, y: y)); x += stepX }
                y += stepY; row += 1
            }
        } else {
            let margin: CGFloat = 36
            let half = CGSize(width: box.width / 2, height: box.height / 2)
            let centre: CGPoint
            switch mark.position {
            case .center: centre = CGPoint(x: size.width / 2, y: size.height / 2)
            case .topLeft: centre = CGPoint(x: margin + half.width, y: size.height - margin - half.height)
            case .topCenter: centre = CGPoint(x: size.width / 2, y: size.height - margin - half.height)
            case .topRight: centre = CGPoint(x: size.width - margin - half.width, y: size.height - margin - half.height)
            case .bottomLeft: centre = CGPoint(x: margin + half.width, y: margin + half.height)
            case .bottomCenter: centre = CGPoint(x: size.width / 2, y: margin + half.height)
            case .bottomRight: centre = CGPoint(x: size.width - margin - half.width, y: margin + half.height)
            }
            place(at: centre)
        }
        context.restoreGState()
    }

    static func draw(_ spec: HeaderFooter, page index: Int, count: Int, info: Info, in context: CGContext, size: CGSize) {
        if spec.skipFirst && index == 0 { return }
        var header = spec.header, footer = spec.footer
        if spec.mirrorEvenPages && (index + 1) % 2 == 0 { header.swapAt(0, 2); footer.swapAt(0, 2) }
        func put(_ templates: [String], baseline: CGFloat) {
            for (slot, template) in templates.enumerated() where !template.trimmingCharacters(in: .whitespaces).isEmpty {
                let text = expand(template, page: index, count: count, spec: spec, info: info)
                let ct = line(text, fontName: spec.fontName, size: spec.fontSize, color: spec.color)
                let width = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
                let x: CGFloat
                switch slot { case 0: x = spec.margin; case 1: x = (size.width - width) / 2; default: x = size.width - spec.margin - width }
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(ct, context)
            }
        }
        context.saveGState()
        put(header, baseline: size.height - spec.margin - spec.fontSize * 0.8)
        put(footer, baseline: spec.margin)
        context.restoreGState()
    }
}

extension PDFProcessing {
    /// Rebuilds the page with `behind` drawn first and `front` drawn last. The page's own content stays vector.
    /// A page turned by /Rotate is rebuilt in the orientation it is seen in (the turn is baked in).
    @MainActor static func decoratedPage(from page: PDFPage, behind: (CGContext, CGSize) -> Void = { _, _ in }, front: (CGContext, CGSize) -> Void) -> PDFPage? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotation = page.rotation
        let seen = rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
        var mediaBox = CGRect(origin: .zero, size: seen)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        context.saveGState(); behind(context, seen); context.restoreGState()
        let previous = page.displaysAnnotations
        page.displaysAnnotations = false
        page.draw(with: .cropBox, to: context)
        page.displaysAnnotations = previous
        context.saveGState(); front(context, seen); context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        return finish(data as Data, carrying: page, cropOrigin: box.origin, rotation: rotation)
    }
}
