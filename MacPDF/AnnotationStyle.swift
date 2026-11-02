import AppKit
import PDFKit
import SwiftUI

/// How new annotations look. Kept in UserDefaults; nothing leaves the Mac.
struct AnnotationStyle: Codable, Equatable {
    enum Alignment: String, Codable, CaseIterable { case left, center, right }

    var highlightOpacity = 0.5
    var lineColor = "#E0301E"
    var inkColor = "#1F5FFF"
    var inkWidth = 2.0
    var textFont = "Helvetica"
    var textSize = 14.0
    var textColor = "#000000"
    var textAlignment = Alignment.left
    var author = NSFullUserName()

    static let key = "annotationStyle"
    static func load() -> AnnotationStyle {
        guard let data = UserDefaults.standard.data(forKey: key), let style = try? JSONDecoder().decode(AnnotationStyle.self, from: data) else { return AnnotationStyle() }
        return style
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) } }

    var nsTextAlignment: NSTextAlignment { switch textAlignment { case .left: .left; case .center: .center; case .right: .right } }
}

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

extension PDFAnnotation {
    /// Sets the font and colour of a text box so that they survive saving. PDFKit's own `font` setter writes the
    /// default-appearance entry in a form it cannot read back; a plain string (with a leading space, which keeps
    /// it from being taken for a name) round-trips correctly.
    func applyTextStyle(font: NSFont, color: NSColor) {
        self.font = font
        self.fontColor = color
        let c = color.usingColorSpace(.sRGB) ?? color
        let entry = String(format: " /%@ %.2f Tf %.3f %.3f %.3f rg", font.fontName, font.pointSize, c.redComponent, c.greenComponent, c.blueComponent)
        _ = setValue(entry as NSString, forAnnotationKey: .defaultAppearance)
    }
}

extension PDFEditing {
    func annotate(page index: Int, bounds: CGRect, text: String, freeText: Bool, style: AnnotationStyle = AnnotationStyle()) throws {
        try mutate { doc in
            guard let page = doc.page(at: index) else { throw EditError.invalidPage }
            let annotation = PDFAnnotation(bounds: bounds, forType: freeText ? .freeText : .text, withProperties: nil)
            annotation.contents = text
            annotation.userName = style.author
            annotation.color = freeText ? .clear : .yellow
            if freeText {
                annotation.alignment = style.nsTextAlignment
                annotation.applyTextStyle(font: NSFont(name: style.textFont, size: CGFloat(style.textSize)) ?? NSFont.systemFont(ofSize: CGFloat(style.textSize)),
                                          color: NSColor(hex: style.textColor) ?? .black)
            }
            page.addAnnotation(annotation)
        }
    }

    func ink(page index: Int, points: [CGPoint], color: NSColor = .systemBlue, width: CGFloat = 2) throws {
        guard points.count > 1 else { return }
        try mutate { doc in
            guard let page = doc.page(at: index) else { throw EditError.invalidPage }
            let pageBounds = page.bounds(for: .cropBox)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: points[0].x - pageBounds.minX, y: points[0].y - pageBounds.minY))
            for point in points.dropFirst() { path.line(to: NSPoint(x: point.x - pageBounds.minX, y: point.y - pageBounds.minY)) }
            let annotation = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
            annotation.color = color
            let border = PDFBorder(); border.lineWidth = width; annotation.border = border
            annotation.add(path)
            page.addAnnotation(annotation)
        }
    }

    /// The annotations on a page that a person put there (links and form fields are not offered for editing).
    static func editableAnnotations(on page: PDFPage) -> [(slot: Int, annotation: PDFAnnotation)] {
        page.annotations.enumerated().compactMap { slot, annotation in
            let type = annotation.type ?? ""
            return type == "Link" || type == "Widget" || type == "Popup" ? nil : (slot, annotation)
        }
    }

    /// Edits one annotation (found by page and position on the page). Undoable like every other change.
    func updateAnnotation(page index: Int, slot: Int, _ change: (PDFAnnotation) -> Void) throws {
        try mutate { doc in
            guard let page = doc.page(at: index), page.annotations.indices.contains(slot) else { throw EditError.invalidPage }
            change(page.annotations[slot])
        }
    }

    func deleteAnnotation(page index: Int, slot: Int) throws {
        try mutate { doc in
            guard let page = doc.page(at: index), page.annotations.indices.contains(slot) else { throw EditError.invalidPage }
            page.removeAnnotation(page.annotations[slot])
        }
    }
}
