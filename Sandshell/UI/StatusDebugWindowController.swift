import SwiftUI

/// The sandbox status window (⌥-click the sidebar's ladybug): containers, kit
/// startup and session runtimes, live (see `StatusDebugView`).
@MainActor
final class StatusDebugWindowController: NSWindowController {
    init(controller: WorkspaceController) {
        let view = StatusDebugView(controller: controller)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sandbox Status  ·  ⌥ ladybug"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 600, height: 540))
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
