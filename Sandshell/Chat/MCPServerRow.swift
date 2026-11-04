import SwiftUI

/// One MCP server in `MCPStatusView`, on one line: its status, its name and
/// — failed — why, in a line. Open, it shows what it runs, the whole error,
/// its tools, Reconnect and Turn On / Off.
struct MCPServerRow: View {
    let server: ChatSession.MCPServer
    let isBusy: Bool
    @Binding var isOpen: Bool
    @Binding var showsTools: Bool
    let reconnect: () -> Void
    let toggleEnabled: () -> Void

    private var isOff: Bool { server.status == "disabled" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(MCPStatusView.color(server.status)).frame(width: 7, height: 7)
                    Text(server.name).font(.role(.body)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(isOff ? .secondary : .primary)
                    if isOpen, let v = server.version { Text(v).font(.role(.meta)).foregroundStyle(.tertiary) }
                    Spacer(minLength: 6)
                    if isBusy { ProgressView().controlSize(.mini) }
                    Text(MCPStatusView.label(server.status)).font(.role(.meta))
                        .foregroundStyle(isOff ? .secondary : MCPStatusView.color(server.status))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(server.name), \(MCPStatusView.label(server.status))")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if let err = server.error, server.status == "failed", !isOpen {
                Text(err).font(.role(.meta)).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 15)
            }
            if isOpen { details }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let detail = server.detail {
                Text(detail).font(.role(.code)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if let err = server.error, server.status != "connected" {
                Text(err).font(.role(.meta)).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if let where_ = server.source ?? server.scope {
                    Text("from \(MCPServerList.title(of: where_))").font(.role(.meta)).foregroundStyle(.tertiary)
                }
                if !server.tools.isEmpty {
                    Button(showsTools ? "Hide ^[\(server.tools.count) tool](inflect: true)"
                                      : "^[\(server.tools.count) tool](inflect: true)") {
                        showsTools.toggle()
                    }
                    .buttonStyle(.link).font(.role(.meta))
                }
                Spacer()
                if !isOff {
                    Button("Reconnect", action: reconnect).controlSize(.small)
                }
                Button(isOff ? "Turn On" : "Turn Off", action: toggleEnabled).controlSize(.small)
            }
            if showsTools {
                Text(server.tools.joined(separator: "  ·  ")).font(.role(.code))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.leading, 15)
    }
}
