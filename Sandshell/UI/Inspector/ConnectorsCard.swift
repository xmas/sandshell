import SwiftUI

/// The chat's MCP servers ("connectors"): each with its state and tools;
/// clicking one opens the MCP details (reconnect, enable/disable).
struct ConnectorsCard: View {
    let model: SessionInspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let servers = model.mcpServers {
                if servers.isEmpty {
                    Text("No MCP servers in this chat.").foregroundStyle(.secondary)
                }
                ForEach(servers) { server in
                    Button {
                        model.showMCP?()
                    } label: {
                        HStack(spacing: 9) {
                            ConnectorMark(name: server.name)
                            Text(server.name).lineLimit(1)
                            Spacer(minLength: 4)
                            if !server.tools.isEmpty {
                                Text("\(server.tools.count)").foregroundStyle(.secondary).font(.role(.code))
                                    .help("\(server.tools.count) tools")
                            }
                            Circle()
                                .fill(Self.statusColor(server.status))
                                .frame(width: 7, height: 7)
                                .accessibilityLabel(server.status)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(server.error ?? server.detail ?? server.status)
                }
            } else if model.hasExtras == false {
                Text("Shows with the sandshell-claude kit (Settings ▸ Kits).").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("MCP Settings…") { model.openMCPSettings?() }
                .buttonStyle(.link)
                .font(.role(.meta))
        }
        .font(.role(.body))
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "connected": .green
        case "failed": .red
        case "needs-auth": .orange
        case "disabled": .gray
        default: .yellow
        }
    }
}

/// A server's mark: its initial on a tinted square (MCP servers carry no icon).
struct ConnectorMark: View {
    let name: String

    var body: some View {
        let initial = name.first.map { String($0).uppercased() } ?? "?"
        Text(initial)
            .font(.role(.meta, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Self.tint(for: name), in: .rect(cornerRadius: 4))
            .accessibilityHidden(true)
    }

    /// A stable colour per name.
    static func tint(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}
