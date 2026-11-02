import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ReaderView: View {
    let openInNewWindow: (URL) -> Void
    @State private var model: ReaderModel
    init(model: ReaderModel, openInNewWindow: @escaping (URL) -> Void) {
        _model = State(initialValue: model)
        self.openInNewWindow = openInNewWindow
    }
    enum ImportMode { case open, merge, images }
    @State private var importMode = ImportMode.open
    @State private var showImporter = false
    @State private var annotationText = ""
    @State private var annotationFreeText = false
    @State private var showingAnnotation = false
    @State private var confirmDelete = false
    @State private var inkMode = false
    @State private var showingStyle = false
    @State private var search = ""
    @State private var sidebar = true
    @State private var selection: SidebarTab = .pages
    @State private var showingPassword = false
    @State private var password = ""
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    private let sidebarWidth: CGFloat = 252
    private let barTop: CGFloat = 8
    private let barHeight: CGFloat = 44

    var body: some View {
        ZStack {
            AmbientBackground()
            if model.document != nil { documentLayer } else { WelcomeView(model: model) { present(.open) } }
        }
        .overlay { if dropTargeted { dropOverlay } }
        .ignoresSafeArea()
        .background(WindowCloseGuard(model: model))
        .frame(minWidth: 780, minHeight: 520)
        .navigationTitle(model.title + (model.isDirty ? " •" : ""))
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importMode == .images ? [.image] : [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                switch importMode {
                case .open: urls.forEach { openDocument($0) }
                case .merge: urls.forEach { model.appendPDF($0) }
                case .images: model.appendImages(urls)
                }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .sheet(item: Binding(get: { model.sheet }, set: { model.sheet = $0 })) { which in
            switch which {
            case .metadata: MetadataSheet(model: model) { model.sheet = nil }
            case .encrypt: EncryptSheet(model: model) { model.sheet = nil }
            case .compress: CompressSheet(model: model) { model.sheet = nil }
            case .signature: SignatureSheet(model: model) { model.sheet = nil }
            case .exportImages: ExportImagesSheet(model: model) { model.sheet = nil }
            case .decorate: DecorateSheet(model: model) { model.sheet = nil }
            case .build: BuildSheet(model: model) { model.sheet = nil }
            case .blank: BlankPageSheet(model: model) { model.sheet = nil }
            case .ocr: OCRSheet(model: model) { model.sheet = nil }
            }
        }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            model.notice = nil
        }
        .alert("刪除頁面？", isPresented: $confirmDelete) {
            Button("刪除", role: .destructive) { model.deleteCurrentPage() }
            Button("取消", role: .cancel) {}
        } message: {
            let pages = model.targetPages
            Text(pages.count > 1 ? String(format: L("將刪除 %ld 頁。此操作可以復原。"), pages.count) : String(format: L("將刪除第 %ld 頁。此操作可以復原。"), (pages.first ?? 0) + 1))
        }
        .alert(annotationFreeText ? "新增文字方塊" : "新增便條", isPresented: $showingAnnotation) {
            TextField("內容", text: $annotationText)
            Button("繼續") { inkMode = false; model.setInkMode(false); model.prepareAnnotation(text: annotationText, freeText: annotationFreeText); annotationText = "" }
            Button("取消", role: .cancel) { annotationText = "" }
        } message: { Text("輸入內容後，點一下頁面放置註解。") }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in openDocument(url) }
                }
            }
            return true
        }
        .onChange(of: model.needsPassword) { _, needsPassword in showingPassword = needsPassword }
        .alert("輸入 PDF 密碼", isPresented: $showingPassword) {
            SecureField("密碼", text: $password)
            Button("開啟") { model.unlock(password); password = "" }
            Button("取消", role: .cancel) { model.cancelPassword(); password = "" }
        } message: { Text("此文件需要密碼才能開啟。") }
        .alert("操作無法完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    // MARK: Layers

    private var documentLayer: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if sidebar {
                    SidebarPanel(model: model, extractSelection: { extractSelectedPages() }, selection: $selection, search: $search, searchFocused: $searchFocused)
                        .frame(width: sidebarWidth)
                        .padding(.leading, 12).padding(.top, barTop + barHeight + 8).padding(.bottom, 12)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ZStack(alignment: .bottom) {
                    PDFCanvas(pdfView: model.pdfView, topInset: barTop + barHeight + 6, bottomInset: 84)
                    bottomDock.padding(.bottom, 16)
                }
            }
            topBar
            if model.inspectMode {
                AnnotationInspector(model: model)
                    .padding(.trailing, 12).padding(.top, barTop + barHeight + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let session = model.redaction {
                RedactionPanel(model: model, session: session)
                    .padding(.trailing, 12).padding(.top, barTop + barHeight + 8).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            VStack(spacing: 8) {
                if model.isPlacingAnnotation { placementBanner }
                if let job = model.job { jobBanner(job) }
                else if let notice = model.notice { noticeBanner(notice) }
            }
            .padding(.top, barTop + barHeight + 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .animation(.smooth(duration: 0.28), value: sidebar)
        .animation(.smooth(duration: 0.28), value: model.redaction != nil)
        .animation(.smooth(duration: 0.25), value: model.isPlacingAnnotation)
        .animation(.smooth(duration: 0.25), value: model.job != nil)
        .animation(.smooth(duration: 0.25), value: model.notice)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.accentColor.opacity(0.08)))
            .overlay {
                Label("放開以開啟 PDF", systemImage: "arrow.down.doc.fill")
                    .font(.title3.weight(.medium)).padding(.horizontal, 22).padding(.vertical, 14)
                    .glassSurface(in: Capsule())
            }
            .padding(12).allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassCapsule {
                GlassIconButton(symbol: "sidebar.left", label: "側邊欄", active: false,
                                shortcut: KeyboardShortcut("s", modifiers: [.command, .control])) { sidebar.toggle() }
            }
            Spacer(minLength: 8)
            titleChip
            Spacer(minLength: 8)
            GlassCapsule {
                GlassIconButton(symbol: "magnifyingglass", label: "搜尋", shortcut: KeyboardShortcut("f")) {
                    selection = .search; sidebar = true; searchFocused = true
                }
                GlassDivider()
                GlassIconButton(symbol: "arrow.uturn.backward", label: "復原") { model.undoEdit() }.disabled(!model.canUndo || model.redaction != nil)
                GlassIconButton(symbol: "arrow.uturn.forward", label: "重做") { model.redoEdit() }.disabled(!model.canRedo || model.redaction != nil)
                GlassDivider()
                GlassIconButton(symbol: "square.and.arrow.down", label: "另存新檔") { model.saveCopyWithPanel() }.disabled(model.redaction != nil)
                moreMenu
            }
        }
        .padding(.leading, 84).padding(.trailing, 14).padding(.top, barTop)
        .frame(height: barTop + barHeight, alignment: .top)
    }

    private var titleChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill").foregroundStyle(Color.accentColor).font(.system(size: 13))
            Text(model.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if model.isDirty {
                Circle().fill(Color.orange).frame(width: 7, height: 7).help("已編輯，尚未儲存")
            }
        }
        .padding(.horizontal, 16).frame(height: 36).frame(maxWidth: 300)
        .glassSurface(in: Capsule())
    }

    private var moreMenu: some View {
        let busy = model.job != nil || model.redaction != nil
        return Menu {
            Menu("頁面", systemImage: "doc.on.doc") {
                Button("插入空白頁…") { model.sheet = .blank }
                Button("在這一頁前面插入空白頁") { model.insertBlankPage(after: false) }
                Button("在這一頁後面插入空白頁") { model.insertBlankPage(after: true) }
                Divider()
                let many = model.targetPages.count > 1
                Menu(many ? "旋轉選取的頁面" : "旋轉這一頁") {
                    Button("順時針 90°") { model.rotateTargets(by: 90) }
                    Button("逆時針 90°") { model.rotateTargets(by: -90) }
                    Button("180°") { model.rotateTargets(by: 180) }
                    Divider()
                    Button("旋轉全部頁面（順時針 90°）") { model.rotateAll(by: 90) }
                }
                Button(many ? "向前移動選取的頁面" : "向前移動這一頁") { model.moveCurrentPage(by: -1) }.disabled((model.targetPages.first ?? 0) <= 0)
                Button(many ? "向後移動選取的頁面" : "向後移動這一頁") { model.moveCurrentPage(by: 1) }.disabled((model.targetPages.last ?? 0) >= model.pageCount - 1)
                Button(many ? "刪除選取的頁面" : "刪除這一頁", role: .destructive) { confirmDelete = true }.disabled(model.targetPages.count >= model.pageCount)
                Divider()
                Button("選取全部頁面") { model.selectAllPages() }
                Button("取消選取") { model.clearPageSelection() }.disabled(model.selectedPages.isEmpty)
            }.disabled(busy)
            Menu("插入與擷取", systemImage: "plus.rectangle.on.rectangle") {
                Button("建立或組合 PDF…") { model.sheet = .build }
                Button("合併 PDF 到最後…") { present(.merge) }
                Button("從圖片新增頁面…") { present(.images) }
                Button("擷取頁面…") { extractPages() }
                Button("匯出為圖片…") { model.sheet = .exportImages }
                Button("分割成每頁一個檔案…") { model.splitPages(rangesText: nil) }
                Button("依範圍分割…") { splitByRanges() }
            }.disabled(busy)
            Button("浮水印、頁首頁尾與頁碼…", systemImage: "text.append") { model.sheet = .decorate }.disabled(busy)
            Menu("掃描頁面", systemImage: "text.viewfinder") {
                Button("文字辨識（OCR）…") { model.sheet = .ocr }
                Button("壓縮…") { model.sheet = .compress }
            }.disabled(busy)
            Menu("表單", systemImage: "list.bullet.rectangle") {
                Button("清除表單欄位") { model.resetForm() }
                Button("扁平化表單") { model.flattenForms() }
            }.disabled(busy || !model.hasFormFields)
            Button("塗黑敏感資訊…", systemImage: "rectangle.dashed.badge.record") { model.beginRedaction() }.disabled(busy)
            Menu("文件資訊與保護", systemImage: "lock.shield") {
                Button("編輯文件資訊…") { model.sheet = .metadata }
                Button("儲存加密副本…") { model.sheet = .encrypt }
                Button("儲存無密碼副本…") { model.exportUnlockedCopy() }.disabled(!(model.document?.isEncrypted ?? false))
            }.disabled(busy)
            Menu("檢視", systemImage: "rectangle.split.2x1") {
                ForEach(ViewMode.allCases) { mode in
                    Button { model.setViewMode(mode) } label: { Label(mode.label, systemImage: model.viewMode == mode ? "checkmark" : "") }
                }
                Divider()
                Button("符合頁面") { model.fitPage() }
                Button("符合寬度") { model.fitWidth() }
                Button("實際大小") { model.actualSize() }
            }
            Menu("分享與拷貝", systemImage: "square.and.arrow.up") {
                Button("分享…") { model.share(from: model.pdfView) }
                Button("拷貝這一頁為圖片") { model.copyCurrentPageAsImage() }
                Button("貼上圖片為新頁") { model.pasteImageAsPage() }.disabled(!model.pasteboardHasImage)
            }
            Divider()
            Button("復原") { model.undoEdit() }.keyboardShortcut("z").disabled(!model.canUndo || busy)
            Button("重做") { model.redoEdit() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo || busy)
            Button("另存新檔…") { saveCopy() }.keyboardShortcut("s")
            Button("儲存到原檔（先備份）…") { model.overwriteOriginal() }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(!model.canOverwriteOriginal)
            Button("列印…") { model.printDocument() }.keyboardShortcut("p")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34).contentShape(Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("更多操作").accessibilityLabel("更多操作")
    }

    // MARK: Bottom dock

    private var bottomDock: some View {
        GlassGroup(spacing: 14) {
            HStack(spacing: 12) {
                GlassCapsule {
                    GlassIconButton(symbol: "chevron.up", label: "上一頁") { model.goToPage(model.currentPage - 1) }
                        .disabled(model.currentPage <= 1)
                    Text("\(model.currentPage) / \(model.pageCount)")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .frame(minWidth: 62)
                        .accessibilityLabel(String(format: L("目前頁碼 %ld，共 %ld 頁"), model.currentPage, model.pageCount))
                    GlassIconButton(symbol: "chevron.down", label: "下一頁") { model.goToPage(model.currentPage + 1) }
                        .disabled(model.currentPage == 0 || model.currentPage >= model.pageCount)
                }
                GlassCapsule {
                    GlassIconButton(symbol: "minus.magnifyingglass", label: "縮小", shortcut: KeyboardShortcut("-")) { model.pdfView.zoomOut(nil) }
                    GlassIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "符合頁面", shortcut: KeyboardShortcut("0")) { model.pdfView.autoScales = true }
                    GlassIconButton(symbol: "plus.magnifyingglass", label: "放大", shortcut: KeyboardShortcut("=")) { model.pdfView.zoomIn(nil) }
                }
                GlassCapsule {
                    markupMenu
                    GlassIconButton(symbol: "signature", label: "簽名…") { model.sheet = .signature }
                    GlassIconButton(symbol: "note.text", label: "新增便條…") { annotationFreeText = false; showingAnnotation = true }
                    GlassIconButton(symbol: "character.textbox", label: "新增文字方塊…") { annotationFreeText = true; showingAnnotation = true }
                    GlassIconButton(symbol: "pencil.tip", label: inkMode ? "結束手繪" : "手繪", active: inkMode) {
                        model.cancelAnnotationPlacement(); inkMode.toggle(); model.setInkMode(inkMode)
                    }
                    GlassIconButton(symbol: "cursorarrow.click.2", label: model.inspectMode ? "結束選取註解" : "選取並修改註解", active: model.inspectMode) {
                        inkMode = false; model.setInspectMode(!model.inspectMode)
                    }
                    GlassIconButton(symbol: "slider.horizontal.3", label: "標註樣式", active: showingStyle) { showingStyle.toggle() }
                        .popover(isPresented: $showingStyle, arrowEdge: .top) { AnnotationStyleForm(model: model) }
                }
            }
        }
    }

    private var markupMenu: some View {
        Menu {
            ForEach(MarkupColor.allCases) { swatch in
                Button { model.markSelection(style: .highlight, color: swatch.color) } label: { Label("螢光筆（\(swatch.name)）", systemImage: "highlighter") }
            }
            Divider()
            Button { model.markSelection(style: .underline, color: NSColor(hex: model.style.lineColor) ?? .systemRed) } label: { Label("底線", systemImage: "underline") }
            Button { model.markSelection(style: .strikeOut, color: NSColor(hex: model.style.lineColor) ?? .systemRed) } label: { Label("刪除線", systemImage: "strikethrough") }
        } label: {
            Image(systemName: "highlighter").font(.system(size: 15, weight: .medium)).frame(width: 34, height: 34).contentShape(Circle())
        } primaryAction: { model.highlightSelection() }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("標示選取文字（長按選擇螢光筆顏色、底線、刪除線）").accessibilityLabel("標示選取文字")
    }

    private var placementBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.point.up.left.fill").foregroundStyle(Color.accentColor)
            Text(model.isPlacingSignature ? "點一下頁面放置簽名" : "點一下頁面放置註解").font(.system(size: 13, weight: .medium))
            Button("取消") { model.cancelAnnotationPlacement() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .glassSurface(in: Capsule())
    }

    private func jobBanner(_ job: JobProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(job.done), total: Double(max(job.total, 1))).frame(width: 110)
            Text("\(job.title) \(job.done) / \(job.total)").font(.system(size: 13, weight: .medium)).monospacedDigit()
            Button("取消") { model.cancelJob() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .glassSurface(in: Capsule())
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(2)
            Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .glassSurface(in: Capsule())
    }

    // MARK: Actions

    private func present(_ mode: ImportMode) { importMode = mode; showImporter = true }

    private func extractPages() {
        let alert = NSAlert()
        alert.messageText = L("擷取頁面")
        alert.informativeText = L("輸入起始與結束頁碼，例如 1-3。擷取會建立新檔，不影響目前文件。")
        let field = NSTextField(string: "1-\(model.pageCount)")
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("選擇儲存位置…")); alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pieces = field.stringValue.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard pieces.count == 2, let first = Int(pieces[0]), let last = Int(pieces[1]), first >= 1, last >= first, last <= model.pageCount else {
            model.error = L("請輸入有效的頁碼範圍。"); return
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "MacPDF-擷取.pdf"
        if panel.runModal() == .OK, let url = panel.url { model.extractPages(first...last, to: url) }
    }
    private func splitByRanges() {
        let alert = NSAlert()
        alert.messageText = L("依範圍分割")
        alert.informativeText = L("輸入頁碼範圍，用逗號分隔，例如 1-3, 5, 8-10。每個範圍會存成一個新檔案。")
        let field = NSTextField(string: "1-\(model.pageCount)")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("選擇資料夾…")); alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.splitPages(rangesText: field.stringValue)
    }
    private func extractSelectedPages() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "MacPDF-擷取.pdf"
        panel.message = L("請選擇新的檔名；MacPDF 不會覆寫現有檔案。")
        if panel.runModal() == .OK, let url = panel.url { model.extractSelectedPages(to: url) }
    }
    private func saveCopy() { model.saveCopyWithPanel() }
    private func openDocument(_ url: URL) {
        if model.document == nil && !model.needsPassword { model.open(url) }
        else { openInNewWindow(url) }
    }
}

