import Foundation
import Testing
@testable import Sandshell

/// Settings ▸ MCP's editing model (Sandshell/UI/MCPConfigModel.swift): the
/// server toggles, dirty tracking against what was applied, and which gateway
/// URLs it accepts.
@MainActor
struct MCPConfigModelTests {
    private func makeModel(servers: [String] = ["notion"]) -> MCPConfigModel {
        MCPConfigModel(url: Workspace.defaultMCPURL, servers: servers)
    }

    @Test func aServerToggleAddsAndRemovesItByName() {
        let model = makeModel()
        model[isEnabled: "linear"] = true
        model[isEnabled: "linear"] = true
        #expect(model.servers == ["notion", "linear"], "turning an enabled server on again adds no duplicate")
        #expect(model[isEnabled: "linear"])

        model[isEnabled: "notion"] = false
        #expect(model.servers == ["linear"])
        #expect(!model[isEnabled: "notion"])
    }

    @Test func editsStayDirtyUntilAppliedOrReverted() {
        let model = makeModel()
        #expect(!model.isDirty)

        model[isEnabled: "miro"] = true
        model.urlString = "http://127.0.0.1:8811"
        #expect(model.isDirty)
        model.revert()
        #expect(!model.isDirty)
        #expect(model.servers == ["notion"])
        #expect(model.urlString == Workspace.defaultMCPURL.absoluteString)

        model[isEnabled: "miro"] = true
        model.commitBaseline()
        #expect(!model.isDirty, "applied edits are the new baseline")
        #expect(model.servers == ["notion", "miro"])
    }

    @Test("Only an absolute http(s) URL with a host resolves", arguments: [
        ("https://gateway.docker.com", true),
        ("  http://127.0.0.1:8811/mcp ", true),
        ("ftp://gateway.docker.com", false),
        ("gateway.docker.com/mcp", false),
        ("", false),
    ])
    func resolvesOnlyHTTPURLs(text: String, resolves: Bool) {
        let model = makeModel()
        model.urlString = text
        #expect((model.resolvedURL() != nil) == resolves)
    }
}
