import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Page thumbnails with click, shift-click and command-click selection, and drag-to-reorder.
struct ThumbnailGrid: View {
    let model: ReaderModel
    var extract: () -> Void = {}
    var exportImages: () -> Void = {}
    @State private var dragging: [Int] = []
    @State private var insertion: Int?
    @State private var heights: [Int: CGFloat] = [:]

    var body: some View {
        let _ = model.revision
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        cell(index).id(index)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .onChange(of: model.currentPage) { _, page in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(page - 1, anchor: .center) }
            }
        }
        .onDrop(of: [.plainText], delegate: EndDrop(model: model, dragging: $dragging, insertion: $insertion))
    }

    private func cell(_ index: Int) -> some View {
        let selected = model.selectedPages.contains(index)
        let current = model.currentPage == index + 1
        return VStack(spacing: 4) {
            ThumbnailImage(model: model, index: index)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentColor : (current ? Color.secondary.opacity(0.6) : .clear), lineWidth: selected ? 3 : 1.5))
            Text("\(index + 1)").font(.caption).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 1)
                .background(Capsule().fill(selected ? Color.accentColor : .clear))
                .foregroundStyle(selected ? Color.white : Color.secondary)
        }
        .padding(6).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
        .background(GeometryReader { geometry in Color.clear.onAppear { heights[index] = geometry.size.height }.onChange(of: geometry.size.height) { _, new in heights[index] = new } })
        .overlay(alignment: .top) { if insertion == index { insertionLine } }
        .overlay(alignment: .bottom) { if insertion == index + 1 && index == model.pageCount - 1 { insertionLine } }
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.selectPage(index, extend: flags.contains(.shift), toggle: flags.contains(.command))
        }
        .onDrag {
            dragging = selected ? model.selectedPages.sorted() : [index]
            if !selected { model.selectPage(index, extend: false, toggle: false) }
            return NSItemProvider(object: "macpdf-pages" as NSString)
        }
        .onDrop(of: [.plainText], delegate: CellDrop(model: model, index: index, height: { heights[index] ?? 120 }, dragging: $dragging, insertion: $insertion))
        .contextMenu {
            Button(model.targetPages.count > 1 ? "順時針旋轉選取的頁面" : "順時針旋轉這一頁") { ensureSelected(index); model.rotateCurrentPage() }
            Button(model.targetPages.count > 1 ? "刪除選取的頁面" : "刪除這一頁", role: .destructive) { ensureSelected(index); model.deleteCurrentPage() }
                .disabled(model.pageCount <= 1)
            Divider()
            Button(model.targetPages.count > 1 ? "複製選取的頁面" : "複製這一頁") { ensureSelected(index); model.duplicateTargets() }
            Button("擷取頁面為新檔案…") { ensureSelected(index); extract() }
            Button("匯出為圖片…") { ensureSelected(index); exportImages() }
            Divider()
            Button("選取全部頁面") { model.selectAllPages() }
        }
        .accessibilityLabel(String(format: L("第 %ld 頁"), index + 1))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func ensureSelected(_ index: Int) {
        if !model.selectedPages.contains(index) { model.selectPage(index, extend: false, toggle: false) }
    }

    private var insertionLine: some View {
        Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 4).offset(y: -4)
    }
}

private struct ThumbnailImage: View {
    let model: ReaderModel
    let index: Int
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).aspectRatio(0.75, contentMode: .fit)
            }
        }
        .frame(maxWidth: 120)
        .task(id: "\(model.revision)-\(index)-\(model.document.map { ObjectIdentifier($0).hashValue } ?? 0)") {
            guard let page = model.document?.page(at: index) else { image = nil; return }
            image = page.thumbnail(of: NSSize(width: 240, height: 320), for: .cropBox)
        }
    }
}

private struct CellDrop: DropDelegate {
    let model: ReaderModel
    let index: Int
    let height: () -> CGFloat
    @Binding var dragging: [Int]
    @Binding var insertion: Int?

    func validateDrop(info: DropInfo) -> Bool { !dragging.isEmpty }
    func dropEntered(info: DropInfo) { insertion = target(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { insertion = target(info); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if insertion == index || insertion == index + 1 { insertion = nil } }
    func performDrop(info: DropInfo) -> Bool {
        let destination = target(info)
        let pages = dragging
        dragging = []; insertion = nil
        guard !pages.isEmpty else { return false }
        // Dropping a block onto itself changes nothing.
        let sorted = pages.sorted()
        if destination >= sorted[0], destination <= sorted[sorted.count - 1] + 1, sorted == Array(sorted[0]...sorted[sorted.count - 1]) { return true }
        model.movePages(pages, before: destination)
        return true
    }
    private func target(_ info: DropInfo) -> Int { info.location.y > height() / 2 ? index + 1 : index }
}

/// Dropping on the gap below the last page puts the pages at the end.
private struct EndDrop: DropDelegate {
    let model: ReaderModel
    @Binding var dragging: [Int]
    @Binding var insertion: Int?
    func validateDrop(info: DropInfo) -> Bool { !dragging.isEmpty }
    func performDrop(info: DropInfo) -> Bool {
        let pages = dragging
        dragging = []; insertion = nil
        guard !pages.isEmpty else { return false }
        model.movePages(pages, before: model.pageCount)
        return true
    }
}
