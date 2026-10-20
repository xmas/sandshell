import Foundation

/// What Remote Control sends a remote device (the web client): chats as plain
/// Codable values. A device follows one session at a time — a full `State`
/// when it starts, then `Patch`es — plus the list of sessions it may open.
enum RemoteWire {
    /// Bumped when a change would break a client built for the old shape.
    static let version = 1
    /// A device opening a long chat gets its last items only.
    static let initialItemLimit = 300
    /// Text past this (a tool's output, a diff side) is cut short.
    static let textLimit = 20_000

    struct SessionSummary: Codable, Equatable, Sendable {
        let id: UUID
        let name: String
        /// `AgentKind.rawValue`, and how it's written.
        let agent: String
        let agentName: String
        /// The session's folder, `~/…`.
        let folder: String
        let phase: Phase
        /// What it waits on you for (a permission's title, a question), if anything.
        let waiting: String?
        /// The DEBUG check session (a fake agent the device's /check drives).
        let isCheck: Bool
    }

    enum Phase: String, Codable, Sendable {
        case starting, ready, running, closed

        init(_ phase: ChatSession.Phase) {
            self = switch phase {
            case .starting: .starting
            case .ready: .ready
            case .running: .running
            case .closed: .closed
            }
        }
    }

    struct Item: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case user, text, thought, tool, plan, notice, image, changes }
        let id: String
        let kind: Kind
        var text: String?
        var attachments: [String]?
        var isError: Bool?
        var tool: Tool?
        var plan: [PlanEntry]?
        /// An image's address on this server (`/api/sessions/<id>/images/<item>/0`).
        var image: String?
        var paths: [String]?
        var restored: Bool?
    }

    struct Tool: Codable, Equatable, Sendable {
        let title: String
        let kind: String
        let status: String
        let input: String
        let output: String
        let diffs: [Diff]
        /// Addresses of its images.
        let images: [String]
    }

    struct Diff: Codable, Equatable, Sendable {
        let path: String
        let oldText: String?
        let newText: String
    }

    struct PlanEntry: Codable, Equatable, Sendable {
        let content: String
        let status: String
    }

    struct Choice: Codable, Equatable, Sendable {
        let id: String
        let name: String
    }

    struct Permission: Codable, Equatable, Sendable {
        struct Option: Codable, Equatable, Sendable { let id: String; let name: String; let kind: String }
        /// Which prompt an answer is for (its JSON-RPC id), so a stale answer is ignored.
        let id: String
        let title: String
        let options: [Option]
    }

    struct Question: Codable, Equatable, Sendable {
        struct Field: Codable, Equatable, Sendable {
            /// choice | multiChoice | text | number | toggle
            let kind: String
            let id: String
            let title: String?
            let detail: String?
            let required: Bool
            let options: [Choice]?
            let secret: Bool?
            /// For a choice's "Other…": the text field it goes with.
            let companionOf: String?
        }
        let id: String
        let message: String
        /// A sign-in link to open instead of a form.
        let url: String?
        let fields: [Field]
    }

    struct Usage: Codable, Equatable, Sendable {
        let used: Int
        let size: Int
        let cost: Double?
    }

    /// Everything about one session but its items.
    struct Status: Codable, Equatable, Sendable {
        let phase: Phase
        let closedReason: String?
        let permission: Permission?
        let question: Question?
        let modes: [Choice]
        let currentMode: String?
        let usage: Usage?
        /// Messages waiting for the turn to end.
        let queued: Int
    }

    /// A session as a device first sees it.
    struct State: Codable, Equatable, Sendable {
        let session: SessionSummary
        let status: Status
        let items: [Item]
        /// Older items left out (`initialItemLimit`).
        let omitted: Int
    }

    /// What changed since the last patch (or the state).
    struct Patch: Codable, Equatable, Sendable {
        let session: UUID
        /// Items new or changed since.
        let upserts: [Item]
        /// Every item id in order — sent only when the order isn't the old one
        /// plus the new ids appended (an item went, or one was inserted).
        let order: [String]?
        let status: Status?
    }

    /// The patch that takes a device from `old` to `new` (nil: nothing changed).
    static func patch(session: UUID, from old: [Item], to new: [Item],
                      oldStatus: Status?, newStatus: Status) -> Patch? {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let upserts = new.filter { before[$0.id] != $0 }
        let oldIDs = old.map(\.id), newIDs = new.map(\.id)
        // Appending keeps the order: the device adds new ids at the end.
        let appended = newIDs.count >= oldIDs.count && Array(newIDs.prefix(oldIDs.count)) == oldIDs
        let status = oldStatus == newStatus ? nil : newStatus
        if upserts.isEmpty, appended, status == nil { return nil }
        return Patch(session: session, upserts: upserts, order: appended ? nil : newIDs, status: status)
    }

    // MARK: From the chat's own types

    static func items(_ items: [ChatItem], session: UUID) -> [Item] {
        items.map { item(from: $0, session: session) }
    }

    static func item(from item: ChatItem, session: UUID) -> Item {
        switch item {
        case .user(_, let text, let attachments):
            return Item(id: item.id, kind: .user, text: text, attachments: attachments.isEmpty ? nil : attachments)
        case .agentText(_, let text):
            return Item(id: item.id, kind: .text, text: text)
        case .thought(_, let text):
            return Item(id: item.id, kind: .thought, text: text)
        case .tool(let call):
            return Item(id: item.id, kind: .tool, tool: tool(call, itemID: item.id, session: session))
        case .toolGroup(let calls):
            // Display only (the Mac's transcript makes these); never in a session's items.
            return Item(id: item.id, kind: .tool, tool: calls.first.map { tool($0, itemID: item.id, session: session) })
        case .plan(_, let entries):
            return Item(id: item.id, kind: .plan, plan: entries.map { PlanEntry(content: $0.content, status: $0.status) })
        case .notice(_, let text, let isError):
            return Item(id: item.id, kind: .notice, text: text, isError: isError ? true : nil)
        case .image:
            return Item(id: item.id, kind: .image, image: imagePath(session: session, item: item.id, index: 0))
        case .fileChanges(_, let paths, let restored):
            return Item(id: item.id, kind: .changes, paths: paths, restored: restored ? true : nil)
        }
    }

    private static func tool(_ call: ChatItem.ToolCall, itemID: String, session: UUID) -> Tool {
        Tool(title: call.title, kind: call.kind, status: call.status, input: clip(call.input), output: clip(call.output),
             diffs: call.diffs.map { Diff(path: $0.path, oldText: $0.oldText.map(clip), newText: clip($0.newText)) },
             images: call.images.indices.map { imagePath(session: session, item: itemID, index: $0) })
    }

    static func imagePath(session: UUID, item: String, index: Int) -> String {
        "/api/sessions/\(session.uuidString)/images/\(item)/\(index)"
    }

    /// The image an address names, from the chat's items.
    static func image(in items: [ChatItem], item: String, index: Int) -> Data? {
        guard let found = items.first(where: { $0.id == item }) else { return nil }
        switch found {
        case .image(_, let data): return index == 0 ? data : nil
        case .tool(let call): return call.images.indices.contains(index) ? call.images[index] : nil
        default: return nil
        }
    }

    static func clip(_ text: String) -> String {
        text.count <= textLimit ? text : String(text.prefix(textLimit)) + "\n… (cut short)"
    }

    static func permission(_ p: PendingPermission?) -> Permission? {
        p.map { Permission(id: $0.id.compactString, title: $0.title,
                           options: $0.options.map { .init(id: $0.id, name: $0.name, kind: $0.kind) }) }
    }

    static func question(_ q: AgentQuestion?) -> Question? {
        guard let q else { return nil }
        let url: String? = if case .url(let u, _) = q.mode { u.absoluteString } else { nil }
        let fields = q.fields.map { f -> Question.Field in
            let (kind, options, secret): (String, [AgentQuestion.Option]?, Bool?) = switch f.kind {
            case .choice(let o): ("choice", o, nil)
            case .multiChoice(let o): ("multiChoice", o, nil)
            case .text(let s): ("text", nil, s ? true : nil)
            case .number: ("number", nil, nil)
            case .toggle: ("toggle", nil, nil)
            }
            return .init(kind: kind, id: f.id, title: f.title, detail: f.detail, required: f.required,
                         options: options?.map { Choice(id: $0.value, name: $0.title) }, secret: secret,
                         companionOf: f.companionOf)
        }
        return Question(id: q.id, message: q.message, url: url, fields: fields)
    }

    /// The JSON a device's answer to `question` stands for.
    static func answer(_ action: String, content: [String: JSONValue]?) -> AgentQuestion.Answer? {
        switch action {
        case "accept": .accept(content ?? [:])
        case "decline": .decline
        case "cancel": .cancel
        default: nil
        }
    }
}

extension RemoteWire.Status {
    @MainActor init(_ chat: ChatSession) {
        let reason: String? = if case .closed(let why) = chat.phase { why } else { nil }
        self.init(phase: .init(chat.phase), closedReason: reason,
                  permission: RemoteWire.permission(chat.permission),
                  question: RemoteWire.question(chat.question),
                  modes: chat.modes.map { .init(id: $0.id, name: $0.name) },
                  currentMode: chat.currentMode,
                  usage: chat.usage.map { .init(used: $0.used, size: $0.size, cost: $0.cost) },
                  queued: chat.queue.items.count)
    }
}
