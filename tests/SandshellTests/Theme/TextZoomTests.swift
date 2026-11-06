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

    @MainActor private func bodySize() -> CGFloat? {
        (ChatRenderer.markdown("Hello").attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
    }

    @Test func chatTextHasItsOwnSize() throws {
        try withZoom {
            #expect(bodySize() == TypeRole.body.pointSize)
            ChatTextZoom.scale = 1.5
            #expect(bodySize() == 19.5)
            #expect(TextZoom.scale == 1)
            TextZoom.zoomIn()
            #expect(ChatTextZoom.scale == 1.5)
            ChatTextZoom.actualSize()
            #expect(ChatTextZoom.isActualSize)
            #expect(TextZoom.scale == 1.15)
        }
    }

    /// Someone already zoomed keeps that size in chats, and zooming the rest doesn't move it.
    @Test func chatsKeepTheSizeTheyWereAt() throws {
        try withZoom {
            TextZoom.defaults.set(1.5, forKey: TextZoom.key)
            #expect(ChatTextZoom.scale == 1.5)
            TextZoom.zoomIn()
            #expect(TextZoom.scale == 1.75)
            #expect(ChatTextZoom.scale == 1.5)
        }
    }

    /// Files' Markdown preview shares the chat's fonts but not its size.
    @Test func renderingAtAnotherSizeIsOnlyForThatRender() throws {
        try withZoom {
            ChatTextZoom.scale = 2
            let size = ChatTextZoom.rendering(at: 1) { bodySize() }
            #expect(size == TypeRole.body.pointSize)
            #expect(ChatTextZoom.scale == 2)
        }
    }

    /// ⌘+ ⌘− ⌘0 size the chat you're in, and everything else otherwise.
    @Test func theKeysKnowWhenYoureInAChat() {
        let transcript = ChatTranscriptView()
        let inside = NSView()
        transcript.addSubview(inside)
        #expect(ChatTextZoom.isInChat(transcript))
        #expect(ChatTextZoom.isInChat(inside))
        #expect(!ChatTextZoom.isInChat(NSView()))
        #expect(!ChatTextZoom.isInChat(nil))
    }

    @Test func chatChangesAreAnnouncedOnTheirOwn() throws {
        try withZoom {
            var chat = 0
            var other = 0
            let tokens = [
                NotificationCenter.default.addObserver(forName: ChatTextZoom.didChange, object: nil, queue: nil) { _ in chat += 1 },
                NotificationCenter.default.addObserver(forName: TextZoom.didChange, object: nil, queue: nil) { _ in other += 1 },
            ]
            defer { for token in tokens { NotificationCenter.default.removeObserver(token) } }
            ChatTextZoom.zoomIn()
            #expect(chat == 1 && other == 0)
            TextZoom.zoomIn()
            #expect(chat == 1 && other == 1)
        }
    }
}
