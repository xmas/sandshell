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
                Text("MCP Servers").font(.headline)
                Spacer()
                if busy == "*" { ProgressView().controlSize(.small) }
                Button { run("*") { try await session.refreshMCP() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Check again")
            }
            .padding([.horizontal, .top], 14).padding(.bottom, 8)
            Divider()
            if let servers = session.mcpServers {
                if servers.isEmpty {
                    Text("This session has no MCP servers. Add them in Settings ▸ MCP, or in the project’s .mcp.json.")
                        .font(.callout).foregroundStyle(.secondary).padding(14)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(servers) { server in
                                row(server)
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
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .frame(width: 400)
        .task { run("*") { try await session.refreshMCP() } }
    }

    @ViewBuilder private func row(_ s: ChatSession.MCPServer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Self.color(s.status)).frame(width: 8, height: 8)
                Text(s.name).font(.system(size: 13, weight: .semibold))
                if let v = s.version { Text(v).font(.caption).foregroundStyle(.tertiary) }
                Spacer()
                Text(Self.label(s.status)).font(.caption).foregroundStyle(Self.color(s.status))
            }
            if let detail = s.detail {
                Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if let err = s.error, s.status != "connected" {
                Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if let where_ = s.source ?? s.scope { Text("from \(where_)").font(.caption).foregroundStyle(.tertiary) }
                if !s.tools.isEmpty {
                    Button(expanded.contains(s.name) ? "Hide \(s.tools.count) tools" : "\(s.tools.count) tools") {
                        if expanded.contains(s.name) { expanded.remove(s.name) } else { expanded.insert(s.name) }
                    }
                    .buttonStyle(.link).font(.caption)
                }
                Spacer()
                if busy == s.name { ProgressView().controlSize(.mini) }
                if s.status != "disabled" {
                    Button("Reconnect") { run(s.name) { try await session.reconnectMCP(s.name) } }
                        .controlSize(.small)
                }
                Button(s.status == "disabled" ? "Enable" : "Disable") {
                    run(s.name) { try await session.setMCP(s.name, enabled: s.status == "disabled") }
                }
                .controlSize(.small)
            }
            if expanded.contains(s.name) {
                Text(s.tools.joined(separator: "  ·  ")).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
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
