#if DEBUG
import AppKit
import Testing
@testable import Sandshell

/// Rebuilding what shows when text settles (`refreshVisibleText`) mustn't be
/// felt: not a pixel moved, wherever you're reading, and quick on a long chat.
@MainActor
struct ChatTranscriptSettleTests {
    /// A long chat of what chats hold: user blocks, prose, code, a table.
    private func items(_ turns: Int) -> [ChatItem] {
        (0..<turns).flatMap { i -> [ChatItem] in
            [.user(id: UUID(), text: "Question \(i): what should we do about the \(i)th thing?", attachments: []),
             .agentText(id: "a\(i)", text: """
             ## Part \(i)

             Here's a paragraph with `inline code` and **bold**, long enough to wrap around the column a few times over, \
             since most of what a chat holds is prose like this, going on for a while before it stops at last.

             ```swift
             func f\(i)(x: Int) -> Int { x + \(i) }
             ```

             | Name | Value |
             |------|-------|
             | one  | \(i)  |

             - a point
             - another point
             """)]
        }
    }

    private func make(_ items: [ChatItem]) async -> (ChatTranscriptView, NSWindow) {
        let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 640, height: 720), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        NotificationCenter.default.removeObserver(view, name: ChatTextZoom.didChange, object: nil)   // TextZoomTests run alongside
        window.orderFrontRegardless()   // offscreen
        view.update(items)
        await Task { @MainActor in }.value
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func settleDisplay(_ view: ChatTranscriptView, _ window: NSWindow) {
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private func pixels(_ view: NSView) -> Data {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    /// Yields the main queue, which holds the check (a nested run loop wouldn't drain it).
    private func wait(_ seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// Changes this close together, as a stream sends them, for `seconds`.
    private func stream(_ view: ChatTranscriptView, for seconds: TimeInterval) async {
        let end = Date.now.addingTimeInterval(seconds)
        while Date.now < end {
            view.debugChanged()
            await wait(0.05)
        }
    }

    /// A reply streaming in never goes quiet, and the rebuild mustn't wait for
    /// it to (xmas-sandshell-7x7: a blank mid-reply stayed until the turn ended).
    @Test func aStreamCantHoldOffTheRebuild() async {
        let (view, window) = await make(items(4))
        defer { window.orderOut(nil); window.close() }
        view.drawnCheckMaxWait = 0.6
        let before = view.debugRefreshes
        await stream(view, for: 1.5)
        #expect(view.debugRefreshes > before)
    }

    /// Control: without the limit, the same stream holds it off the whole time.
    @Test func withoutTheLimitTheStreamWould() async {
        let (view, window) = await make(items(4))
        defer { window.orderOut(nil); window.close() }
        view.drawnCheckMaxWait = 3600
        let before = view.debugRefreshes
        await stream(view, for: 1.5)
        #expect(view.debugRefreshes == before)
    }

    /// Text that settled while the chat didn't show is rebuilt when it does.
    @Test func aChatShownAgainGetsTheRebuildItMissed() async {
        let (view, window) = await make(items(4))
        defer { window.orderOut(nil); window.close() }
        await wait(0.7)
        view.isHidden = true
        let before = view.debugRefreshes
        view.debugChanged()
        await wait(0.7)
        #expect(view.debugRefreshes == before, "Nothing's rebuilt while it's hidden")
        view.isHidden = false
        await wait(0.7)
        #expect(view.debugRefreshes > before)
    }

    /// ⌘+ in a chat: the text comes back at the new size, on screen.
    @Test(arguments: [nil, 0.0, 0.4] as [Double?])
    func changingTheTextSizeKeepsTheTextShowing(scrolledTo fraction: Double?) async throws {
        let suite = "SandshellZoomBlank-\(UUID().uuidString)"
        let saved = TextZoom.defaults
        TextZoom.defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            TextZoom.defaults.removePersistentDomain(forName: suite)
            TextZoom.defaults = saved
        }
        let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 720), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.close() }
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderFrontRegardless()
        view.update(items(60))
        await wait(0.2)
        view.layoutSubtreeIfNeeded()
        if let fraction { view.debugScroll(toFraction: fraction) }
        await wait(0.2)
        window.displayIfNeeded()
        #expect(Set(pixels(view)).count > 8, "Text to start with")
        for step in 1...3 {
            NotificationCenter.default.post(name: ChatTextZoom.didChange, object: nil)   // as ⌘+ does
            ChatTextZoom.scale = [1.15, 1.3, 1.5][step - 1]
            await wait(0.9)
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(view.debugUndrawnVisibleHeight < 1, "Step \(step): undrawn")
            #expect(view.debugUnlaidVisibleHeight < 1, "Step \(step): unlaid")
            #expect(Set(pixels(view)).count > 8, "Step \(step): nothing on screen")
        }
    }

