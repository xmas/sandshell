import Foundation

/// Outcome of one kit's (or one startup step's) run inside the sandbox.
enum KitStartupOutcome: Equatable {
    /// The dispatcher has started this step/kit and not yet reported on it.
    case running
    case ok
    /// Exited 0 but printed a `WARNING` line (e.g. "could not obtain binary,
    /// continuing without it").
    case warning
    /// Exited non-zero. The dispatcher aborts the whole chain on the first one.
    case failed(exitCode: Int)
    /// Configured for the sandbox but never reached — an earlier kit failed and
    /// the dispatcher stopped.
    case skipped
    /// Configured for the sandbox, dispatcher finished, but the log has no entry
    /// for it (a kit with no startup steps).
    case noSteps

    var isProblem: Bool {
        switch self {
        case .warning, .failed, .skipped: true
        case .running, .ok, .noSteps: false
        }
    }

    var label: String {
        switch self {
        case .running:                "installing"
        case .ok:                     "ok"
        case .warning:                "warning"
        case .failed(let code):       "failed (exit \(code))"
        case .skipped:                "skipped"
        case .noSteps:                "not run"
        }
    }

    /// Ranking so a kit's aggregate outcome is its worst step.
    fileprivate var severity: Int {
        switch self {
        case .ok: 0
        case .noSteps: 0
        case .running: 1
        case .warning: 2
        case .skipped: 3
        case .failed: 4
        }
    }
}

/// Parsed view of the sandbox's kit startup log
/// (`/var/log/sbx-kit-startup.log`, written by `/etc/durable-startup.d/run.sh`).
///
/// The dispatcher appends one block per boot:
/// ```
/// === dispatcher run 2026-09-17T21:25:15Z ===
/// > /etc/durable-startup.d/002-startup-hatch-kit/000-cmd.sh
/// [hatch-kit] WARNING: could not obtain hatch-mcp binary.
/// ok /etc/durable-startup.d/002-startup-hatch-kit/000-cmd.sh
/// > /etc/durable-startup.d/003-startup-beads-kit/000-cmd.sh
/// fail /etc/durable-startup.d/003-startup-beads-kit/000-cmd.sh exit=22
/// === dispatcher complete ===
/// ```
/// Only the **last** block is parsed. A `fail` line ends the run (the dispatcher
/// `exit`s), so a block with a failure and no "complete" marker is *aborted*.
struct KitStartupReport: Equatable {
    struct Step: Equatable {
        /// Full script path as logged, e.g. `/etc/durable-startup.d/003-startup-beads-kit/000-cmd.sh`.
        var script: String
        var outcome: KitStartupOutcome
        /// Everything the step printed between its `>` and `ok`/`fail` lines.
        var output: [String]
    }

    struct Kit: Equatable, Identifiable {
        /// Namespace directory, e.g. `003-startup-beads-kit`.
        var id: String
        /// Kit name as `sbx` knows it, e.g. `beads-kit` (namespace minus the
        /// `NNN-startup-` prefix). Matches the leaf of a directory kit ref.
        var name: String
        var steps: [Step]

        var outcome: KitStartupOutcome {
            steps.map(\.outcome).max(by: { $0.severity < $1.severity }) ?? .noSteps
        }
        /// `WARNING` lines the kit printed (trimmed, tag stripped).
        var warnings: [String] {
            steps.flatMap(\.output).compactMap(KitStartupParser.warningText)
        }
        /// Output lines of the worst step worth showing as detail: progress-bar
        /// noise (curl's `% Total … Dload Upload` table) is dropped, and when the
        /// step printed anything error-like those lines win over the rest.
        var detailLines: [String] {
            let worst = steps.max(by: { $0.outcome.severity < $1.outcome.severity })
            let lines = (worst?.output ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !KitStartupParser.isProgressNoise($0) }
            let errors = lines.filter(KitStartupParser.looksLikeError)
            return errors.isEmpty ? lines : errors
        }
        var output: [String] { steps.flatMap(\.output) }
    }

    var startedAt: Date?
    var kits: [Kit]
    /// `=== dispatcher complete ===` was logged.
    var isComplete: Bool
    /// A step failed and the dispatcher stopped (no "complete" marker follows).
    var isAborted: Bool { !isComplete && kits.contains { if case .failed = $0.outcome { return true }; return false } }
    /// Still running: no completion, no abort.
    var isInProgress: Bool { !isComplete && !isAborted }

