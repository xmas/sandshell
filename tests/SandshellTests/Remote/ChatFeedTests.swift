import Foundation
import Testing
@testable import Sandshell

/// `ChatFeed`: one chat for every page that shows it (the in-app web view,
/// Remote Control's devices) — numbered patches, a state for a newcomer that
/// doesn't lose anyone else their place, the items held during a replay.
@MainActor
struct ChatFeedTests {
    private let chat = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: "/nonexistent/work",
                                   home: "/nonexistent/home")

    /// A page as `remote/web/app.js` keeps one: a state, then patches that
    /// must each follow on from the last.
    @MainActor
    final class Page {
        var rev: Int?
        var items: [String: String] = [:]
        var order: [String] = []
        var states = 0
        var patches = 0
        var outOfStep = 0

        func start(_ state: ChatFeed.Snapshot) {
            rev = state.rev
            items = Dictionary(state.items.map { ($0.id, $0.text ?? "") }, uniquingKeysWith: { $1 })
            order = state.items.map(\.id)
        }

        func receive(_ event: ChatFeed.Event) {
            switch event {
            case .state(let state):
                states += 1
                start(state)
            case .patch(let patch):
                // Not started yet: its state covers this (listeners pass on
                // patches only to pages that have had one).
                guard rev != nil else { return }
                patches += 1
                if patch.base != rev { outOfStep += 1 }
                rev = patch.rev
                for item in patch.upserts {
                    if items[item.id] == nil, patch.order == nil { order.append(item.id) }
                    items[item.id] = item.text ?? ""
                }
                if let new = patch.order { order = new }
            }
        }

        var shown: [String] { order.map { "\($0)|\(items[$0] ?? "?")" } }
    }

    private func chunk(_ text: String, _ message: String) -> JSONValue {
        ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)], "messageId": .string(message)]
    }

    /// What a page should show: the chat's items as the wire has them.
    private var expected: [String] {
        RemoteWire.items(chat.items, session: chat.ownSessionID).map { "\($0.id)|\($0.text ?? "")" }
    }

    private func follow(_ page: Page) {
        chat.feed.listen(page) { page, event in page.receive(event) }
        page.start(chat.feed.state())
    }

    @Test func everyPageFollowsOnFromItsState() {
        chat.debugSetPhase(.ready)
        chat.debugApply(chunk("Hello", "m1"))
        let a = Page(), b = Page()
        follow(a)
        follow(b)
        chat.debugApply(chunk(" there", "m1"))
        chat.debugApply(chunk("Second", "m2"))
        _ = chat.feed.state()   // flushes what's pending, as the next 80 ms would
        for page in [a, b] {
            #expect(page.shown == expected)
            #expect(page.outOfStep == 0)
            #expect(page.patches >= 1)
        }
    }

    /// A newcomer's state comes after what's pending went to those already
    /// following: it's the base of the next patch for everyone.
    @Test func aNewcomerDoesntCostTheOthersTheirPlace() {
        chat.debugSetPhase(.ready)
        let a = Page()
        follow(a)
        chat.debugApply(chunk("Pending when the newcomer comes", "m1"))
        let b = Page()
        follow(b)
        #expect(a.shown == expected, "It had what was pending first")
        #expect(a.rev == b.rev)
        chat.debugApply(chunk("After", "m2"))
        _ = chat.feed.state()
        #expect(a.outOfStep == 0)
        #expect(b.outOfStep == 0)
        #expect(a.shown == b.shown)
        #expect(b.shown == expected)
    }

    /// A resume replaying its history: pages keep what they show (the status
    /// goes on), then get the result once, as a state.
    @Test func aReplayIsHeldThenSentWhole() {
        chat.debugSetPhase(.ready)
        chat.debugApply(chunk("Before", "m1"))
        let page = Page()
        follow(page)
        let before = page.shown
        chat.debugSetPhase(.starting)
        chat.debugApply(chunk("Replayed", "m2"))
        #expect(chat.isReplaying)
        let newcomer = Page()
        follow(newcomer)
        #expect(page.shown == before, "Held")
        #expect(newcomer.shown == before, "A newcomer gets what was shown, not the replay half done")
        chat.debugSetPhase(.ready)
        _ = chat.feed.state()
        #expect(page.states == 1)
        #expect(page.shown == expected)
        #expect(newcomer.shown == expected)
        #expect(page.outOfStep == 0)
    }

    @Test func aPageThatsGoneHearsNothingMore() {
        chat.debugSetPhase(.ready)
        var page: Page? = Page()
        weak let gone = page
        follow(page!)
        page = nil
        #expect(gone == nil, "The feed doesn't keep its listeners")
        chat.debugApply(chunk("Nobody's listening", "m1"))
        _ = chat.feed.state()
    }

    @Test(arguments: [
        (ChatSession.Phase.ready, false, false),
        (.ready, true, false),
        (.starting, false, false),   // nothing yet: a new chat
        (.starting, true, true),     // a resume replaying
        (.running, true, false),
    ])
    func whatCountsAsAReplay(phase: ChatSession.Phase, hasItems: Bool, replaying: Bool) {
        chat.debugSetPhase(phase)
        let items: [ChatItem] = hasItems ? [.agentText(id: "m1", text: "hi")] : []
        #expect(chat.isReplaying(items) == replaying)
    }
}
