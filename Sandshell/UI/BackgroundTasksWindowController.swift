import SwiftUI

/// Window ▸ Background Tasks: every session's background work in this window.
@MainActor
final class BackgroundTasksWindowController: NSWindowController {
    init(controller: WorkspaceController, title: String,
         loadOutput: @escaping (UUID, BackgroundTask) async -> String?,
         onSelectSession: @escaping (UUID) -> Void,
         canStop: ((UUID, BackgroundTask) -> Bool)? = nil,
         stopTask: ((UUID, BackgroundTask) async -> Bool)? = nil) {
        let view = BackgroundTasksView(
            controller: controller,
            sessionIDs: { [weak controller] in controller?.orderedSessions.map(\.id) ?? [] },
            loadOutput: loadOutput,
            onSelectSession: onSelectSession,
            stopTask: stopTask, canStop: canStop)
        let hosting = NSHostingController(rootView: view.frame(minWidth: 380, minHeight: 260))
        let window = NSPanel(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel]
        window.title = "Background Tasks — \(title)"
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.setContentSize(NSSize(width: 460, height: 420))
        // Each window's panel remembers its own frame (a name in use by another
        // window's panel can't be shared: take the next one).
        for n in 0..<20 where window.setFrameAutosaveName(n == 0 ? "BackgroundTasksPanel" : "BackgroundTasksPanel \(n + 1)") {
            break
        }
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
