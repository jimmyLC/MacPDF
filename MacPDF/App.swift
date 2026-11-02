import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MacPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands { ReaderCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Lets UI checks run in a fixed appearance without touching the system setting.
        if let style = ProcessInfo.processInfo.environment["MACPDF_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: style == "light" ? .aqua : .darkAqua)
        }
        // MACPDF_COMPARE=/path/old.pdf:/path/new.pdf opens the comparison window directly.
        if let pair = ProcessInfo.processInfo.environment["MACPDF_COMPARE"]?.split(separator: ":").map(String.init), pair.count == 2 {
            PDFWindows.shared.compare(old: URL(fileURLWithPath: pair[0]), new: URL(fileURLWithPath: pair[1]))
        }
        #endif
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        PDFWindows.shared.showWelcomeIfNeeded()
    }
    /// Finder > Quick Actions / Services: "Open with MacPDF" for selected PDFs.
    @MainActor @objc func openPDFs(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        PDFWindows.shared.open(urls.filter { $0.pathExtension.lowercased() == "pdf" })
    }
    func application(_ sender: NSApplication, open urls: [URL]) {
        PDFWindows.shared.open(urls)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PDFWindows.shared.showWelcomeIfNeeded() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for model in OpenDocuments.shared.models.allObjects where model.isDirty {
            let alert = NSAlert()
            alert.messageText = String(format: L("要儲存 %@ 的變更嗎？"), model.title)
            alert.informativeText = L("結束前請另存新檔，或丟棄這份文件的修改。")
            alert.addButton(withTitle: L("另存新檔…")); alert.addButton(withTitle: L("取消")); alert.addButton(withTitle: L("丟棄變更"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                model.saveCopyWithPanel()
                if model.isDirty { return .terminateCancel }
            case .alertThirdButtonReturn:
                if !model.discardChanges() { return .terminateCancel }
            default: return .terminateCancel
            }
        }
        return .terminateNow
    }

}

struct ReaderCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("開啟 PDF…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.pdf]
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK { PDFWindows.shared.open(panel.urls) }
            }.keyboardShortcut("o")
            Button("比較兩份 PDF…") { PDFWindows.shared.chooseAndCompare() }
            Button("批次處理…") { PDFWindows.shared.openBatch() }
        }
        CommandMenu("文件") {
            Button("文字辨識（OCR）") { PDFWindows.shared.keyModel?.runOCR() }
            Button("壓縮…") { PDFWindows.shared.keyModel?.sheet = .compress }
            Divider()
            Button("清除表單欄位") { PDFWindows.shared.keyModel?.resetForm() }
            Button("扁平化表單") { PDFWindows.shared.keyModel?.flattenForms() }
            Divider()
            Button("塗黑敏感資訊…") { PDFWindows.shared.keyModel?.beginRedaction() }
            Divider()
            Button("編輯文件資訊…") { PDFWindows.shared.keyModel?.sheet = .metadata }
            Button("儲存加密副本…") { PDFWindows.shared.keyModel?.sheet = .encrypt }
            Button("儲存無密碼副本…") { PDFWindows.shared.keyModel?.exportUnlockedCopy() }
        }
    }
}

@MainActor final class OpenDocuments {
    static let shared = OpenDocuments()
    let models = NSHashTable<ReaderModel>.weakObjects()
}
