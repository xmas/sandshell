import AppKit
import Testing
@testable import Sandshell

@MainActor
struct ChatColumnTests {
    @Test(arguments: [
        (CGFloat(400), CGFloat(400)),   // narrow: the whole width (the text reflows)
        (840, 840),                     // the column plus its margins
        (1000, 840),                    // wider: the column, centered by the clip view
        (2000, 840),
    ])
    func theTextViewIsTheReadableColumnAtMost(width: CGFloat, textView: CGFloat) {
        #expect(ChatTranscriptView.textViewWidth(forWidth: width) == textView)
    }

    @Test func aWideTranscriptCentersItsTextWithoutResizingIt() {
        let transcript = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 1600, height: 400))
        transcript.layoutSubtreeIfNeeded()
        let before = transcript.debugTextViewWidth
        transcript.setFrameSize(NSSize(width: 1300, height: 400))
        transcript.layoutSubtreeIfNeeded()
        #expect(before == 840 && transcript.debugTextViewWidth == 840, "the text keeps its width")
        #expect(abs(transcript.debugTextColumn.midX - transcript.bounds.midX) <= 8, "and stays centered")
    }
}
