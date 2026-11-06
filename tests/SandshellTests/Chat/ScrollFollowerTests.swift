#if DEBUG
import AppKit
import Testing
@testable import Sandshell

/// Following the end with momentum (`ScrollFollower`): it starts and ends slow.
struct ScrollFollowerTests {
    private let frame: CGFloat = 1.0 / 120

    /// The speed over a move from rest to `target`, frame by frame.
    private func speeds(to target: CGFloat) -> [CGFloat] {
        var follower = ScrollFollower(position: 0)
        var out: [CGFloat] = []
        for _ in 0..<600 {
            let before = follower.position
            follower.step(toward: target, dt: frame)
            out.append((follower.position - before) / frame)
            if follower.isAtRest(at: target) { break }
        }
        return out
    }

    @Test func startsSlowBuildsAndEndsSlow() throws {
        let v = speeds(to: 300)
        let peak = try #require(v.max())
        let top = try #require(v.firstIndex(of: peak))
        #expect(v[0] < peak * 0.15, "Eases in")
        #expect(top > 3, "Takes a moment to get going")
        #expect(try #require(v.last) < peak * 0.1, "Eases out")
        #expect(zip(v, v.dropFirst()).prefix(top).allSatisfy { $0 <= $1 }, "Only speeds up, to the peak")
        #expect(zip(v, v.dropFirst()).dropFirst(top).allSatisfy { $0 >= $1 }, "Only slows, after it")
    }

    @Test func arrivesInAboutHalfASecondWithoutOvershooting() {
        var follower = ScrollFollower(position: 0)
        var time: CGFloat = 0
        while !follower.isAtRest(at: 300), time < 3 {
            follower.step(toward: 300, dt: frame)
            time += frame
            #expect(follower.position <= 300.01)
        }
        #expect(time > 0.4 && time < 1.5, "Took \(time) s")
    }

    /// Text streaming in: one motion, never stopping and starting.
    @Test func aMovingEndIsOneMotion() {
        var follower = ScrollFollower(position: 0)
        var target: CGFloat = 0
        var last: CGFloat = 0
        for i in 1...300 {
            if i.isMultiple(of: 12) { target += 22 }   // a line, ten times a second
            follower.step(toward: target, dt: frame)
            #expect(follower.position >= last, "Never goes backward")
            last = follower.position
        }
        #expect(target - follower.position < 70, "Keeps up: about two lines behind, plus the one just arrived")
    }

    @Test func aLongFrameIsStable() {
        var follower = ScrollFollower(position: 0)
        follower.step(toward: 300, dt: 2)
        #expect(follower.position <= 300 && follower.position > 290)
    }

    @Test func textGettingShorterDoesntLeaveItPastTheEnd() {
        var follower = ScrollFollower(position: 500, velocity: 0)
        for _ in 0..<240 { follower.step(toward: 300, dt: frame) }
        #expect(abs(follower.position - 300) < 1)
    }
}

/// The real view following a reply, on a real display link.
@MainActor
struct ChatTranscriptFollowTests {
    private func make() async -> (ChatTranscriptView, NSWindow, [ChatItem]) {
        let chat: [ChatItem] = (0..<40).map { .agentText(id: "a\($0)", text: "Reply \($0): " + String(repeating: "words that wrap around ", count: 14)) }
        let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 640, height: 520), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01       // on screen for the display link, not to the eye
        window.ignoresMouseEvents = true
        window.level = .floating       // not behind other windows: following only eases when seen
        window.contentView = view
        window.orderFrontRegardless()
        for _ in 0..<40 where !window.occlusionState.contains(.visible) { await run(0.05) }
        view.update(chat)
        await Task { @MainActor in }.value
        view.debugScrollToBottom()
        view.debugEasesFollow = true
        return (view, window, chat)
    }

    private func run(_ seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) }

    @Test func aReplyArrivingEasesToTheEnd() async {
        let (view, window, chat) = await make()
        defer { window.orderOut(nil); window.close() }
        let start = view.debugScrollY
        // A locked screen has no display link to watch.
        guard window.occlusionState.contains(.visible) else { return }
        view.update(chat + [.agentText(id: "new", text: String(repeating: "A new reply, several lines long, arriving. ", count: 12))])
        await Task { @MainActor in }.value
        #expect(view.debugFollowIsMoving, "Animating, not jumping")
        #expect(view.debugScrollY - start < 10, "Doesn't jump there")
        // Watch it move: slow, faster, slow.
        var seen = [view.debugScrollY]
        for _ in 0..<150 where view.debugFollowIsMoving {
            await run(0.016)
            seen.append(view.debugScrollY)
        }
        let steps = zip(seen, seen.dropFirst()).map { $1 - $0 }
        let peak = steps.max() ?? 0
        #expect(steps.count > 15, "Took a while: \(steps.count) samples")
        #expect(steps.allSatisfy { $0 >= 0 }, "Only ever forward")
        #expect((steps.first ?? 0) < peak * 0.6, "Starts slow: \(steps.prefix(4)) of \(peak)")
        #expect((steps.last ?? 0) < peak * 0.25, "Ends slow: \(steps.suffix(4)) of \(peak)")
        #expect(peak > 2, "Really moved")
        await run(0.1)
        #expect(!view.debugFollowIsMoving, "Comes to rest")
        #expect(abs(view.debugDocumentHeight - view.bounds.height - view.debugScrollY) < 1, "At the end")
        #expect(view.debugIsFollowingEnd)
    }

    @Test func scrollingUpTakesTheViewBack() async {
        let (view, window, chat) = await make()
        defer { window.orderOut(nil); window.close() }
        view.update(chat + [.agentText(id: "new", text: String(repeating: "A new reply, several lines long, arriving. ", count: 12))])
        await Task { @MainActor in }.value
        await run(0.1)
        view.debugUserScroll(by: -200)
        #expect(!view.debugFollowIsMoving)
        #expect(!view.debugIsFollowingEnd)
        let y = view.debugScrollY
        await run(0.3)
        #expect(view.debugScrollY == y, "Left where you put it")
    }
}
#endif
