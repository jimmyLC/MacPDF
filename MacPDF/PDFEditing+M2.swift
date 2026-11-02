import AppKit
import PDFKit

/// M2 operations: page replacement (OCR/compression), forms, metadata, images, protection.
extension PDFEditing {
    // MARK: Page replacement

    /// Swaps pages in place and re-points links and bookmarks that targeted the old pages.
    func replace(pages replacements: [Int: PDFPage]) throws {
        guard !replacements.isEmpty else { return }
        try mutate { doc in
            // Links on a rebuilt page lose their targets while it is made. Note where each one pointed (as a page
            // number, which a replacement does not change) before anything is swapped, and restore them afterwards.
            struct Link { let page: Int; let slot: Int; let count: Int; let target: Int; let point: CGPoint }
            var links: [Link] = []
            for index in replacements.keys.sorted() {
                guard let old = doc.page(at: index) else { throw EditError.invalidPage }
                let annotations = old.annotations
                for (slot, annotation) in annotations.enumerated() {
                    let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
                    guard let destination, let page = destination.page else { continue }
                    let target = doc.index(for: page)
                    if target != NSNotFound { links.append(Link(page: index, slot: slot, count: annotations.count, target: target, point: destination.point)) }
                }
            }
            var pairs: [(old: PDFPage, new: PDFPage)] = []
            for index in replacements.keys.sorted() {
                guard let old = doc.page(at: index), let new = replacements[index]?.copy() as? PDFPage else { throw EditError.invalidPage }
                doc.removePage(at: index)
                doc.insert(new, at: index)
                pairs.append((old, new))
            }
            for link in links {
                guard let page = doc.page(at: link.page), let target = doc.page(at: link.target) else { continue }
                let annotations = page.annotations
                if annotations.count == link.count, annotations[link.slot].type == "Link" {
                    let destination = PDFDestination(page: target, at: link.point)
                    annotations[link.slot].destination = destination
                    annotations[link.slot].action = PDFActionGoTo(destination: destination)
                }
            }
            Self.rebind(in: doc, pairs: pairs)
        }
        reparse()
    }

