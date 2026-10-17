#if DEBUG
import AppKit
import Testing
@testable import Sandshell

/// The bar a reply shows under the pointer: Copy, and Fork where forking is
/// wired (a subagent's transcript window has no fork).
@MainActor
struct ChatTranscriptHoverTests {
    private func transcript(forking: Bool) -> ChatTranscriptView {
        // Filled before it has a size, as a subagent's window fills its transcript.
        let view = ChatTranscriptView()
        if forking { view.onFork = { _ in } }
        view.debugApplyNow([.agentText(id: "a", text: "A reply to hover over.")])
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test(arguments: [false, true])
    func hoverBarOffersForkOnlyWhereItIsWired(forking: Bool) {
        let view = transcript(forking: forking)
        view.debugHoverFirstReply()
        #expect(view.debugReplyActionsShown, "hovering a reply shows its bar")
        #expect(view.debugForkShown == forking)
    }

    @Test func forkWiredLaterShowsOnTheNextHover() {
        let view = transcript(forking: false)
        view.debugHoverFirstReply()
        #expect(!view.debugForkShown)
        view.onFork = { _ in }
        view.debugHoverFirstReply()
        #expect(view.debugForkShown)
        view.onFork = nil
        view.debugHoverFirstReply()
        #expect(!view.debugForkShown)
    }
}
#endif
