import AppKit
import SwiftUI

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
        let controller = NSWindowController(window: window)
        controllers.append(controller)
        models[ObjectIdentifier(controller)] = model
        OpenDocuments.shared.models.add(model)
        window.center()
        if present { controller.showWindow(nil) }
        return controller
    }
    @objc private func closed(_ note: Notification) {
        guard let window = note.object as? NSWindow, let controller = controllers.first(where: { $0.window === window }) else { return }
        models.removeValue(forKey: ObjectIdentifier(controller))
        controllers.removeAll { $0 === controller }
    }
}
