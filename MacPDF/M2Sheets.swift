import SwiftUI

enum M2Sheet: String, Identifiable {
    case metadata, encrypt, compress
    var id: String { rawValue }
}

private struct SheetFrame<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            content
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct MetadataSheet: View {
    let model: ReaderModel
    let close: () -> Void
    @State private var title = ""
    @State private var author = ""
    @State private var subject = ""
    @State private var keywords = ""

    var body: some View {
        SheetFrame(title: "文件資訊", symbol: "info.circle") {
            Form {
                TextField("標題", text: $title)
                TextField("作者", text: $author)
                TextField("主旨", text: $subject)
                TextField("關鍵字（以逗號分隔）", text: $keywords)
            }
            HStack {
                Button("清除全部", role: .destructive) { title = ""; author = ""; subject = ""; keywords = "" }
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("儲存") { model.setMetadata(title: title, author: author, subject: subject, keywords: keywords); close() }
                    .keyboardShortcut(.defaultAction).prominentGlassButton()
            }
        }
        .onAppear {
            let values = model.metadata
            title = values["title"] ?? ""; author = values["author"] ?? ""
            subject = values["subject"] ?? ""; keywords = values["keywords"] ?? ""
        }
    }
}

struct EncryptSheet: View {
    let model: ReaderModel
    let close: () -> Void
    @State private var password = ""
    @State private var confirm = ""
    @State private var owner = ""
    @State private var permissions = PDFEditing.Permissions()

    private var valid: Bool { !password.isEmpty && password == confirm }

    var body: some View {
        SheetFrame(title: "儲存加密副本", symbol: "lock.doc") {
            Form {
                SecureField("開啟密碼", text: $password)
                SecureField("再輸入一次", text: $confirm)
                SecureField("擁有者密碼（選填，用於變更權限）", text: $owner)
                Toggle("允許列印", isOn: $permissions.printing)
                Toggle("允許複製內容", isOn: $permissions.copying)
                Toggle("允許編輯", isOn: $permissions.editing)
            }
            if !confirm.isEmpty && password != confirm {
                Text("兩次輸入的密碼不一致").font(.callout).foregroundStyle(.red)
            }
            Text("密碼不會被儲存。忘記密碼就無法開啟這份副本。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("選擇位置並儲存…") {
                    let (user, ownerPassword, options) = (password, owner, permissions)
                    close()
                    DispatchQueue.main.async { model.exportEncryptedCopy(userPassword: user, ownerPassword: ownerPassword, permissions: options) }
                }
                .keyboardShortcut(.defaultAction).prominentGlassButton().disabled(!valid)
            }
        }
    }
}

struct CompressSheet: View {
    let model: ReaderModel
    let close: () -> Void
    @State private var preset = PDFProcessing.Preset.standard

    var body: some View {
        SheetFrame(title: "壓縮掃描頁面", symbol: "arrow.down.right.and.arrow.up.left") {
            Picker("品質", selection: $preset) {
                Text("高品質").tag(PDFProcessing.Preset.high)
                Text("標準").tag(PDFProcessing.Preset.standard)
                Text("最小檔案").tag(PDFProcessing.Preset.small)
            }.pickerStyle(.segmented).labelsHidden()
            Text(detail).font(.callout).foregroundStyle(.secondary)
            Text("只會處理整頁都是圖片的掃描頁面，並保留可搜尋的文字；其他頁面保持不變。可以復原。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("開始壓縮") { let chosen = preset; close(); model.compress(chosen) }
                    .keyboardShortcut(.defaultAction).prominentGlassButton()
            }
        }
    }

    private var detail: LocalizedStringKey {
        switch preset {
        case .high: "約 200 dpi，適合需要細看的文件。"
        case .standard: "約 150 dpi，大多數情況的平衡選擇。"
        case .small: "約 100 dpi，檔案最小，細節會變粗。"
        }
    }
}
