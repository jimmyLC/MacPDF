import AppKit
import PDFKit
import Vision
import ImageIO

/// Page-level rendering helpers for OCR, compression and image import.
/// Everything here produces new pages; nothing writes to disk.
enum PDFProcessing {
    struct TextLine: Sendable {
        let text: String
        /// Normalised to the rendered image, origin at the bottom left (Vision convention).
        let box: CGRect
    }

    enum Preset: String, CaseIterable, Identifiable {
        case high, standard, small
        var id: String { rawValue }
        var dpi: CGFloat { switch self { case .high: 200; case .standard: 150; case .small: 100 } }
        var quality: CGFloat { switch self { case .high: 0.75; case .standard: 0.6; case .small: 0.45 } }
    }

    static let ocrScale: CGFloat = 2.5
    /// A page that already carries this much text is not treated as a scan.
    static let textThreshold = 12

    @MainActor static func hasText(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count >= textThreshold
    }

    // MARK: Rendering

    @MainActor static func renderImage(of page: PDFPage, scale: CGFloat, includeAnnotations: Bool = false) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let previous = page.displaysAnnotations
        page.displaysAnnotations = includeAnnotations
        defer { page.displaysAnnotations = previous }
        // The thumbnail is upright, so a page rotated by 90 or 270 degrees swaps its sides.
        let sideways = page.rotation % 180 != 0
        let image = page.thumbnail(of: NSSize(width: (sideways ? box.height : box.width) * scale, height: (sideways ? box.width : box.height) * scale), for: .cropBox)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: OCR

