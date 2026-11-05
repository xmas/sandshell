import AppKit
import Testing
@testable import Sandshell

/// View ▸ Make Text Bigger / Smaller / Actual Size (`TextZoom`), on a defaults
/// suite of its own.
@MainActor
@Suite(.serialized)
struct TextZoomTests {
    private func withZoom(_ body: @MainActor () throws -> Void) throws {
        let suite = "SandshellTextZoomTests-\(UUID().uuidString)"
        let saved = TextZoom.defaults
        TextZoom.defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            TextZoom.defaults.removePersistentDomain(forName: suite)
            TextZoom.defaults = saved
        }
        try body()
    }

    @Test func stepsUpAndDownAndBack() throws {
        try withZoom {
            #expect(TextZoom.scale == 1)
            #expect(TextZoom.isActualSize)
            TextZoom.zoomIn()
            #expect(TextZoom.scale == 1.15)
            TextZoom.zoomOut(); TextZoom.zoomOut()
            #expect(TextZoom.scale == 0.85)
            TextZoom.actualSize()
            #expect(TextZoom.scale == 1)
        }
    }

    @Test func stopsAtTheEnds() throws {
        try withZoom {
            for _ in 0..<20 { TextZoom.zoomIn() }
            #expect(TextZoom.scale == TextZoom.steps.last)
            #expect(!TextZoom.canZoomIn)
            for _ in 0..<20 { TextZoom.zoomOut() }
            #expect(TextZoom.scale == TextZoom.steps.first)
            #expect(!TextZoom.canZoomOut)
        }
    }

    @Test(arguments: [(0, 1), (-3, 1), (1.12, 1.15), (9, 2.5), (0.78, 0.75)] as [(CGFloat, CGFloat)])
    func aSavedSizeSnapsToAStep(saved: CGFloat, step: CGFloat) {
        #expect(TextZoom.nearestStep(saved) == step)
    }

    @Test func aChangeIsAnnounced() throws {
        try withZoom {
            var posts = 0
            let token = NotificationCenter.default.addObserver(forName: TextZoom.didChange, object: nil, queue: nil) { _ in posts += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            TextZoom.zoomIn()
            TextZoom.actualSize()
            TextZoom.actualSize()   // already there: nothing to redraw
            #expect(posts == 2)
        }
    }

    @Test func chatTextGrowsWithIt() throws {
        try withZoom {
            @MainActor func bodySize() -> CGFloat? {
                (ChatRenderer.markdown("Hello").attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
            }
            #expect(bodySize() == TypeRole.body.pointSize)
            TextZoom.scale = 1.5
            #expect(bodySize() == 19.5)
        }
    }
}
