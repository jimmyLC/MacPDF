import AppKit
import SwiftUI

/// Preserve SwiftUI's delegate while intercepting a close with unsaved edits.
struct WindowCloseGuard: NSViewRepresentable {
    let model: ReaderModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let window = view?.window, let coordinator else { return }
            coordinator.install(on: window)
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window {
            window.title = model.title + (model.isDirty ? " •" : "")
            context.coordinator.install(on: window)
        }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: ReaderModel
        nonisolated(unsafe) weak var previous: (any NSWindowDelegate)?
        weak var window: NSWindow?
        init(model: ReaderModel) { self.model = model }
        func install(on window: NSWindow) {
            guard self.window !== window || window.delegate !== self else { return }
            self.window = window
            if window.delegate !== self { previous = window.delegate; window.delegate = self }
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if model.isDirty {
                let alert = NSAlert()
                alert.messageText = L("要儲存變更嗎？")
                alert.informativeText = L("未儲存的變更會遺失。可以另存新檔，或保留原始文件並丟棄修改。")
                alert.addButton(withTitle: L("另存新檔…"))
                alert.addButton(withTitle: L("取消"))
                alert.addButton(withTitle: L("丟棄變更"))
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    model.saveCopyWithPanel()
                    guard !model.isDirty else { return false }
                case .alertThirdButtonReturn:
                    guard model.discardChanges() else { return false }
                default: return false
                }
            }
            return previous?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previous?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previous?.responds(to: selector) == true { return previous }
            return super.forwardingTarget(for: selector)
        }
    }
}