    @Test(arguments: [0.0, 0.1, 0.37, 0.5, 0.83, 1.0])
    func notAPixelMoves(fraction: Double) async {
        let (view, window) = await make(items(150))
        defer { window.orderOut(nil); window.close() }
        view.debugScroll(toFraction: fraction)
        for _ in 0..<4 { settleDisplay(view, window) }
        let y = view.debugScrollY, image = pixels(view)
        if fraction > 0 { #expect(y > 1000, "Really scrolled down") }
        #expect(Set(image).count > 8, "There's text on screen to compare")
        // Control: a single point of scroll shows up in the comparison.
        view.debugScroll(toFraction: (y + (fraction == 0 ? 1 : -1)) / (view.debugDocumentHeight - view.bounds.height))
        settleDisplay(view, window)
        #expect(pixels(view) != image, "This test can see a one-point jump")
        view.debugScroll(toFraction: y / (view.debugDocumentHeight - view.bounds.height))
        settleDisplay(view, window)
        #expect(pixels(view) == image, "Back where it was")
        for pass in 1...3 {
            view.debugSettle()
            settleDisplay(view, window)
            #expect(abs(view.debugScrollY - y) < 0.5, "pass \(pass): scrolled \(view.debugScrollY - y) pt at \(fraction)")
            #expect(pixels(view) == image, "pass \(pass): pixels changed at \(fraction)")
        }
    }

    /// Reading further up while the reply streams in below: nothing you're
    /// looking at moves.
    @Test func textArrivingBelowLeavesTheReaderAlone() async {
        var chat = items(150)
        let (view, window) = await make(chat)
        defer { window.orderOut(nil); window.close() }
        view.debugScroll(toFraction: 0.4)
        for _ in 0..<4 { settleDisplay(view, window) }
        #expect(!view.debugIsFollowingEnd)
        let y = view.debugScrollY, image = pixels(view)
        var reply = ""
        for i in 0..<30 {
            reply += "word \(i) of a reply still arriving, "
            view.update(chat + [.agentText(id: "new", text: reply)])
            await Task { @MainActor in }.value
            view.debugSettle()
            settleDisplay(view, window)
            #expect(abs(view.debugScrollY - y) < 0.5, "chunk \(i): scrolled \(view.debugScrollY - y) pt")
        }
        #expect(pixels(view) == image)
        chat.removeAll()
    }

    /// Watching a reply come in: settling keeps the end in view as it grows.
    @Test func followingTheEndKeepsFollowing() async {
        let chat = items(150)
        let (view, window) = await make(chat)
        defer { window.orderOut(nil); window.close() }
        view.debugScrollToBottom()
        for _ in 0..<3 { settleDisplay(view, window) }
        var reply = ""
        for i in 0..<30 {
            reply += "word \(i) of a reply still arriving, and more of it so the lines wrap, "
            view.update(chat + [.agentText(id: "new", text: reply)])
            await Task { @MainActor in }.value
            view.debugSettle()
            settleDisplay(view, window)
            #expect(view.debugIsFollowingEnd)
            let gap = view.debugDocumentHeight - view.bounds.height - view.debugScrollY
            #expect(gap < 30, "chunk \(i): \(gap) pt short of the end")
        }
    }

    @Test(arguments: [50, 500])
    func settlingIsUnderAFrame(turns: Int) async {
        let (view, window) = await make(items(turns))
        defer { window.orderOut(nil); window.close() }
        for fraction in [0.0, 0.5, 1.0] {
            // The end as the app gets there: laid out, not an estimate.
            if fraction == 1 { view.debugScrollToBottom() } else { view.debugScroll(toFraction: fraction) }
            for _ in 0..<3 { settleDisplay(view, window) }
            var times: [Double] = []
            for _ in 0..<40 {
                let start = ContinuousClock.now
                view.debugSettle()
                let took = ContinuousClock.now - start
                let ms = Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000
                times.append(ms)
                window.displayIfNeeded()
            }
            times.sort()
            #expect(times[20] < 16, "Under a frame at \(fraction), \(turns) turns: median \(times[20]) ms")
        }
    }
}
#endif

#if DEBUG
/// The text of a chat can actually be read: rendered on its background, light
/// and dark, at every text size, the contrast of the pixels themselves. (A
/// check that text exists passes for black text on a black panel.)
@MainActor
@Suite(.serialized)
struct TranscriptReadableTests {
    private final class Panel: NSView {
        var fill: NSColor = .black
        override func draw(_ dirtyRect: NSRect) { fill.setFill(); bounds.fill() }
    }

