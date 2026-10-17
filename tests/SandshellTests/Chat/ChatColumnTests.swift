import AppKit
import Testing
@testable import Sandshell

@MainActor
struct ChatColumnTests {
    @Test(arguments: [
        (CGFloat(400), CGFloat(20)),   // narrow: just the margin
        (840, 20),                     // the column plus margins: still the margin
        (1000, 100),                   // wider: centered
        (1601, 400),                   // odd widths round down
    ])
    func textInsetCentersAReadableColumn(width: CGFloat, inset: CGFloat) {
        #expect(ChatTranscriptView.sideInset(forWidth: width) == inset)
    }

    @Test func aWideTranscriptReadsAtMostTheReadableWidth() {
        let width: CGFloat = 2000
        let inset = ChatTranscriptView.sideInset(forWidth: width)
        #expect(width - 2 * inset == ChatTranscriptView.readableWidth)
    }
}
