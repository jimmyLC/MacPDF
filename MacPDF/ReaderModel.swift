import AppKit
import PDFKit
import UniformTypeIdentifiers
import Observation

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
    private(set) var isPlacingAnnotation = false
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var currentPage = 0
    var pageCount: Int { document?.pageCount ?? 0 }
    private var pending: (PDFDocument, URL, Bool)?
    var sourceURL: URL? { activeURL }
    private var activeURL: URL?
    private var displayName: String?
    private var activeScoped = false
    private let recentKey = "recentPDFBookmarks"
    private var recoveryID = UUID()
    private let recovery = RecoveryStore()
    private(set) var recoveryEntries: [RecoveryEntry] = []

    var title: String { displayName ?? activeURL?.lastPathComponent ?? "MacPDF" }

    override init() {
        pdfView = ReaderPDFView()
        super.init()
        pdfView.onInk = { [weak self] page, points in self?.addInk(page: page, points: points) }
        pdfView.onPlacement = { [weak self] page, point in self?.placeAnnotation(page: page, point: point) }
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        loadRecents()
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

    private func install(_ candidate: PDFDocument, url: URL, scoped: Bool, recoveredTitle: String? = nil) {
        clearPending()
        cancelSearch()
        if let document { NotificationCenter.default.removeObserver(self, name: nil, object: document) }
        if let activeURL, activeScoped { activeURL.stopAccessingSecurityScopedResource() }
        activeURL = url; activeScoped = scoped; displayName = recoveredTitle
        editor = PDFEditing(document: candidate)
        document = candidate; pdfView.document = candidate; pdfView.autoScales = true
        results = []
        hasSearched = false
        updatePage()
        NotificationCenter.default.addObserver(self, selector: #selector(foundMatch(_:)), name: .PDFDocumentDidFindMatch, object: candidate)
        NotificationCenter.default.addObserver(self, selector: #selector(finishedSearch(_:)), name: .PDFDocumentDidEndFind, object: candidate)
        if recoveredTitle == nil { addRecent(url) }
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
        guard let editor else { return }
        let oldPage = currentPage
        do {
            try operation(editor)
            replaceDisplayedDocument(editor.document, page: oldPage)
            revision += 1
            if let data = editor.document.dataRepresentation() {
                do { try recovery.save(id: recoveryID, title: title, data: data); recoveryEntries = recovery.entries() }
                catch { self.error = String(format: L("修改已套用，但無法建立恢復檔：%@"), error.localizedDescription) }
            } else { self.error = L("修改已套用，但無法建立恢復檔。") }
        } catch { self.error = error.localizedDescription }
    }
    private func replaceDisplayedDocument(_ replacement: PDFDocument, page: Int) {
        cancelSearch()
        if let document { NotificationCenter.default.removeObserver(self, name: nil, object: document) }
        document = replacement
        pdfView.document = replacement
        NotificationCenter.default.addObserver(self, selector: #selector(foundMatch(_:)), name: .PDFDocumentDidFindMatch, object: replacement)
        NotificationCenter.default.addObserver(self, selector: #selector(finishedSearch(_:)), name: .PDFDocumentDidEndFind, object: replacement)
        results = []; hasSearched = false
        goToPage(min(max(page, 1), replacement.pageCount))
    }
    func rotateCurrentPage() { edit { try $0.rotate(page: currentPage - 1) } }
    func deleteCurrentPage() { edit { try $0.delete(page: currentPage - 1) } }
    func moveCurrentPage(by offset: Int) {
        let target = currentPage - 1 + offset
        edit { try $0.move(page: currentPage - 1, to: target) }
        if target >= 0 && target < pageCount { goToPage(target + 1) }
    }
    func undoEdit() { editWithoutHistory { try $0.undo() } }
    func redoEdit() { editWithoutHistory { try $0.redo() } }
    private func editWithoutHistory(_ operation: (PDFEditing) throws -> Void) { edit(operation) }
    func appendPDF(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let other = PDFDocument(url: url), other.pageCount > 0 else { error = L("無法讀取要合併的 PDF。"); return }
        edit { try $0.append(other) }
    }
    func highlightSelection() {
        guard let selection = pdfView.currentSelection, let document else { error = PDFEditing.EditError.noSelection.localizedDescription; return }
        let selections = selection.selectionsByLine()
        let groups = Dictionary(grouping: selections.flatMap { line in line.pages.map { ($0, line.bounds(for: $0)) } }, by: { document.index(for: $0.0) })
        guard groups.count == 1, let (index, lines) = groups.first else { error = L("請選取同一頁內的文字。"); return }
        edit { try $0.highlight(page: index, bounds: lines.map(\.1)) }
    }
    func setInkMode(_ enabled: Bool) { pdfView.inkMode = enabled }
    private func addInk(page: Int, points: [CGPoint]) { edit { try $0.ink(page: page, points: points) } }
    func prepareAnnotation(text: String, freeText: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingAnnotation = (text, freeText)
        isPlacingAnnotation = true; pdfView.placingAnnotation = true
    }
    func cancelAnnotationPlacement() {
        pendingAnnotation = nil; isPlacingAnnotation = false; pdfView.placingAnnotation = false
    }
    private func placeAnnotation(page: Int, point: CGPoint) {
        guard let (text, freeText) = pendingAnnotation else { return }
        cancelAnnotationPlacement()
        let bounds = CGRect(x: point.x, y: point.y, width: freeText ? 160 : 24, height: freeText ? 40 : 24)
        edit { try $0.annotate(page: page, bounds: bounds, text: text, freeText: freeText) }
    }
    func saveCopy(to url: URL) {
        guard let editor else { return }
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
        guard let editor else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try editor.extract(pages: range, to: url) }
        catch { self.error = error.localizedDescription }
    }
    func printDocument() {
        guard let document else { return }
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

    func find(_ query: String) {
        cancelSearch()
        results = []
        hasSearched = false
        guard let document, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        hasSearched = true
        isSearching = true
        document.beginFindString(query, withOptions: .caseInsensitive)
    }

    func cancelSearch() {
        if isSearching { hasSearched = false }
        document?.cancelFindString()
        isSearching = false
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
        let result = results[index]; pdfView.setCurrentSelection(result, animate: true); pdfView.go(to: result)
    }

    func openRecent(_ url: URL) { open(url) }

    private func loadRecents() {
        let entries = UserDefaults.standard.array(forKey: recentKey) as? [Data] ?? []
        recents = entries.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    private func addRecent(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var entries = UserDefaults.standard.array(forKey: recentKey) as? [Data] ?? []
        entries.removeAll { data in
            var stale = false
            return (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)) == url
        }
        entries.insert(bookmark, at: 0)
        UserDefaults.standard.set(Array(entries.prefix(8)), forKey: recentKey)
        loadRecents()
    }
}
