import Foundation

/// A chat's MCP servers as the MCP panel lists them: in groups by where
/// they're configured (claude.ai, plugins, ~/.claude.json, the project…),
/// the ones with a problem first in each. And which of them make the
/// composer's MCP chip red: only real failures — a claude.ai connector
/// nobody signed in to is routine, not broken.
enum MCPServerList {
    typealias Server = ChatSession.MCPServer

    struct Group: Identifiable, Equatable {
        /// Claude Code's word for where they're from (`source`, else `scope`).
        let source: String
        let servers: [Server]
        var id: String { source }
        var title: String { MCPServerList.title(of: source) }
        /// On, but not working (failed or waiting for sign-in).
        var notConnected: [Server] { servers.filter { MCPServerList.isProblem($0.status) } }
        var on: [Server] { servers.filter { $0.status != "disabled" } }
        var off: [Server] { servers.filter { $0.status == "disabled" } }
    }

    /// Where a server is from, as the groups go by.
    static func source(of server: Server) -> String {
        guard let from = server.source ?? server.scope, !from.isEmpty else { return "other" }
        return from
    }

    /// The groups, in a fixed order (the project's own first, then the ones
    /// that come from further away), servers ordered problem-first, then by
    /// name. `query` keeps the servers whose name, command/URL or group
    /// title contains it (Finder-style matching); empty groups go.
    static func groups(_ servers: [Server], matching query: String = "") -> [Group] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let kept = q.isEmpty ? servers : servers.filter { s in
            [s.name, s.detail, title(of: source(of: s))].contains { $0?.localizedStandardContains(q) == true }
        }
        return Dictionary(grouping: kept, by: source(of:))
            .map { Group(source: $0.key, servers: $0.value.sorted(by: inPanelOrder)) }
            .sorted { a, b in
                let (ra, rb) = (groupRank(a.source), groupRank(b.source))
                return ra != rb ? ra < rb : a.source.localizedStandardCompare(b.source) == .orderedAscending
            }
    }

    /// The ones that make the MCP chip red: on, and failed.
    static func failing(_ servers: [Server]) -> [Server] {
        servers.filter { $0.status == "failed" }
    }

    /// "12 connected · 2 failed · 3 need sign-in · 4 off": what's worth knowing.
    static func summary(_ servers: [Server]) -> String {
        func count(_ status: String) -> Int { servers.count { $0.status == status } }
        var parts: [String] = []
        if case let n = count("connected"), n > 0 { parts.append("\(n) connected") }
        if case let n = count("failed"), n > 0 { parts.append("\(n) failed") }
        if case let n = count("needs-auth"), n > 0 { parts.append("\(n) need\(n == 1 ? "s" : "") sign-in") }
        if case let n = count("disabled"), n > 0 { parts.append("\(n) off") }
        return parts.joined(separator: " · ")
    }

    /// Failed or waiting for sign-in (and not turned off).
    static func isProblem(_ status: String) -> Bool { status == "failed" || status == "needs-auth" }

    static func title(of source: String) -> String {
        switch source.lowercased() {
        case "claudeai", "claude.ai", "claude-ai": "claude.ai"
        case "plugin": "Plugins"
        case "user": "User"
        case "project": "Project"
        case "local": "Local"
        case "managed", "enterprise": "Managed"
        case "dynamic", "sdk", "session": "This Session"
        case "other": "Other"
        default: source.prefix(1).uppercased() + source.dropFirst()
        }
    }

    private static let order = ["project", "local", "user", "plugin", "managed", "enterprise", "claudeai", "claude.ai", "claude-ai"]
    private static func groupRank(_ source: String) -> Int {
        order.firstIndex(of: source.lowercased()) ?? order.count
    }

    private static func statusRank(_ status: String) -> Int {
        switch status {
        case "failed": 0
        case "needs-auth": 1
        case "connected": 3
        case "disabled": 4
        default: 2   // pending
        }
    }

    private static func inPanelOrder(_ a: Server, _ b: Server) -> Bool {
        let (ra, rb) = (statusRank(a.status), statusRank(b.status))
        return ra != rb ? ra < rb : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
