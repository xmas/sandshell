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

/// Notes on artboards (`CanvasNote`, `CanvasView`): what the agent gets.
@MainActor
struct CanvasNoteTests {
    private func board() -> CanvasBoard {
        CanvasBoard(folder: URL(filePath: "/w/.sandshell/canvas/onboarding"), title: "Onboarding", artboards: [
            .init(id: "welcome", title: "Welcome", file: "welcome.html", url: nil, x: nil, y: nil, width: 390, height: 844),
            .init(id: "app", title: "App", file: nil, url: URL(string: "http://localhost:5173/"), x: nil, y: nil, width: 800, height: 600),
        ])
    }

    @Test func oneNoteNamesTheBoardArtboardAndElement() {
        let note = CanvasNote(artboard: "welcome", point: .zero,
                              element: .init(selector: "main > button.cta", text: "Get started"), text: "Make this bolder")
        #expect(CanvasNote.message([note], board: board()) == """
        Canvas note on “Onboarding” (/w/.sandshell/canvas/onboarding):

        Artboard `welcome` (welcome.html), at `main > button.cta` (“Get started”):
        Make this bolder
        """)
    }

    @Test func severalNotesGoAsOneNumberedMessage() {
        let message = CanvasNote.message([
            CanvasNote(artboard: "welcome", point: .zero, element: nil, text: "First"),
            CanvasNote(artboard: "app", point: .zero, element: .init(selector: "body", text: ""), text: "Second"),
        ], board: board())
        #expect(message.hasPrefix("Canvas notes on"))
        #expect(message.contains("1. Artboard `welcome` (welcome.html):\nFirst"))
        #expect(message.contains("2. Artboard `app`, at `body`:\nSecond"), "A URL artboard has no file, and no text means no quote")
    }

    @Test func aMarkedScreenshotIsAPicture() throws {
        let image = NSImage(size: NSSize(width: 100, height: 80), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let png = try #require(CanvasNote.markedPNG(image, marks: [(number: 1, point: CGPoint(x: 20, y: 10))]))
        let marked = try #require(NSBitmapImageRep(data: png))
        #expect(marked.pixelsWide >= 100)
        let scale = CGFloat(marked.pixelsWide) / 100
        // Top left in page terms, so a flipped image would put it at the bottom.
        let hit = try #require(marked.colorAt(x: Int(20 * scale), y: Int(4 * scale))?.usingColorSpace(.sRGB))
        #expect(hit.redComponent > 0.7 && hit.blueComponent < 0.5, "The mark is where the note points")
    }

    private func canvas(_ html: String) async throws -> (CanvasView, NSWindow, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandshell-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"title": "Notes", "artboards": [{"id": "a", "file": "a.html", "width": 400, "height": 300}]}"#.utf8)
            .write(to: folder.appending(path: CanvasBoard.fileName))
        try Data(html.utf8).write(to: folder.appending(path: "a.html"))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = CanvasView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(canvas)
        window.orderFrontRegardless()
        canvas.show(folder)
        canvas.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(10)
        while canvas.debugLoadedCount < 1, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        try #require(canvas.debugLoadedCount == 1)
        return (canvas, window, folder)
    }

    @Test func thePageSaysWhatsAtAPoint() async throws {
        let (canvas, window, folder) = try await canvas("""
        <body style="margin:0"><main id="m"><p>Intro</p>
        <button class="cta big" style="position:absolute;left:50px;top:100px;width:200px;height:50px">  Get   started </button></main></body>
        """)
        defer { window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        let element = try #require(await canvas.debugElement("a", at: CGPoint(x: 100, y: 120)))
        #expect(element.selector == "main#m > button.cta.big")
        #expect(element.text == "Get started")
    }

    /// ⌥-click asks for a note about what's under the pointer; a plain click is the page's.
    @Test func optionClickStartsANoteOnWhatsThere() async throws {
        let (canvas, window, folder) = try await canvas("""
        <body style="margin:0"><div id="top" style="height:100px">Top</div><div id="low" style="height:200px">Low</div></body>
        """)
        defer { window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.debugClick("a", at: CGPoint(x: 20, y: 250), option: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(canvas.debugNoteElement == nil)
        canvas.debugClick("a", at: CGPoint(x: 20, y: 250), option: true)
        let end = Date().addingTimeInterval(5)
        while canvas.debugNoteElement == nil, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        #expect(canvas.debugNoteElement?.selector == "div#low", "From the top of the page: a flipped point would land on #top")
        #expect(canvas.debugNotePopoverShown)
    }

    @Test func notesPinThenGoAsOneMessageWithAShot() async throws {
        let (canvas, window, folder) = try await canvas(#"<body style="background:#fff"><p>Hi</p></body>"#)
        defer { window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        #expect(!canvas.debugNotesBarShown)
        canvas.addNote(CanvasNote(artboard: "a", point: CGPoint(x: 10, y: 10), element: nil, text: "One"))
        canvas.addNote(CanvasNote(artboard: "a", point: CGPoint(x: 90, y: 40), element: nil, text: "Two"))
        #expect(canvas.debugPins("a") == 2)
        #expect(canvas.debugNotesBarText == "2 notes")
        var sent: (String, [ChatAttachment])?
        canvas.onSendNotes = { sent = ($0, $1); return true }
        await canvas.sendNotes()
        let (text, shots) = try #require(sent)
        #expect(text.contains("One") && text.contains("Two"))
        #expect(shots.count == 1, "One shot per artboard")
        guard case .image(_, let mime, let name)? = shots.first?.kind else {
            Issue.record("Not an image")
            return
        }
        #expect(mime == "image/png" && name == "a.png")
        #expect(canvas.notes.isEmpty && !canvas.debugNotesBarShown && canvas.debugPins("a") == 0)
    }

    @Test func notesStayIfThereIsNoChat() async throws {
        let (canvas, window, folder) = try await canvas("<p>Hi</p>")
        defer { window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.addNote(CanvasNote(artboard: "a", point: .zero, element: nil, text: "Keep me"))
        canvas.onSendNotes = { _, _ in false }
        await canvas.sendNotes()
        #expect(canvas.notes.count == 1)
    }
}
