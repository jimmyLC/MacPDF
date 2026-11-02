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
        PDFWindows.shared.showWelcomeIfNeeded()
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
        }
        CommandMenu("文件") {
            Button("文字辨識（OCR）") { PDFWindows.shared.keyModel?.runOCR() }
            Button("壓縮…") { PDFWindows.shared.keyModel?.sheet = .compress }
            Divider()
            Button("清除表單欄位") { PDFWindows.shared.keyModel?.resetForm() }
            Button("扁平化表單") { PDFWindows.shared.keyModel?.flattenForms() }
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
