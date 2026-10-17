import SwiftUI

/// Hosts the setup wizard in its own window (first launch + Open Folder).
@MainActor
final class SetupWindowController: NSWindowController {
    init(welcome: Bool,
         onCreate: @escaping (URL, RootProfile, MountPolicy, [String]) -> Void,
         onDefault: @escaping () -> Void = {}) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        super.init(window: window)
        let view = SetupWizardView(
            welcome: welcome,
            defaultRoot: WorkspaceBootstrap.defaultRoot,
            onCreate: { [weak self] url, profile, policy, kits in
                onCreate(url, profile, policy, kits); self?.close()
            },
            onDefault: { [weak self] in onDefault(); self?.close() },
            onCancel: { [weak self] in self?.close() },
            onOpenExisting: { [weak self] url in
                Log.info(.app, "setup: \(url.path(percentEncoded: false)) is a known workspace — opening directly")
                (NSApp.delegate as? AppDelegate)?.openWorkspace(url)
                self?.close()
            })
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
