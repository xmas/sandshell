import AppKit
import SwiftUI

/// A terminal session's search window (⌘F): its scrollback, searched.
@MainActor
final class TerminalSearchWindowController: NSWindowController, NSWindowDelegate {
    let model = TerminalSearchModel()
    var onClose: (() -> Void)?

    init(sessionName: String) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Search — \(sessionName)"
        w.isRestorable = false
        w.center()
        super.init(window: w)
        w.delegate = self
        w.contentViewController = NSHostingController(
            rootView: TerminalSearchView(model: model, onClose: { [weak self] in self?.close() })
        )
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func loadText(_ text: String) { model.load(text: text) }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
