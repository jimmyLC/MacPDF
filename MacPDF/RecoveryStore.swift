import Foundation

struct RecoveryEntry: Identifiable, Codable {
    let id: UUID
    let title: String
    let updated: Date
}

struct RecoveryStore {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacPDF/Recovery", isDirectory: true)
    }
    private func file(_ id: UUID, _ ext: String) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext) }
    func save(id: UUID, title: String, data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file(id, "pdf"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id, "pdf").path)
        let entry = RecoveryEntry(id: id, title: title, updated: Date())
        try JSONEncoder().encode(entry).write(to: file(id, "json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id, "json").path)
    }
    func entries() -> [RecoveryEntry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        // A crash between the snapshot and manifest writes must not hide a recoverable PDF.
        return files.filter { $0.pathExtension == "pdf" }.compactMap { pdfURL in
            guard let id = UUID(uuidString: pdfURL.deletingPathExtension().lastPathComponent) else { return nil }
            if let data = try? Data(contentsOf: file(id, "json")),
               let entry = try? JSONDecoder().decode(RecoveryEntry.self, from: data), entry.id == id { return entry }
            let date = (try? pdfURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return RecoveryEntry(id: id, title: L("未命名恢復文件"), updated: date)
        }.sorted { $0.updated > $1.updated }
    }
    func url(for id: UUID) -> URL { file(id, "pdf") }
    func remove(_ id: UUID) throws {
        for ext in ["json", "pdf"] {
            let path = file(id, ext)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }
}