// MARK: - Sidebar

enum SidebarTab: Int, CaseIterable {
    case pages, outline, search
    var symbol: String {
        switch self { case .pages: "square.grid.2x2"; case .outline: "list.bullet.indent"; case .search: "magnifyingglass" }
    }
    var label: LocalizedStringKey {
        switch self { case .pages: "頁面"; case .outline: "目錄"; case .search: "搜尋" }
    }
}

struct SidebarPanel: View {
    let model: ReaderModel
    var extractSelection: () -> Void = {}
    @Binding var selection: SidebarTab
    @Binding var search: String
    var searchFocused: FocusState<Bool>.Binding
    @Namespace private var tabNamespace

    var body: some View {
        VStack(spacing: 0) {
            tabs.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            Group {
                if let document = model.document {
                    switch selection {
                    case .pages: ThumbnailGrid(model: model, extract: extractSelection, exportImages: { model.sheet = .exportImages })
                    case .outline: OutlineList(document: document, pdfView: model.pdfView)
                    case .search: searchPane
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases, id: \.rawValue) { tab in
                Button { withAnimation(.smooth(duration: 0.22)) { selection = tab } } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .background {
                            if selection == tab {
                                Capsule().fill(Color.primary.opacity(0.13)).matchedGeometryEffect(id: "tab", in: tabNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).help(tab.label).accessibilityLabel(tab.label)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private var searchPane: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("搜尋 PDF", text: $search)
                    .textFieldStyle(.plain).focused(searchFocused)
                    .onSubmit { model.find(search) }
                if !search.isEmpty {
                    Button { search = ""; model.find("") } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .padding(.horizontal, 12)
            HStack(spacing: 6) {
                Toggle("Aa", isOn: Binding(get: { model.searchCaseSensitive }, set: { model.searchCaseSensitive = $0; if !search.isEmpty { model.find(search) } }))
                    .toggleStyle(.button).controlSize(.small).help("區分大小寫").accessibilityLabel("區分大小寫")
                Toggle("全字", isOn: Binding(get: { model.searchWholeWord }, set: { model.searchWholeWord = $0; if !search.isEmpty { model.find(search) } }))
                    .toggleStyle(.button).controlSize(.small).help("只找完整的字").accessibilityLabel("只找完整的字")
                Spacer()
                if !model.results.isEmpty {
                    Text("\((model.resultIndex ?? -1) + 1) / \(model.results.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Button { model.previousResult() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).disabled(model.results.isEmpty).help("上一筆").accessibilityLabel("上一筆")
                Button { model.nextResult() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).disabled(model.results.isEmpty).help("下一筆").accessibilityLabel("下一筆")
            }.padding(.horizontal, 14)
            if model.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small); Text("搜尋中…").font(.callout)
                    Spacer()
                    Button("停止") { model.cancelSearch() }.controlSize(.small)
                }.padding(.horizontal, 14)
            }
            if model.hasSearched && !model.isSearching && model.results.isEmpty {
                ContentUnavailableView("找不到符合的文字", systemImage: "text.magnifyingglass")
            } else {
                List(model.results.indices, id: \.self) { index in
                    Button { model.goToResult(index) } label: {
                        Text(model.resultTitle(index)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.resultIndex == index ? Color.accentColor.opacity(0.18) : Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }
}

// MARK: - PDFKit bridges

struct PDFCanvas: NSViewRepresentable {
    let pdfView: ReaderPDFView
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    func makeNSView(context: Context) -> ReaderPDFView { pdfView }
    func updateNSView(_ view: ReaderPDFView, context: Context) {
        view.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
    }
}

struct ThumbnailView: NSViewRepresentable {
    let document: PDFDocument
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView(); view.pdfView = pdfView; view.thumbnailSize = NSSize(width: 120, height: 160)
        view.backgroundColor = .clear
        return view
    }
    func updateNSView(_ view: PDFThumbnailView, context: Context) { view.pdfView = pdfView }
}

struct OutlineList: View {
    let document: PDFDocument
    let pdfView: PDFView
    var body: some View {
        if let root = document.outlineRoot {
            List { ForEach(0..<root.numberOfChildren, id: \.self) { index in
                if let child = root.child(at: index) { OutlineRow(outline: child, pdfView: pdfView) }
            }}
            .scrollContentBackground(.hidden)
        } else { ContentUnavailableView("沒有目錄", systemImage: "list.bullet.indent") }
    }
}

struct OutlineRow: View {
    let outline: PDFOutline
    let pdfView: PDFView
    var body: some View {
        if outline.numberOfChildren > 0 {
            DisclosureGroup {
                ForEach(0..<outline.numberOfChildren, id: \.self) { index in
                    if let child = outline.child(at: index) { OutlineRow(outline: child, pdfView: pdfView) }
                }
            } label: { Button(outline.label ?? L("未命名")) { navigate() }.buttonStyle(.plain) }
        } else { Button(outline.label ?? L("未命名")) { navigate() }.buttonStyle(.plain) }
    }
    private func navigate() { if let destination = outline.destination { pdfView.go(to: destination) } }
}

enum MarkupColor: String, CaseIterable, Identifiable {
    case yellow, green, pink, blue
    var id: String { rawValue }
    var name: String { switch self { case .yellow: L("黃"); case .green: L("綠"); case .pink: L("粉紅"); case .blue: L("藍") } }
    var color: NSColor { switch self { case .yellow: .yellow; case .green: .systemGreen; case .pink: .systemPink; case .blue: .systemTeal } }
}
