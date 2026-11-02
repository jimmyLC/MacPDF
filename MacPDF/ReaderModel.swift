import AppKit
import PDFKit
import UniformTypeIdentifiers
import Observation

struct JobProgress { var title: String; var done: Int; var total: Int }

@MainActor @Observable
final class ReaderModel: NSObject {
    let pdfView: ReaderPDFView
    private(set) var document: PDFDocument?
    private(set) var editor: PDFEditing?
    private(set) var revision = 0
    var isDirty: Bool { _ = revision; return editor?.dirty ?? false }
    var canUndo: Bool { _ = revision; return editor?.canUndo ?? false }
    var canRedo: Bool { _ = revision; return editor?.canRedo ?? false }
    private(set) var recents: [URL] = []
    private(set) var needsPassword = false
    private(set) var results: [PDFSelection] = []
    var error: String?
    private var pendingAnnotation: (String, Bool)?
    private var pendingSignature: CGImage?
    var isPlacingSignature: Bool { pendingSignature != nil }
    let signatures = SignatureStore()
    private(set) var isPlacingAnnotation = false
    private(set) var isSearching = false
    var searchCaseSensitive = false
    var searchWholeWord = false
    private(set) var resultIndex: Int?
    private var searchTask: Task<Void, Never>?
    var viewMode = ViewMode.continuous
    var style = AnnotationStyle.load() { didSet { style.save() } }
    struct AnnotationRef: Equatable { let page: Int; let slot: Int }
    private(set) var inspected: AnnotationRef?
    private(set) var inspectMode = false
    private(set) var hasSearched = false
    private(set) var currentPage = 0
    /// Thumbnail selection, zero-based page indices.
    var selectedPages: Set<Int> = []
    private var selectionAnchor: Int?
    var pageCount: Int { document?.pageCount ?? 0 }
    private var pending: (PDFDocument, URL, Bool)?
    var sourceURL: URL? { activeURL }
    private var activeURL: URL?
    private var displayName: String?
    private var activeScoped = false
    static let recentKey = "recentPDFBookmarks"
    private var recentKey: String { Self.recentKey }
    private var recoveryID = UUID()
    private let recovery = RecoveryStore()
    private(set) var recoveryEntries: [RecoveryEntry] = []
    private(set) var job: JobProgress?
    private(set) var hasFormFields = false
    var notice: String?
    var sheet: M2Sheet?
    private(set) var redaction: RedactionSession?
    private var jobTask: Task<Void, Never>?
    private var formSnapshotTask: Task<Void, Never>?

    var title: String { displayName ?? activeURL?.lastPathComponent ?? "MacPDF" }

