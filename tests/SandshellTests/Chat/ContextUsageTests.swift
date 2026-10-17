import Foundation
import Testing
@testable import Sandshell

struct ContextUsageTests {
    /// getContextUsage()'s reply, as the SDK returns it (camelCase).
    private static let reply: JSONValue = [
        "model": "claude-opus-5-5",
        "totalTokens": 200_000,
        "maxTokens": 1_000_000,
        "rawMaxTokens": 1_000_000,
        "percentage": 20,
        "categories": [
            ["name": "Messages", "tokens": 150_000, "color": "promptBorder", "kind": "used"],
            ["name": "System tools", "tokens": 20_000, "color": "inactive", "kind": "used"],
            ["name": "Autocompact buffer", "tokens": 33_000, "color": "inactive", "kind": "buffer"],
            ["name": "Free space", "tokens": 797_000, "color": "inactive", "kind": "free"],
            ["name": "MCP tools (deferred)", "tokens": 9_000, "color": "inactive", "kind": "deferred"],
            ["name": "Empty", "tokens": 0, "color": "inactive", "kind": "used"],
        ],
        "mcpTools": [
            ["name": "mcp__slack__send", "serverName": "slack", "tokens": 400, "isLoaded": true],
            ["name": "mcp__slack__read", "serverName": "slack", "tokens": 600],
            ["name": "mcp__bear__note", "serverName": "bear", "tokens": 2_000, "isLoaded": false],
        ],
        "memoryFiles": [["path": "/Users/me/CLAUDE.md", "type": "Project", "tokens": 7_800]],
        "skills": ["totalSkills": 2, "includedSkills": 2, "tokens": 300,
                   "skillFrontmatter": [["name": "pdf", "source": "plugin", "tokens": 120]]],
        "autoCompactThreshold": 967_000,
        "isAutoCompactEnabled": true,
    ]

    @Test func decodesTheBreakdown() throws {
        let usage = try #require(ContextUsage(Self.reply))
        #expect(usage.model == "claude-opus-5-5")
        #expect(usage.totalTokens == 200_000)
        #expect(usage.maxTokens == 1_000_000)
        #expect(usage.percentage == 20)
        #expect(usage.categories.count == 6)
        #expect(usage.windowRows.map(\.name) == ["Messages", "System tools", "Autocompact buffer", "Free space"],
                "deferred and empty rows aren't in the window")
        #expect(usage.deferredRows.map(\.name) == ["MCP tools (deferred)"])
        #expect(usage.usedTokens == 170_000)
        #expect(usage.untilAutoCompact == 767_000)
        #expect(usage.memoryFiles.first?.detail == "Project")
        #expect(usage.skills.map(\.name) == ["pdf"])
        #expect(usage.mcpTools.first { $0.name == "mcp__bear__note" }?.deferred == true)
    }

    @Test func groupsMCPToolsByServerMostTokensFirst() throws {
        let usage = try #require(ContextUsage(Self.reply))
        let groups = usage.mcpToolsByServer
        #expect(groups.map(\.server) == ["bear", "slack"])
        #expect(groups.map(\.tokens) == [2_000, 1_000])
        #expect(groups[1].tools.map(\.name) == ["mcp__slack__read", "mcp__slack__send"], "a server's tools, biggest first")
    }

    @Test(.tags(.edgeCase)) func autoCompactOffMeansNoCountdown() throws {
        guard case .object(var object) = Self.reply else { Issue.record("not an object"); return }
        object["isAutoCompactEnabled"] = .bool(false)
        let usage = try #require(ContextUsage(.object(object)))
        #expect(usage.untilAutoCompact == nil)
    }

    @Test(.tags(.edgeCase)) func olderRepliesWithoutKindsUseIsDeferred() throws {
        let usage = try #require(ContextUsage([
            "totalTokens": 10, "maxTokens": 100,
            "categories": [["name": "Tools", "tokens": 5, "isDeferred": true], ["name": "Messages", "tokens": 5]],
        ]))
        #expect(usage.categories.map(\.kind) == [.deferred, .used])
        #expect(usage.percentage == 10, "computed when the reply has none")
    }

    @Test(arguments: [JSONValue.null, ["totalTokens": 5], ["categories": []]])
    func notABreakdown(value: JSONValue) {
        #expect(ContextUsage(value) == nil)
    }
}