    private static func rebind(in doc: PDFDocument, pairs: [(old: PDFPage, new: PDFPage)]) {
        func mapped(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let page = destination.page, let target = pairs.first(where: { $0.old === page })?.new else { return nil }
            let result = PDFDestination(page: target, at: destination.point)
            result.zoom = destination.zoom
            return result
        }
        for index in 0..<doc.pageCount {
            for annotation in doc.page(at: index)?.annotations ?? [] {
                if let replacement = mapped(annotation.destination) { annotation.destination = replacement }
                if let goTo = annotation.action as? PDFActionGoTo, let replacement = mapped(goTo.destination) {
                    annotation.action = PDFActionGoTo(destination: replacement)
                }
            }
        }
        func walk(_ outline: PDFOutline) {
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                if let replacement = mapped(child.destination) { child.destination = replacement }
                walk(child)
            }
        }
        if let root = doc.outlineRoot { walk(root) }
    }

    // MARK: Forms

    static func widgets(in doc: PDFDocument) -> [PDFAnnotation] {
        (0..<doc.pageCount).flatMap { doc.page(at: $0)?.annotations ?? [] }.filter { $0.widgetFieldType != nil && $0.widgetFieldType != .signature && $0.type == "Widget" }
    }

    func resetFormFields() throws {
        try mutate { doc in
            for widget in Self.widgets(in: doc) {
                switch widget.widgetFieldType {
                case .button: widget.buttonWidgetState = .offState
                default: widget.widgetStringValue = ""
                }
            }
        }
    }

    /// Burns form fields into the page content. Other annotations stay editable.
    func flattenForms() throws {
        try mutate { doc in
            guard !Self.widgets(in: doc).isEmpty else { return }
            var stash: [[PDFAnnotation]] = []
            for index in 0..<doc.pageCount {
                guard let page = doc.page(at: index) else { continue }
                let others = page.annotations.filter { $0.type != "Widget" }
                others.forEach { page.removeAnnotation($0) }
                stash.append(others)
            }
            guard let data = doc.dataRepresentation(options: [PDFDocumentWriteOption.burnInAnnotationsOption: true]),
                  let flat = PDFDocument(data: data), flat.pageCount == doc.pageCount else { throw EditError.cannotSerialize }
            var replacements: [Int: PDFPage] = [:]
            for index in 0..<flat.pageCount {
                guard let page = flat.page(at: index)?.copy() as? PDFPage else { throw EditError.cannotSerialize }
                stash[index].forEach { page.addAnnotation($0) }
                replacements[index] = page
            }
            var pairs: [(old: PDFPage, new: PDFPage)] = []
            for index in 0..<doc.pageCount {
                guard let old = doc.page(at: index), let new = replacements[index] else { continue }
                doc.removePage(at: index); doc.insert(new, at: index)
                pairs.append((old, new))
            }
            Self.rebind(in: doc, pairs: pairs)
        }
        reparse()
    }

    // MARK: Metadata

    static let metadataKeys: [PDFDocumentAttribute] = [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute]

    func setMetadata(_ values: [PDFDocumentAttribute: Any]) throws {
        try mutate { doc in doc.documentAttributes = values }
    }

    // MARK: Images

    func appendImages(_ urls: [URL], sheet: PDFProcessing.PageSheet = .a4) throws {
        let pages = urls.compactMap { PDFProcessing.page(fromImageAt: $0, sheet: sheet) }
        guard !pages.isEmpty else { throw EditError.cannotSerialize }
        try appendPages(pages)
    }

    /// Adds ready-made pages at the end (or in front of `index`).
    func appendPages(_ pages: [PDFPage], before index: Int? = nil) throws {
        guard !pages.isEmpty else { throw EditError.cannotSerialize }
        try mutate { doc in
            let at = min(max(index ?? doc.pageCount, 0), doc.pageCount)
            for (offset, page) in pages.enumerated() { doc.insert(page, at: at + offset) }
        }
        reparse()
    }

    // MARK: Protection

    /// A fresh, unencrypted copy that keeps pages, links and bookmarks.
    private func plainCopy() throws -> PDFDocument {
        guard !Self.containsSignatureField(document) else { throw EditError.signatureField }
        let output = PDFDocument()
        try Self.copyPages(from: document, range: 0..<document.pageCount, into: output)
        output.documentAttributes = document.documentAttributes
        return output
    }

    func exportUnlocked(to url: URL) throws {
        let plain = try plainCopy()
        try Self.writeNew(plain, to: url)
    }

    /// What a reader who only knows the open password may do. Accessibility access is always kept.
    struct Permissions {
        var printing = true, copying = true, editing = true
        var mask: UInt {
            var value: UInt = PDFAccessPermissions.allowsContentAccessibility.rawValue
            if printing { value |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue | PDFAccessPermissions.allowsHighQualityPrinting.rawValue }
            if copying { value |= PDFAccessPermissions.allowsContentCopying.rawValue }
            if editing {
                value |= PDFAccessPermissions.allowsDocumentChanges.rawValue | PDFAccessPermissions.allowsDocumentAssembly.rawValue
                    | PDFAccessPermissions.allowsCommenting.rawValue | PDFAccessPermissions.allowsFormFieldEntry.rawValue
            }
            return value
        }
    }

    func exportEncrypted(to url: URL, userPassword: String, ownerPassword: String?, permissions: Permissions) throws {
        let plain = try plainCopy()
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: userPassword,
            .ownerPasswordOption: (ownerPassword?.isEmpty == false ? ownerPassword! : UUID().uuidString),
            .accessPermissionsOption: NSNumber(value: permissions.mask),
        ]
        guard let data = plain.dataRepresentation(options: options) else { throw EditError.cannotSerialize }
        try Self.writeNew(data: data, to: url)
    }
}