    override init() {
        pdfView = ReaderPDFView()
        super.init()
        pdfView.onRedactRect = { [weak self] page, rect in self?.addManualMark(page: page, rect: rect) }
        pdfView.onInspect = { [weak self] ref in self?.inspected = ref.map { AnnotationRef(page: $0.0, slot: $0.1) } }
        pdfView.onInk = { [weak self] page, points in self?.addInk(page: page, points: points) }
        pdfView.onPlacement = { [weak self] page, point in self?.placeAnnotation(page: page, point: point) }
        pdfView.autoScales = true
        pdfView.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.10, green: 0.105, blue: 0.15, alpha: 1)
                : NSColor(red: 0.91, green: 0.925, blue: 0.96, alpha: 1)
        }
        pdfView.pageBreakMargins = NSEdgeInsets(top: 8, left: 28, bottom: 8, right: 28)
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(annotationHit(_:)), name: .PDFViewAnnotationHit, object: pdfView)
        loadRecents()
        NotificationCenter.default.addObserver(self, selector: #selector(recentsChanged(_:)), name: .macpdfRecentsChanged, object: nil)
        recoveryEntries = recovery.entries()
    }

    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        guard let candidate = PDFDocument(url: url) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            error = L("無法讀取這份 PDF。檔案可能已損壞或無法存取。")
            return
        }
        if candidate.isLocked {
            clearPending()
            pending = (candidate, url, scoped)
            needsPassword = true
        } else if candidate.pageCount > 0 { install(candidate, url: url, scoped: scoped) }
        else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            error = L("這份 PDF 沒有可讀取的頁面。")
        }
    }

    func unlock(_ password: String) {
        guard let (candidate, url, scoped) = pending else { return }
        if candidate.unlock(withPassword: password) {
            pending = nil
            needsPassword = false
            install(candidate, url: url, scoped: scoped)
        } else {
            needsPassword = false
            clearPending()
            error = L("密碼不正確，請重新開啟檔案再試一次。")
        }
    }

    func cancelPassword() { needsPassword = false; clearPending() }

    private func clearPending() {
        if let (_, url, scoped) = pending, scoped { url.stopAccessingSecurityScopedResource() }
        pending = nil
    }

    private func install(_ candidate: PDFDocument, url: URL?, scoped: Bool, recoveredTitle: String? = nil) {
        clearPending()
        cancelSearch()
        if let document { NotificationCenter.default.removeObserver(self, name: nil, object: document) }
        if let activeURL, activeScoped { activeURL.stopAccessingSecurityScopedResource() }
        activeURL = url; activeScoped = scoped; displayName = recoveredTitle
        editor = PDFEditing(document: candidate)
        document = candidate; pdfView.document = candidate; pdfView.autoScales = true
        pdfView.scrollToTopSoon()
        results = []
        hasSearched = false
        selectedPages = []; selectionAnchor = nil
        updateFormFlag()
        updatePage()
        NotificationCenter.default.addObserver(self, selector: #selector(foundMatch(_:)), name: .PDFDocumentDidFindMatch, object: candidate)
        NotificationCenter.default.addObserver(self, selector: #selector(finishedSearch(_:)), name: .PDFDocumentDidEndFind, object: candidate)
        if recoveredTitle == nil, let url { addRecent(url) }
    }

    @objc private func pageChanged(_ notification: Notification) { updatePage() }

    private func updatePage() {
        guard let document, let page = pdfView.currentPage else { currentPage = 0; return }
        let index = document.index(for: page)
        currentPage = index == NSNotFound ? 0 : index + 1
    }

    func goToPage(_ pageNumber: Int) {
        guard let document, (1...document.pageCount).contains(pageNumber),
              let page = document.page(at: pageNumber - 1) else { return }
        pdfView.go(to: page)
        updatePage()
    }

    isolated deinit {
        document?.cancelFindString()
        NotificationCenter.default.removeObserver(self)
        if let (_, url, scoped) = pending, scoped { url.stopAccessingSecurityScopedResource() }
        if let activeURL, activeScoped { activeURL.stopAccessingSecurityScopedResource() }
    }

    private func edit(_ operation: (PDFEditing) throws -> Void) {
        guard let editor, redaction == nil else { return }
        let oldPage = currentPage
        do {
            try operation(editor)
            replaceDisplayedDocument(editor.document, page: oldPage)
            revision += 1
            saveRecoverySnapshot()
        } catch { self.error = error.localizedDescription }
    }
    private func saveRecoverySnapshot() {
        guard let editor else { return }
        if let data = editor.document.dataRepresentation() {
            do { try recovery.save(id: recoveryID, title: title, data: data); recoveryEntries = recovery.entries() }
            catch { self.error = String(format: L("修改已套用，但無法建立恢復檔：%@"), error.localizedDescription) }
        } else { self.error = L("修改已套用，但無法建立恢復檔。") }
    }
    private func updateFormFlag() {
        hasFormFields = document.map { !PDFEditing.widgets(in: $0).isEmpty } ?? false
    }
    private func replaceDisplayedDocument(_ replacement: PDFDocument, page: Int) {
        cancelSearch()
        if let document { NotificationCenter.default.removeObserver(self, name: nil, object: document) }
        document = replacement
        pdfView.document = replacement
        NotificationCenter.default.addObserver(self, selector: #selector(foundMatch(_:)), name: .PDFDocumentDidFindMatch, object: replacement)
        NotificationCenter.default.addObserver(self, selector: #selector(finishedSearch(_:)), name: .PDFDocumentDidEndFind, object: replacement)
        results = []; hasSearched = false
        selectedPages = selectedPages.filter { $0 < replacement.pageCount }
        updateFormFlag()
        goToPage(min(max(page, 1), replacement.pageCount))
    }
    /// The pages page commands act on: the thumbnail selection, or just the page on screen.
    var targetPages: [Int] {
        let chosen = selectedPages.filter { $0 >= 0 && $0 < pageCount }.sorted()
        return chosen.isEmpty ? [max(currentPage - 1, 0)] : chosen
    }

    func selectPage(_ index: Int, extend: Bool, toggle: Bool) {
        guard index >= 0, index < pageCount else { return }
        if extend, let anchor = selectionAnchor {
            selectedPages = Set(min(anchor, index)...max(anchor, index))
        } else if toggle {
            if selectedPages.contains(index) { selectedPages.remove(index) } else { selectedPages.insert(index) }
            selectionAnchor = index
        } else {
            selectedPages = [index]; selectionAnchor = index
        }
        if !toggle || selectedPages.contains(index) { goToPage(index + 1) }
    }
    func selectAllPages() { selectedPages = Set(0..<pageCount) }
    func clearPageSelection() { selectedPages = []; selectionAnchor = nil }

    func rotateTargets(by degrees: Int) { let pages = targetPages; edit { try $0.rotate(pages: pages, by: degrees) } }
    func rotateAll(by degrees: Int) { let all = Array(0..<pageCount); edit { try $0.rotate(pages: all, by: degrees) } }
    func rotateCurrentPage() { let pages = targetPages; edit { try $0.rotate(pages: pages) } }
    func deleteCurrentPage() {
        let pages = targetPages
        edit { try $0.delete(pages: pages) }
        if error == nil { clearPageSelection() }
    }
    func moveCurrentPage(by offset: Int) {
        let pages = targetPages
        guard let first = pages.first, let last = pages.last else { return }
        let destination = offset < 0 ? first - 1 : last + 2
        guard destination >= 0, destination <= pageCount else { return }
        movePages(pages, before: destination)
    }
    /// Drag and drop and the menu commands both end up here.
    func movePages(_ pages: [Int], before destination: Int) {
        var placed: [Int] = []
        edit { placed = try $0.move(pages: pages, before: destination) }
        if error == nil, !placed.isEmpty {
            selectedPages = Set(placed); selectionAnchor = placed.first
            goToPage(placed[0] + 1)
        }
    }
    func extractSelectedPages(to url: URL) {
        guard let editor, redaction == nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try editor.extract(pageList: targetPages, to: url); notice = String(format: L("已擷取 %ld 頁。"), targetPages.count) }
        catch { self.error = error.localizedDescription }
    }

    /// Renders the pages to PNG or JPEG files in a folder the user picks.
    func exportImages(pages: [Int], format: PDFProcessing.ImageFormat, dpi: CGFloat) {
        guard let document, jobTask == nil, redaction == nil, !pages.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = L("選擇存放圖片的資料夾。每張圖片都是新檔，不會覆寫現有檔案。")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let base = (sourceURL?.deletingPathExtension().lastPathComponent ?? title.replacingOccurrences(of: ".pdf", with: ""))
        let width = max(3, String(document.pageCount).count)
        job = JobProgress(title: L("匯出圖片中"), done: 0, total: pages.count)
        jobTask = Task { [weak self] in
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            var written = 0, failed = false
            for (n, index) in pages.enumerated() {
                guard let self, !Task.isCancelled else { break }
                self.job?.done = n
                guard let page = document.page(at: index), let data = PDFProcessing.imageData(of: page, dpi: dpi, format: format) else { failed = true; break }
                let url = PDFProcessing.imageURL(base: base, number: index + 1, width: width, format: format, in: folder)
                do { try data.write(to: url, options: .withoutOverwriting); written += 1 }
                catch { self.error = error.localizedDescription; failed = true; break }
                await Task.yield()
            }
            guard let self else { return }
            let cancelled = self.jobTask?.isCancelled ?? false
            self.job = nil; self.jobTask = nil
            if cancelled { self.notice = String(format: L("已取消，已匯出 %ld 張。"), written) }
            else if failed && self.error == nil { self.error = L("無法把頁面轉成圖片。") }
            else if !failed { self.notice = String(format: L("已匯出 %ld 張圖片。"), written) }
        }
    }

    func undoEdit() { editWithoutHistory { try $0.undo() } }
    func redoEdit() { editWithoutHistory { try $0.redo() } }
    private func editWithoutHistory(_ operation: (PDFEditing) throws -> Void) { edit(operation) }
    /// Shows a freshly built document as an unsaved "Untitled" document; saving always asks for a new file.
    func adoptNew(_ built: PDFDocument, title: String) {
        install(built, url: nil, scoped: false, recoveredTitle: title)
        editor = PDFEditing(document: built, dirty: true)
        revision += 1
        saveRecoverySnapshot()
    }

    func buildDocument(_ items: [PDFBuilder.Item], sheet: PDFProcessing.PageSheet, intoCurrent: Bool, before index: Int?) {
        do {
            let built = try PDFBuilder.build(items, sheet: sheet)
            if intoCurrent, editor != nil {
                edit { try $0.insert(built, before: index) }
                if error == nil { notice = String(format: L("已加入 %ld 頁。"), built.pageCount) }
            } else if document == nil {
                adoptNew(built, title: L("未命名.pdf"))
            } else {
                PDFWindows.shared.openNew(built, title: L("未命名.pdf"))
            }
        } catch { self.error = error.localizedDescription }
    }

    func insertBlankPages(count: Int, around page: Int, after: Bool, size: CGSize?) {
        let reference = document?.page(at: page)
        var chosen = size
        if chosen == nil, let reference {
            let box = reference.bounds(for: .cropBox)
            chosen = reference.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
        }
        guard let chosen else { return }
        let start = after ? page + 1 : page
        edit { editor in for _ in 0..<count { try editor.insertBlankPage(before: start, size: chosen) } }
        if error == nil { goToPage(start + 1); notice = String(format: L("已插入 %ld 張空白頁。"), count) }
    }

    func insertBlankPage(after: Bool) {
        let at = currentPage - 1
        edit { try $0.insertBlankPage(relativeTo: at, after: after) }
        if error == nil { goToPage(after ? at + 2 : at + 1); notice = L("已插入空白頁。") }
    }

    /// Splits into one file per range in a folder the user picks. `rangesText` nil means one file per page.
    func splitPages(rangesText: String?) {
        guard let editor, redaction == nil else { return }
        let ranges: [ClosedRange<Int>]
        do {
            ranges = try rangesText.map { try PDFEditing.parseRanges($0, pageCount: pageCount) } ?? (1...pageCount).map { $0...$0 }
        } catch { self.error = L("請輸入有效的頁碼範圍，例如 1-3, 5, 8-10。"); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = L("選擇存放分割檔案的資料夾。每個檔案都是新檔，不會覆寫現有檔案。")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let base = (sourceURL?.deletingPathExtension().lastPathComponent ?? title.replacingOccurrences(of: ".pdf", with: ""))
        do {
            let files = try editor.split(ranges: ranges, into: folder, baseName: base)
            notice = String(format: L("已分割成 %ld 個檔案。"), files.count)
        } catch { self.error = error.localizedDescription }
    }

    func appendPDF(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let other = PDFDocument(url: url), other.pageCount > 0 else { error = L("無法讀取要合併的 PDF。"); return }
        edit { try $0.append(other) }
    }
    func highlightSelection() { markSelection(style: .highlight, color: .yellow) }
    private var lineColor: NSColor { NSColor(hex: self.style.lineColor) ?? .systemRed }
    func markSelection(style: PDFAnnotationSubtype, color: NSColor) {
        guard let selection = pdfView.currentSelection, let document else { error = PDFEditing.EditError.noSelection.localizedDescription; return }
        let selections = selection.selectionsByLine()
        let groups = Dictionary(grouping: selections.flatMap { line in line.pages.map { ($0, line.bounds(for: $0)) } }, by: { document.index(for: $0.0) })
        guard groups.count == 1, let (index, lines) = groups.first else { error = L("請選取同一頁內的文字。"); return }
        let opacity = CGFloat(self.style.highlightOpacity), author = self.style.author
        edit { try $0.markup(page: index, bounds: lines.map(\.1), style: style, color: color, opacity: opacity, author: author) }
    }
    func setInkMode(_ enabled: Bool) { pdfView.inkMode = enabled; if enabled { setInspectMode(false) } }

    func setInspectMode(_ enabled: Bool) {
        inspectMode = enabled; pdfView.inspectMode = enabled
        if enabled { pdfView.inkMode = false; cancelAnnotationPlacement() } else { inspected = nil }
    }

    /// The annotation being inspected, read from the document on screen.
    var inspectedAnnotation: PDFAnnotation? {
        _ = revision
        guard let ref = inspected, let page = document?.page(at: ref.page), page.annotations.indices.contains(ref.slot) else { return nil }
        return page.annotations[ref.slot]
    }
    func updateInspected(_ change: @escaping (PDFAnnotation) -> Void) {
        guard let ref = inspected else { return }
        edit { try $0.updateAnnotation(page: ref.page, slot: ref.slot, change) }
    }
    func deleteInspected() {
        guard let ref = inspected else { return }
        edit { try $0.deleteAnnotation(page: ref.page, slot: ref.slot) }
        if error == nil { inspected = nil; notice = L("已刪除註解，可以復原。") }
    }
    private func addInk(page: Int, points: [CGPoint]) {
        let color = NSColor(hex: style.inkColor) ?? .systemBlue, width = CGFloat(style.inkWidth)
        edit { try $0.ink(page: page, points: points, color: color, width: width) }
    }
    func prepareAnnotation(text: String, freeText: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingAnnotation = (text, freeText)
        isPlacingAnnotation = true; pdfView.placingAnnotation = true
    }
    func cancelAnnotationPlacement() {
        pendingAnnotation = nil; pendingSignature = nil; isPlacingAnnotation = false; pdfView.placingAnnotation = false
    }
    func prepareSignature(_ image: CGImage) {
        setInkMode(false); setRedactDrawing(false)
        pendingAnnotation = nil; pendingSignature = image
        isPlacingAnnotation = true; pdfView.placingAnnotation = true
    }

    private func placeSignature(_ image: CGImage, page index: Int, at point: CGPoint) {
        cancelAnnotationPlacement()
        guard let page = document?.page(at: index) else { return }
        guard page.rotation == 0 else { error = L("旋轉過的頁面無法簽名，請先把頁面轉回原本的方向。"); return }
        let width: CGFloat = 160
        let size = CGSize(width: width, height: width * CGFloat(image.height) / CGFloat(image.width))
        var rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        let box = page.bounds(for: .cropBox)
        rect.origin.x = min(max(rect.minX, box.minX), box.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, box.minY), box.maxY - rect.height)
        guard let stamped = PDFProcessing.stampedPage(from: page, image: image, rect: rect) else { error = L("無法放置簽名。"); return }
        edit { try $0.replace(pages: [index: stamped]) }
        if error == nil { notice = L("已放置簽名，可以復原。") }
    }

    private func placeAnnotation(page: Int, point: CGPoint) {
        if let image = pendingSignature { placeSignature(image, page: page, at: point); return }
        guard let (text, freeText) = pendingAnnotation else { return }
        cancelAnnotationPlacement()
        let bounds = CGRect(x: point.x, y: point.y, width: freeText ? 160 : 24, height: freeText ? 40 : 24)
        let current = style
        edit { try $0.annotate(page: page, bounds: bounds, text: text, freeText: freeText, style: current) }
    }
    func saveCopy(to url: URL) {
        guard let editor, redaction == nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try editor.export(to: url); displayName = url.lastPathComponent; revision += 1
            do { try recovery.remove(recoveryID); recoveryEntries = recovery.entries() }
            catch { self.error = String(format: L("副本已儲存，但無法刪除恢復檔：%@"), error.localizedDescription) }
        }
        catch { self.error = error.localizedDescription }
    }

    func extractPages(_ range: ClosedRange<Int>, to url: URL) {
        guard let editor, redaction == nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try editor.extract(pages: range, to: url) }
        catch { self.error = error.localizedDescription }
    }
    func printDocument() {
        guard let document, redaction == nil else { return }
        guard let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            error = L("無法建立列印工作。"); return
        }
        operation.run()
    }
    @discardableResult func discardChanges() -> Bool {
        do {
            try recovery.remove(recoveryID); recoveryEntries = recovery.entries()
            editor?.markDiscarded(); revision += 1
            return true
        } catch { self.error = String(format: L("無法刪除恢復檔：%@"), error.localizedDescription); return false }
    }
    func saveCopyWithPanel() {
        guard redaction == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "MacPDF-副本.pdf"
        panel.message = L("請選擇新的檔名；MacPDF 不會覆寫現有檔案。")
        if panel.runModal() == .OK, let url = panel.url { saveCopy(to: url) }
    }

    func restore(_ entry: RecoveryEntry) {
        let url = recovery.url(for: entry.id)
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { error = L("無法讀取恢復檔。"); return }
        install(doc, url: url, scoped: false, recoveredTitle: entry.title)
        recoveryID = entry.id
        editor = PDFEditing(document: doc, dirty: true)
        revision += 1
        // The recovered snapshot is not the original; export always creates a new file.
    }
    func discardRecovery(_ entry: RecoveryEntry) {
        do { try recovery.remove(entry.id); recoveryEntries = recovery.entries() }
        catch { self.error = String(format: L("無法刪除恢復檔：%@"), error.localizedDescription) }
    }

    /// Searches page by page so large files stay responsive and the search can be stopped.
    func find(_ query: String) {
        cancelSearch()
        results = []; resultIndex = nil
        hasSearched = false
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, !trimmed.isEmpty else { return }
        var pattern = NSRegularExpression.escapedPattern(for: trimmed)
        if searchWholeWord { pattern = "(?<![\\p{L}\\p{N}])" + pattern + "(?![\\p{L}\\p{N}])" }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: searchCaseSensitive ? [] : [.caseInsensitive]) else { return }
        hasSearched = true; isSearching = true
        searchTask = Task { [weak self] in
            for index in 0..<document.pageCount {
                guard !Task.isCancelled, let self else { return }
                if let page = document.page(at: index), let text = page.string, !text.isEmpty {
                    let whole = NSRange(location: 0, length: (text as NSString).length)
                    for match in expression.matches(in: text, range: whole) where match.range.length > 0 {
                        if let selection = page.selection(for: match.range) { self.results.append(selection) }
                    }
                }
                if index % 10 == 9 { await Task.yield() }
            }
            self?.isSearching = false
            self?.searchTask = nil
        }
    }

    func cancelSearch() {
        if isSearching { hasSearched = false }
        searchTask?.cancel(); searchTask = nil
        document?.cancelFindString()
        isSearching = false
    }

    func nextResult() { step(1) }
    func previousResult() { step(-1) }
    private func step(_ direction: Int) {
        guard !results.isEmpty else { return }
        let next = ((resultIndex ?? (direction > 0 ? -1 : 0)) + direction + results.count) % results.count
        goToResult(next)
    }

    @objc private func foundMatch(_ notification: Notification) {
        guard let source = notification.object as? PDFDocument, source === document,
              let match = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
        results.append(match)
    }

    @objc private func finishedSearch(_ notification: Notification) {
        guard let source = notification.object as? PDFDocument, source === document else { return }
        isSearching = false
    }

    func resultTitle(_ index: Int) -> String {
        let result = results[index]
        let page = result.pages.first.flatMap { document?.index(for: $0) }.map { $0 + 1 } ?? 0
        return String(format: L("第 %ld 頁：%@"), page, result.string ?? "")
    }

    func goToResult(_ index: Int) {
        guard results.indices.contains(index) else { return }
        resultIndex = index
        let result = results[index]; pdfView.setCurrentSelection(result, animate: true); pdfView.go(to: result)
    }

    func openRecent(_ url: URL) { open(url) }

    // MARK: M2

    @objc private func annotationHit(_ notification: Notification) {
        guard let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation, annotation.type == "Widget",
              let editor, !editor.document.isEncrypted else { return }
        // Form values live in the displayed document; track them so close/quit and recovery know.
        editor.markDirty(); revision += 1
        formSnapshotTask?.cancel()
        formSnapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.saveRecoverySnapshot() }
        }
    }

    func cancelJob() { jobTask?.cancel() }

    /// PDFView runs its own on-screen text recognition, which makes `page.string` report text that is not
    /// in the file. Ask a detached copy instead, so only text that would be saved counts.
    private func pagesWithoutEmbeddedText() -> [Int] {
        guard let data = document?.dataRepresentation(), let probe = PDFDocument(data: data) else { return [] }
        return (0..<probe.pageCount).filter { index in probe.page(at: index).map { !PDFProcessing.hasText($0) } ?? false }
    }

    func runOCR() {
        guard let document, jobTask == nil else { return }
        let candidates = pagesWithoutEmbeddedText().filter { document.page(at: $0)?.rotation == 0 }
        guard !candidates.isEmpty else { notice = L("沒有需要辨識的頁面（已有文字，或是旋轉過的頁面）。"); return }
        let start = revision
        job = JobProgress(title: L("文字辨識中"), done: 0, total: candidates.count)
        jobTask = Task { [weak self] in
            var results: [Int: PDFPage] = [:]
            for (n, index) in candidates.enumerated() {
                guard let self, !Task.isCancelled else { break }
                self.job?.done = n
                guard let page = self.document?.page(at: index),
                      let image = PDFProcessing.renderImage(of: page, scale: PDFProcessing.ocrScale) else { continue }
                let lines = (try? await Task.detached(priority: .userInitiated) { try PDFProcessing.recognize(image) }.value) ?? []
                guard !lines.isEmpty, let rebuilt = PDFProcessing.searchablePage(from: page, lines: lines) else { continue }
                results[index] = rebuilt
            }
            self?.finishPageJob(results: results, startRevision: start, cancelledMessage: L("已取消文字辨識。"),
                                emptyMessage: L("沒有辨識到文字。")) { count in String(format: L("已辨識 %ld 頁，現在可以搜尋與選取文字。"), count) }
        }
    }

    func compress(_ preset: PDFProcessing.Preset) {
        guard let document, jobTask == nil else { return }
        let candidates = (0..<document.pageCount).filter { document.page(at: $0).map { PDFProcessing.isImageDominant($0) } ?? false }
        guard !candidates.isEmpty else { notice = L("沒有可壓縮的掃描頁面。"); return }
        let start = revision
        let before = document.dataRepresentation()?.count ?? 0
        job = JobProgress(title: L("壓縮中"), done: 0, total: candidates.count)
        jobTask = Task { [weak self] in
            var results: [Int: PDFPage] = [:]
            for (n, index) in candidates.enumerated() {
                guard let self, !Task.isCancelled else { break }
                self.job?.done = n
                if let page = self.document?.page(at: index), let rebuilt = PDFProcessing.compressedPage(from: page, preset: preset) { results[index] = rebuilt }
                await Task.yield()
            }
            self?.finishPageJob(results: results, startRevision: start, cancelledMessage: L("已取消壓縮。"),
                                emptyMessage: L("無法壓縮這些頁面。")) { [weak self] count in
                let after = self?.editor?.document.dataRepresentation()?.count ?? before
                if after >= before {
                    self?.undoEdit()
                    return L("壓縮後檔案沒有變小，已還原。")
                }
                let formatter = ByteCountFormatter(); formatter.countStyle = .file
                return String(format: L("已壓縮 %ld 頁：%@ → %@"), count, formatter.string(fromByteCount: Int64(before)), formatter.string(fromByteCount: Int64(after)))
            }
        }
    }

    private func finishPageJob(results: [Int: PDFPage], startRevision: Int, cancelledMessage: String, emptyMessage: String,
                               success: (Int) -> String) {
        let cancelled = jobTask?.isCancelled ?? false
        job = nil; jobTask = nil
        guard !cancelled else { notice = cancelledMessage; return }
        guard revision == startRevision else { notice = L("文件在處理期間已變更，結果未套用。"); return }
        guard !results.isEmpty else { notice = emptyMessage; return }
        edit { try $0.replace(pages: results) }
        if error == nil { notice = success(results.count) }
    }

    /// Watermark and/or header-footer over the given pages. Pages are rebuilt, so their own text stays real text.
    func decorate(watermark: Decoration.Watermark?, headerFooter: Decoration.HeaderFooter?, pages: [Int]) {
        guard let document, jobTask == nil, redaction == nil, !pages.isEmpty else { return }
        let hasMark = watermark.map { !$0.isEmpty } ?? false, hasText = headerFooter.map { !$0.isEmpty } ?? false
        guard hasMark || hasText else { notice = L("沒有要加入的內容。"); return }
        let attributes = document.documentAttributes ?? [:]
        let info = Decoration.Info(title: (attributes[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title.replacingOccurrences(of: ".pdf", with: ""),
                                   author: attributes[PDFDocumentAttribute.authorAttribute] as? String ?? "", filename: title)
        let count = document.pageCount
        let start = revision
        job = JobProgress(title: L("加入中"), done: 0, total: pages.count)
        jobTask = Task { [weak self] in
            var results: [Int: PDFPage] = [:]
            for (n, index) in pages.enumerated() {
                guard let self, !Task.isCancelled else { break }
                self.job?.done = n
                guard let page = self.document?.page(at: index) else { continue }
                let rebuilt = PDFProcessing.decoratedPage(from: page, behind: { context, size in
                    if let mark = watermark, mark.behind { Decoration.draw(mark, in: context, size: size) }
                }, front: { context, size in
                    if let mark = watermark, !mark.behind { Decoration.draw(mark, in: context, size: size) }
                    if let spec = headerFooter { Decoration.draw(spec, page: index, count: count, info: info, in: context, size: size) }
                })
                if let rebuilt { results[index] = rebuilt }
                await Task.yield()
            }
            self?.finishPageJob(results: results, startRevision: start, cancelledMessage: L("已取消。"), emptyMessage: L("無法加入內容。")) { count in
                String(format: L("已加入到 %ld 頁，可以復原。"), count)
            }
        }
    }

    func resetForm() { edit { try $0.resetFormFields() }; if error == nil { notice = L("已清除表單欄位。") } }
    func flattenForms() { edit { try $0.flattenForms() }; if error == nil { notice = L("表單已烙入頁面，無法再填寫。可以復原。") } }

    var metadata: [String: String] {
        guard let attributes = document?.documentAttributes else { return [:] }
        func text(_ key: PDFDocumentAttribute) -> String {
            if let value = attributes[key] as? String { return value }
            if let values = attributes[key] as? [String] { return values.joined(separator: ", ") }
            return ""
        }
        return ["title": text(.titleAttribute), "author": text(.authorAttribute), "subject": text(.subjectAttribute), "keywords": text(.keywordsAttribute)]
    }
    func setMetadata(title: String, author: String, subject: String, keywords: String) {
        var values: [PDFDocumentAttribute: Any] = [:]
        if !title.isEmpty { values[.titleAttribute] = title }
        if !author.isEmpty { values[.authorAttribute] = author }
        if !subject.isEmpty { values[.subjectAttribute] = subject }
        let words = keywords.split(whereSeparator: { ",，;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !words.isEmpty { values[.keywordsAttribute] = words }
        edit { try $0.setMetadata(values) }
    }

    func appendPages(_ pages: [PDFPage]) { edit { try $0.appendPages(pages) } }

    func appendImages(_ urls: [URL]) {
        let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { scoped.forEach { if $0.1 { $0.0.stopAccessingSecurityScopedResource() } } }
        edit { try $0.appendImages(urls) }
        if error == nil { notice = String(format: L("已新增 %ld 張圖片為頁面。"), urls.count) }
    }

    func exportEncryptedCopy(userPassword: String, ownerPassword: String, permissions: PDFEditing.Permissions) {
        guard let editor, redaction == nil, let url = choosePDFDestination(suggested: "MacPDF-加密.pdf") else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try editor.exportEncrypted(to: url, userPassword: userPassword, ownerPassword: ownerPassword, permissions: permissions); notice = L("已儲存加密副本。") }
        catch { self.error = error.localizedDescription }
    }

    func exportUnlockedCopy() {
        guard let editor, redaction == nil, let url = choosePDFDestination(suggested: "MacPDF-無密碼.pdf") else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try editor.exportUnlocked(to: url); notice = L("已儲存無密碼副本。") }
        catch { self.error = error.localizedDescription }
    }

    func choosePDFDestination(suggested: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggested
        panel.message = L("請選擇新的檔名；MacPDF 不會覆寫現有檔案。")
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: M3 redaction

    func beginRedaction() {
        guard document != nil, redaction == nil, job == nil else { return }
        guard let editor, !editor.document.isEncrypted else { error = L("加密的 PDF 無法塗黑。請先儲存無密碼副本。"); return }
        guard !PDFEditing.containsSignatureField(editor.document) else { error = PDFEditing.EditError.signatureField.localizedDescription; return }
        cancelAnnotationPlacement(); setInkMode(false)
        redaction = RedactionSession()
    }

    func endRedaction() {
        if let document { Redaction.clearOverlays(in: document) }
        redaction = nil; pdfView.redactDrawing = false
    }

    func setRedactDrawing(_ enabled: Bool) {
        redaction?.drawing = enabled
        pdfView.redactDrawing = enabled
        if enabled { cancelAnnotationPlacement(); setInkMode(false) }
    }

    private func addMarks(_ marks: [RedactionMark]) {
        guard let document, let redaction else { return }
        for mark in marks {
            let duplicate = redaction.marks.contains { $0.page == mark.page && $0.rect.insetBy(dx: -1, dy: -1).contains(mark.rect) && mark.source != .manual }
            if duplicate { continue }
            redaction.marks.append(mark); Redaction.show(mark, on: document)
        }
    }

    private func addManualMark(page: Int, rect: CGRect) {
        addMarks([RedactionMark(page: page, rect: rect, text: L("手動框選"), source: .manual)])
    }

    func scanRedaction() {
        guard let document, let redaction else { return }
        let keywords = redaction.keywords.split(whereSeparator: { ",，;；\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        do {
            let found = try Redaction.find(in: document, keywords: keywords, kinds: redaction.kinds, regex: redaction.regex.isEmpty ? nil : redaction.regex)
            let before = redaction.marks.count
            addMarks(found)
            redaction.scanned = true
            redaction.lastFound = redaction.marks.count - before
        } catch { self.error = L("自訂規則不是有效的規則運算式。") }
    }

    func removeMark(_ id: UUID) {
        guard let document, let redaction else { return }
        redaction.marks.removeAll { $0.id == id }
        Redaction.removeOverlay(for: id, in: document)
    }

    func clearMarks() {
        guard let document, let redaction else { return }
        redaction.marks.removeAll(); Redaction.clearOverlays(in: document)
    }

    func goToMark(_ mark: RedactionMark) {
        guard let page = document?.page(at: mark.page) else { return }
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: mark.rect.minX, y: mark.rect.maxY + 40)))
    }

    /// Builds, verifies and only then asks where to save. Nothing is written when verification fails.
    func applyRedaction() {
        guard let document, let redaction, jobTask == nil, !redaction.marks.isEmpty else { return }
        let marks = redaction.marks
        let pages = Set(marks.map(\.page)).count
        Redaction.clearOverlays(in: document)
        job = JobProgress(title: L("塗黑處理中"), done: 0, total: pages)
        jobTask = Task { [weak self] in
            let built = await Redaction.build(from: document, marks: marks) { done, _ in self?.job?.done = done }
            guard let self else { return }
            let cancelled = self.jobTask?.isCancelled ?? false
            self.job = nil; self.jobTask = nil
            guard !cancelled else { marks.forEach { Redaction.show($0, on: document) }; self.notice = L("已取消塗黑。"); return }
            guard let built, built.pageCount == document.pageCount else {
                marks.forEach { Redaction.show($0, on: document) }
                self.error = L("塗黑失敗，原始檔沒有被修改。"); return
            }
            let report = Redaction.verify(built, source: document, marks: marks)
            guard report.passed else {
                marks.forEach { Redaction.show($0, on: document) }
                self.error = String(format: L("驗證沒有通過：第 %@ 頁可能仍有文字或區域未塗黑。沒有儲存任何檔案，請手動檢查。"),
                                    report.failedPages.map(String.init).joined(separator: "、"))
                return
            }
            guard let url = self.choosePDFDestination(suggested: "MacPDF-塗黑.pdf") else {
                marks.forEach { Redaction.show($0, on: document) }; return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = built.dataRepresentation() else { marks.forEach { Redaction.show($0, on: document) }; self.error = L("塗黑失敗，原始檔沒有被修改。"); return }
            do {
                try PDFEditing.writeNew(data: data, to: url)
                self.endRedaction()
                self.notice = String(format: L("%ld 頁、%ld 個區域已永久移除，驗證通過。原始檔沒有被修改。"), report.pages, report.regions)
            } catch {
                marks.forEach { Redaction.show($0, on: document) }
                self.error = error.localizedDescription
            }
        }
    }

    func clearRecents() {
        UserDefaults.standard.removeObject(forKey: recentKey)
        NotificationCenter.default.post(name: .macpdfRecentsChanged, object: nil)
    }
    @objc private func recentsChanged(_ note: Notification) { loadRecents() }

    static func recentURLs() -> [URL] {
        let entries = UserDefaults.standard.array(forKey: recentKey) as? [Data] ?? []
        return entries.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }
    static func clearAllRecents() {
        UserDefaults.standard.removeObject(forKey: recentKey)
        NotificationCenter.default.post(name: .macpdfRecentsChanged, object: nil)
    }
    private func loadRecents() { recents = Self.recentURLs() }

    private func addRecent(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var entries = UserDefaults.standard.array(forKey: recentKey) as? [Data] ?? []
        entries.removeAll { data in
            var stale = false
            return (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)) == url
        }
        entries.insert(bookmark, at: 0)
        UserDefaults.standard.set(Array(entries.prefix(8)), forKey: recentKey)
        NotificationCenter.default.post(name: .macpdfRecentsChanged, object: nil)
    }
}

extension Notification.Name { static let macpdfRecentsChanged = Notification.Name("macpdfRecentsChanged") }
