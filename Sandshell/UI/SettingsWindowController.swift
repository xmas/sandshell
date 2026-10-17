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
    /// The pane shown; the view is built once, so showing the window again
    /// keeps a pane's unapplied edits (and any confirmation it has up).
    private let selection: InspectorSelection

    /// Show `controller`'s settings: an open window as it is, or on `pane`
    /// when one is asked for; a new one on `pane`, else the last one used.
    static func show(for controller: WorkspaceController, pane: InspectorPane? = nil, owner: NSWindow?) {
        let key = ObjectIdentifier(controller)
        let settings: SettingsWindowController
        if let existing = open[key] {
            settings = existing
            if let pane { settings.selection.select(pane) }
        } else {
            settings = SettingsWindowController(controller: controller, pane: pane ?? lastPane, owner: owner)
            open[key] = settings
        }
        settings.showWindow(nil)
        settings.window?.makeKeyAndOrderFront(nil)
    }

    /// The open Settings window of a workspace window, if any.
    static func window(for owner: NSWindow) -> NSWindow? {
        open.values.first { $0.workspaceWindow === owner }?.window
    }

    /// The open Settings window of `controller`'s workspace, if any — for a
    /// pane's alert to come up as a sheet on it.
    static func window(for controller: WorkspaceController) -> NSWindow? {
        open[ObjectIdentifier(controller)]?.window
    }

    /// Close the Settings window of `owner` (its workspace window is closing).
    static func close(for owner: NSWindow) {
        for settings in open.values where settings.workspaceWindow === owner { settings.close() }
    }

    static var lastPane: InspectorPane {
        UserDefaults.standard.string(forKey: lastPaneKey).flatMap(InspectorPane.init(rawValue:)) ?? .general
    }

    private init(controller: WorkspaceController, pane: InspectorPane, owner: NSWindow?) {
        self.controller = controller
        self.workspaceWindow = owner
        self.selection = InspectorSelection(pane)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "\(controller.rootURL.lastPathComponent) Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        window.delegate = self
        let key = Self.lastPaneKey
        let remember: (InspectorPane) -> Void = { p in UserDefaults.standard.set(p.rawValue, forKey: key) }
        let view = InspectorView(controller: controller, selection: selection,
                                 onClose: { [weak self] in self?.close() }, onPaneChange: remember)
        window.contentViewController = NSHostingController(rootView: view)
        remember(selection.pane)
        if !window.setFrameUsingName("SettingsWindow") { window.center() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.open[ObjectIdentifier(controller)] = nil
    }
}
