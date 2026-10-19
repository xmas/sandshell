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

    @Test func aDocumentNarrowerThanTheClipIsCentered() {
        let clip = CenteringClipView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        clip.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 2000))
        let bounds = clip.constrainBoundsRect(NSRect(x: 0, y: 500, width: 1000, height: 300))
        #expect(bounds.origin.x == -80, "80 points of margin each side")
        #expect(bounds.origin.y == 500, "vertical scrolling is untouched")
    }

    @Test(.tags(.edgeCase)) func aWiderDocumentScrollsAsUsual() {
        let clip = CenteringClipView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        clip.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 2000))
        #expect(clip.constrainBoundsRect(NSRect(x: 0, y: 0, width: 400, height: 300)).origin.x == 0)
    }
}
