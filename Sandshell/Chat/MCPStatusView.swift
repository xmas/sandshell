import SwiftUI

/// The chat's MCP servers as Claude Code sees them in this session: whether
/// each is connected (or failed, and why), what it runs, where it's configured,
/// and its tools — with Reconnect and Enable / Disable.
struct MCPStatusView: View {
    @ObservedObject var session: ChatSession
    @State private var busy: String?
    @State private var error: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MCP Servers").font(.role(.title))
                Spacer()
                if busy == "*" { ProgressView().controlSize(.small) }
                Button("Check Again", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless).help("Check again")
            }
            .padding([.horizontal, .top], 14).padding(.bottom, 8)
            Divider()
            if let servers = session.mcpServers {
                if servers.isEmpty {
                    ContentUnavailableView("No MCP Servers", systemImage: "server.rack",
                                           description: Text("Add them in Settings ▸ MCP, or in the project’s .mcp.json."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(servers) { server in
                                MCPServerRow(server: server, isBusy: busy == server.name,
                                             isExpanded: $expanded[contains: server.name],
                                             reconnect: { reconnect(server) },
                                             toggleEnabled: { toggleEnabled(server) })
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .frame(maxHeight: 420)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Asking Claude…").foregroundStyle(.secondary) }
                    .padding(14)
            }
            if let error {
                Text(error).font(.role(.meta)).foregroundStyle(.red).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .frame(width: 400)
        .task { refresh() }
    }

    private func refresh() {
        run("*") { try await session.refreshMCP() }
    }

    private func reconnect(_ server: ChatSession.MCPServer) {
        run(server.name) { try await session.reconnectMCP(server.name) }
    }

    private func toggleEnabled(_ server: ChatSession.MCPServer) {
        run(server.name) { try await session.setMCP(server.name, enabled: server.status == "disabled") }
    }

    private func run(_ key: String, _ work: @escaping () async throws -> Void) {
        busy = key
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "connected": .green
        case "failed": .red
        case "needs-auth": .orange
        case "disabled": .gray
        default: .yellow
        }
    }

    static func label(_ status: String) -> String {
        switch status {
        case "connected": "Connected"
        case "failed": "Failed"
        case "needs-auth": "Needs sign-in"
        case "disabled": "Off"
        default: "Connecting…"
        }
    }
}

private extension Set {
    /// Whether `member` is in the set; setting it inserts or removes it
    /// (a `Binding<Bool>` through `$set[contains: member]`).
    subscript(contains member: Element) -> Bool {
        get { contains(member) }
        set { if newValue { insert(member) } else { remove(member) } }
    }
}
