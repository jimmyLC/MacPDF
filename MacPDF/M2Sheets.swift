import SwiftUI
import UniformTypeIdentifiers

enum M2Sheet: String, Identifiable {
    case metadata, encrypt, compress, signature, exportImages
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

struct SignatureSheet: View {
    let model: ReaderModel
    let close: () -> Void
    enum Mode: String, CaseIterable, Identifiable { case saved, draw, typed, image; var id: String { rawValue } }
    @State private var mode = Mode.draw
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var text = ""
    @State private var fontName = Signature.typedFonts[0]
    @State private var picture: CGImage?
    @State private var keep = true
    @State private var items: [SignatureStore.Item] = []
    @State private var showingPicker = false

    private var candidate: CGImage? {
        switch mode {
        case .saved: nil
        case .draw: Signature.drawn(strokes: strokes + (current.count > 1 ? [current] : []))
        case .typed: Signature.typed(text, fontName: fontName)
        case .image: picture
        }
    }

    var body: some View {
        SheetFrame(title: "簽名", symbol: "signature") {
            Picker("方式", selection: $mode) {
                if !items.isEmpty { Text("已儲存").tag(Mode.saved) }
                Text("手繪").tag(Mode.draw)
                Text("打字").tag(Mode.typed)
                Text("圖片").tag(Mode.image)
            }.pickerStyle(.segmented).labelsHidden()
            Group {
                switch mode {
                case .saved: savedGrid
                case .draw: drawPad
                case .typed: typedPad
                case .image: imagePad
                }
            }.frame(height: 170)
            if mode != .saved { Toggle("儲存為常用簽名", isOn: $keep) }
            Text("簽名會放在頁面上你點的位置，可以復原。簽名只存在這台 Mac 上。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                if mode != .saved {
                    Button("使用") { use(candidate) }
                        .keyboardShortcut(.defaultAction).prominentGlassButton().disabled(candidate == nil)
                }
            }
        }
        .onAppear { items = model.signatures.items(); if !items.isEmpty { mode = .saved } }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                picture = Signature.fromImage(at: url)
                if picture == nil { model.error = L("無法讀取這張圖片，或圖片中找不到簽名。") }
            }
        }
    }

    private func use(_ image: CGImage?) {
        guard let image else { return }
        if mode != .saved, keep { _ = try? model.signatures.save(image) }
        close()
        model.prepareSignature(image)
    }

    private var drawPad: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { context, _ in
                for stroke in strokes + [current] where stroke.count > 1 {
                    var path = Path(); path.move(to: stroke[0]); stroke.dropFirst().forEach { path.addLine(to: $0) }
                    context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
            .overlay(alignment: .bottom) { Text("在這裡用觸控板或滑鼠簽名").font(.caption).foregroundStyle(.tertiary).padding(.bottom, 6).opacity(strokes.isEmpty && current.isEmpty ? 1 : 0) }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { current.append($0.location) }
                .onEnded { _ in if current.count > 1 { strokes.append(current) }; current = [] })
            Button("清除") { strokes = []; current = [] }.controlSize(.small).padding(8).disabled(strokes.isEmpty)
        }
    }

    private var typedPad: some View {
        VStack(spacing: 10) {
            TextField("輸入姓名", text: $text).textFieldStyle(.roundedBorder)
            Picker("字型", selection: $fontName) {
                ForEach(Signature.typedFonts, id: \.self) { Text($0).tag($0) }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
                if let image = candidate { Image(decorative: image, scale: 2).resizable().scaledToFit().padding(10) }
            }
        }
    }

    private var imagePad: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
                if let image = picture { Image(decorative: image, scale: 2).resizable().scaledToFit().padding(10) }
                else { Text("選一張在白紙上簽名的照片或掃描圖，白色背景會自動去掉。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding() }
            }
            Button("選擇圖片…") { showingPicker = true }
        }
    }

    private var savedGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(items) { item in
                    ZStack(alignment: .topTrailing) {
                        Button { if let image = model.signatures.image(item) { close(); model.prepareSignature(image) } } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
                                if let image = model.signatures.image(item) { Image(decorative: image, scale: 2).resizable().scaledToFit().padding(8) }
                            }.frame(height: 70)
                        }.buttonStyle(.plain)
                        Button { model.signatures.delete(item); items = model.signatures.items(); if items.isEmpty { mode = .draw } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).padding(4).accessibilityLabel("刪除這個簽名")
                    }
                }
            }
        }
    }
}

struct ExportImagesSheet: View {
    let model: ReaderModel
    let close: () -> Void
    enum Scope: String, Identifiable { case all, selected, range; var id: String { rawValue } }
    @State private var scope = Scope.all
    @State private var range = ""
    @State private var format = PDFProcessing.ImageFormat.png
    @State private var dpi = 150

    private var pages: [Int]? {
        switch scope {
        case .all: return Array(0..<model.pageCount)
        case .selected: return model.targetPages
        case .range:
            guard let ranges = try? PDFEditing.parseRanges(range, pageCount: model.pageCount) else { return nil }
            return ranges.flatMap { $0.map { $0 - 1 } }
        }
    }

    var body: some View {
        SheetFrame(title: "匯出為圖片", symbol: "photo.on.rectangle") {
            Picker("頁面", selection: $scope) {
                Text("全部").tag(Scope.all)
                if !model.selectedPages.isEmpty { Text("選取的頁面").tag(Scope.selected) }
                Text("範圍").tag(Scope.range)
            }.pickerStyle(.segmented)
            if scope == .range { TextField("例如 1-3, 5", text: $range).textFieldStyle(.roundedBorder) }
            Picker("格式", selection: $format) { Text("PNG（無損）").tag(PDFProcessing.ImageFormat.png); Text("JPEG（較小）").tag(PDFProcessing.ImageFormat.jpeg) }
                .pickerStyle(.segmented)
            Picker("解析度", selection: $dpi) { Text("72 dpi（螢幕）").tag(72); Text("150 dpi").tag(150); Text("300 dpi（列印）").tag(300) }
                .pickerStyle(.segmented)
            Text("每頁存成一張圖片，檔名像「檔名-001.png」。已有同名檔案時會加編號，不會覆寫。單邊最多 10000 像素。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("選擇資料夾並匯出…") {
                    guard let chosen = pages else { return }
                    let (kind, resolution) = (format, CGFloat(dpi))
                    close()
                    DispatchQueue.main.async { model.exportImages(pages: chosen, format: kind, dpi: resolution) }
                }
                .keyboardShortcut(.defaultAction).prominentGlassButton().disabled(pages?.isEmpty ?? true)
            }
        }
        .onAppear { if !model.selectedPages.isEmpty { scope = .selected } }
    }
}
