#if DEBUG
import AppKit
import Testing
@testable import Sandshell

/// Streaming updates are drawn once per turn, and what's drawn is the latest.
@MainActor
struct ChatTranscriptUpdateTests {
    /// Lets the main actor run what's queued on it: a Task made now runs after
    /// the ones `update` queued.
    private func nextTurn() async {
        await Task { @MainActor in }.value
    }

    /// Several updates in one turn (stream chunks, then a notice) draw the last
    /// one's items, not the first's: a reply isn't left a few words short.
    @Test func updatesInOneTurnDrawTheLatestItems() async {
        let view = ChatTranscriptView()
        view.update([.agentText(id: "r", text: "The quick")])
        view.update([.agentText(id: "r", text: "The quick brown")])
        view.update([.agentText(id: "r", text: "The quick brown fox"),
                     .notice(id: UUID(), text: "Turn ended", isError: false)])
        #expect(!view.debugText.contains("quick"), "drawn on the next turn, once")
        await nextTurn()
        #expect(view.debugText.contains("The quick brown fox"))
        #expect(view.debugText.contains("Turn ended"))
    }

    /// An update after the batch was drawn starts a new one.
    @Test func laterUpdatesAreDrawnToo() async {
        let view = ChatTranscriptView()
        view.update([.agentText(id: "r", text: "First")])
        await nextTurn()
        #expect(view.debugText.contains("First"))
        view.update([.agentText(id: "r", text: "First, then second")])
        view.update([.agentText(id: "r", text: "First, then second, then third")])
        await nextTurn()
        #expect(view.debugText.contains("then third"))
    }
}
#endif