    func kit(named name: String) -> Kit? { kits.first { $0.name == name } }
}

/// A workspace kit reconciled against the startup report — what the UI renders.
struct KitStartupEntry: Equatable, Identifiable {
    /// The kit reference from `WorkspaceConfig.kits` (path/zip/OCI).
    var ref: String
    /// Name used to match the log (`ref`'s last path component).
    var name: String
    var outcome: KitStartupOutcome
    /// Detail lines for the banner / inspector (warnings first, else last output).
    var detail: [String]
    var id: String { ref }
}

/// Snapshot of kit startup for one workspace container.
struct KitStartupStatus: Equatable {
    var containerName: String
    var report: KitStartupReport?
    /// Set when the log couldn't be read (container stopped, old daemon without
    /// a dispatcher, `sbx exec` failure). The UI shows nothing in that case.
    var fetchError: String?
    var fetchedAt: Date
    /// Kits configured for this workspace, reconciled against `report`.
    var entries: [KitStartupEntry]

    var problems: [KitStartupEntry] { entries.filter { $0.outcome.isProblem } }
    var installing: [KitStartupEntry] { entries.filter { $0.outcome == .running } }
    /// True while the dispatcher is still working (kits may still be installing).
    var isInProgress: Bool { report?.isInProgress ?? false }
    var isComplete: Bool { report?.isComplete ?? false }
    var hasProblems: Bool { !problems.isEmpty }

    /// Stable identity of *this* set of findings — used to remember a dismissed
    /// banner so it doesn't return on every poll, but does return after a rebuild.
    var signature: String {
        let started = report?.startedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return containerName + "|" + started + "|" + problems.map { "\($0.name)=\($0.outcome.label)" }.joined(separator: ",")
    }

    /// Reconcile the configured kit refs against a parsed report.
    static func make(containerName: String, kitRefs: [String], report: KitStartupReport?,
                     fetchError: String? = nil, now: Date = .now) -> KitStartupStatus {
        var entries: [KitStartupEntry] = []
        for ref in kitRefs {
            let name = KitStartupParser.kitName(forRef: ref)
            guard let report else {
                entries.append(KitStartupEntry(ref: ref, name: name, outcome: .running, detail: []))
                continue
            }
            if let kit = report.kit(named: name) {
                let warnings = kit.warnings
                let detail = warnings.isEmpty ? Array(kit.detailLines.suffix(3)) : warnings
                entries.append(KitStartupEntry(ref: ref, name: name, outcome: kit.outcome, detail: detail))
            } else if report.isAborted {
                let culprit = report.kits.first { if case .failed = $0.outcome { return true }; return false }?.name
                entries.append(KitStartupEntry(
                    ref: ref, name: name, outcome: .skipped,
                    detail: [culprit.map { "Startup stopped after “\($0)” failed." } ?? "Startup stopped after an earlier failure."]))
            } else if report.isComplete {
                entries.append(KitStartupEntry(
                    ref: ref, name: name, outcome: .noSteps,
                    detail: ["No startup steps for this kit ran in this sandbox. If the kit was added after the sandbox was created, rebuild to apply it."]))
            } else {
                entries.append(KitStartupEntry(ref: ref, name: name, outcome: .running, detail: []))
            }
        }
        return KitStartupStatus(containerName: containerName, report: report, fetchError: fetchError,
                                fetchedAt: now, entries: entries)
    }
}

enum KitStartupParser {
    /// In-sandbox path of the dispatcher log.
    static let logPath = "/var/log/sbx-kit-startup.log"

    private static let runMarker = "=== dispatcher run "
    private static let completeMarker = "=== dispatcher complete ==="

    /// Parse the last dispatcher run in `text`. Returns nil if no run marker exists.
    static func parse(_ text: String) -> KitStartupReport? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.lastIndex(where: { $0.hasPrefix(runMarker) }) else { return nil }

        var report = KitStartupReport(startedAt: parseTimestamp(lines[start]), kits: [], isComplete: false)
        var current: (namespace: String, step: KitStartupReport.Step)?

        func flush(_ outcome: KitStartupOutcome) {
            guard var cur = current else { return }
            cur.step.outcome = outcome
            if let i = report.kits.firstIndex(where: { $0.id == cur.namespace }) {
                report.kits[i].steps.append(cur.step)
            } else {
                report.kits.append(KitStartupReport.Kit(id: cur.namespace, name: kitName(forNamespace: cur.namespace), steps: [cur.step]))
            }
            current = nil
        }

