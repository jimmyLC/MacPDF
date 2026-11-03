import AppKit
import SwiftUI
import PDFKit

/// The sole owner of document windows, used by Finder and in-app opens alike.
@MainActor final class PDFWindows: NSObject {
    static let shared = PDFWindows()
    private(set) var controllers: [NSWindowController] = []
    private var models: [ObjectIdentifier: ReaderModel] = [:]
    let present: Bool
    init(present: Bool = true) {
        self.present = present
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(closed(_:)), name: NSWindow.willCloseNotification, object: nil)
    }
    /// The model of the key document window, for menu-bar commands.
    var keyModel: ReaderModel? {
        let controller = controllers.first { $0.window?.isKeyWindow == true }
            ?? controllers.first { $0.window?.isMainWindow == true }
            ?? controllers.last { $0.window?.isVisible == true }
        return controller.flatMap { models[ObjectIdentifier($0)] }
    }
    func showWelcomeIfNeeded() {
        if controllers.isEmpty { _ = createWindow() }
    }
    func open(_ urls: [URL]) {
        for url in urls {
            if let existing = controllers.first(where: { models[ObjectIdentifier($0)]?.sourceURL?.standardizedFileURL == url.standardizedFileURL }) {
                if present { existing.showWindow(nil) }
                continue
            }
            let controller = controllers.first { controller in
                guard let model = models[ObjectIdentifier(controller)] else { return false }
                return model.document == nil && !model.needsPassword && model.error == nil
            } ?? createWindow()
            guard let model = models[ObjectIdentifier(controller)] else { continue }
            model.open(url)
            controller.window?.title = model.title
            if present { controller.showWindow(nil) }
        }
    }
    private var compareControllers: [NSWindowController] = []

    /// A new unsaved document built in the app (not read from a file).
    func openNew(_ document: PDFDocument, title: String) {
        let controller = controllers.first { controller in
            guard let model = models[ObjectIdentifier(controller)] else { return false }
            return model.document == nil && !model.needsPassword && model.error == nil
        } ?? createWindow()
        guard let model = models[ObjectIdentifier(controller)] else { return }
        model.adoptNew(document, title: title)
        controller.window?.title = model.title
        if present { controller.showWindow(nil) }
    }

    /// Asks for two PDFs (older first by modification date) and opens a side-by-side comparison.
    func chooseAndCompare() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.message = L("選擇要比較的兩份 PDF。修改時間較早的會當作舊版，之後可以對調。")
        guard panel.runModal() == .OK else { return }
        guard panel.urls.count == 2 else {
            let alert = NSAlert(); alert.messageText = L("請剛好選擇兩份 PDF。"); alert.runModal(); return
        }
        let dated = panel.urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        compare(old: dated[0], new: dated[1])
    }

    func openBatch() {
        let model = BatchModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L("批次處理")
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 780, height: 480)
        window.contentViewController = NSHostingController(rootView: BatchView(model: model))
        window.setContentSize(NSSize(width: 900, height: 600))
        let controller = NSWindowController(window: window)
        compareControllers.append(controller)
        window.center()
        controller.showWindow(nil)
    }

    func compare(old: URL, new: URL) {
        let model = CompareModel()
        let scoped = [old, new].map { ($0, $0.startAccessingSecurityScopedResource()) }
        model.load(old: old, new: new)
        scoped.forEach { if $0.1 { $0.0.stopAccessingSecurityScopedResource() } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(format: L("比較：%@ ↔ %@"), old.lastPathComponent, new.lastPathComponent)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 980, height: 560)
        window.contentViewController = NSHostingController(rootView: CompareView(model: model))
        window.setContentSize(NSSize(width: 1280, height: 800))
        let controller = NSWindowController(window: window)
        compareControllers.append(controller)
        window.center()
        controller.showWindow(nil)
    }

    private func createWindow() -> NSWindowController {
        let model = ReaderModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = model.title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 780, height: 520)
        window.contentViewController = NSHostingController(rootView: ReaderView(model: model) { [weak self] url in self?.open([url]) })
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.tabbingIdentifier = "MacPDF.document"
        let wantsTabs = UserDefaults.standard.bool(forKey: Preferences.tabsKey)
        window.tabbingMode = wantsTabs ? .preferred : .disallowed
        let controller = NSWindowController(window: window)
        controllers.append(controller)
        models[ObjectIdentifier(controller)] = model
        OpenDocuments.shared.models.add(model)
        window.center()
        // The size and place of the last document window come back next time, on the same screen.
        window.setFrameAutosaveName("MacPDF.document")
        // A remembered frame that is too small or no longer on any screen is not used.
        let remembered = window.frame
        if remembered.width < window.minSize.width || remembered.height < window.minSize.height
            || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(remembered) }) {
            window.setContentSize(NSSize(width: 1100, height: 760)); window.center()
        }
        if present { controller.showWindow(nil) }
        return controller
    }
    @objc private func closed(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        compareControllers.removeAll { $0.window === window }
        guard let controller = controllers.first(where: { $0.window === window }) else { return }
        models.removeValue(forKey: ObjectIdentifier(controller))
        controllers.removeAll { $0 === controller }
    }
}
