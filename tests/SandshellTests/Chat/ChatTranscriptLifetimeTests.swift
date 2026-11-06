#if DEBUG
import AppKit
import Testing
@testable import Sandshell

/// A closed chat's transcript goes away: a live one re-renders on every text
/// zoom, so one left behind would slow the app down.
@MainActor
struct ChatTranscriptLifetimeTests {
    @Test func aClosedTranscriptGoesAway() async throws {
        weak var gone: ChatTranscriptView?
        do {
            let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
            let window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 640, height: 520), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()
            view.update([.agentText(id: "a", text: "Hello")])
            await Task { @MainActor in }.value
            view.debugSettle()
            gone = view
            window.orderOut(nil)
            window.close()
            window.contentView = nil
        }
        for _ in 0..<40 where gone != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(gone == nil, "Still alive after its window closed")
    }
}
#endif
