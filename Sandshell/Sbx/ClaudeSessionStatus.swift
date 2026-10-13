import Combine
import Foundation

/// The JSON Claude Code feeds its `statusLine` command on stdin, decoded for the
/// per-session readout (model, context window, tokens, cost). Only the fields
/// Sandshell shows are modeled; unknown keys are ignored. See
/// https://code.claude.com/docs/en/statusline#available-data
struct ClaudeSessionStatus: Codable, Equatable {
    struct Model: Codable, Equatable {
        var id: String
        var displayName: String
        enum CodingKeys: String, CodingKey { case id, displayName = "display_name" }
    }
    struct Effort: Codable, Equatable {
        var level: String?
    }
    struct ContextWindow: Codable, Equatable {
        struct Usage: Codable, Equatable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens", outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
        var totalInputTokens: Int?
        var totalOutputTokens: Int?
        var contextWindowSize: Int?
        var usedPercentage: Double?
        var currentUsage: Usage?
        enum CodingKeys: String, CodingKey {
            case totalInputTokens = "total_input_tokens", totalOutputTokens = "total_output_tokens"
            case contextWindowSize = "context_window_size", usedPercentage = "used_percentage"
            case currentUsage = "current_usage"
        }
    }
    struct Cost: Codable, Equatable {
        var totalCostUSD: Double?
        var totalDurationMs: Double?
        var totalAPIDurationMs: Double?
        var totalLinesAdded: Int?
        var totalLinesRemoved: Int?
        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd", totalDurationMs = "total_duration_ms"
            case totalAPIDurationMs = "total_api_duration_ms"
            case totalLinesAdded = "total_lines_added", totalLinesRemoved = "total_lines_removed"
        }
    }
    struct Workspace: Codable, Equatable {
        var currentDir: String?
        var projectDir: String?
        enum CodingKeys: String, CodingKey { case currentDir = "current_dir", projectDir = "project_dir" }
    }
    /// Sandbox facts the feed script splices in (not part of Claude's JSON):
    /// container hostname, cgroup memory, 1-minute load.
    struct Sandshell: Codable, Equatable {
        var host: String?
        var memUsed: Double?
        var memTotal: Double?
        var load: Double?
        enum CodingKeys: String, CodingKey { case host, memUsed = "mem_used", memTotal = "mem_total", load }
    }

    /// Plan usage windows (claude.ai Pro/Max, or a gateway spend limit). Each
    /// window is independently absent; Claude Code drops one after it resets.
    struct RateLimits: Codable, Equatable {
        struct Window: Codable, Equatable {
            var usedPercentage: Double?
            var resetsAt: Double?
            enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage", resetsAt = "resets_at" }
        }
        var fiveHour: Window?
        var sevenDay: Window?
        var spendLimit: Window?
        enum CodingKeys: String, CodingKey { case fiveHour = "five_hour", sevenDay = "seven_day", spendLimit = "spend_limit" }
    }

    var sessionID: String?
    var transcriptPath: String?
    var version: String?
    var model: Model?
    var effort: Effort?
    var workspace: Workspace?
    var contextWindow: ContextWindow?
    var cost: Cost?
    var exceeds200kTokens: Bool?
    var rateLimits: RateLimits?
    var sandshell: Sandshell?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", transcriptPath = "transcript_path", version
        case model, effort, workspace, contextWindow = "context_window", cost
        case exceeds200kTokens = "exceeds_200k_tokens", rateLimits = "rate_limits", sandshell
    }

    /// Tokens currently occupying the context window (what "ctx NN%" measures):
    /// fresh input + cache writes + cache reads of the latest turn.
    var contextTokens: Int? {
        guard let u = contextWindow?.currentUsage else { return nil }
        let parts = [u.inputTokens, u.cacheCreationInputTokens, u.cacheReadInputTokens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// One entry in the model chooser. `nil` id means "let Claude Code pick its
/// default". Ids are what `claude --model` accepts.
struct ClaudeModelChoice: Hashable, Identifiable, Sendable {
    let id: String?
    let title: String
    static let systemDefault = ClaudeModelChoice(id: nil, title: "Default")
    /// Offline fallback for the chooser, and the preferred id where several
    /// ids name the same model (the live list comes from `ClaudeModelCatalog`).
    static let builtIn: [ClaudeModelChoice] = [
        ClaudeModelChoice(id: "claude-fable-5-1", title: "Fable 5.1"),
        ClaudeModelChoice(id: "claude-opus-5-5", title: "Opus 5.5"),
        ClaudeModelChoice(id: "claude-sonnet-5-5", title: "Sonnet 5.5"),
        ClaudeModelChoice(id: "claude-sonnet-5", title: "Sonnet 5"),
        ClaudeModelChoice(id: "claude-haiku-4-5-20251001", title: "Haiku 4.5"),
    ]
    static func title(forID id: String?) -> String {
        guard let id else { return systemDefault.title }
        return builtIn.first { $0.id == id }?.title ?? ClaudeModelName.pretty(id)
    }
}

/// The model chooser's contents, rebuilt as its sources change so new models
/// appear (and retired ones drop out) without an app release:
/// - the LiteLLM feed's first-party Anthropic models not past deprecation
///   (refreshed daily by `ClaudeUsageStore`, cached in ~/.sandshell/model-prices.json),
/// - models this Mac's transcripts used this month,
/// - ids typed into "Other model id…" (kept in UserDefaults),
/// - `ClaudeModelChoice.builtIn` as the offline floor.
/// Snapshot ids collapse onto one entry per model; each family shows its two
/// newest versions up top (plus anything used or typed) and the rest under "Older".
@MainActor
final class ClaudeModelCatalog: ObservableObject {
    static let shared = ClaudeModelCatalog()

    struct Menu: Equatable {
        var current: [ClaudeModelChoice] = []
        var older: [ClaudeModelChoice] = []
    }
    @Published private(set) var menu = Menu()

    private var feed: [String] = []
    private var used: [String] = []
    private var custom: [String]
    private static let customKey = "claudeModels.custom"
    private static let customLimit = 8
    private static let perFamily = 2
    private static let familyOrder = ["fable", "mythos", "opus", "sonnet", "haiku"]
    /// Families listed up top; the rest (Mythos is invitation-only) sit under
    /// "Older" unless used or typed.
    private static let mainFamilies: Set<String> = ["fable", "opus", "sonnet", "haiku"]

    private init() {
        custom = UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sandshell/model-prices.json")
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(ClaudePriceSources.FeedCache.self, from: data) {
            feed = cache.models ?? []
        }
        rebuild()
    }

    func setFeedModels(_ ids: [String]) {
        guard ids != feed else { return }
        feed = ids
        rebuild()
    }

    func setUsedModels(_ ids: [String]) {
        let ids = ids.sorted()
        guard ids != used else { return }
        used = ids
        rebuild()
    }

    /// Remember an id typed into "Other model id…" (most recent first).
    func addCustom(_ id: String) {
        custom.removeAll { $0 == id }
        custom.insert(id, at: 0)
        custom = Array(custom.prefix(Self.customLimit))
        UserDefaults.standard.set(custom, forKey: Self.customKey)
        rebuild()
    }

    private struct Entry {
        var id: String
        var title: String
        var family: String
        var version: [Int]
        var pinned: Bool
    }

    /// "claude-sonnet-4-5-20250929" → ("sonnet", [4, 5]); "claude-3-5-haiku" →
    /// ("haiku", [3, 5]). Dated suffixes and trailing ".0" are dropped so
    /// snapshots and aliases of one model share a key. Nil for non-Claude ids.
    private static func parse(_ id: String) -> (family: String, version: [Int])? {
        let parts = ClaudePriceBook.normalize(id).split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return nil }
        var family: String?
        var version: [Int] = []
        for p in parts.dropFirst() {
            if p.allSatisfy(\.isNumber) {
                if p.count < 8, let n = Int(p) { version.append(n) }
            } else if family == nil {
                family = p
            }
        }
        while version.count > 1, version.last == 0 { version.removeLast() }
        return family.map { ($0, version) }
    }

    private func rebuild() {
        let builtInIDs = ClaudeModelChoice.builtIn.compactMap(\.id)
        let pinned = Set(custom).union(used)
        var groups: [String: Entry] = [:]
        var loose: [ClaudeModelChoice] = []   // typed ids that aren't Claude-shaped (gateway aliases)
        for id in builtInIDs + feed + used + custom {
            guard let parsed = Self.parse(id) else {
                if custom.contains(id), !loose.contains(where: { $0.id == id }) {
                    loose.append(ClaudeModelChoice(id: id, title: id))
                }
                continue
            }
            let (family, version) = parsed
            let key = "\(family) \(version.map(String.init).joined(separator: "."))"
            let title = ClaudeModelChoice.builtIn.first { $0.id == id }?.title ?? ClaudeModelName.pretty(id)
            let entry = Entry(id: id, title: title, family: family, version: version, pinned: pinned.contains(id))
            guard var existing = groups[key] else { groups[key] = entry; continue }
            existing.pinned = existing.pinned || entry.pinned
            // Preferred id: built-in, then typed, then the shortest (undated alias).
            func rank(_ i: String) -> (Int, Int, String) {
                (builtInIDs.contains(i) ? 0 : custom.contains(i) ? 1 : 2, i.count, i)
            }
            if rank(id) < rank(existing.id) { existing.id = id; existing.title = title }
            groups[key] = existing
        }

        func familyRank(_ f: String) -> Int { Self.familyOrder.firstIndex(of: f) ?? Self.familyOrder.count }
        let sorted = groups.values.sorted {
            if $0.family != $1.family {
                let a = familyRank($0.family), b = familyRank($1.family)
                return a != b ? a < b : $0.family < $1.family
            }
            return $1.version.lexicographicallyPrecedes($0.version)   // newest first
        }
        var out = Menu()
        var shown: [String: Int] = [:]
        for e in sorted {
            let choice = ClaudeModelChoice(id: e.id, title: e.title)
            let known = Self.mainFamilies.contains(e.family)
            if e.pinned || (known && shown[e.family, default: 0] < Self.perFamily) {
                out.current.append(choice)
                shown[e.family, default: 0] += 1
            } else {
                out.older.append(choice)
            }
        }
        out.current.append(contentsOf: loose)
        if out != menu { menu = out }
    }
}

/// Effort levels offered in the effort chooser. `nil` id means "let Claude Code
/// pick its default". Ids are what `claude --effort` accepts.
struct ClaudeEffortChoice: Hashable, Identifiable {
    let id: String?
    let title: String
    static let systemDefault = ClaudeEffortChoice(id: nil, title: "Default")
    static let catalog: [ClaudeEffortChoice] = [
        .systemDefault,
        ClaudeEffortChoice(id: "low", title: "Low"),
        ClaudeEffortChoice(id: "medium", title: "Medium"),
        ClaudeEffortChoice(id: "high", title: "High"),
        ClaudeEffortChoice(id: "xhigh", title: "Extra High"),
        ClaudeEffortChoice(id: "max", title: "Max"),
    ]
    static func title(forID id: String?) -> String {
        guard let id else { return systemDefault.title }
        return catalog.first { $0.id == id }?.title ?? id.capitalized
    }
}

/// The per-workspace status feed: Sandshell owns Claude's `statusLine` command
/// for the sessions it launches. The script persists each status JSON (plus the
/// sandbox's host/memory/load) to `<root>/.sandshell/status/<session-uuid>.json`,
/// which the app watches, and prints a deliberately minimal in-terminal status
/// line — just `path (branch*)` — since the title strip carries model, context,
/// tokens and cost. Everything lives under the workspace root, which is
/// bind-mounted at the same path inside the container, so host and container
/// agree on paths.
enum ClaudeStatusFeed {
    static func statusDir(root: URL) -> URL {
        WorkspaceState.controlDir(root: root).appendingPathComponent("status", isDirectory: true)
    }
    static func scriptURL(root: URL) -> URL {
        WorkspaceState.controlDir(root: root).appendingPathComponent("statusline.sh")
    }
    static func statusFile(root: URL, sessionID: UUID) -> URL {
        statusDir(root: root).appendingPathComponent("\(sessionID.uuidString).json")
    }

    /// Ensure the status dir and the (idempotent) feed script exist. Returns the
    /// script path, or nil when the control dir isn't writable.
    @discardableResult
    static func prepare(root: URL) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: statusDir(root: root), withIntermediateDirectories: true)
            let url = scriptURL(root: root)
            if (try? String(contentsOf: url, encoding: .utf8)) != scriptBody {
                try scriptBody.write(to: url, atomically: true, encoding: .utf8)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            Log.error(.workspace, "status feed: cannot prepare \(root.path): \(error)")
            return nil
        }
    }

    /// Inline JSON for `claude --settings`, pointing `statusLine` at the feed script.
    static func settingsJSON(scriptPath: String) -> String {
        let escaped = scriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"statusLine":{"type":"command","command":"\#(escaped)"}}"#
    }

    static func removeStatusFile(root: URL, sessionID: UUID) {
        try? FileManager.default.removeItem(at: statusFile(root: root, sessionID: sessionID))
    }

    /// Runs inside the container on every status-line refresh, so it stays cheap:
    /// one jq to splice sandbox facts, one write, two git calls for the line.
    static let scriptBody = """
    #!/bin/sh
    # Sandshell status feed (generated; edits are overwritten).
    # 1. Persist Claude Code's status JSON (+ sandbox host/mem/load) for the Sandshell window.
    # 2. Print a minimal status line for the terminal: path (branch*). Sandshell shows the rest.
    input=$(cat)
    dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
    [ -n "$dir" ] || dir=$(pwd)
    if [ -n "$SANDSHELL_STATUS_DIR" ] && [ -n "$SANDSHELL_SESSION_ID" ]; then
      mkdir -p "$SANDSHELL_STATUS_DIR" 2>/dev/null
      mem_used=0; mem_total=0; load=0
      if [ -r /sys/fs/cgroup/memory.current ] && [ -r /sys/fs/cgroup/memory.max ]; then
        mem_used=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
        mem_total=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
      fi
      if [ "$mem_total" = "max" ] || [ "${mem_total:-0}" = 0 ]; then
        mem_total=$(awk '/^MemTotal:/{print $2*1024}' /proc/meminfo 2>/dev/null)
        [ "${mem_used:-0}" = 0 ] && mem_used=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print (t-a)*1024}' /proc/meminfo 2>/dev/null)
      fi
      [ -r /proc/loadavg ] && load=$(awk '{print $1}' /proc/loadavg)
      out=$(printf '%s' "$input" | jq -c --arg host "$(hostname)" --arg mu "${mem_used:-0}" --arg mt "${mem_total:-0}" --arg load "${load:-0}" \\
            '. + {sandshell: {host: $host, mem_used: ($mu|tonumber? // 0), mem_total: ($mt|tonumber? // 0), load: ($load|tonumber? // 0)}}' 2>/dev/null)
      [ -n "$out" ] || out=$input
      tmp="$SANDSHELL_STATUS_DIR/$SANDSHELL_SESSION_ID.json.tmp"
      if printf '%s\\n' "$out" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$SANDSHELL_STATUS_DIR/$SANDSHELL_SESSION_ID.json" 2>/dev/null
      fi
    fi
    DIM=$(printf '\\033[2m'); RST=$(printf '\\033[0m'); GREEN=$(printf '\\033[32m'); RED=$(printf '\\033[31m')
    line="${DIM}${dir}${RST}"
    if branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null); then
      if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null | head -n1)" ]; then
        line="$line ${GREEN}(${branch}${RED}*${GREEN})${RST}"
      else
        line="$line ${GREEN}(${branch})${RST}"
      fi
    fi
    printf '%s' "$line"

    """
}
