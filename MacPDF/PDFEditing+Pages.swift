import AppKit
import PDFKit

/// Blank pages and splitting into several files.
extension PDFEditing {
    /// Adds an empty page the size of `reference` as seen on screen. `after` false puts it in front.
    func insertBlankPage(relativeTo reference: Int, after: Bool) throws {
        try mutate { doc in
            guard let page = doc.page(at: reference) else { throw EditError.invalidPage }
            let box = page.bounds(for: .cropBox)
            let sideways = page.rotation % 180 != 0
            let size = CGSize(width: sideways ? box.height : box.width, height: sideways ? box.width : box.height)
            let blank = PDFPage()
            let area = CGRect(origin: .zero, size: size)
            blank.setBounds(area, for: .mediaBox)
            blank.setBounds(area, for: .cropBox)
            doc.insert(blank, at: after ? reference + 1 : reference)
        }
        reparse()
    }

    /// "1-3, 5, 8-10" (also full-width commas and dashes) as page ranges, in the order written.
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let folded = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let normalized = folded.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "－", with: "-")
        var ranges: [ClosedRange<Int>] = []
        for piece in normalized.split(separator: ",") {
            let parts = piece.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count <= 2, let first = Int(parts[0]) else { throw EditError.invalidPage }
            let last = parts.count == 2 ? Int(parts[1]) : first
            guard let last, first >= 1, last >= first, last <= pageCount else { throw EditError.invalidPage }
            ranges.append(first...last)
        }
        guard !ranges.isEmpty else { throw EditError.invalidPage }
        return ranges
    }

    /// Writes each range as its own new file in `folder`, named `base-001.pdf` or `base-001-003.pdf`.
    /// Existing files are never replaced; a number is added instead. Returns the files written.
    @discardableResult
    func split(ranges: [ClosedRange<Int>], into folder: URL, baseName: String) throws -> [URL] {
        guard !document.isEncrypted else { throw EditError.encryptedInput }
        guard !Self.containsSignatureField(document) else { throw EditError.signatureField }
        guard ranges.allSatisfy({ $0.lowerBound >= 1 && $0.upperBound <= document.pageCount }) else { throw EditError.invalidPage }
        let width = max(3, String(document.pageCount).count)
        func number(_ n: Int) -> String { String(format: "%0\(width)d", n) }
        var written: [URL] = []
        for range in ranges {
            let output = PDFDocument()
            try Self.copyPages(from: document, range: (range.lowerBound - 1)..<range.upperBound, into: output)
            let stem = range.count == 1 ? "\(baseName)-\(number(range.lowerBound))" : "\(baseName)-\(number(range.lowerBound))-\(number(range.upperBound))"
            var target = folder.appendingPathComponent(stem + ".pdf")
            var counter = 2
            while FileManager.default.fileExists(atPath: target.path) && counter < 1000 {
                target = folder.appendingPathComponent("\(stem) \(counter).pdf"); counter += 1
            }
            guard let data = output.dataRepresentation() else { throw EditError.cannotSerialize }
            try Self.writeNew(data: data, to: target)
            written.append(target)
        }
        return written
    }
}

// MARK: Several pages at once

extension PDFEditing {
    static func cleanPages(_ pages: [Int], count: Int) throws -> [Int] {
        let unique = Array(Set(pages)).sorted()
        guard !unique.isEmpty, unique.allSatisfy({ $0 >= 0 && $0 < count }) else { throw EditError.invalidPage }
        return unique
    }

    func rotate(pages: [Int]) throws {
        try mutate { doc in
            for index in try Self.cleanPages(pages, count: doc.pageCount) {
                guard let page = doc.page(at: index) else { throw EditError.invalidPage }
                page.rotation = (page.rotation + 90) % 360
            }
        }
    }

    func delete(pages: [Int]) throws {
        try mutate { doc in
            let doomed = try Self.cleanPages(pages, count: doc.pageCount)
            guard doomed.count < doc.pageCount else { throw EditError.lastPage }
            for index in doomed.reversed() { doc.removePage(at: index) }
        }
        reparse()
    }

