import AppKit
import SwiftUI

/// A folder's Settings (⌘,): its own window, not a sheet — it doesn't block
/// the workspace, it can sit beside it while you watch a sandbox rebuild, and
/// it opens on the pane you used last. One per workspace window.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ObjectIdentifier: SettingsWindowController] = [:]
    private static let lastPaneKey = "settingsLastPane"

    /// The workspace window it belongs to (closed with it).
    private(set) weak var workspaceWindow: NSWindow?
    private let controller: WorkspaceController

    /// Show `controller`'s settings (on `pane`, else the last one used).
    static func show(for controller: WorkspaceController, pane: InspectorPane? = nil, owner: NSWindow?) {
        let key = ObjectIdentifier(controller)
        let settings = open[key] ?? SettingsWindowController(controller: controller, owner: owner)
        open[key] = settings
        settings.select(pane ?? lastPane)
        settings.showWindow(nil)
        settings.window?.makeKeyAndOrderFront(nil)
    }

    /// The open Settings window of a workspace window, if any.
    static func window(for owner: NSWindow) -> NSWindow? {
        open.values.first { $0.workspaceWindow === owner }?.window
    }

    /// Close the Settings window of `owner` (its workspace window is closing).
    static func close(for owner: NSWindow) {
        for settings in open.values where settings.workspaceWindow === owner { settings.close() }
    }

    static var lastPane: InspectorPane {
        UserDefaults.standard.string(forKey: lastPaneKey).flatMap(InspectorPane.init(rawValue:)) ?? .general
    }

    private init(controller: WorkspaceController, owner: NSWindow?) {
        self.controller = controller
        self.workspaceWindow = owner
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "\(controller.rootURL.lastPathComponent) Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func select(_ pane: InspectorPane) {
        let key = Self.lastPaneKey
        let close: () -> Void = { [weak self] in self?.close() }
        let remember: (InspectorPane) -> Void = { p in UserDefaults.standard.set(p.rawValue, forKey: key) }
        let view = InspectorView(controller: controller, initialPane: pane, onClose: close, onPaneChange: remember)
        guard let window else { return }
        let wasVisible = window.isVisible
        window.contentViewController = NSHostingController(rootView: view)
        remember(pane)
        if !wasVisible, !window.setFrameUsingName("SettingsWindow") { window.center() }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[ObjectIdentifier(controller)] = nil
    }
}
