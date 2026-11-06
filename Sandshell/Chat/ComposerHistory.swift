import Foundation

// The composer's pure logic: messages waiting for the running turn, walking
// back through what you sent (↑/↓), and the ghost text Tab accepts.

// MARK: - Queued messages

/// A message typed while a turn runs: shown above the composer until the turn
/// ends, then sent.
struct QueuedPrompt: Identifiable, Equatable {
    let id: UUID
    var text: String
    var attachments: [ChatAttachment]

    init(id: UUID = UUID(), text: String, attachments: [ChatAttachment] = []) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }
}

/// The messages waiting for the running turn (or the start), in the order
/// they were sent. They go together, in that order, as the next prompt.
struct PromptQueue: Equatable {
    private(set) var items: [QueuedPrompt] = []

    var isEmpty: Bool { items.isEmpty }

    /// Behind the others.
    mutating func append(text: String, attachments: [ChatAttachment] = []) {
        items.append(QueuedPrompt(text: text, attachments: attachments))
    }

    /// Ahead of the others (a message a catch-up holds back goes first).
    mutating func prepend(text: String, attachments: [ChatAttachment] = []) {
        items.insert(QueuedPrompt(text: text, attachments: attachments), at: 0)
    }

    /// Takes one out (Remove, or Edit pulling it back into the composer);
    /// the rest keep their order.
    @discardableResult
    mutating func remove(_ id: QueuedPrompt.ID) -> QueuedPrompt? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    /// All of them as one prompt: the texts a paragraph apart, in order, and
    /// every attachment. Empties the queue.
    mutating func takeAll() -> (text: String, attachments: [ChatAttachment])? {
        guard !items.isEmpty else { return nil }
        defer { items = [] }
        return (items.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"), items.flatMap(\.attachments))
    }
}

// MARK: - Sent history

/// ↑ in an empty composer brings back the last message you sent; ↑/↓ walk
/// further back and forward; ↓ past the newest (or ⎋) puts back what was
/// there. The entries are what this chat sent, oldest first; editing a
/// recalled one doesn't change them.
struct ComposerHistory: Equatable {
    /// Oldest first, without blanks or a message repeated straight after itself.
    let entries: [String]
    /// The entry shown; nil while not walking the history.
    private(set) var index: Int?
    /// What the composer held before the walk started.
    private(set) var draft = ""

    init(sent: [String]) {
        var entries: [String] = []
        for text in sent where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text != entries.last {
            entries.append(text)
        }
        self.entries = entries
    }

    var isWalking: Bool { index != nil }

    /// The composer shows the recalled entry as it was (so ↑/↓ keep walking).
    func isShowingEntry(_ text: String) -> Bool {
        guard let index else { return false }
        return entries[index] == text
    }

    /// One further back from what's shown (the newest, to start); nil when
    /// there's nothing earlier (the composer keeps what it has).
    mutating func older(current: String) -> String? {
        let next: Int
        if let index {
            guard index > 0 else { return nil }
            next = index - 1
        } else {
            guard !entries.isEmpty else { return nil }
            draft = current
            next = entries.count - 1
        }
        index = next
        return entries[next]
    }

    /// One forward; past the newest, the draft again (and the walk ends). Nil
    /// when not walking.
    mutating func newer() -> String? {
        guard let index else { return nil }
        if index + 1 < entries.count {
            self.index = index + 1
            return entries[index + 1]
        }
        return cancel()
    }

    /// ↑ walks back only from a recalled message's first line (and ↓ forward
    /// only from its last); elsewhere in a multi-line one they move the caret.
    static func caretOnFirstLine(of text: String, caret: NSRange) -> Bool {
        let ns = text as NSString
        guard caret.length == 0, caret.location <= ns.length else { return false }
        return ns.rangeOfCharacter(from: .newlines, range: NSRange(location: 0, length: caret.location)).location == NSNotFound
    }

    static func caretOnLastLine(of text: String, caret: NSRange) -> Bool {
        let ns = text as NSString
        guard caret.length == 0, caret.location <= ns.length else { return false }
        let rest = NSRange(location: caret.location, length: ns.length - caret.location)
        return ns.rangeOfCharacter(from: .newlines, range: rest).location == NSNotFound
    }

    /// Stop walking: the draft from before it (nil when not walking).
    mutating func cancel() -> String? {
        guard index != nil else { return nil }
        index = nil
        return draft
    }
}

// MARK: - Ghost text

/// What Tab would add, shown greyed after the caret: the rest of the slash
/// command being typed. The completion list's highlighted command when it's
/// open (Tab takes that), else the one it would list first.
enum CommandGhost {
    /// The characters after `text` that complete `/name`; nil when `text`
    /// isn't a bare `/partial` command or nothing continues it.
    /// - Parameters:
    ///   - commands: the agent's command names, without the slash.
    ///   - selected: the completion list's highlighted command, if it's open.
    static func suffix(for text: String, commands: [String], selected: String? = nil) -> String? {
        guard text.hasPrefix("/"), text.count > 1,
              !text.contains(where: { $0.isWhitespace || $0 == "\u{FFFC}" }) else { return nil }
        let typed = String(text.dropFirst())
        let lower = typed.lowercased()
        func continues(_ name: String) -> Bool { name.count > typed.count && name.lowercased().hasPrefix(lower) }
        let name: String?
        if let selected {
            name = continues(selected) ? selected : nil
        } else {
            name = commands.filter(continues).min()   // the list's order: its first match
        }
        return name.map { String($0.dropFirst(typed.count)) }
    }
}

/// What's been typed in a chat and hasn't gone: the field's text, and messages
/// queued behind a start or a turn. Kept by session on disk, as it's typed, so
/// a reload, a reconnect, a sandbox that never came up or the app going away
/// can't take it; the chat puts it back in the field when it next comes up.
/// (Text only: pasted images don't outlive the app.)
@MainActor
enum ComposerDrafts {
    static var defaults = AppDelegate.isHostingTests
        ? (UserDefaults(suiteName: "SandshellComposerDraftTests") ?? .standard) : .standard

    private static func typedKey(_ id: UUID) -> String { "composerDraft.\(id.uuidString)" }
    private static func queuedKey(_ id: UUID) -> String { "composerQueued.\(id.uuidString)" }

    static func typed(for id: UUID) -> String { defaults.string(forKey: typedKey(id)) ?? "" }
    static func queued(for id: UUID) -> [String] { defaults.stringArray(forKey: queuedKey(id)) ?? [] }

    static func save(typed text: String, for id: UUID) {
        if text.isEmpty { defaults.removeObject(forKey: typedKey(id)) } else { defaults.set(text, forKey: typedKey(id)) }
    }

    static func save(queued: [String], for id: UUID) {
        if queued.isEmpty { defaults.removeObject(forKey: queuedKey(id)) } else { defaults.set(queued, forKey: queuedKey(id)) }
    }

    /// A message that didn't go, back ahead of what's been typed since.
    static func putBack(_ text: String, for id: UUID) {
        save(typed: joined([text, typed(for: id)]), for: id)
    }

    /// What goes back in the field, and the queued messages now that they're
    /// there. Not those if the next chat is carrying them to send (`keepQueued`
    /// false): they'd go twice.
    static func restore(for id: UUID, keepQueued: Bool) -> String {
        if keepQueued { save(typed: joined(queued(for: id) + [typed(for: id)]), for: id) }
        save(queued: [], for: id)
        return typed(for: id)
    }

    static func forget(_ id: UUID) {
        save(typed: "", for: id)
        save(queued: [], for: id)
    }

    static func joined(_ texts: [String]) -> String {
        texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

