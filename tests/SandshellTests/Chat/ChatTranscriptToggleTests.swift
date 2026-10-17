#if DEBUG
import AppKit
import Testing
@testable import Sandshell

/// "Show more" / "Show less" links open and close what they belong to.
@MainActor
struct ChatTranscriptToggleTests {
    /// A transcript showing `items` now (and keeping them, as `update` does).
    private func transcript(_ items: [ChatItem]) -> ChatTranscriptView {
        let view = ChatTranscriptView()
        view.update(items)
        view.debugApplyNow(items)
        return view
    }

    /// The link's id is percent-encoded once and must be decoded once: decoded
    /// twice, "t%41" came back as "tA" and the link opened nothing.
    @Test(arguments: ["t1", "t%41", "t%", "t 1"])
    func showMoreOpensAThought(id: String) {
        let view = transcript([.thought(id: id, text: "one\ntwo\nthree\nfour")])
        #expect(!view.debugText.contains("three"), "a long thought starts folded")
        view.debugToggle("thought-\(id)")
        #expect(view.debugText.contains("three"))
        #expect(view.debugText.contains("Show less"))
        view.debugToggle("thought-\(id)")
        #expect(!view.debugText.contains("three"))
    }
}
#endif
