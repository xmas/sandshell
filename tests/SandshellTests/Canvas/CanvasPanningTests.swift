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

    /// A trackpad gesture from start to finish, and what comes after it: the
    /// board was jumping to the bottom. It stays where the fingers left it.
    @Test func aTrackpadGesturePansAndStaysPut() async throws {
        let (canvas, window, folder) = try await canvas()
        defer { canvas.show(nil); window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.zoom(by: 2)
        let start = canvas.debugVisibleOrigin
        canvas.debugGesture(over: "a", dx: -30, dy: -20, phase: 1)
        for _ in 0..<5 { canvas.debugGesture(over: "a", dx: -30, dy: -20, phase: 2) }
        canvas.debugGesture(over: "a", dx: 0, dy: 0, phase: 4)
        let end = canvas.debugVisibleOrigin
        #expect(end.x > start.x && end.y > start.y)
        #expect(abs(end.x - start.x) < 800 && abs(end.y - start.y) < 800, "By what the fingers moved, no jump")
        try await Task.sleep(for: .milliseconds(500))
        #expect(canvas.debugVisibleOrigin == end, "Nothing moves it afterwards")
        canvas.debugGesture(over: "a", dx: 40, dy: 25, phase: 1)
        #expect(canvas.debugVisibleOrigin.x < end.x && canvas.debugVisibleOrigin.y < end.y, "And it comes back the other way")
    }

    @Test func scrollingEmptySpacePansTooInEveryDirection() async throws {
        let (canvas, window, folder) = try await canvas()
        defer { canvas.show(nil); window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        let start = canvas.debugVisibleOrigin
        canvas.debugScrollBoard(dx: 50, dy: -40)
        #expect(canvas.debugVisibleOrigin.x < start.x, "Left")
        #expect(canvas.debugVisibleOrigin.y > start.y, "Down: diagonal, both at once")
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
        #expect(abs(canvas.debugVisibleOrigin.x - far.x) < 0.5 && abs(canvas.debugVisibleOrigin.y - far.y) < 0.5,
                "Stops with the board still in view")
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

        Artboard `welcome` (welcome.html), at `main > button.cta` (“Get started”), point (0, 0):
        Make this bolder
        """)
    }

    @Test func severalNotesGoAsOneNumberedMessage() {
        let message = CanvasNote.message([
            CanvasNote(artboard: "welcome", point: .zero, element: nil, text: "First"),
            CanvasNote(artboard: "app", point: .zero, element: .init(selector: "body", text: ""), text: "Second"),
        ], board: board())
        #expect(message.hasPrefix("Canvas notes on"))
        #expect(message.contains("1. Artboard `welcome` (welcome.html), point (0, 0):\nFirst"))
        #expect(message.contains("2. Artboard `app`, at `body`, point (0, 0):\nSecond"), "A URL artboard has no file, and no text means no quote")
    }

    @Test func aMarkedScreenshotIsAPicture() throws {
        let image = NSImage(size: NSSize(width: 100, height: 80), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let png = try #require(CanvasNote.markedPNG(image, marks: [CanvasNote.Mark(number: 1, point: CGPoint(x: 20, y: 10))]))
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

    @Test func anAreaIsDescribedInTheMessage() {
        let note = CanvasNote(artboard: "welcome", point: CGPoint(x: 60, y: 90),
                              area: CGRect(x: 10, y: 20, width: 100, height: 140), element: nil, text: "Tighten this")
        #expect(CanvasNote.message([note], board: board()).contains("(welcome.html), area 100×140 at (10, 20):\nTighten this"))
    }

    private let cards = """
    <body style="margin:0"><section id="s" style="position:absolute;left:0;top:0;width:300px;height:200px">
    <div id="one" style="position:absolute;left:10px;top:10px;width:100px;height:50px">One</div>
    <div id="two" style="position:absolute;left:150px;top:10px;width:100px;height:50px">Two</div></section></body>
    """

    @Test func withCommentOffAClickIsThePages() async throws {
        let (canvas, window, folder) = try await canvas(cards)
        defer { window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        #expect(!canvas.debugOverlayShown("a"))
        canvas.setCommenting(true)
        #expect(canvas.debugOverlayShown("a"))
        canvas.setCommenting(false)
        #expect(!canvas.debugOverlayShown("a"))
    }

    @Test func aClickInCommentModeIsAboutWhatsThere() async throws {
        let (canvas, window, folder) = try await canvas(cards)
        defer { window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.setCommenting(true)
        canvas.layoutSubtreeIfNeeded()
        canvas.debugCommentGesture("a", from: CGPoint(x: 40, y: 30))
        let end = Date().addingTimeInterval(5)
        while canvas.debugNoteElement == nil, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        #expect(canvas.debugNoteElement?.selector == "section#s > div#one" || canvas.debugNoteElement?.selector == "div#one")
        #expect(canvas.debugNotePopoverShown)
    }

    @Test func aDragIsAboutTheSmallestThingAroundIt() async throws {
        let (canvas, window, folder) = try await canvas(cards)
        defer { window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.setCommenting(true)
        canvas.layoutSubtreeIfNeeded()
        canvas.debugCommentGesture("a", from: CGPoint(x: 30, y: 20), to: CGPoint(x: 220, y: 50))
        let end = Date().addingTimeInterval(5)
        while canvas.debugNoteElement == nil, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        #expect(canvas.debugNoteElement?.selector == "section#s", "Across both cards: their section")
    }

    @Test func aShakyClickIsAClickNotAnArea() async throws {
        let (canvas, window, folder) = try await canvas(cards)
        defer { window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.setCommenting(true)
        canvas.layoutSubtreeIfNeeded()
        canvas.debugCommentGesture("a", from: CGPoint(x: 40, y: 30), to: CGPoint(x: 43, y: 31))
        let end = Date().addingTimeInterval(5)
        while canvas.debugNoteElement == nil, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        #expect(canvas.debugNoteElement?.selector.hasSuffix("div#one") == true)
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

/// A design session offers its board again, once it's been closed.
@MainActor
struct ShowBoardButtonTests {
    @Test func theStripOffersItOnlyWhenAsked() {
        let strip = PaneStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        #expect(!strip.showsBoardButton)
        strip.showsBoardButton = true
        #expect(strip.showsBoardButton)
    }
}

/// Any session can have a board: making one, and telling a running chat.
@MainActor
struct SessionBoardTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "boards-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func eachNewBoardIsItsOwnAndLoads() throws {
        try withRoot { root in
            let first = try CanvasBoard.create(root: root)
            let second = try CanvasBoard.create(root: root)
            #expect(first.relative == ".sandshell/canvas/design")
            #expect(second.relative == ".sandshell/canvas/design-2")
            guard case .success(let board) = CanvasBoard.load(folder: second.folder) else {
                Issue.record("It doesn't load")
                return
            }
            #expect(board.title == "Design 2" && board.artboards.isEmpty)
            #expect(CanvasBoard.list(root: root).count == 2)
        }
    }

    @Test func aNoticeGoesAheadOfTheMessage() {
        let blocks = ChatSession.promptBlocks("hello", [], notice: ChatSession.boardNotice(board: "/w/.sandshell/canvas/design"))
        #expect(blocks.count == 2)
        #expect(blocks[0]["text"]?.string?.contains("/w/.sandshell/canvas/design") == true)
        #expect(blocks[1]["text"]?.string == "hello")
    }

    @Test func withNoNoticeTheMessageIsAlone() {
        #expect(ChatSession.promptBlocks("hello", []).count == 1)
    }
}


/// Stepping through a board's artboards in order (‹ ›, ⌘[ ⌘], ← →).
@MainActor
struct CanvasSteppingTests {
    private func canvas() throws -> (CanvasView, NSWindow, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandshell-step-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let artboards = (1...3).map { #"{"id": "a\#($0)", "title": "Option \#($0)", "file": "a.html", "width": 400, "height": 300, "x": \#($0 * 600), "y": 0}"# }
        try Data(#"{"title": "Steps", "artboards": [\#(artboards.joined(separator: ","))]}"#.utf8)
            .write(to: folder.appending(path: CanvasBoard.fileName))
        try Data("<body>x</body>".utf8).write(to: folder.appending(path: "a.html"))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = CanvasView(frame: window.contentView!.bounds)
        canvas.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(canvas)
        window.orderFrontRegardless()
        canvas.show(folder)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window, folder)
    }

    private func label(_ view: NSView) -> String? {
        if let b = view as? NSButton, b.accessibilityIdentifier() == "canvas-step" { return b.title }
        return view.subviews.lazy.compactMap(label).first
    }

    @Test func stepsGoInTheBoardsOrderAndStopAtTheEnds() throws {
        let (canvas, window, folder) = try canvas()
        defer { canvas.show(nil); window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        #expect(canvas.stepIndex == nil)
        #expect(label(canvas) == "3 screens")
        canvas.nextArtboard()
        #expect(canvas.stepIndex == 0)
        #expect(label(canvas) == "1 of 3 · Option 1")
        canvas.nextArtboard(); canvas.nextArtboard(); canvas.nextArtboard()
        #expect(canvas.stepIndex == 2, "stays on the last")
        canvas.previousArtboard()
        #expect(label(canvas) == "2 of 3 · Option 2")
        canvas.showWholeBoard()
        #expect(canvas.stepIndex == nil)
        canvas.previousArtboard()
        #expect(canvas.stepIndex == 2, "from the whole board, back starts at the end")
    }

    @Test func theArrowKeysStepWhileTheCanvasHasFocus() throws {
        let (canvas, window, folder) = try canvas()
        defer { canvas.show(nil); window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        window.makeFirstResponder(canvas)
        canvas.keyDown(with: key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        #expect(canvas.stepIndex == 0)
        #expect(canvas.performKeyEquivalent(with: key(30, "]", .command)))
        #expect(canvas.stepIndex == 1)
        #expect(canvas.performKeyEquivalent(with: key(33, "[", .command)))
        #expect(canvas.stepIndex == 0)
    }

    @Test func theMenuListsEveryArtboardTheShownOneTicked() throws {
        let (canvas, window, folder) = try canvas()
        defer { canvas.show(nil); window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.go(to: 1)
        let items = canvas.artboardMenu().items.filter { !$0.isSeparatorItem && !$0.isSectionHeader }
        #expect(items.map(\.title) == ["Option 1", "Option 2", "Option 3"], "one page: its screens, nothing else")
        #expect(items.filter { $0.state == .on }.map(\.title) == ["Option 2"])
        #expect(CanvasView.target(in: window) === canvas, "the window's canvas, for View ▸ Next Screen")
    }

    @Test func anEmptyBoardHasNoStepper() throws {
        let (canvas, window, folder) = try canvas()
        defer { canvas.show(nil); window.orderOut(nil); window.close(); try? FileManager.default.removeItem(at: folder) }
        canvas.show(nil)
        canvas.nextArtboard()
        #expect(canvas.stepIndex == nil)
    }
}

/// A board of pages: one page shown at a time, designs as rows, the menus
/// and All Pages.
@MainActor
struct CanvasPagesTests {
    private static let json = #"""
        {"title": "Agate", "pages": [
          {"id": "people", "title": "People", "designs": [
            {"id": "p1", "title": "Who is who", "file": "a.html", "width": 400, "height": 300},
            {"id": "p2", "title": "Keeping up", "file": "a.html", "width": 400, "height": 300}]},
          {"id": "connections", "title": "Connections", "note": "Ways in to connecting a service", "designs": [
            {"id": "a", "title": "A connection picked", "width": 400, "height": 300, "screens": [
              {"id": "a1", "title": "Nothing picked", "file": "a.html"},
              {"id": "a2", "title": "GitHub", "file": "a.html"},
              {"id": "a3", "title": "Slack", "file": "a.html"}]},
            {"id": "b", "title": "A route picked", "width": 400, "height": 300, "screens": [
              {"id": "b1", "title": "Gmail", "file": "a.html"},
              {"id": "b2", "title": "Drive", "file": "a.html"}]}]}]}
        """#

    private func canvas() throws -> (CanvasView, NSWindow, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandshell-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.json.utf8).write(to: folder.appending(path: CanvasBoard.fileName))
        try Data("<body>x</body>".utf8).write(to: folder.appending(path: "a.html"))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = CanvasView(frame: window.contentView!.bounds)
        canvas.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(canvas)
        window.orderFrontRegardless()
        canvas.show(folder)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window, folder)
    }

    private func close(_ canvas: CanvasView, _ window: NSWindow, _ folder: URL) {
        canvas.show(nil)
        window.orderOut(nil)
        window.close()
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func itShowsOnePageAtATime() throws {
        let (canvas, window, folder) = try canvas()
        defer { close(canvas, window, folder) }
        #expect(canvas.pageID == "people", "the first page")
        #expect(canvas.debugArtboardIDs == ["p1", "p2"], "only its artboards")
        #expect(canvas.stripLabel == "Canvas · People")
        canvas.stepPage(by: 1)
        #expect(canvas.pageID == "connections")
        #expect(canvas.debugArtboardIDs == ["a1", "a2", "a3", "b1", "b2"])
        canvas.stepPage(by: 1)
        #expect(canvas.pageID == "connections", "stays on the last")
    }

    @Test func screensStepWithinThePageAndArrowsChangeDesign() throws {
        let (canvas, window, folder) = try canvas()
        defer { close(canvas, window, folder) }
        canvas.showPage("connections")
        canvas.nextArtboard()
        #expect(canvas.pageScreens[canvas.stepIndex ?? -1] == "a1")
        canvas.nextArtboard(); canvas.nextArtboard(); canvas.nextArtboard()
        #expect(canvas.pageScreens[canvas.stepIndex ?? -1] == "b1", "past A3 it goes on to B1")
        canvas.stepDesign(by: -1)
        #expect(canvas.pageScreens[canvas.stepIndex ?? -1] == "a1", "↑: the design before, its first screen")
        canvas.stepDesign(by: 1)
        #expect(canvas.pageScreens[canvas.stepIndex ?? -1] == "b1")
    }

    @Test func revealingAScreenOnAnotherPageGoesThere() throws {
        let (canvas, window, folder) = try canvas()
        defer { close(canvas, window, folder) }
        canvas.goTo("b2")
        #expect(canvas.pageID == "connections")
        #expect(canvas.pageScreens[canvas.stepIndex ?? -1] == "b2")
    }

    @Test func theBarsMenuOpensTheShownDesignAndListsTheOtherPages() throws {
        let (canvas, window, folder) = try canvas()
        defer { close(canvas, window, folder) }
        canvas.goTo("a2")
        let items = canvas.artboardMenu().items
        let titles = items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Connections", "A · A connection picked", "A1 · Nothing picked", "A2 · GitHub", "A3 · Slack",
                           "B · A route picked", "Other Pages", "People", "All Pages"])
        #expect(items.filter { $0.state == .on }.map(\.title) == ["A2 · GitHub"])
        #expect(items.first { $0.title == "B · A route picked" }?.submenu?.items.map(\.title) == ["B1 · Gmail", "B2 · Drive"],
                "a design not shown: its screens a submenu away")
        let goTo = canvas.goToMenu().items
        #expect(goTo.map(\.title) == ["People", "Connections"])
        #expect(goTo[1].submenu?.items.map(\.title) == ["A · A connection picked", "B · A route picked"])
        #expect(goTo[0].submenu?.items.map(\.title) == ["A · Who is who", "B · Keeping up"], "one-screen designs: an item each")
        #expect(canvas.pagesMenu().items.filter { $0.state == .on }.map(\.title) == ["Connections"])
    }

    @Test func allPagesShowsACardEachAndOneOpensItsPage() throws {
        let (canvas, window, folder) = try canvas()
        defer { close(canvas, window, folder) }
        canvas.showAllPages()
        #expect(canvas.showsAllPages)
        #expect(canvas.debugArtboardIDs.isEmpty, "no pages load on All Pages")
        #expect(canvas.debugCardTitles == ["People", "Connections"])
        #expect(canvas.stripLabel == "Canvas · All Pages")
        canvas.debugOpenCard("Connections")
        #expect(!canvas.showsAllPages && canvas.pageID == "connections")
    }
}

/// A big board loads only the pages in view, a few at a time.
@MainActor
struct CanvasLoadingTests {
    @Test func onlyThePagesInViewLoad() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandshell-lazy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two near each other, two so far off to the right that even zoomed
        // all the way out (it opens zoomed to fit) neither pair is in view.
        let xs = [0, 500, 60_000, 60_500]
        let artboards = xs.enumerated().map { #"{"id": "a\#($0.offset)", "file": "p\#($0.offset).html", "width": 400, "height": 300, "x": \#($0.element), "y": 0}"# }
        try Data(#"{"title": "Lazy", "artboards": [\#(artboards.joined(separator: ","))]}"#.utf8).write(to: folder.appending(path: CanvasBoard.fileName))
        for i in xs.indices { try Data("<body>\(i)</body>".utf8).write(to: folder.appending(path: "p\(i).html")) }
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = CanvasView(frame: window.contentView!.bounds)
        canvas.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(canvas)
        window.orderFrontRegardless()
        defer { canvas.show(nil); window.orderOut(nil); window.close() }
        canvas.show(folder)
        canvas.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))   // its zoom to fit
        #expect(canvas.debugLoadedCount == 0, "nothing in view yet")
        #expect(canvas.debugWebViewCount == 0, "no page started for any of them yet")
        canvas.go(to: 0)   // the first two in view, at a size that loads pages
        let end = Date().addingTimeInterval(15)
        while canvas.debugLoadedCount < 2, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(canvas.debugLoadedCount == 2, "the two in view, not the two far off")
        #expect(canvas.debugWebViewCount == 2, "web views only for the pages that loaded")
        #expect(canvas.debugSharesProcessPool, "one process pool for the app, not one each")
        canvas.go(to: 3)
        let later = Date().addingTimeInterval(15)
        while canvas.debugLoadedCount < 4, Date() < later { try await Task.sleep(for: .milliseconds(50)) }
        #expect(canvas.debugLoadedCount == 4, "going there loads them")
    }

    @Test func aPicturesNameIsTheFileAndWhenItChanged() {
        let file = URL(filePath: "/tmp/board/a.html")
        let a = ArtboardPictures.key(file, stamp: Date(timeIntervalSince1970: 1))
        #expect(a != nil && a == ArtboardPictures.key(file, stamp: Date(timeIntervalSince1970: 1)))
        #expect(a != ArtboardPictures.key(file, stamp: Date(timeIntervalSince1970: 2)), "a new version, a new picture")
        #expect(ArtboardPictures.key(URL(string: "http://localhost:5173/")!, stamp: .now) == nil, "a server's page: none")
    }
}
