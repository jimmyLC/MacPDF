import SwiftUI

struct WelcomeView: View {
    let model: ReaderModel
    let open: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 56)
                appMark
                VStack(spacing: 6) {
                    Text("MacPDF").font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text("本機處理，不上傳、不追蹤").foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    Button(action: open) {
                        Label("開啟 PDF…", systemImage: "folder").padding(.horizontal, 10)
                    }
                    .prominentGlassButton().controlSize(.large).keyboardShortcut("o")
                    Text("或把 PDF 拖曳到這個視窗").font(.callout).foregroundStyle(.tertiary)
                }
                GlassGroup(spacing: 16) {
                    VStack(spacing: 16) {
                        if !model.recoveryEntries.isEmpty { recoveryCard }
                        if !model.recents.isEmpty { recentCard }
                    }
                }
                .padding(.top, 8)
                Spacer(minLength: 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var appMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor, Color.purple.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(0.9)
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 40, weight: .regular)).foregroundStyle(.white)
        }
        .frame(width: 88, height: 88)
        .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.accentColor.opacity(0.35), radius: 24, y: 10)
    }

    private var recoveryCard: some View {
        card(title: "可恢復的文件", symbol: "arrow.counterclockwise.circle") {
            ForEach(model.recoveryEntries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.clock").foregroundStyle(.orange)
                    Text(entry.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("恢復") { model.restore(entry) }.controlSize(.small)
                    Button("丟棄", role: .destructive) { model.discardRecovery(entry) }.controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .accessibilityLabel(String(format: L("恢復 %@"), entry.title))
            }
        }
    }

    private var recentCard: some View {
        card(title: "最近開啟", symbol: "clock", trailing: AnyView(Button("清除記錄") { model.clearRecents() }.controlSize(.small))) {
            ForEach(Array(model.recents.prefix(6)), id: \.absoluteString) { url in
                RecentRow(url: url) { model.openRecent(url) }
            }
        }
    }

    private func card<Rows: View>(title: LocalizedStringKey, symbol: String, trailing: AnyView? = nil, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
            rows()
        }
        .padding(12)
        .frame(width: 420)
        .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
