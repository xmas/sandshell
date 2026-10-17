import SwiftUI

/// One MCP server in `MCPStatusView`: its status, what it runs, why it failed,
/// where it's configured, its tools, and Reconnect / Enable / Disable.
struct MCPServerRow: View {
    let server: ChatSession.MCPServer
    let isBusy: Bool
    @Binding var isExpanded: Bool
    let reconnect: () -> Void
    let toggleEnabled: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(MCPStatusView.color(server.status)).frame(width: 8, height: 8)
                Text(server.name).font(.body.weight(.semibold))
                if let v = server.version { Text(v).font(.caption).foregroundStyle(.tertiary) }
                Spacer()
                Text(MCPStatusView.label(server.status)).font(.caption).foregroundStyle(MCPStatusView.color(server.status))
            }
            if let detail = server.detail {
                Text(detail).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if let err = server.error, server.status != "connected" {
                Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if let where_ = server.source ?? server.scope { Text("from \(where_)").font(.caption).foregroundStyle(.tertiary) }
                if !server.tools.isEmpty {
                    Button(isExpanded ? "Hide ^[\(server.tools.count) tool](inflect: true)"
                                      : "^[\(server.tools.count) tool](inflect: true)") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.link).font(.caption)
                }
                Spacer()
                if isBusy { ProgressView().controlSize(.mini) }
                if server.status != "disabled" {
                    Button("Reconnect", action: reconnect)
                        .controlSize(.small)
                }
                Button(server.status == "disabled" ? "Enable" : "Disable", action: toggleEnabled)
                    .controlSize(.small)
            }
            if isExpanded {
                Text(server.tools.joined(separator: "  ·  ")).font(.subheadline.monospaced())
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
