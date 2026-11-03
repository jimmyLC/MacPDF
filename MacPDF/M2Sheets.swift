import SwiftUI
import UniformTypeIdentifiers

enum M2Sheet: String, Identifiable {
    case metadata, encrypt, compress, signature, exportImages, decorate, build, blank, ocr
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
    @State private var creator = ""
    @State private var producer = ""

    var body: some View {
        SheetFrame(title: "文件資訊", symbol: "info.circle") {
            Form {
                TextField("標題", text: $title)
                TextField("作者", text: $author)
                TextField("主旨", text: $subject)
                TextField("關鍵字（以逗號分隔）", text: $keywords)
                TextField("建立者（建立這份文件的程式）", text: $creator)
                TextField("產生器（輸出 PDF 的程式）", text: $producer)
                LabeledContent("建立日期") { Text(model.documentDates.created.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—") }
                LabeledContent("修改日期") { Text(model.documentDates.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—") }
            }
            HStack {
                Button("清除全部", role: .destructive) { title = ""; author = ""; subject = ""; keywords = ""; creator = ""; producer = "" }
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("儲存") { model.setMetadata(title: title, author: author, subject: subject, keywords: keywords, creator: creator, producer: producer); close() }
                    .keyboardShortcut(.defaultAction).prominentGlassButton()
            }
        }
        .onAppear {
            let values = model.metadata
            title = values["title"] ?? ""; author = values["author"] ?? ""
            subject = values["subject"] ?? ""; keywords = values["keywords"] ?? ""
            creator = values["creator"] ?? ""; producer = values["producer"] ?? ""
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
    @State private var eligible: [PDFProcessing.Preset: Int] = [:]

    private struct Option { let preset: PDFProcessing.Preset; let name: LocalizedStringKey; let detail: LocalizedStringKey; let symbol: String }
    private let options = [
        Option(preset: .small, name: "最小檔案", detail: "約 100 dpi，用來寄信或上傳，細節會變粗", symbol: "envelope"),
        Option(preset: .standard, name: "平衡", detail: "約 150 dpi，大多數文件的好選擇", symbol: "doc.text"),
        Option(preset: .high, name: "列印", detail: "約 200 dpi，印出來依然清楚", symbol: "printer"),
        Option(preset: .best, name: "高品質", detail: "約 300 dpi，幾乎看不出差別", symbol: "sparkles"),
    ]

    var body: some View {
        SheetFrame(title: "壓縮 PDF", symbol: "arrow.down.right.and.arrow.up.left") {
            VStack(spacing: 8) {
                ForEach(options, id: \.preset) { option in
                    Button { preset = option.preset } label: {
                        HStack(spacing: 12) {
                            Image(systemName: option.symbol).frame(width: 24).foregroundStyle(preset == option.preset ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.name).font(.system(size: 13, weight: .semibold))
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: preset == option.preset ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(preset == option.preset ? Color.accentColor : .secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(preset == option.preset ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(summary).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("開始壓縮") { let chosen = preset; close(); model.compress(chosen) }
                    .keyboardShortcut(.defaultAction).prominentGlassButton().disabled((eligible[preset] ?? 1) == 0)
            }
        }
        .onAppear { eligible = model.compressiblePageCounts() }
    }

    private var summary: String {
        let count = eligible[preset] ?? 0
        return count == 0 ? L("這份文件沒有可以再壓縮的頁面。")
            : String(format: L("會處理 %ld 頁的圖片，文字仍可搜尋與選取；其他頁面不動。壓縮後如果沒有變小，會自動還原。可以復原。"), count)
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
            Picker("格式", selection: $format) { Text("PNG（無損）").tag(PDFProcessing.ImageFormat.png); Text("JPEG（較小）").tag(PDFProcessing.ImageFormat.jpeg); Text("TIFF").tag(PDFProcessing.ImageFormat.tiff) }
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

struct DecorateSheet: View {
    let model: ReaderModel
    let close: () -> Void
    enum Tab: String, CaseIterable, Identifiable { case watermark, headerFooter; var id: String { rawValue } }
    @State private var tab = Tab.watermark
    @State private var range = ""
    @State private var mark = Decoration.Watermark()
    @State private var markColor = Color.gray
    @State private var text = HeaderFooterState()
    @State private var showingPicker = false
    @State private var imageName: String?

    struct HeaderFooterState {
        var header = ["", "", ""]
        var footer = ["", "{page}", ""]
        var size = 10.0
        var margin = 28.0
        var skipFirst = false
        var mirror = false
        var start = 1
        var color = Color.black
    }

    private var pages: [Int]? {
        let trimmed = range.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Array(0..<model.pageCount) }
        guard let ranges = try? PDFEditing.parseRanges(trimmed, pageCount: model.pageCount) else { return nil }
        return Array(Set(ranges.flatMap { $0.map { $0 - 1 } })).sorted()
    }

    private var headerFooter: Decoration.HeaderFooter {
        var spec = Decoration.HeaderFooter()
        spec.header = text.header; spec.footer = text.footer; spec.fontSize = CGFloat(text.size); spec.margin = CGFloat(text.margin)
        spec.skipFirst = text.skipFirst; spec.mirrorEvenPages = text.mirror; spec.startNumber = text.start; spec.color = NSColor(text.color)
        return spec
    }

    var body: some View {
        SheetFrame(title: "浮水印、頁首頁尾與頁碼", symbol: "text.append") {
            Picker("類型", selection: $tab) { Text("浮水印").tag(Tab.watermark); Text("頁首／頁尾／頁碼").tag(Tab.headerFooter) }
                .pickerStyle(.segmented).labelsHidden()
            if tab == .watermark { watermarkForm } else { headerFooterForm }
            TextField("套用頁面（空白＝全部，例如 1-3, 5）", text: $range).textFieldStyle(.roundedBorder)
            Text("加入後這些頁面會重新產生，頁面文字仍可選取。可以復原。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("加入") { apply() }.keyboardShortcut(.defaultAction).prominentGlassButton()
                    .disabled(pages == nil || (tab == .watermark ? mark.isEmpty : headerFooter.isEmpty))
            }
        }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                mark.image = image; imageName = url.lastPathComponent
            } else { model.error = L("無法讀取這張圖片。") }
        }
    }

    private func apply() {
        guard let chosen = pages else { return }
        var watermark = mark; watermark.color = NSColor(markColor)
        let spec = headerFooter
        let isMark = tab == .watermark
        close()
        DispatchQueue.main.async {
            model.decorate(watermark: isMark ? watermark : nil, headerFooter: isMark ? nil : spec, pages: chosen)
        }
    }

    private var watermarkForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("浮水印文字（例如「機密」）", text: $mark.text).textFieldStyle(.roundedBorder)
            HStack {
                Button(imageName == nil ? "改用圖片…" : "換圖片…") { showingPicker = true }.controlSize(.small)
                if let imageName { Text(imageName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("移除圖片") { mark.image = nil; self.imageName = nil }.controlSize(.small) }
            }
            if mark.image == nil {
                LabeledContent("字級") { Slider(value: $mark.fontSize, in: 16...200) }
                ColorPicker("顏色", selection: $markColor)
            } else {
                LabeledContent("圖片大小") { Slider(value: $mark.imageScale, in: 0.1...1) }
            }
            LabeledContent("透明度") { Slider(value: $mark.opacity, in: 0.05...1) }
            LabeledContent("旋轉") { Slider(value: $mark.rotation, in: -90...90, step: 5) }
            Picker("位置", selection: $mark.position) { ForEach(Decoration.Position.allCases) { Text($0.label).tag($0) } }.disabled(mark.tiled)
            Toggle("平鋪整頁", isOn: $mark.tiled)
            Toggle("放在頁面內容後面", isOn: $mark.behind)
        }
    }

    private var headerFooterForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow { Text("頁首").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading); Color.clear; Color.clear }
                GridRow { ForEach(0..<3, id: \.self) { TextField(["左", "中", "右"][$0], text: $text.header[$0]).textFieldStyle(.roundedBorder) } }
                GridRow { Text("頁尾").font(.caption).foregroundStyle(.secondary); Color.clear; Color.clear }
                GridRow { ForEach(0..<3, id: \.self) { TextField(["左", "中", "右"][$0], text: $text.footer[$0]).textFieldStyle(.roundedBorder) } }
            }
            HStack(spacing: 6) {
                Text("頁碼樣式").font(.caption).foregroundStyle(.secondary)
                Button("1") { text.footer[1] = "{page}" }
                Button("Page 1 of N") { text.footer[1] = "Page {page} of {pages}" }
                Button("第 1 頁，共 N 頁") { text.footer[1] = "第 {page} 頁，共 {pages} 頁" }
            }.controlSize(.small)
            Text("可用代號：{page} {pages} {title} {author} {filename} {date}").font(.caption).foregroundStyle(.secondary)
            HStack { LabeledContent("字級") { Slider(value: $text.size, in: 6...24, step: 1) }; ColorPicker("", selection: $text.color).labelsHidden() }
            LabeledContent("邊距") { Slider(value: $text.margin, in: 12...72, step: 2) }
            Stepper("起始頁碼：\(text.start)", value: $text.start, in: 0...9999)
            Toggle("首頁不加（頁碼從第二頁開始算）", isOn: $text.skipFirst)
            Toggle("偶數頁左右對調（像書本）", isOn: $text.mirror)
        }
    }
}

struct BuildSheet: View {
    let model: ReaderModel
    let close: () -> Void
    struct Entry: Identifiable { let id = UUID(); var item: PDFBuilder.Item; var ranges = "" }
    @State private var entries: [Entry] = []
    @State private var sheet = PDFProcessing.PageSheet.a4
    @State private var intoCurrent = false
    @State private var position = 0
    @State private var picking: Kind?
    enum Kind: Identifiable { case images, pdfs; var id: Int { self == .images ? 0 : 1 } }

    private func name(_ item: PDFBuilder.Item) -> String {
        switch item {
        case .image(let url): "🖼 " + url.lastPathComponent
        case .pdf(let url, _): "📄 " + url.lastPathComponent
        case .blank: "▭ " + L("空白頁")
        case .clipboard: "📋 " + L("剪貼簿的圖片")
        }
    }

    var body: some View {
        SheetFrame(title: "建立或組合 PDF", symbol: "doc.badge.plus") {
            HStack {
                Button("加入圖片…") { picking = .images }
                Button("加入 PDF…") { picking = .pdfs }
                Button("加入空白頁") { entries.append(Entry(item: .blank)) }
                Button("加入剪貼簿圖片") { addClipboard() }.disabled(!model.pasteboardHasImage)
            }.controlSize(.small)
            List {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 6) {
                        Text(name(entry.item)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if case .pdf = entry.item {
                            TextField("頁碼", text: $entries[index].ranges).textFieldStyle(.roundedBorder).frame(width: 90)
                                .help("例如 1-3, 5；空白代表全部頁面")
                        }
                        Button { entries.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        Button { entries.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index == entries.count - 1)
                        Button { entries.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                    }.buttonStyle(.plain)
                }
            }
            .frame(height: 170)
            .overlay { if entries.isEmpty { Text("加入圖片、PDF 或空白頁，排好順序後建立。").font(.callout).foregroundStyle(.secondary) } }
            Text("圖片與空白頁的尺寸").font(.caption).foregroundStyle(.secondary)
            Picker("圖片與空白頁的尺寸", selection: $sheet) {
                Text("A4").tag(PDFProcessing.PageSheet.a4); Text("Letter").tag(PDFProcessing.PageSheet.letter); Text("跟圖片一樣大").tag(PDFProcessing.PageSheet.image)
            }.pickerStyle(.segmented).labelsHidden()
            if model.document != nil {
                Text("放到").font(.caption).foregroundStyle(.secondary)
                Picker("放到", selection: $intoCurrent) { Text("新的文件").tag(false); Text("目前的文件").tag(true) }.pickerStyle(.segmented).labelsHidden()
                if intoCurrent {
                    Stepper(position == 0 ? L("放在最後") : String(format: L("放在第 %ld 頁前面"), position), value: $position, in: 0...max(model.pageCount, 1))
                }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("建立") { create() }.keyboardShortcut(.defaultAction).prominentGlassButton().disabled(entries.isEmpty)
            }
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking == .pdfs ? [.pdf] : [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { entries.append(Entry(item: picking == .pdfs ? .pdf(url, ranges: "") : .image(url))) }
        }
    }

    private func addClipboard() {
        guard let image = (NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first else { return }
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { entries.append(Entry(item: .clipboard(cg))) }
    }

    private func create() {
        let items = entries.map { entry -> PDFBuilder.Item in
            if case .pdf(let url, _) = entry.item { return .pdf(url, ranges: entry.ranges) }
            return entry.item
        }
        let (chosenSheet, current, at) = (sheet, intoCurrent && model.document != nil, position)
        close()
        DispatchQueue.main.async { model.buildDocument(items, sheet: chosenSheet, intoCurrent: current, before: at == 0 ? nil : at - 1) }
    }
}

struct BlankPageSheet: View {
    let model: ReaderModel
    let close: () -> Void
    enum Size: String, CaseIterable, Identifiable { case match, a4, a5, letter, custom; var id: String { rawValue } }
    @State private var size = Size.match
    @State private var landscape = false
    @State private var width = 595.0
    @State private var height = 842.0
    @State private var count = 1
    @State private var place = 1
    @State private var after = true

    var body: some View {
        SheetFrame(title: "插入空白頁", symbol: "doc.badge.plus") {
            Stepper("張數：\(count)", value: $count, in: 1...100)
            Stepper("位置：第 \(place) 頁的\(after ? "後面" : "前面")", value: $place, in: 1...max(model.pageCount, 1))
            Picker("", selection: $after) { Text("前面").tag(false); Text("後面").tag(true) }.pickerStyle(.segmented).labelsHidden()
            Picker("尺寸", selection: $size) {
                Text("跟這一頁一樣").tag(Size.match); Text("A4").tag(Size.a4); Text("A5").tag(Size.a5); Text("Letter").tag(Size.letter); Text("自訂").tag(Size.custom)
            }
            if size == .custom {
                HStack { TextField("寬（點）", value: $width, format: .number).textFieldStyle(.roundedBorder); TextField("高（點）", value: $height, format: .number).textFieldStyle(.roundedBorder) }
            }
            if size != .match && size != .custom { Toggle("橫向", isOn: $landscape) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("插入") { insert() }.keyboardShortcut(.defaultAction).prominentGlassButton()
                    .disabled(size == .custom && (width < 20 || height < 20))
            }
        }
        .onAppear { place = max(model.currentPage, 1) }
    }

    private func insert() {
        let chosen: CGSize?
        switch size {
        case .match: chosen = nil
        case .a4: chosen = landscape ? CGSize(width: 841.89, height: 595.28) : CGSize(width: 595.28, height: 841.89)
        case .a5: chosen = landscape ? CGSize(width: 595.28, height: 419.53) : CGSize(width: 419.53, height: 595.28)
        case .letter: chosen = landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
        case .custom: chosen = CGSize(width: width, height: height)
        }
        let (n, page, behind) = (count, place - 1, after)
        close()
        DispatchQueue.main.async { model.insertBlankPages(count: n, around: page, after: behind, size: chosen) }
    }
}

struct OCRSheet: View {
    let model: ReaderModel
    let close: () -> Void
    static let languages: [(code: String, name: String)] = [("zh-Hant", "繁體中文"), ("zh-Hans", "简体中文"), ("en-US", "English"), ("ja-JP", "日本語"), ("ko-KR", "한국어")]
    enum Scope: String, Identifiable { case all, current, range; var id: String { rawValue } }
    @State private var chosen: Set<String> = ["zh-Hant", "en-US"]
    @State private var scope = Scope.all
    @State private var range = ""

    private var pages: [Int]? {
        switch scope {
        case .all: return nil
        case .current: return [max(model.currentPage - 1, 0)]
        case .range:
            guard let ranges = try? PDFEditing.parseRanges(range, pageCount: model.pageCount) else { return [] }
            return Array(Set(ranges.flatMap { $0.map { $0 - 1 } })).sorted()
        }
    }

    var body: some View {
        SheetFrame(title: "文字辨識（OCR）", symbol: "text.viewfinder") {
            Text("辨識語言").font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                ForEach(Self.languages, id: \.code) { language in
                    Toggle(language.name, isOn: Binding(get: { chosen.contains(language.code) },
                                                         set: { if $0 { chosen.insert(language.code) } else { chosen.remove(language.code) } }))
                        .toggleStyle(.checkbox)
                }
            }
            Picker("頁面", selection: $scope) { Text("全部").tag(Scope.all); Text("目前這一頁").tag(Scope.current); Text("範圍").tag(Scope.range) }
                .pickerStyle(.segmented)
            if scope == .range { TextField("例如 1-3, 5", text: $range).textFieldStyle(.roundedBorder) }
            Text("只會辨識沒有文字的頁面；已有文字或旋轉過的頁面會略過並告訴你。辨識完成後可以搜尋與選取文字，也可以復原。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("開始辨識") {
                    let order = Self.languages.map(\.code).filter { chosen.contains($0) }
                    let target = pages
                    close()
                    DispatchQueue.main.async { model.runOCR(languages: order, pages: target) }
                }
                .keyboardShortcut(.defaultAction).prominentGlassButton()
                .disabled(chosen.isEmpty || (scope == .range && (pages?.isEmpty ?? true)))
            }
        }
    }
}