        for raw in lines[(start + 1)...] {
            let line = raw.trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.hasPrefix("> ") {
                flush(.running)   // a previous step without ok/fail (shouldn't happen)
                let script = String(line.dropFirst(2))
                current = (namespace(of: script), KitStartupReport.Step(script: script, outcome: .running, output: []))
            } else if line.hasPrefix("ok "), let cur = current, line.dropFirst(3) == cur.step.script[...] {
                let warned = cur.step.output.contains { warningText($0) != nil }
                flush(warned ? .warning : .ok)
            } else if line.hasPrefix("fail "), let cur = current, line.dropFirst(5).hasPrefix(cur.step.script) {
                let code = line.range(of: "exit=").map { Int(line[$0.upperBound...].trimmingCharacters(in: .whitespaces)) ?? -1 } ?? -1
                flush(.failed(exitCode: code))
            } else if line == completeMarker {
                flush(.running)
                report.isComplete = true
            } else if current != nil {
                current?.step.output.append(line)
            }
            // Other lines outside a step (e.g. "no startup root") are ignored.
        }
        flush(.running)
        return report
    }

    /// `/etc/durable-startup.d/003-startup-beads-kit/000-cmd.sh` → `003-startup-beads-kit`.
    static func namespace(of script: String) -> String {
        let parts = script.split(separator: "/")
        guard parts.count >= 2 else { return script }
        return String(parts[parts.count - 2])
    }

    /// `003-startup-beads-kit` → `beads-kit`; `001-startup-claude` → `claude`.
    static func kitName(forNamespace ns: String) -> String {
        var s = Substring(ns)
        // Strip the ordering prefix (digits + dash).
        let digits = s.prefix { $0.isNumber }
        if !digits.isEmpty, s.dropFirst(digits.count).first == "-" {
            s = s.dropFirst(digits.count + 1)
        }
        if s.hasPrefix("startup-") { s = s.dropFirst("startup-".count) }
        return String(s)
    }

    /// The name `sbx` gives a kit ref's startup namespace: the last path
    /// component (for `/path/to/hatch-kit`, `hatch-kit.zip` → `hatch-kit`), or the
    /// image name for an OCI ref (`ghcr.io/org/hatch-kit:1.2` → `hatch-kit`).
    static func kitName(forRef ref: String) -> String {
        var leaf = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        while leaf.hasSuffix("/") { leaf.removeLast() }
        leaf = (leaf as NSString).lastPathComponent
        if leaf.lowercased().hasSuffix(".zip") { leaf = String(leaf.dropLast(4)) }
        if let at = leaf.firstIndex(of: "@") { leaf = String(leaf[..<at]) }
        if let colon = leaf.firstIndex(of: ":") { leaf = String(leaf[..<colon]) }
        return leaf.isEmpty ? ref : leaf
    }

    /// curl/wget progress output: the `% Total % Received …` header, the
    /// `Dload Upload Total Spent Left Speed` header, and rows that are only
    /// numbers/units/punctuation.
    static func isProgressNoise(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("%") { return true }
        if t.hasPrefix("Dload") { return true }
        let numeric = CharacterSet(charactersIn: "0123456789 .:-%kKmMgGbB")
        return !t.isEmpty && t.unicodeScalars.allSatisfy { numeric.contains($0) }
    }

    /// Heuristic for a line that explains a failure (used to pick detail lines).
    static func looksLikeError(_ line: String) -> Bool {
        let l = line.lowercased()
        let needles = ["error", "fail", "cannot", "can't", "could not", "couldn't", "not found",
                       "denied", "timed out", "timeout", "refused", "warning", "unable", "missing",
                       "no such", "curl:", "wget:", "exit=", "exit code"]
        return needles.contains { l.contains($0) }
    }

    /// If `line` is a warning (`[kit] WARNING: …`, `warning: …`), return the
    /// message with any `[tag]` prefix and the `WARNING:` keyword stripped.
    static func warningText(_ line: String) -> String? {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        let lower = s.lowercased()
        guard lower.hasPrefix("warning") else { return nil }
        s = String(s.dropFirst("warning".count))
        if s.hasPrefix(":") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func parseTimestamp(_ line: String) -> Date? {
        // "=== dispatcher run 2026-09-17T21:25:15Z ==="
        let body = line.dropFirst(runMarker.count)
        let stamp = body.split(separator: " ").first.map(String.init) ?? ""
        return try? Date(stamp, strategy: .iso8601)
    }
}
