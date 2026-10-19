import AppKit
import SwiftUI

/// An expanded sandbox row: what the sandbox was built with (agent, mounts),
/// the commands that create and enter it, and run / stop / rebuild / delete.
struct SandboxDetailView: View {
    let sb: Sandbox
    @ObservedObject var controller: WorkspaceController
    let requestDelete: () -> Void

    private var busy: Bool { controller.sandboxBusy.contains(sb.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Agent", value: sb.agent)
            LabeledContent("Status", value: sb.status)
            LabeledContent("ID") {
                Text(sb.id).font(.role(.code))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Mounts (\(sb.workspaces.count))")
                .font(.role(.meta)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(sb.workspaces, id: \.self) { spec in
                let ro = spec.hasSuffix(":ro")
                HStack(spacing: 6) {
                    Image(systemName: ro ? "lock.fill" : "externaldrive.fill")
                        .font(.symbol(.meta))
                        .foregroundStyle(ro ? Color.secondary : Color.accentColor)
                    Text((ro ? String(spec.dropLast(3)) : spec).tildeAbbreviated)
                        .font(.role(.code))
                        .lineLimit(1).truncationMode(.middle)
                    if ro { Text("ro").font(.role(.meta)).foregroundStyle(.secondary) }
                }
            }

            Text("Commands").font(.role(.meta)).foregroundStyle(.secondary).padding(.top, 6)
            CommandBlock(label: "Create", command: controller.createCommandDisplay(for: sb))
            CommandBlock(label: "Launch", command: controller.launchCommandDisplay(for: sb))

            HStack(spacing: 8) {
                if sb.isRunning {
                    Button("Stop", action: stop)
                        .accessibilityIdentifier("sandbox-stop-\(sb.name)")
                } else {
                    Button("Run", action: run)
                        .accessibilityIdentifier("sandbox-run-\(sb.name)")
                }
                Button("Rebuild", action: rebuild)
                    .accessibilityIdentifier("sandbox-rebuild-\(sb.name)")
                Spacer()
                Button("Delete", role: .destructive, action: requestDelete)
                    .accessibilityIdentifier("sandbox-delete-\(sb.name)")
            }
            .disabled(busy)
            .padding(.top, 8)
            if let error = controller.sandboxErrors[sb.name] {
                Text(error).font(.role(.meta)).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("sandbox-error-\(sb.name)")
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stop() { controller.stopSandbox(sb.name) }
    private func run() { controller.startSandbox(sb.name) }
    private func rebuild() { controller.rebuildSandbox(sb) }
}

/// A labeled, monospaced, selectable command with a copy button.
private struct CommandBlock: View {
    let label: String
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.role(.meta)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy \(label) Command", systemImage: "doc.on.doc", action: copy)
                    .labelStyle(.iconOnly)
                    .font(.role(.meta))
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Copy")
            }
            Text(command)
                .font(.role(.code))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quinary, in: .rect(cornerRadius: 5))
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
