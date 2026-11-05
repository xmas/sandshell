import AppKit
import Testing
@testable import Sandshell

/// Panning a board (`CanvasView`): the bug was that a scroll over an artboard
/// went to its page, so a board zoomed in — artboards filling the view —
/// panned only while the pointer happened to be over empty space.
@MainActor
struct CanvasPanningTests {
    private func canvas() async throws -> (CanvasView, NSWindow, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandshell-pan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"title": "Pan", "artboards": [{"id": "a", "file": "a.html", "width": 1200, "height": 900}]}"#.utf8)
            .write(to: folder.appending(path: CanvasBoard.fileName))
        try Data(#"<body style="margin:0"><div style="height:6000px">Tall</div></body>"#.utf8).write(to: folder.appending(path: "a.html"))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = CanvasView(frame: window.contentView!.bounds)
        canvas.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(canvas)
        window.orderFrontRegardless()   // offscreen; a scroll view only scrolls in a window that's in
        canvas.show(folder)
        canvas.layoutSubtreeIfNeeded()
        canvas.zoomToFit()
        // Loaded, as on screen: a page with nothing in it yet passes scrolls on anyway.
        let end = Date().addingTimeInterval(10)
        while canvas.debugLoadedCount < 1, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        try #require(canvas.debugLoadedCount == 1)
        return (canvas, window, folder)
    }

    /// A scroll view may scroll a moment later: let the run loop turn.
    private func scroll(_ canvas: CanvasView, dx: Int32, dy: Int32, option: Bool = false) {
        canvas.debugScroll(over: "a", dx: dx, dy: dy, option: option)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @Test func scrollingOverAPageWhileZoomedInPansTheBoard() async throws {
        let (canvas, window, folder) = try await canvas()
        defer { canvas.show(nil); window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.zoom(by: 4)
        #expect(canvas.debugMagnification > 1)
        let before = canvas.debugVisibleOrigin
        scroll(canvas, dx: -60, dy: -40)
        let after = canvas.debugVisibleOrigin
        #expect(after.x > before.x, "Right")
        #expect(after.y > before.y, "Down, and both at once")
    }

    /// The page is taller than its artboard, so it has somewhere to scroll
    /// (one that can't passes the scroll on, and the board pans).
    @Test func optionScrollGoesToThePage() async throws {
        let (canvas, window, folder) = try await canvas()
        defer { canvas.show(nil); window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.zoom(by: 4)
        let before = canvas.debugVisibleOrigin
        scroll(canvas, dx: -60, dy: -40, option: true)
        #expect(canvas.debugVisibleOrigin == before)
    }

    @Test func aFittedBoardStillPansButNeverOutOfSight() async throws {
        let (canvas, window, folder) = try await canvas()
        defer { canvas.show(nil); window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        let fitted = canvas.debugVisibleOrigin
        scroll(canvas, dx: -60, dy: -40)
        #expect(canvas.debugVisibleOrigin != fitted, "Pans though it all fits")
        for _ in 0..<30 { scroll(canvas, dx: -3000, dy: -3000) }
        let far = canvas.debugVisibleOrigin
        for _ in 0..<3 { scroll(canvas, dx: -3000, dy: -3000) }
        #expect(canvas.debugVisibleOrigin == far, "Stops with the board still in view")
    }
}
