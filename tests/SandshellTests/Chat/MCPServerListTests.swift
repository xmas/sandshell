import Testing
@testable import Sandshell

/// The MCP panel's groups and the composer chip's red (`MCPServerList`).
struct MCPServerListTests {
    static func server(_ name: String, _ status: String, source: String? = nil, scope: String? = nil,
                       detail: String? = nil) -> ChatSession.MCPServer {
        .init(name: name, status: status, scope: scope, source: source, detail: detail, tools: [])
    }

    static let mixed: [ChatSession.MCPServer] = [
        server("gmail", "needs-auth", scope: "claudeai"),
        server("hatch", "failed", scope: "local", detail: "http://host.docker.internal:31337/mcp"),
        server("asana", "connected", scope: "claudeai"),
        server("incident-io", "needs-auth", scope: "project"),
        server("zendesk", "disabled", scope: "claudeai"),
        server("mcp-gateway", "failed", source: "plugin", scope: "user"),
        server("box", "failed", scope: "claudeai"),
        server("linear", "pending", scope: "claudeai"),
    ]

    @Test func onlyFailuresMakeTheChipRed() {
        #expect(MCPServerList.failing(Self.mixed).map(\.name) == ["hatch", "mcp-gateway", "box"])
        #expect(MCPServerList.failing([Self.server("gmail", "needs-auth"), Self.server("z", "disabled")]).isEmpty,
                "Waiting for sign-in, or turned off, is routine")
    }

    @Test func groupsGoProjectFirstAndClaudeAILast() {
        let groups = MCPServerList.groups(Self.mixed)
        #expect(groups.map(\.source) == ["project", "local", "plugin", "claudeai"])
        #expect(groups.map(\.title) == ["Project", "Local", "Plugins", "claude.ai"])
    }

    @Test func problemsComeFirstInAGroup() throws {
        let claude = try #require(MCPServerList.groups(Self.mixed).first { $0.source == "claudeai" })
        #expect(claude.servers.map(\.name) == ["box", "gmail", "linear", "asana", "zendesk"])
        #expect(claude.notConnected.map(\.name) == ["box", "gmail"])
        #expect(claude.on.count == 4)
        #expect(claude.off.map(\.name) == ["zendesk"])
    }

    @Test(arguments: [
        ("gma", ["gmail"]),
        ("31337", ["hatch"]),           // its URL
        ("claude.ai", ["box", "gmail", "linear", "asana", "zendesk"]),   // its group's title
        ("HATCH", ["hatch"]),
        ("nothing like it", []),
    ])
    func filtering(_ query: String, _ names: [String]) {
        #expect(MCPServerList.groups(Self.mixed, matching: query).flatMap(\.servers).map(\.name) == names)
    }

    @Test func aServerFromNowhereIsOther() {
        let groups = MCPServerList.groups([Self.server("x", "connected")])
        #expect(groups.map(\.title) == ["Other"])
    }

    @Test func theSummarySaysWhatsWorthKnowing() {
        #expect(MCPServerList.summary(Self.mixed) == "1 connected · 3 failed · 2 need sign-in · 1 off")
        #expect(MCPServerList.summary([Self.server("a", "needs-auth")]) == "1 needs sign-in")
    }
}
