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
