#if DEBUG
import AppKit
import Testing
@testable import Sandshell

/// The blank chat (xmas-sandshell-7x7): a reply in the transcript yet not
/// drawn. The check that heals it has to see it first — it missed paragraphs
/// TextKit 2 never laid out, which have no lines and so looked like spacers.
@MainActor
struct ChatTranscriptDrawnTests {
    @Test func unlaidTextShowingIsSeenAndDrawnAgain() async throws {
        let paragraph = "Your real hub is already set up for this; you've been signing in to the wrong one. "
            + String(repeating: "The compose file shows the team, the proxy and the sign-in settings. ", count: 6)
        let items: [ChatItem] = (0..<40).flatMap { i -> [ChatItem] in
            [.user(id: UUID(), text: "Question \(i)", attachments: []), .agentText(id: "a\(i)", text: paragraph)]
        }
        let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 640, height: 520), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()   // offscreen
        defer { window.orderOut(nil); window.close() }
        view.update(items)
        await Task { @MainActor in }.value
        view.debugScrollToBottom()
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(view.debugUndrawnVisibleHeight < 1, "Drawn to begin with")

        view.debugForgetLayout()
        #expect(view.debugUndrawnVisibleHeight > 100, "Seen: the lines showing have no layout")
        view.debugCheckDrawn()
        window.displayIfNeeded()
        #expect(view.debugUndrawnVisibleHeight < 1, "Laid out and drawn again")
    }
}
#endif
