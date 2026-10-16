import Foundation

/// One ready-to-go ACP agent per (sandbox, folder, launch settings): started
/// and past `initialize` before anyone asks, so a new chat skips `sbx exec`,
/// the adapter's startup and the handshake (~1.5 s) — the way the Claude app
/// keeps a spare CLI to claim. A spare nobody claims goes after `idleLimit`.
@MainActor
final class ACPSparePool {
    static let shared = ACPSparePool()

    struct Spare {
        let connection: ACPConnection
        let tag: SbxCommand.ProcessTag
        let container: String
        let created: Date
        var ready = false
    }

    private var spares: [String: Spare] = [:]
    private let idleLimit: TimeInterval = 10 * 60

    /// Launch arguments minus the per-launch process tag: what must match.
    static func key(_ arguments: [String]) -> String {
        arguments.filter { !$0.hasPrefix("SANDSHELL_SESSION=") && !$0.hasPrefix("SANDSHELL_LAUNCH=") }
            .joined(separator: "\u{1}")
    }

    /// Take the spare for these arguments if it's up and through `initialize`.
    func claim(_ arguments: [String]) -> Spare? {
        let key = Self.key(arguments)
        guard let spare = spares.removeValue(forKey: key) else { return nil }
        guard spare.connection.isRunning else { retire(spare); return nil }
        // Still in its handshake: leave it for the next chat, start this one cold.
        guard spare.ready else { spares[key] = spare; return nil }
        Log.info(.sbx, "chat: claimed a warm agent in “\(spare.container)” (\(Int(Date().timeIntervalSince(spare.created)))s old)")
        return spare
    }

    /// Start a spare like `arguments` (built with `tag`), unless one's waiting.
    func warm(_ arguments: [String], tag: SbxCommand.ProcessTag, container: String) {
        // Off for a launch with -SandshellNoSpares YES (diagnosis, tests).
        if UserDefaults.standard.bool(forKey: "SandshellNoSpares") { return }
        let key = Self.key(arguments)
        if let existing = spares[key], existing.connection.isRunning { return }
        let conn = ACPConnection(executable: PathFixer.sbxPath(), arguments: arguments)
        do { try conn.start() } catch { return }
        spares[key] = Spare(connection: conn, tag: tag, container: container, created: Date())
        Task { [weak self] in
            // Drain its stream until claimed (stderr chatter); the claimer re-reads nothing from before.
            let ok = (try? await conn.request("initialize", ChatSession.initializeParams)) != nil
            guard let self, var spare = self.spares[key], spare.connection === conn else { return }
            if ok { spare.ready = true; self.spares[key] = spare } else { self.spares[key] = nil; self.retire(spare) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.idleLimit ?? 600))
            guard let self, let spare = self.spares[key], spare.connection === conn else { return }
            self.spares[key] = nil
            self.retire(spare)
        }
    }

    /// Stop every spare (quitting).
    func drain() {
        for spare in spares.values { retire(spare) }
        spares = [:]
    }

    private func retire(_ spare: Spare) {
        spare.connection.terminate()
        SbxClient.reapSessionProcesses(container: spare.container, match: spare.tag.pairs[1])
    }
}
