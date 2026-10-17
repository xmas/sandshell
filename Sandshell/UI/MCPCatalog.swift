import Foundation

/// A known MCP server the user can enable, registered individually via
/// `sbx mcp add <name> <addArgs…> --skip_auth` (no bundles). From the Docker
/// Sandboxes MCP runbook.
struct MCPServerDef: Identifiable, Hashable {
    let name: String
    let detail: String       // host (remote) or a short "local" note
    let addArgs: [String]    // args after `sbx mcp add <name>`
    var id: String { name }
    /// Remote (`--url`) servers use hosted OAuth; local (`--command`) don't.
    var isRemote: Bool { addArgs.first == "--url" }
}

enum MCPCatalog {
    static let servers: [MCPServerDef] = [
        .init(name: "notion",     detail: "mcp.notion.com",   addArgs: ["--url", "https://mcp.notion.com/mcp"]),
        .init(name: "atlassian",  detail: "mcp.atlassian.com", addArgs: ["--url", "https://mcp.atlassian.com/v1/mcp"]),
        .init(name: "grafana",    detail: "mcp.grafana.com",  addArgs: ["--url", "https://mcp.grafana.com/mcp"]),
        .init(name: "granola",    detail: "mcp.granola.ai",   addArgs: ["--url", "https://mcp.granola.ai/mcp"]),
        .init(name: "linear",     detail: "mcp.linear.app",   addArgs: ["--url", "https://mcp.linear.app/mcp"]),
        .init(name: "miro",       detail: "mcp.miro.com",     addArgs: ["--url", "https://mcp.miro.com/mcp"]),
        .init(name: "stripe",     detail: "mcp.stripe.com",   addArgs: ["--url", "https://mcp.stripe.com"]),
        .init(name: "playwright", detail: "npx @playwright/mcp (local)",
              addArgs: ["--command", "npx", "--args", "@playwright/mcp@latest"]),
    ]
    static func server(named name: String) -> MCPServerDef? { servers.first { $0.name == name } }
}
