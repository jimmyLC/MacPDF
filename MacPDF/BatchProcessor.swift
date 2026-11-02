import AppKit
import PDFKit
import Observation

/// Runs the same steps over many PDFs and writes each result as a new file in a chosen folder.
enum BatchProcessor {
    struct Options: Equatable {
        var ocr = false
        var compress = false
        var preset = PDFProcessing.Preset.standard
        var flatten = false
        var isEmpty: Bool { !ocr && !compress && !flatten }
    }

    enum Outcome: Equatable {
        case waiting, running, done(String), skipped(String), failed(String)
    }

    /// Applies the steps to one document and returns the result bytes. The input is edited in memory only.
    @MainActor static func process(_ document: PDFDocument, options: Options) async throws -> Data {
        guard !document.isLocked, !document.isEncrypted else { throw PDFEditing.EditError.encryptedInput }
        guard !PDFEditing.containsSignatureField(document) else { throw PDFEditing.EditError.signatureField }
        let editor = PDFEditing(document: document)
        if options.ocr {
            var rebuilt: [Int: PDFPage] = [:]
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), page.rotation == 0, !PDFProcessing.hasText(page),
                      let image = PDFProcessing.renderImage(of: page, scale: PDFProcessing.ocrScale) else { continue }
                let lines = (try? await Task.detached(priority: .userInitiated) { try PDFProcessing.recognize(image) }.value) ?? []
                if !lines.isEmpty, let new = PDFProcessing.searchablePage(from: page, lines: lines) { rebuilt[index] = new }
                try Task.checkCancellation()
            }
            try editor.replace(pages: rebuilt)
        }
        if options.flatten { try editor.flattenForms() }
        if options.compress {
            let current = editor.document
            var rebuilt: [Int: PDFPage] = [:]
            for index in 0..<current.pageCount {
                guard let page = current.page(at: index), PDFProcessing.isImageDominant(page),
                      let new = PDFProcessing.compressedPage(from: page, preset: options.preset) else { continue }
                rebuilt[index] = new
                try Task.checkCancellation()
                await Task.yield()
            }
            try editor.replace(pages: rebuilt)
        }
        guard let data = editor.document.dataRepresentation() else { throw PDFEditing.EditError.cannotSerialize }
        return data
    }

    /// `name-批次.pdf`, then `name-批次 2.pdf`, and so on. An existing file is never replaced.
    static func outputURL(for input: URL, in folder: URL) -> URL {
        let base = input.deletingPathExtension().lastPathComponent + "-批次"
        var candidate = folder.appendingPathComponent(base + ".pdf")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) && counter < 1000 {
            candidate = folder.appendingPathComponent("\(base) \(counter).pdf"); counter += 1
        }
        return candidate
    }
}

@MainActor @Observable
final class BatchModel {
    var files: [URL] = []
    var outcomes: [URL: BatchProcessor.Outcome] = [:]
    var options = BatchProcessor.Options()
    var folder: URL?
    private(set) var running = false
    private(set) var finished = false
    private var task: Task<Void, Never>?

    var canStart: Bool { !files.isEmpty && folder != nil && !options.isEmpty && !running }

    func add(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" && !files.contains(url) {
            files.append(url); outcomes[url] = .waiting
        }
        finished = false
    }
    func remove(_ url: URL) { files.removeAll { $0 == url }; outcomes[url] = nil }

    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.message = L("選擇要批次處理的 PDF。")
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = L("選擇輸出資料夾。結果會存成新檔，不會覆寫任何檔案。")
        if panel.runModal() == .OK { folder = panel.url }
    }

    func start() {
        guard canStart, let folder else { return }
        running = true; finished = false
        for url in files { outcomes[url] = .waiting }
        let list = files, options = options
        task = Task { [weak self] in
            let folderScoped = folder.startAccessingSecurityScopedResource()
            defer { if folderScoped { folder.stopAccessingSecurityScopedResource() } }
            for url in list {
                guard let self, !Task.isCancelled else { break }
                self.outcomes[url] = .running
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let document = PDFDocument(url: url) else { self.outcomes[url] = .failed(L("無法讀取")); continue }
                do {
                    let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let data = try await BatchProcessor.process(document, options: options)
                    let target = BatchProcessor.outputURL(for: url, in: folder)
                    try PDFEditing.writeNew(data: data, to: target)
                    let formatter = ByteCountFormatter(); formatter.countStyle = .file
                    self.outcomes[url] = .done(before > 0 ? "\(formatter.string(fromByteCount: Int64(before))) → \(formatter.string(fromByteCount: Int64(data.count)))" : target.lastPathComponent)
                } catch is CancellationError { self.outcomes[url] = .skipped(L("已取消")) }
                catch let error as PDFEditing.EditError {
                    switch error {
                    case .encryptedInput, .signatureField: self.outcomes[url] = .skipped(error.localizedDescription)
                    default: self.outcomes[url] = .failed(error.localizedDescription)
                    }
                } catch { self.outcomes[url] = .failed(error.localizedDescription) }
            }
            self?.running = false; self?.finished = true
        }
    }
    func cancel() { task?.cancel() }
}
