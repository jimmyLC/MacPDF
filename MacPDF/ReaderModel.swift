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
    private(set) var job: JobProgress?
    private(set) var hasFormFields = false
    var notice: String?
    var sheet: M2Sheet?
    private var jobTask: Task<Void, Never>?
    private var formSnapshotTask: Task<Void, Never>?

    var title: String { displayName ?? activeURL?.lastPathComponent ?? "MacPDF" }

    override init() {
        pdfView = ReaderPDFView()
        super.init()
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
        pdfView.scrollToTopSoon()
        results = []
        hasSearched = false
        updateFormFlag()
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
        updateFormFlag()
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

    func appendImages(_ urls: [URL]) {
        let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { scoped.forEach { if $0.1 { $0.0.stopAccessingSecurityScopedResource() } } }
        edit { try $0.appendImages(urls) }
        if error == nil { notice = String(format: L("已新增 %ld 張圖片為頁面。"), urls.count) }
    }

    func exportEncryptedCopy(userPassword: String, ownerPassword: String, permissions: PDFEditing.Permissions) {
        guard let editor, let url = choosePDFDestination(suggested: "MacPDF-加密.pdf") else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try editor.exportEncrypted(to: url, userPassword: userPassword, ownerPassword: ownerPassword, permissions: permissions); notice = L("已儲存加密副本。") }
        catch { self.error = error.localizedDescription }
    }

    func exportUnlockedCopy() {
        guard let editor, let url = choosePDFDestination(suggested: "MacPDF-無密碼.pdf") else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try editor.exportUnlocked(to: url); notice = L("已儲存無密碼副本。") }
        catch { self.error = error.localizedDescription }
    }

    private func choosePDFDestination(suggested: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggested
        panel.message = L("請選擇新的檔名；MacPDF 不會覆寫現有檔案。")
        return panel.runModal() == .OK ? panel.url : nil
    }

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
