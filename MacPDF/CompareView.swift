import SwiftUI
import PDFKit
import Observation

@MainActor @Observable
final class CompareModel {
    let oldView = PDFView()
    let newView = PDFView()
    private(set) var oldName = ""
    private(set) var newName = ""
    private(set) var result: PDFCompare.Result?
    private(set) var selected = 0
    var error: String?
    private var oldURL: URL?
    private var newURL: URL?

    init() {
        for view in [oldView, newView] {
            view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
            view.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(red: 0.10, green: 0.105, blue: 0.15, alpha: 1) : NSColor(red: 0.91, green: 0.925, blue: 0.96, alpha: 1)
            }
        }
    }

    func load(old: URL, new: URL) {
        oldURL = old; newURL = new
        // Fresh copies are compared and painted, so the files on disk are untouched.
        guard let a = PDFDocument(url: old), let b = PDFDocument(url: new), !a.isLocked, !b.isLocked, a.pageCount > 0, b.pageCount > 0 else {
            error = L("無法讀取其中一份 PDF（可能已損壞或需要密碼）。"); return
        }
        oldName = old.lastPathComponent; newName = new.lastPathComponent
        // Compared before the views see the documents, so only text stored in the files counts.
        let outcome = PDFCompare.compare(old: a, new: b)
        PDFCompare.paint(outcome, old: a, new: b)
        oldView.document = a; newView.document = b
        result = outcome; selected = 0
        if !outcome.changes.isEmpty { select(0) }
    }

    func swap() { if let oldURL, let newURL { load(old: newURL, new: oldURL) } }

    func select(_ index: Int) {
        guard let result, result.changes.indices.contains(index) else { return }
        selected = index
        let change = result.changes[index]
        func show(_ view: PDFView, page: Int?, rects: [CGRect]) {
            guard let page, let target = view.document?.page(at: page) else { return }
            let top = rects.map(\.maxY).max() ?? target.bounds(for: .cropBox).maxY
            view.go(to: PDFDestination(page: target, at: CGPoint(x: 0, y: min(top + 80, target.bounds(for: .cropBox).maxY))))
        }
        show(oldView, page: change.oldPage, rects: change.oldRects)
        show(newView, page: change.newPage, rects: change.newRects)
    }
    func next() { if let result, !result.changes.isEmpty { select((selected + 1) % result.changes.count) } }
    func previous() { if let result, !result.changes.isEmpty { select((selected - 1 + result.changes.count) % result.changes.count) } }
}

struct ComparePDF: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

struct CompareView: View {
    let model: CompareModel

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 10) {
                header
                if let result = model.result, result.isIdentical {
                    ContentUnavailableView("兩份文件沒有差異", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 10) {
                        pane(model.oldName, label: "舊版", view: model.oldView)
                        pane(model.newName, label: "新版", view: model.newView)
                        changeList.frame(width: 290)
                    }
                }
            }
            .padding(12).padding(.top, 22)
        }
        .ignoresSafeArea()
        .frame(minWidth: 980, minHeight: 560)
        .alert("操作無法完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            GlassCapsule {
                GlassIconButton(symbol: "arrow.left.arrow.right", label: "對調新舊版") { model.swap() }
            }
            if let result = model.result {
                Text(summary(result)).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 36).glassSurface(in: Capsule())
                if !result.oldHasText || !result.newHasText {
                    Label("有一份文件幾乎沒有文字（可能是掃描檔），請先做文字辨識再比較。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .padding(.horizontal, 12).frame(height: 36).glassSurface(in: Capsule())
                }
            }
            Spacer()
            GlassCapsule {
                GlassIconButton(symbol: "chevron.up", label: "上一個差異") { model.previous() }
                GlassIconButton(symbol: "chevron.down", label: "下一個差異") { model.next() }
            }
        }
    }

    private func summary(_ result: PDFCompare.Result) -> String {
        result.isIdentical ? L("沒有差異") : String(format: L("%ld 處差異"), result.changes.count)
    }

    private func pane(_ name: String, label: LocalizedStringKey, view: PDFView) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            ComparePDF(view: view).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var changeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                legend(.systemRed, "刪除"); legend(.systemGreen, "新增"); legend(.systemYellow, "修改")
            }.padding(.horizontal, 14).padding(.top, 12)
            List(Array((model.result?.changes ?? []).enumerated()), id: \.element.id) { index, change in
                Button { model.select(index) } label: { row(change) }
                    .buttonStyle(.plain)
                    .listRowBackground(index == model.selected ? Color.accentColor.opacity(0.18) : Color.clear)
            }
            .scrollContentBackground(.hidden)
        }
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func legend(_ color: NSColor, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) { Circle().fill(Color(nsColor: color)).frame(width: 8, height: 8); Text(text).font(.caption) }
    }

    private func row(_ change: PDFCompare.Change) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: change.kind == .added ? .systemGreen : change.kind == .removed ? .systemRed : .systemYellow)).frame(width: 8, height: 8)
                Text(pageLabel(change)).font(.caption).foregroundStyle(.secondary)
            }
            if change.wholePage {
                Text(change.kind == .added ? "新增的頁面" : "刪除的頁面").lineLimit(1)
            } else {
                if !change.oldText.isEmpty { Text(change.oldText).strikethrough().foregroundStyle(.secondary).lineLimit(2) }
                if !change.newText.isEmpty { Text(change.newText).lineLimit(2) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pageLabel(_ change: PDFCompare.Change) -> String {
        switch (change.oldPage, change.newPage) {
        case let (o?, n?): o == n ? String(format: L("第 %ld 頁"), n + 1) : String(format: L("舊版第 %ld 頁 → 新版第 %ld 頁"), o + 1, n + 1)
        case let (o?, nil): String(format: L("舊版第 %ld 頁"), o + 1)
        case let (nil, n?): String(format: L("新版第 %ld 頁"), n + 1)
        default: ""
        }
    }
}