    private func items(_ turns: Int) -> [ChatItem] {
        (0..<turns).flatMap { i -> [ChatItem] in
            [.user(id: UUID(), text: "Question \(i): what should we do about the \(i)th thing?", attachments: []),
             .thought(id: "t\(i)", text: "Thinking about the \(i)th thing for a moment."),
             .agentText(id: "a\(i)", text: "## Part \(i)\n\nA paragraph with `inline code` and **bold**, long enough to wrap.\n\n```swift\nlet x = \(i)\n```")]
        }
    }

    private func luminance(_ c: NSColor) -> Double {
        guard let c = c.usingColorSpace(.sRGB) else { return 0 }
        func f(_ v: CGFloat) -> Double { v <= 0.03928 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent)
    }

    /// The strongest contrast on `view` against `background`.
    private func bestContrast(_ view: NSView, background: NSColor) throws -> Double {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let bg = luminance(background)
        var best = 1.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let l = luminance(c)
                best = max(best, (max(l, bg) + 0.05) / (min(l, bg) + 0.05))
            }
        }
        return best
    }

    private func window(dark: Bool) -> (NSWindow, Panel, ChatTranscriptView) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 720), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let panel = Panel(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
        panel.fill = dark ? .hex("0f1219") : .white
        let view = ChatTranscriptView(frame: panel.bounds)
        view.autoresizingMask = [.width, .height]
        panel.addSubview(view)
        window.contentView = panel
        window.orderFrontRegardless()
        return (window, panel, view)
    }

    /// A long chat, read from partway up, sized up and down with replies still
    /// coming: no help from here, just the run loop, as in the app.
    @Test(arguments: [(true, 0.5), (true, 0.9), (false, 0.9)] as [(Bool, Double)])
    func aLongChatStaysReadableThroughSizeChanges(dark: Bool, fraction: Double) async throws {
        let suite = "SandshellReadableLong-\(UUID().uuidString)"
        let saved = TextZoom.defaults
        TextZoom.defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            TextZoom.defaults.removePersistentDomain(forName: suite)
            TextZoom.defaults = saved
        }
        let (window, panel, view) = window(dark: dark)
        defer { window.orderOut(nil); window.close() }
        view.debugEasesFollow = true
        var all = items(120)
        view.update(all)
        try await Task.sleep(for: .milliseconds(800))
        view.debugScroll(toFraction: fraction)
        try await Task.sleep(for: .milliseconds(400))
        var failures: [String] = []
        for (step, scale) in ([1.3, 1.75, 1.15, 1] as [CGFloat]).enumerated() {
            ChatTextZoom.scale = scale
            all.append(.agentText(id: "more\(step)", text: "And another reply number \(step), still arriving."))
            view.update(all)
            try await Task.sleep(for: .milliseconds(900))
            window.displayIfNeeded()
            let contrast = try bestContrast(panel, background: panel.fill)
            let line = "step \(step) x\(scale): contrast \(String(format: "%.1f", contrast)), undrawn \(Int(view.debugUndrawnVisibleHeight)), "
                + "unlaid \(Int(view.debugUnlaidVisibleHeight)), y \(Int(view.debugScrollY)) of \(Int(view.debugDocumentHeight))"
            if contrast < 7 || view.debugUndrawnVisibleHeight >= 1 || view.debugUnlaidVisibleHeight >= 1 { failures.append(line) }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: " | ")))
    }

    @Test(arguments: [true, false], [1, 0.75, 1.5, 2.5] as [CGFloat])
    func aChatCanBeReadAtEverySize(dark: Bool, scale: CGFloat) async throws {
        let suite = "SandshellReadable-\(UUID().uuidString)"
        let saved = TextZoom.defaults
        TextZoom.defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            TextZoom.defaults.removePersistentDomain(forName: suite)
            TextZoom.defaults = saved
        }
        let (window, panel, view) = window(dark: dark)
        defer { window.orderOut(nil); window.close() }
        view.debugEasesFollow = true
        view.update(items(40))
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        ChatTextZoom.scale = scale   // what ⌘+ and ⌘− do; the chat redraws itself
        try await Task.sleep(for: .seconds(1.2))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let contrast = try bestContrast(panel, background: panel.fill)
        #expect(contrast >= 7, "\(dark ? "dark" : "light") at \(scale): best contrast \(contrast)")
        #expect(view.debugUndrawnVisibleHeight < 1)
    }
}
#endif