    /// Moves the pages, keeping their order, so they sit in front of the page that is currently at `destination`
    /// (`pageCount` means the very end). Returns where the moved pages end up.
    @discardableResult
    func move(pages: [Int], before destination: Int) throws -> [Int] {
        var placed: [Int] = []
        try mutate { doc in
            let moving = try Self.cleanPages(pages, count: doc.pageCount)
            guard destination >= 0, destination <= doc.pageCount else { throw EditError.invalidPage }
            let objects = moving.compactMap { doc.page(at: $0) }
            guard objects.count == moving.count else { throw EditError.invalidPage }
            let target = destination - moving.filter { $0 < destination }.count
            for index in moving.reversed() { doc.removePage(at: index) }
            for (offset, page) in objects.enumerated() { doc.insert(page, at: target + offset) }
            placed = (0..<objects.count).map { target + $0 }
        }
        reparse()
        return placed
    }

    /// Puts a copy of each page right after the last of them, keeping their order.
    @discardableResult
    func duplicate(pages: [Int]) throws -> [Int] {
        var placed: [Int] = []
        try mutate { doc in
            let chosen = try Self.cleanPages(pages, count: doc.pageCount)
            let copies = try chosen.map { index -> PDFPage in
                guard let copy = doc.page(at: index)?.copy() as? PDFPage else { throw EditError.invalidPage }
                return copy
            }
            let start = chosen[chosen.count - 1] + 1
            for (offset, copy) in copies.enumerated() { doc.insert(copy, at: start + offset) }
            placed = (0..<copies.count).map { start + $0 }
        }
        reparse()
        return placed
    }

    /// Writes the chosen pages, in document order, as one new file.
    func extract(pageList: [Int], to url: URL) throws {
        guard !document.isEncrypted else { throw EditError.encryptedInput }
        guard !Self.containsSignatureField(document) else { throw EditError.signatureField }
        let chosen = try Self.cleanPages(pageList, count: document.pageCount)
        let output = PDFDocument()
        var start = chosen[0], previous = chosen[0]
        for index in chosen.dropFirst() + [Int.max] {
            if index == previous + 1 { previous = index; continue }
            try Self.copyPages(from: document, range: start..<(previous + 1), into: output)
            start = index; previous = index
        }
        try Self.writeNew(output, to: url)
    }
}

// MARK: Saving over the original

extension PDFEditing {
    static var defaultBackupFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MacPDF/Backups", isDirectory: true)
    }

    /// Copies the current file to `backupFolder`, then replaces it in one step. If the backup cannot be made the
    /// original is left untouched. Returns the backup file.
    @discardableResult
    static func overwrite(_ url: URL, with data: Data, backupFolder: URL) throws -> URL {
        guard PDFDocument(data: data) != nil else { throw EditError.cannotSerialize }
        let manager = FileManager.default
        try manager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent + "-" + formatter.string(from: Date())
        var backup = backupFolder.appendingPathComponent(stem + ".pdf")
        var counter = 2
        while manager.fileExists(atPath: backup.path) && counter < 1000 { backup = backupFolder.appendingPathComponent("\(stem) \(counter).pdf"); counter += 1 }
        do { try manager.copyItem(at: url, to: backup) } catch { throw EditError.writeFailed(L("無法備份原檔，所以沒有覆寫。")) }
        let original = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        let copied = (try? manager.attributesOfItem(atPath: backup.path)[.size] as? Int) ?? -2
        guard original == copied else { try? manager.removeItem(at: backup); throw EditError.writeFailed(L("備份和原檔大小不一致，所以沒有覆寫。")) }
        let staging: URL
        do { staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true) }
        catch { throw EditError.writeFailed(L("此儲存位置不支援安全覆寫，請改用另存新檔。")) }
        defer { try? manager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("MacPDF-new.pdf")
        try data.write(to: staged)
        do { _ = try manager.replaceItemAt(url, withItemAt: staged) } catch { throw EditError.writeFailed(error.localizedDescription) }
        return backup
    }

    func overwriteOriginal(at url: URL, backupFolder: URL = PDFEditing.defaultBackupFolder) throws -> URL {
        guard !document.isEncrypted else { throw EditError.encryptedInput }
        guard allowSignatureFieldEdits || !Self.containsSignatureField(document) else { throw EditError.signatureField }
        guard let data = document.dataRepresentation() else { throw EditError.cannotSerialize }
        let backup = try Self.overwrite(url, with: data, backupFolder: backupFolder)
        markDiscarded()
        return backup
    }
}
