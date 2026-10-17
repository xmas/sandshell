import SwiftUI

/// Window controller for the Open Workspaces dialog.
final class OpenWindowController: NSWindowController {
    init(onOpen: @escaping (URL) -> Void, onOpenNew: @escaping () -> Void) {
        let window = NSWindow()
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = "Open Workspace"
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.minSize = NSSize(width: 420, height: 320)
        super.init(window: window)

        let view = OpenFoldersView(
            onOpen: { [weak self] url in
                onOpen(url)
                self?.close()
            },
            onOpenNew: { [weak self] in onOpenNew(); self?.close() },
            onClose: { [weak self] in self?.close() })
        // Setting the content view controller resizes the window to the SwiftUI
        // view's fitting size (which for a ScrollView is tiny, so the window
        // collapsed to minSize). Don't let SwiftUI drive the window size; set
        // ours afterwards, then let a remembered user resize win over it.
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 520, height: 620))
        window.center()
        window.setFrameAutosaveName("OpenWorkspaceBrowser")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
