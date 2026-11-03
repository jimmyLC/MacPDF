import SwiftUI
import PDFKit
import Observation
import UniformTypeIdentifiers

enum TextScope: String, CaseIterable, Identifiable {
    case page, all
    var id: String { rawValue }
}

@MainActor @Observable
final class TextSession {
    var scope = TextScope.page
    var pages: [TextExtraction.PageText] = []
    /// Text the user has typed, by page index; absent means unchanged.
    var edits: [Int: String] = [:]
    var loading = false
    var progress = (done: 0, total: 0)
    var task: Task<Void, Never>?
    /// Set by "Convert to Markdown": when reading ends, go straight to the save panel.
    var autoExport = false

    func original(_ page: TextExtraction.PageText) -> String { page.lines.map(\.text).joined(separator: "\n") }
    func text(for page: TextExtraction.PageText) -> String { edits[page.index] ?? original(page) }
    func isEdited(_ page: TextExtraction.PageText) -> Bool { edits[page.index].map { $0 != original(page) } ?? false }

    /// Pages with the user's text applied. If the number of lines changed, sizes and positions no longer line up, so
    /// the page is rebuilt as plain paragraphs.
    var current: [TextExtraction.PageText] {
        pages.map { page in
            guard isEdited(page), let typed = edits[page.index] else { return page }
            let rows = typed.components(separatedBy: "\n")
            var copy = page
            if rows.count == page.lines.count {
                copy.lines = zip(page.lines, rows).map { var line = $0; line.text = $1; return line }
            } else {
                let size = page.lines.map(\.size).sorted().dropFirst(page.lines.count / 2).first ?? 12
                copy.lines = rows.map { TextExtraction.Line(text: $0, box: .zero, size: size) }
            }
            return copy
        }
    }
}

struct TextPanel: View {
    let model: ReaderModel
    let session: TextSession

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("文字", systemImage: "text.viewfinder").font(.headline)
                Spacer()
                Button("完成") { model.closeTextPanel() }.controlSize(.small).keyboardShortcut(.cancelAction)
            }
            Picker("範圍", selection: Binding(get: { session.scope }, set: { model.setTextScope($0) })) {
                Text("這一頁").tag(TextScope.page); Text("全部頁面").tag(TextScope.all)
            }.pickerStyle(.segmented).labelsHidden()
            if session.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(format: L("讀取文字中 %ld / %ld"), session.progress.done, session.progress.total)).font(.caption)
                    Spacer()
                    Button("停止") { model.stopTextLoading() }.controlSize(.small)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.pages.isEmpty && !session.loading {
                        Text("這裡沒有找到文字。如果是掃描的頁面，請確認辨識語言（在設定裡）。").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(session.pages, id: \.index) { page in pageEditor(page) }
                }
            }
            .frame(minHeight: 160)
            Text("可以直接修改文字。掃描頁修改後按「寫回 PDF」，之後搜尋與複製會是修改後的文字；原本就有文字的頁面不會被改動，修改只用在複製與匯出。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("複製") { model.copyExtractedText() }
                Menu("匯出") {
                    Button("Markdown（.md）…") { model.saveExtractedText(markdown: true) }
                    Button("純文字（.txt）…") { model.saveExtractedText(markdown: false) }
                }
                Spacer()
                Button("寫回 PDF") { model.applyTextCorrections() }
                    .prominentGlassButton().disabled(!model.canApplyTextCorrections)
            }.controlSize(.small).disabled(session.pages.isEmpty)
        }
        .padding(16)
        .frame(width: 340)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func pageEditor(_ page: TextExtraction.PageText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(format: L("第 %ld 頁"), page.index + 1)).font(.caption.weight(.semibold))
                Text(page.recognised ? "辨識自圖片" : "PDF 的文字").font(.caption).foregroundStyle(.secondary)
                if session.isEdited(page) { Circle().fill(Color.orange).frame(width: 6, height: 6) }
                Spacer()
            }
            TextEditor(text: Binding(get: { session.text(for: page) }, set: { session.edits[page.index] = $0 }))
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 90, maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}
