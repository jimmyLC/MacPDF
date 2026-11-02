import SwiftUI
import Observation

@MainActor @Observable
final class RedactionSession {
    var marks: [RedactionMark] = []
    var drawing = false
    var keywords = ""
    var regex = ""
    var kinds: Set<PIIKind> = [.email, .card, .phone]
    var scanned = false
    var lastFound = 0
}

struct RedactionPanel: View {
    let model: ReaderModel
    let session: RedactionSession
    @State private var confirming = false

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("塗黑", systemImage: "rectangle.dashed.badge.record").font(.headline)
                Spacer()
                Button("取消") { model.endRedaction() }.controlSize(.small).keyboardShortcut(.cancelAction)
            }
            Text("找到的內容只是候選，請逐一檢查；沒有被框起來的地方不會被塗黑。")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                TextField("關鍵字（以逗號分隔）", text: $session.keywords).textFieldStyle(.roundedBorder)
                TextField("自訂規則（規則運算式，選填）", text: $session.regex).textFieldStyle(.roundedBorder)
                FlowKinds(selection: $session.kinds)
                HStack {
                    Button("尋找") { model.scanRedaction() }.prominentGlassButton().controlSize(.small)
                    Toggle(isOn: Binding(get: { session.drawing }, set: { model.setRedactDrawing($0) })) {
                        Label("手動畫框", systemImage: "rectangle.dashed")
                    }.toggleStyle(.button).controlSize(.small)
                }
                if session.scanned {
                    Text(session.lastFound == 0 ? L("沒有找到符合項目，請調整關鍵字或類別。") : String(format: L("新增了 %ld 個候選區域。"), session.lastFound))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(String(format: L("標記清單（%ld）"), session.marks.count)).font(.subheadline.weight(.medium))
                Spacer()
                Button("全部移除") { model.clearMarks() }.controlSize(.small).disabled(session.marks.isEmpty)
            }
            List(session.marks) { mark in
                HStack(spacing: 8) {
                    Button { model.goToMark(mark) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(format: L("第 %ld 頁"), mark.page + 1)).font(.caption).foregroundStyle(.secondary)
                            Text(mark.text).lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button { model.removeMark(mark.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("移除這個標記").accessibilityLabel("移除這個標記")
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)

            Button { confirming = true } label: {
                Label("套用並另存…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            .prominentGlassButton().controlSize(.large).disabled(session.marks.isEmpty || model.job != nil)
        }
        .padding(16)
        .frame(width: 320)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .alert("永久移除標記的內容？", isPresented: $confirming) {
            Button("套用並另存…", role: .destructive) { model.applyRedaction() }
            Button("取消", role: .cancel) {}
        } message: {
            let pages = Set(session.marks.map(\.page)).count
            Text(String(format: L("這會永久移除 %ld 頁、%ld 個區域的文字與圖片，這些頁面會變成不能選取文字的圖片。原始檔不會被修改，會另存新檔。塗黑後無法復原。"), pages, session.marks.count))
        }
    }
}

private struct FlowKinds: View {
    @Binding var selection: Set<PIIKind>
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("自動找出").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                ForEach(PIIKind.allCases) { kind in
                    Toggle(kind.label, isOn: Binding(get: { selection.contains(kind) },
                                                      set: { if $0 { selection.insert(kind) } else { selection.remove(kind) } }))
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
            }
        }
    }
}
