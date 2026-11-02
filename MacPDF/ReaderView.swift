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
    @State private var choosing = false
    @State private var choosingMerge = false
    @State private var annotationText = ""
    @State private var annotationFreeText = false
    @State private var showingAnnotation = false
    @State private var confirmDelete = false
    @State private var inkMode = false
    @State private var search = ""
    @State private var sidebar = true
    @State private var selection: Int = 0
    @State private var showingPassword = false
    @State private var password = ""

    var body: some View {
        HSplitView {
            if sidebar, let document = model.document {
                VStack {
                    Picker("側邊欄", selection: $selection) {
                        Text("頁面").tag(0); Text("目錄").tag(1); Text("搜尋").tag(2)
                    }.pickerStyle(.segmented).padding(8)
                    if selection == 0 {
                        ThumbnailView(document: document, pdfView: model.pdfView)
                    } else if selection == 1 {
                        OutlineList(document: document, pdfView: model.pdfView)
                    } else {
                        TextField("搜尋 PDF", text: $search)
                            .textFieldStyle(.roundedBorder).padding(.horizontal)
                            .onSubmit { model.find(search) }
                        if model.isSearching {
                            HStack { ProgressView().controlSize(.small); Text("搜尋中…"); Button("停止") { model.cancelSearch() } }.padding(.horizontal)
                        }
                        if model.hasSearched && !model.isSearching && model.results.isEmpty {
                            Text("找不到符合的文字").foregroundStyle(.secondary).padding()
                        }
                        List(model.results.indices, id: \.self) { index in
                            Button(model.resultTitle(index)) { model.goToResult(index) }
                                .buttonStyle(.plain)
                        }
                    }
                }.frame(minWidth: 190, idealWidth: 230, maxWidth: 350)
            }
            if model.document != nil {
                VStack(spacing: 0) {
                    if model.isPlacingAnnotation {
                        HStack { Text("點一下頁面放置註解"); Spacer(); Button("取消") { model.cancelAnnotationPlacement() } }.padding(8)
                    }
                    PDFCanvas(pdfView: model.pdfView).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.richtext").font(.system(size: 52)).foregroundStyle(.secondary)
                    Text("開啟 PDF 開始閱讀").font(.title2)
                    Button("開啟 PDF…") { choosing = true }.keyboardShortcut("o")
                    if !model.recoveryEntries.isEmpty {
                        Text("可恢復的文件").font(.headline)
                        ForEach(model.recoveryEntries) { entry in
                            HStack {
                                Button(String(format: L("恢復 %@"), entry.title)) { model.restore(entry) }
                                Button("丟棄", role: .destructive) { model.discardRecovery(entry) }
                            }
                        }
                    }
                    if !model.recents.isEmpty {
                        Text("最近開啟").foregroundStyle(.secondary)
                        ForEach(model.recents, id: \.absoluteString) { url in
                            Button(url.lastPathComponent) { model.openRecent(url) }.buttonStyle(.link)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowCloseGuard(model: model))
        .frame(minWidth: 700, minHeight: 500)
        .navigationTitle(model.title + (model.isDirty ? " •" : ""))
        .safeAreaInset(edge: .top) {
            HStack {
                Button { choosing = true } label: { Label("開啟", systemImage: "folder") }
                Button { sidebar.toggle() } label: { Label("側邊欄", systemImage: "sidebar.left") }
                Button { model.goToPage(model.currentPage - 1) } label: { Label("上一頁", systemImage: "chevron.up") }
                    .disabled(model.currentPage <= 1)
                Text("\(model.currentPage) / \(model.pageCount)").monospacedDigit().accessibilityLabel(String(format: L("目前頁碼 %ld，共 %ld 頁"), model.currentPage, model.pageCount))
                Button { model.goToPage(model.currentPage + 1) } label: { Label("下一頁", systemImage: "chevron.down") }
                    .disabled(model.currentPage == 0 || model.currentPage >= model.pageCount)
                Menu {
                    Button("順時針旋轉這一頁") { model.rotateCurrentPage() }
                    Button("向前移動這一頁") { model.moveCurrentPage(by: -1) }.disabled(model.currentPage <= 1)
                    Button("向後移動這一頁") { model.moveCurrentPage(by: 1) }.disabled(model.currentPage >= model.pageCount)
                    Button("刪除這一頁", role: .destructive) { confirmDelete = true }.disabled(model.pageCount <= 1)
                    Divider()
                    Button("合併 PDF 到最後…") { choosingMerge = true }
                    Button("擷取頁面／分割…") { extractPages() }
                    Button("標示選取文字") { model.highlightSelection() }
                    Button("新增便條…") { annotationFreeText = false; showingAnnotation = true }
                    Button("新增文字方塊…") { annotationFreeText = true; showingAnnotation = true }
                    Divider()
                    Button("復原") { model.undoEdit() }.keyboardShortcut("z").disabled(!model.canUndo)
                    Button("重做") { model.redoEdit() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
                    Button("另存新檔…") { saveCopy() }.keyboardShortcut("s")
                    Button("列印…") { model.printDocument() }.keyboardShortcut("p")
                } label: { Label("編輯", systemImage: "pencil") }.disabled(model.document == nil)
                Button { model.cancelAnnotationPlacement(); inkMode.toggle(); model.setInkMode(inkMode) } label: { Label(inkMode ? "結束手繪" : "手繪", systemImage: inkMode ? "pencil.tip.crop.circle.badge.minus" : "pencil.tip") }.disabled(model.document == nil)
                Button { saveCopy() } label: { Label("另存新檔", systemImage: "square.and.arrow.down") }.disabled(model.document == nil)
                Button { model.pdfView.zoomOut(nil) } label: { Label("縮小", systemImage: "minus.magnifyingglass") }
                Button { model.pdfView.zoomIn(nil) } label: { Label("放大", systemImage: "plus.magnifyingglass") }
                Button { model.pdfView.autoScales = true } label: { Label("符合頁面", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { selection = 2; sidebar = true } label: { Label("搜尋", systemImage: "magnifyingglass") }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): openDocument(url)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $choosingMerge, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): model.appendPDF(url)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .alert("刪除頁面？", isPresented: $confirmDelete) {
            Button("刪除", role: .destructive) { model.deleteCurrentPage() }
            Button("取消", role: .cancel) {}
        } message: { Text(String(format: L("將刪除第 %ld 頁。此操作可以復原。"), model.currentPage)) }
        .alert(annotationFreeText ? "新增文字方塊" : "新增便條", isPresented: $showingAnnotation) {
            TextField("內容", text: $annotationText)
            Button("繼續") { inkMode = false; model.setInkMode(false); model.prepareAnnotation(text: annotationText, freeText: annotationFreeText); annotationText = "" }
            Button("取消", role: .cancel) { annotationText = "" }
        } message: { Text("輸入內容後，點一下頁面放置註解。") }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
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
    private func saveCopy() { model.saveCopyWithPanel() }
    private func openDocument(_ url: URL) {
        if model.document == nil && !model.needsPassword { model.open(url) }
        else { openInNewWindow(url) }
    }
}

struct PDFCanvas: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ view: PDFView, context: Context) {}
}

struct ThumbnailView: NSViewRepresentable {
    let document: PDFDocument
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView(); view.pdfView = pdfView; view.thumbnailSize = NSSize(width: 120, height: 160); return view
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