    static func recognize(_ image: CGImage) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let top = observation.topCandidates(1).first, !top.string.isEmpty else { return nil }
            return TextLine(text: top.string, box: observation.boundingBox)
        }
    }

    /// Redraws the page and lays an invisible text layer over it, so the text can be searched and copied.
    @MainActor static func searchablePage(from page: PDFPage, lines: [TextLine]) -> PDFPage? {
        let box = page.bounds(for: .cropBox)
        var mediaBox = CGRect(origin: .zero, size: box.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        let previous = page.displaysAnnotations
        page.displaysAnnotations = false
        page.draw(with: .cropBox, to: context)
        page.displaysAnnotations = previous
        drawInvisibleText(lines, in: context, size: box.size)
        context.endPDFPage()
        context.closePDF()
        return finish(data as Data, carrying: page, cropOrigin: box.origin)
    }

    /// Redraws the page with a picture laid over it at `rect` (page space). The page's own content stays vector,
    /// so its text remains selectable. Rotated pages are not supported.
    @MainActor static func stampedPage(from page: PDFPage, image: CGImage, rect: CGRect) -> PDFPage? {
        let box = page.bounds(for: .cropBox)
        guard page.rotation == 0, box.width > 0, box.height > 0 else { return nil }
        var mediaBox = CGRect(origin: .zero, size: box.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        let previous = page.displaysAnnotations
        page.displaysAnnotations = false
        page.draw(with: .cropBox, to: context)
        page.displaysAnnotations = previous
        context.draw(image, in: rect.offsetBy(dx: -box.minX, dy: -box.minY))
        context.endPDFPage()
        context.closePDF()
        return finish(data as Data, carrying: page, cropOrigin: box.origin)
    }

    private static func drawInvisibleText(_ lines: [TextLine], in context: CGContext, size: CGSize) {
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                              width: line.box.width * size.width, height: line.box.height * size.height)
            let font = NSFont.systemFont(ofSize: max(rect.height * 0.85, 1))
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard width > 0 else { continue }
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: rect.width / width, y: 1)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    /// The page's existing text as lines, so a rebuilt page can keep it searchable.
    @MainActor static func textLines(of page: PDFPage) -> [TextLine] {
        let box = page.bounds(for: .cropBox)
        guard page.rotation == 0, box.width > 0, box.height > 0, let selection = page.selection(for: box) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return TextLine(text: text, box: CGRect(x: (bounds.minX - box.minX) / box.width, y: (bounds.minY - box.minY) / box.height,
                                                    width: bounds.width / box.width, height: bounds.height / box.height))
        }
    }

    /// True when one embedded image is big enough to be the whole page, as in a scan.
    @MainActor static func isImageDominant(_ page: PDFPage) -> Bool {
        guard let ref = page.pageRef, var node = ref.dictionary else { return false }
        let box = page.bounds(for: .cropBox)
        var resources: CGPDFDictionaryRef?
        // Resources may be inherited from a parent page-tree node.
        for _ in 0..<12 {
            if CGPDFDictionaryGetDictionary(node, "Resources", &resources) { break }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(node, "Parent", &parent), let next = parent else { return false }
            node = next
        }
        var xObjects: CGPDFDictionaryRef?
        guard let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return false }
        final class Box { var largest = 0 }
        let result = Box()
        CGPDFDictionaryApplyBlock(xObjects, { _, object, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" else { return true }
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dict, "Width", &width); CGPDFDictionaryGetInteger(dict, "Height", &height)
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            box.largest = max(box.largest, Int(width) * Int(height))
            return true
        }, Unmanaged.passUnretained(result).toOpaque())
        return CGFloat(result.largest) >= 0.5 * box.width * box.height
    }

    // MARK: Compression

    /// Re-encodes a scanned page as a down-sampled JPEG page of the same size.
    @MainActor static func compressedPage(from page: PDFPage, preset: Preset) -> PDFPage? {
        let box = page.bounds(for: .cropBox)
        let scale = preset.dpi / 72
        guard let rendered = renderImage(of: page, scale: scale),
              let jpeg = jpegImage(from: rendered, quality: preset.quality) else { return nil }
        // The thumbnail already honours /Rotate, so the new page is upright.
        let size = CGSize(width: CGFloat(rendered.width) / scale, height: CGFloat(rendered.height) / scale)
        guard size.width > 0, size.height > 0, box.width > 0 else { return nil }
        let lines = textLines(of: page)
        guard let data = pdfData(size: size, draw: { context in
            context.draw(jpeg, in: CGRect(origin: .zero, size: size))
            if !lines.isEmpty { drawInvisibleText(lines, in: context, size: size) }
        }) else { return nil }
        return finish(data, carrying: page, cropOrigin: box.origin, rotation: page.rotation)
    }

    // MARK: Images to pages

    enum PageSheet: String, CaseIterable, Identifiable {
        case a4, letter, image
        var id: String { rawValue }
        /// Portrait size in points; `image` has none because the page takes the picture's own shape.
        var portrait: CGSize? {
            switch self { case .a4: CGSize(width: 595.28, height: 841.89); case .letter: CGSize(width: 612, height: 792); case .image: nil }
        }
    }

    /// Fits the image on a page (portrait or landscape to match the picture) and embeds it as JPEG.
    static func page(fromImageAt url: URL, sheet: PageSheet = .a4) -> PDFPage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 3508]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return page(fromImage: cg, sheet: sheet)
    }

    static func page(fromImage cg: CGImage, sheet: PageSheet = .a4) -> PDFPage? {
        guard let jpeg = jpegImage(from: cg, quality: 0.9) else { return nil }
        let size: CGSize
        if let portrait = sheet.portrait {
            let landscape = cg.width > cg.height
            size = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        } else {
            // One pixel per point would be huge; scale so the long side is about A4.
            let long = max(cg.width, cg.height)
            let scale = min(1, 842 / CGFloat(long))
            size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        }
        let fit = min(size.width / CGFloat(cg.width), size.height / CGFloat(cg.height))
        let drawn = CGSize(width: CGFloat(cg.width) * fit, height: CGFloat(cg.height) * fit)
        let rect = CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height)
        guard let data = pdfData(size: size, draw: { $0.draw(jpeg, in: rect) }),
              let document = PDFDocument(data: data) else { return nil }
        return document.page(at: 0)?.copy() as? PDFPage
    }

    // MARK: Shared

    private static func jpegImage(from image: CGImage, quality: CGFloat) -> CGImage? {
        // Flatten onto white so transparency does not turn black in JPEG.
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: flat).representation(using: .jpeg, properties: [.compressionFactor: quality]),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func pdfData(size: CGSize, draw: (CGContext) -> Void) -> Data? {
        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Loads a one-page PDF and re-attaches the original page's annotations (internal-link targets are dropped).
    @MainActor static func finish(_ data: Data, carrying original: PDFPage, cropOrigin: CGPoint, rotation: Int = 0) -> PDFPage? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0)?.copy() as? PDFPage else { return nil }
        // A rotated original has been baked upright, so its annotations are not carried over.
        guard rotation == 0 else { return page }
        for annotation in original.annotations {
            guard let copy = annotation.copy() as? PDFAnnotation else { continue }
            copy.bounds = copy.bounds.offsetBy(dx: -cropOrigin.x, dy: -cropOrigin.y)
            if copy.destination != nil { copy.destination = nil; copy.action = nil }
            if copy.action is PDFActionGoTo { copy.action = nil }
            page.addAnnotation(copy)
        }
        return page
    }
}

// MARK: Pages to pictures

extension PDFProcessing {
    enum ImageFormat: String, CaseIterable, Identifiable {
        case png, jpeg, tiff
        var id: String { rawValue }
        var fileExtension: String { switch self { case .png: "png"; case .jpeg: "jpg"; case .tiff: "tiff" } }
    }

    /// Longest side allowed for a rendered page, as docs/05 section 6.2 limits it.
    static let maximumPixels: CGFloat = 10_000

    @MainActor static func imageData(of page: PDFPage, dpi: CGFloat, format: ImageFormat) -> Data? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(dpi / 72, maximumPixels / max(box.width, box.height))
        guard let rendered = renderImage(of: page, scale: scale, includeAnnotations: true) else { return nil }
        // Pages have no transparency; flatten onto white so JPEG does not turn black.
        guard let context = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let area = CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(area)
        context.draw(rendered, in: area)
        guard let flat = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: flat)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case .tiff: return rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])
        }
    }

    /// `base-001.png`, then `base-001 2.png` if that exists. Files are only ever created, never replaced.
    static func imageURL(base: String, number: Int, width: Int, format: ImageFormat, in folder: URL) -> URL {
        let stem = "\(base)-" + String(format: "%0\(width)d", number)
        var url = folder.appendingPathComponent(stem + "." + format.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) && counter < 1000 {
            url = folder.appendingPathComponent("\(stem) \(counter).\(format.fileExtension)"); counter += 1
        }
        return url
    }
}
