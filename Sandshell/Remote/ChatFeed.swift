import Combine
import Foundation

/// What a page can show: a live chat (`ChatSession`), or a transcript read
/// from disk (`ItemsTranscript`: a subagent's).
@MainActor
protocol ChatFeedSource: AnyObject {
    /// Its id on the wire (`RemoteWire.Item`s and image paths carry it).
    var feedID: UUID { get }
    var items: [ChatItem] { get }
    var feedStatus: RemoteWire.Status { get }
    /// The items are being replaced wholesale: show the result once.
    var isReplaying: Bool { get }
    /// Fires before any change (`objectWillChange`).
    var willChange: ObservableObjectPublisher { get }
    var feed: ChatFeed { get }
}

/// One chat as pages see it (the in-app transcript, Remote Control's devices):
/// what changed, as numbered patches, and everything when a page starts or
/// has lost its place. Every page of a chat is fed from this one object
/// (`ChatSession.feed`), so they all hold, number and catch up the same way.
///
/// - Watches the chat and sends a burst of changes once (`delay` later:
///   `objectWillChange` comes before the change).
/// - While the chat's items are being replaced wholesale (`ChatSession.isReplaying`),
///   pages keep what they show and get only the status; the result goes as
///   one state when it's done.
/// - `state()` sends what's pending to those already listening first, so a
///   newcomer's state is the base of the next patch for everyone.
@MainActor
final class ChatFeed {
    struct Snapshot: Equatable {
        let items: [RemoteWire.Item]
        let status: RemoteWire.Status
        /// The next patch's `base`.
        let rev: Int
    }

    enum Event {
        /// Everything again (a replay ended): pages show this instead.
        case state(Snapshot)
        case patch(RemoteWire.Patch)
    }

    static let delay: TimeInterval = 0.08

    /// The source owns its feed (`ChatSession.feed`).
    private unowned let chat: any ChatFeedSource
    private var feed: RemoteWire.Feed
    private var listeners: [Listener] = []
    private var watch: AnyCancellable?
    private var flushScheduled = false
    /// The items changed while held: pages need everything once it's done.
    private var needsState = false

    private struct Listener {
        weak var owner: AnyObject?
        let receive: (Event) -> Void
    }

    init(_ source: any ChatFeedSource) {
        chat = source
        feed = RemoteWire.Feed(session: source.feedID)
    }

    /// Changes from now on go to `receive` while `owner` lives (or until
    /// `stopListening`). Start a page with `state()`.
    func listen<Owner: AnyObject>(_ owner: Owner, _ receive: @escaping (Owner, Event) -> Void) {
        stopListening(owner)
        listeners.append(Listener(owner: owner) { [weak owner] event in
            if let owner { receive(owner, event) }
        })
        if watch == nil {
            watch = chat.willChange.sink { [weak self] _ in self?.changed() }
        }
    }

    func stopListening(_ owner: AnyObject) {
        listeners.removeAll { $0.owner == nil || $0.owner === owner }
        if listeners.isEmpty { stop() }
    }

    /// Everything, for a page starting (or starting over).
    func state() -> Snapshot {
        flush()
        let status = chat.feedStatus
        // What pages showed before the replay, not the replay half done.
        guard !chat.isReplaying else { return Snapshot(items: feed.items, status: status, rev: feed.rev) }
        let now = feed.state(chat.items, status: status)
        return Snapshot(items: now.items, status: now.status, rev: now.rev)
    }

    // MARK: Private

    private func changed() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            guard let self, self.flushScheduled else { return }
            self.flushScheduled = false
            self.flush()
        }
    }

    /// What changed since the last state or patch, to every listener.
    private func flush() {
        flushScheduled = false
        listeners.removeAll { $0.owner == nil }
        guard !listeners.isEmpty else { return stop() }
        let status = chat.feedStatus
        // Nothing anyone's had to follow on from: take a start, quietly.
        let fresh = feed.rev == 0
        if chat.isReplaying {
            needsState = true
            if let patch = feed.patch(status: status), !fresh { emit(.patch(patch)) }
        } else if needsState || fresh {
            needsState = false
            let now = feed.state(chat.items, status: status)
            if !fresh { emit(.state(Snapshot(items: now.items, status: now.status, rev: now.rev))) }
        } else if let patch = feed.patch(chat.items, status: status) {
            emit(.patch(patch))
        }
    }

    private func emit(_ event: Event) {
        for listener in listeners { listener.receive(event) }
    }

    /// Nobody's listening: stop watching, and start afresh for the next one.
    private func stop() {
        watch = nil
        flushScheduled = false
        needsState = false
        feed = RemoteWire.Feed(session: chat.feedID)
    }
}

/// A transcript that isn't a live chat (a subagent's, read from its file):
/// its items, for a page to show.
@MainActor
final class ItemsTranscript: ObservableObject, ChatFeedSource {
    @Published var items: [ChatItem] = []
    let feedID = UUID()
    var feedStatus: RemoteWire.Status {
        RemoteWire.Status(phase: .ready, closedReason: nil, permission: nil, question: nil, modes: [],
                          currentMode: nil, usage: nil, queued: 0)
    }
    var isReplaying: Bool { false }
    var willChange: ObservableObjectPublisher { objectWillChange }
    private(set) lazy var feed = ChatFeed(self)
}
