import Foundation

/// A notification an agent left with `sandshell-notify` (Sandshell's kits):
/// "tell me when the build passes".
struct AgentNote: Decodable, Equatable, Sendable {
    /// The session its process says it's for (`SANDSHELL_SESSION`; a warm
    /// spare's for a chat that started on one).
    var session: String?
    var title: String?
    var message: String
    var at: Date?

    /// Its process's session, if it named one.
    var processSession: UUID? { session.flatMap(UUID.init(uuidString:)) }
}

/// The workspace's `.sandshell/notify`, mounted into its sandboxes: agents
/// leave notes there, the app takes them (each window on the folder looks;
/// the first to claim a note shows it).
enum AgentNotes {
    static func directory(root: URL) -> URL {
        WorkspaceState.controlDir(root: root).appending(path: "notify", directoryHint: .isDirectory)
    }

    /// Notes older than this when found (left while no window was open on the
    /// folder) are dropped: old news.
    static let staleAfter: TimeInterval = 30 * 60

    /// Take every note waiting in `dir`, oldest first, removing them. A file
    /// another window claimed first is left to it; one that isn't a note is
    /// removed.
    static func take(from dir: URL, now: Date = .now) -> [AgentNote] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            return (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
                ?? (try? Date(text, strategy: .iso8601)) ?? .distantPast
        }
        var notes: [(name: String, note: AgentNote)] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = dir.appending(path: name)
            // Claimed by renaming: only one window's rename succeeds.
            let claimed = dir.appending(path: ".claimed-\(UUID().uuidString)")
            guard (try? fm.moveItem(at: file, to: claimed)) != nil else { continue }
            defer { try? fm.removeItem(at: claimed) }
            guard let data = try? Data(contentsOf: claimed),
                  var note = try? decoder.decode(AgentNote.self, from: data) else { continue }
            note.message = note.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if let at = note.at, now.timeIntervalSince(at) > staleAfter { continue }
            guard !note.message.isEmpty || !(note.title ?? "").isEmpty else { continue }
            notes.append((name, note))
        }
        // Names start with the time they were left (ms since 1970).
        return notes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.note)
    }
}
