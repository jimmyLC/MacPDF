import AppKit
import CoreGraphics

/// Builds signature pictures (drawn, typed or imported) and keeps the ones the user wants to reuse.
enum Signature {
    static let typedFonts = ["Snell Roundhand", "Bradley Hand", "Savoye LET", "Zapfino"]

    /// Transparent-background picture of the drawn strokes, cropped to the ink. Points are y-down view coordinates.
    static func drawn(strokes: [[CGPoint]], lineWidth: CGFloat = 3) -> CGImage? {
        let points = strokes.flatMap { $0 }
        guard points.count > 1 else { return nil }
        let pad: CGFloat = 6, scale: CGFloat = 3
        let minX = points.map(\.x).min()! - pad, maxX = points.map(\.x).max()! + pad
        let minY = points.map(\.y).min()! - pad, maxY = points.map(\.y).max()! + pad
        let width = Int(((maxX - minX) * scale).rounded(.up)), height = Int(((maxY - minY) * scale).rounded(.up))
        guard width > 1, height > 1, let context = bitmap(width: width, height: height) else { return nil }
        context.setStrokeColor(CGColor(gray: 0.05, alpha: 1))
        context.setLineWidth(lineWidth * scale); context.setLineCap(.round); context.setLineJoin(.round)
        for stroke in strokes where stroke.count > 1 {
            context.beginPath()
            // View space is y-down; the bitmap is y-up.
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - minX) * scale, y: (maxY - p.y) * scale) }
            context.move(to: map(stroke[0]))
            for point in stroke.dropFirst() { context.addLine(to: map(point)) }
            context.strokePath()
        }
        return context.makeImage()
    }

    static func typed(_ text: String, fontName: String) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let font = NSFont(name: fontName, size: 96) ?? NSFont.systemFont(ofSize: 96, weight: .light)
        let attributed = NSAttributedString(string: trimmed, attributes: [.font: font, .foregroundColor: NSColor(white: 0.05, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetImageBounds(line, nil)
        let pad: CGFloat = 12
        let width = Int((bounds.width + pad * 2).rounded(.up)), height = Int((bounds.height + pad * 2).rounded(.up))
        guard width > 1, height > 1, let context = bitmap(width: width, height: height) else { return nil }
        context.textPosition = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    /// A photo or scan of a signature on paper: light pixels become transparent, ink keeps its colour.
    static func fromImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else { return nil }
        return removeBackground(image)
    }

    static func removeBackground(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let context = bitmap(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let sourceAlpha = Int(pixels[i + 3])
            guard sourceAlpha > 0 else { continue }
            // Context pixels are premultiplied; recover the real colour first.
            let r = Int(pixels[i]) * 255 / sourceAlpha, g = Int(pixels[i + 1]) * 255 / sourceAlpha, b = Int(pixels[i + 2]) * 255 / sourceAlpha
            let luminance = (r * 299 + g * 587 + b * 114) / 1000
            // Paper (light) fades out between luminance 175 and 235; ink stays.
            let alpha = min(255, max(0, (235 - luminance) * 255 / 60)) * sourceAlpha / 255
            pixels[i] = UInt8(min(255, r * alpha / 255)); pixels[i + 1] = UInt8(min(255, g * alpha / 255)); pixels[i + 2] = UInt8(min(255, b * alpha / 255))
            pixels[i + 3] = UInt8(alpha)
            if alpha > 20 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        } }
        guard maxX >= minX, let full = context.makeImage() else { return nil }
        return full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Reusable signatures live in the app's own support folder as PNG files.
struct SignatureStore {
    struct Item: Identifiable, Equatable { let id: String; let url: URL }
    let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MacPDF/Signatures", isDirectory: true)
    }

    func items() -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "png" }
            .sorted { ($0.lastPathComponent) < ($1.lastPathComponent) }
            .map { Item(id: $0.lastPathComponent, url: $0) }
    }

    @discardableResult func save(_ image: CGImage) throws -> Item {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = Signature.png(image) else { throw PDFEditing.EditError.cannotSerialize }
        let url = folder.appendingPathComponent(String(format: "%013d-%@.png", Int(Date().timeIntervalSince1970 * 1000), UUID().uuidString.prefix(6) as CVarArg))
        try data.write(to: url, options: .atomic)
        return Item(id: url.lastPathComponent, url: url)
    }

    func image(_ item: Item) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func delete(_ item: Item) { try? FileManager.default.removeItem(at: item.url) }
}
