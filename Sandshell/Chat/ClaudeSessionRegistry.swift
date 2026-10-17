import Foundation

/// Claude Code's registry of running sessions: one `~/.claude/sessions/<pid>.json`
/// per live `claude` process, saying which conversation it has open, who
/// started it (`entrypoint`: cli, claude-desktop, sdk-ts…) and whether it's
/// mid-turn (`status`: busy / idle). Our sandboxes mount `~/.claude`, so their
/// agents register here too (`pidDomain` linux…); Mac processes say `darwin`.
/// The Claude app reads the same files to tell a live writer from a stale one.
enum ClaudeSessionRegistry {
    struct Entry: Decodable, Equatable, Sendable {
        var pid: Int32
        var sessionId: String
        var entrypoint: String?
        var status: String?
        var pidDomain: String?
        var procStart: String?
        var updatedAt: Double?
        var statusUpdatedAt: Double?

        var isBusy: Bool { status == "busy" }
        var isOnThisMac: Bool { pidDomain == nil || pidDomain == "darwin" }
        /// When it last said anything (ms since 1970 in the file).
        var lastUpdate: Date? {
            (statusUpdatedAt ?? updatedAt).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    /// Every registered writer of `sessionID`, live or not. Blocks: call off main.
    nonisolated static func entries(home: String, sessionID: String) -> [Entry] {
        let dir = URL(filePath: home).appending(path: ".claude/sessions", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir.appending(path: name).path(percentEncoded: false)),
                  data.range(of: Data(sessionID.utf8)) != nil,
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.sessionId == sessionID else { return nil }
            return entry
        }
    }

    /// Whether an entry's process is still the one that wrote it. On this Mac:
    /// the pid exists and started when the entry says (pids get reused). In a
    /// sandbox we can't see the process: trust it while it's been heard from
    /// recently, or busy without having gone quiet for long.
    nonisolated static func isAlive(_ e: Entry, now: Date = .now) -> Bool {
        if e.isOnThisMac {
            // (kill with 0 or a negative pid probes a process group, not a process.)
            guard e.pid > 0, kill(e.pid, 0) == 0 || errno == EPERM else { return false }
            guard let started = e.procStart, !started.isEmpty else { return true }
            return processStart(e.pid) == started
        }
        guard let last = e.lastUpdate else { return false }
        return now.timeIntervalSince(last) < (e.isBusy ? 30 * 60 : 6 * 3600)
    }

    /// An entry's identity for remembering it was found gone.
    static func key(_ e: Entry) -> String { "\(e.pid):\(e.procStart ?? "")" }

    /// A busy entry in a sandbox that's gone quiet: ask inside the running
    /// sandboxes whether its process is still there — the pid, started when the
    /// entry says (`/proc/<pid>/stat` field 22, clock ticks since boot). Each
    /// sandbox is its own VM, so any of them could hold that pid. nil: couldn't
    /// tell (keep trusting the entry's age).
    static func sandboxedProcessIsAlive(_ e: Entry) async -> Bool? {
        guard !e.isOnThisMac, let start = e.procStart, Int(start) != nil else { return nil }
        guard let boxes = try? await SbxClient.shared.list() else { return nil }
        let running = boxes.filter(\.isRunning).map(\.name)
        // No sandbox running: nothing in one can be either.
        guard !running.isEmpty else { return false }
        let script = "s=$(sed 's/.*) //' /proc/\(e.pid)/stat 2>/dev/null | cut -d' ' -f20); "
            + "if [ \"$s\" = \(start) ]; then echo alive; else echo gone; fi"
        let answers = await withTaskGroup(of: String?.self) { group in
            for name in running { group.addTask { await SbxClient.shared.exec(inSandbox: name, script: script) } }
            return await group.reduce(into: [String?]()) { $0.append($1?.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return verdict(answers)
    }

    /// What the running sandboxes said of a process (one answer each, nil: it
    /// couldn't be asked): alive if any holds it; gone only when every one said
    /// so — one that didn't answer (busy, timed out) could be the one holding
    /// it; else nil (couldn't tell).
    nonisolated static func verdict(_ answers: [String?]) -> Bool? {
        if answers.contains("alive") { return true }
        return answers.allSatisfy { $0 == "gone" } ? false : nil
    }

    /// The live writer of `sessionID` that isn't our own chat agent (the one
    /// in a sandbox with entrypoint sdk-ts), busiest and most recent first.
    /// `gone`: entries already found dead (`key`).
    nonisolated static func otherWriter(home: String, sessionID: String, gone: Set<String> = []) -> Entry? {
        entries(home: home, sessionID: sessionID)
            .filter { !( !$0.isOnThisMac && $0.entrypoint == "sdk-ts") && !gone.contains(key($0)) && isAlive($0) }
            .sorted { ($0.isBusy ? 1 : 0, $0.lastUpdate ?? .distantPast) > ($1.isBusy ? 1 : 0, $1.lastUpdate ?? .distantPast) }
            .first
    }

    /// `ps -o lstart=` in UTC: how Claude Code records `procStart` on macOS.
    nonisolated static func processStart(_ pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/ps")
        p.arguments = ["-o", "lstart=", "-p", "\(pid)"]
        p.environment = ["TZ": "UTC"]   // Claude Code records it in UTC
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // ps pads single-digit days ("Oct  5"); the registry doesn't.
        return s.isEmpty ? nil : s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
