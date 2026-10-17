import Foundation

/// Claude Code's `/context` breakdown for a chat (the Agent SDK's
/// `getContextUsage()`, through the sandshell-claude kit's wrapper): how the
/// context window is spent, by category, with the MCP tools, memory files and
/// skills behind it, and how far it is from compacting on its own.
struct ContextUsage: Equatable, Sendable {
    struct Category: Equatable, Sendable, Identifiable {
        enum Kind: String, Sendable { case used, free, buffer, deferred }
        let name: String
        let tokens: Int
        /// Claude Code's colour name for the row (`promptBorder`, `inactive`, a hex…).
        let color: String
        let kind: Kind
        var id: String { name }
    }
    struct Item: Equatable, Sendable, Identifiable {
        let name: String
        /// The MCP server, or the memory file's source ("Project", "User").
        let detail: String?
        let tokens: Int
        /// An MCP tool that's only described to the model when it asks (deferred).
        var deferred = false
        var id: String { (detail ?? "") + "/" + name }
    }

    let model: String
    let totalTokens: Int
    /// The window usage is measured against (the auto-compact window).
    let maxTokens: Int
    let percentage: Int
    let categories: [Category]
    let mcpTools: [Item]
    let memoryFiles: [Item]
    let skills: [Item]
    let autoCompactThreshold: Int?
    let isAutoCompactEnabled: Bool

    /// The rows that fill the window (used, then the buffer, then free space).
    var windowRows: [Category] { categories.filter { $0.kind != .deferred && $0.tokens > 0 } }
    /// Tool schemas outside the window, listed for awareness.
    var deferredRows: [Category] { categories.filter { $0.kind == .deferred && $0.tokens > 0 } }
    var usedTokens: Int { categories.filter { $0.kind == .used }.reduce(0) { $0 + $1.tokens } }
    /// Tokens left before Claude Code compacts the conversation by itself.
    var untilAutoCompact: Int? {
        guard isAutoCompactEnabled, let threshold = autoCompactThreshold else { return nil }
        return max(0, threshold - totalTokens)
    }

    /// From `getContextUsage()`'s reply (camelCase, as the SDK returns it).
    init?(_ v: JSONValue) {
        guard let cats = v["categories"]?.array, let total = v["totalTokens"]?.int else { return nil }
        model = v["model"]?.string ?? ""
        totalTokens = total
        maxTokens = v["maxTokens"]?.int ?? v["rawMaxTokens"]?.int ?? 0
        percentage = v["percentage"]?.int ?? (maxTokens > 0 ? total * 100 / maxTokens : 0)
        categories = cats.compactMap { c in
            guard let name = c["name"]?.string else { return nil }
            let kind = c["kind"]?.string.flatMap(Category.Kind.init(rawValue:))
                ?? (c["isDeferred"]?.bool == true ? .deferred : .used)
            return Category(name: name, tokens: c["tokens"]?.int ?? 0, color: c["color"]?.string ?? "", kind: kind)
        }
        mcpTools = (v["mcpTools"]?.array ?? []).compactMap { t in
            guard let name = t["name"]?.string else { return nil }
            return Item(name: name, detail: t["serverName"]?.string, tokens: t["tokens"]?.int ?? 0,
                        deferred: t["isLoaded"]?.bool == false)
        }
        memoryFiles = (v["memoryFiles"]?.array ?? []).compactMap { f in
            guard let path = f["path"]?.string else { return nil }
            return Item(name: path, detail: f["type"]?.string, tokens: f["tokens"]?.int ?? 0)
        }
        skills = (v["skills"]?["skillFrontmatter"]?.array ?? []).compactMap { s in
            guard let name = s["name"]?.string else { return nil }
            return Item(name: name, detail: s["source"]?.string, tokens: s["tokens"]?.int ?? 0)
        }
        autoCompactThreshold = v["autoCompactThreshold"]?.int
        isAutoCompactEnabled = v["isAutoCompactEnabled"]?.bool ?? false
    }

    /// The MCP tools grouped by server, most tokens first.
    var mcpToolsByServer: [(server: String, tokens: Int, tools: [Item])] {
        Dictionary(grouping: mcpTools, by: { $0.detail ?? "" })
            .map { (server: $0.key, tokens: $0.value.reduce(0) { $0 + $1.tokens }, tools: $0.value.sorted { $0.tokens > $1.tokens }) }
            .sorted { $0.tokens > $1.tokens }
    }
}
