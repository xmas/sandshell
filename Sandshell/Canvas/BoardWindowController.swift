import AppKit

/// A Canvas board in a window of its own, full screen: a design to look at
/// big (or on another display) while its chat goes on in the workspace window.
/// It's the same live board — it reloads as the agent writes — and one window
/// per board: opening it again brings that window forward.
@MainActor
final class BoardWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [URL: BoardWindowController] = [:]

    let folder: URL
    private let canvas = CanvasView()

    /// Open `folder`'s board in its window (made full screen), or bring it forward.
    @discardableResult
    static func show(_ folder: URL, fullScreen: Bool = true) -> BoardWindowController {
        let key = folder.standardizedFileURL
        if let existing = open[key] {
            existing.bringForward()
            return existing
        }
        let controller = BoardWindowController(folder: key)
        open[key] = controller
        controller.bringForward()
        if fullScreen, !AutomatedRun.isActive, !AppDelegate.isHostingTests { controller.window?.toggleFullScreen(nil) }
        return controller
    }

    /// On screen and key (made, not shown, under unit tests).
    private func bringForward() {
        guard !AppDelegate.isHostingTests else { return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The open board windows.
    static var windows: [BoardWindowController] { Array(open.values) }

    private init(folder: URL) {
        self.folder = folder
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("CanvasBoardWindow")
        super.init(window: window)
        window.delegate = self
        window.contentView = canvas
        canvas.show(folder)
        window.title = canvas.board?.title ?? folder.lastPathComponent
        window.subtitle = "Canvas"
        window.representedURL = folder
        if !window.setFrameUsingName("CanvasBoardWindow") { window.center() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowDidEnterFullScreen(_ notification: Notification) { canvas.zoomToFit() }
    func windowDidExitFullScreen(_ notification: Notification) { canvas.zoomToFit() }

    func windowWillClose(_ notification: Notification) {
        Self.open[folder] = nil
    }

    #if DEBUG
    var debugCanvas: CanvasView { canvas }
    #endif
}
