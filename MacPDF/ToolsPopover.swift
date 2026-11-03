import SwiftUI

/// The handful of things people open a PDF tool for, as big buttons.
struct ToolsPopover: View {
    let model: ReaderModel
    let dismiss: () -> Void

    private struct Tile: View {
        let symbol: String
        let title: LocalizedStringKey
        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular)).frame(height: 28)
                Text(title).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(width: 82, height: 82)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func tile(_ symbol: String, _ title: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button { dismiss(); DispatchQueue.main.async(execute: action) } label: { Tile(symbol: symbol, title: title) }.buttonStyle(.plain)
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(82), spacing: 10), count: 4)
        VStack(alignment: .leading, spacing: 12) {
            Text("常用工具").font(.headline)
            LazyVGrid(columns: columns, spacing: 10) {
                tile("rectangle.stack.badge.plus", "合併") { model.sheet = .build }
                tile("scissors", "拆分") { model.sheet = .split }
                Menu {
                    Button("順時針 90°") { model.rotateTargets(by: 90) }
                    Button("逆時針 90°") { model.rotateTargets(by: -90) }
                    Button("180°") { model.rotateTargets(by: 180) }
                    Divider()
                    Button("全部頁面順時針 90°") { model.rotateAll(by: 90) }
                } label: { Tile(symbol: "rotate.right", title: "轉方向") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                tile("text.viewfinder", "文字") { model.openTextPanel() }
                tile("doc.richtext", "轉成 Markdown") { model.convertToMarkdown() }
                tile("lock", "加上密碼") { model.sheet = .encrypt }
                tile("arrow.down.right.and.arrow.up.left", "壓縮") { model.sheet = .compress }
                tile("magnifyingglass.circle", "讓掃描檔可搜尋") { model.sheet = .ocr }
            }
            Text("全部在這台 Mac 上處理，文件不會上傳。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }
}
