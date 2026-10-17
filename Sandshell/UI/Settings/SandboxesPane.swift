import AppKit
import SwiftUI

/// Settings ▸ Sandboxes: every `sbx` sandbox on the machine, each expandable to
/// show what it was built with (agent + mounts), with run / stop / rebuild /
/// delete actions.
struct SandboxesPaneView: View {
    @ObservedObject var controller: WorkspaceController
    @State private var pendingDelete: Sandbox?
    /// Expanded rows, by name: Stop/Run moves a row between the sections
    /// (a new row view), and it should stay open under the cursor.
    @State private var expanded: Set<String> = []

    /// Running sandboxes shown above, stopped/inactive ones below.
    private var running: [Sandbox] { controller.allSandboxes.filter { $0.isRunning } }
    private var inactive: [Sandbox] { controller.allSandboxes.filter { !$0.isRunning } }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { controller.workspace.cloneRepo }, set: { controller.setCloneRepo($0) })) {
                    Text("Agents work on a private clone of the repo")
                    Text("sbx --clone: the folder stays read-only to agents; their commits come back through the "
                         + "sandbox-<name> git remote. Takes effect when a sandbox is next rebuilt.")
                }
                .disabled(controller.isGitRepository == false && controller.workspace.cloneRepo == false)
                .accessibilityIdentifier("sandboxes-clone-repo")
            } header: {
                Text("This folder")
            } footer: {
                if controller.isGitRepository == false {
                    Text("Needs a git repository.").foregroundStyle(.secondary)
                }
            }
            Section {
                if controller.sandboxesLoading && controller.allSandboxes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading sandboxes…").foregroundStyle(.secondary)
                    }
                } else if controller.allSandboxes.isEmpty {
                    Text("No sandboxes yet — open a session to create one.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Sandboxes")
                    if controller.sandboxesLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { controller.refreshSandboxes() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Refresh")
                        .accessibilityIdentifier("sandboxes-refresh")
                }
            }
            if !running.isEmpty {
                Section("Running (\(running.count))") {
                    ForEach(running) { sb in
                        SandboxRow(sb: sb, controller: controller, expanded: $expanded[contains: sb.name]) {
                            pendingDelete = sb
                        }
                    }
                }
            }
            if !inactive.isEmpty {
                Section("Inactive (\(inactive.count))") {
                    ForEach(inactive) { sb in
                        SandboxRow(sb: sb, controller: controller, expanded: $expanded[contains: sb.name]) {
                            pendingDelete = sb
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        .onAppear { controller.refreshSandboxes() }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", item: $pendingDelete) { sb in
            Button("Delete Sandbox", role: .destructive) { controller.deleteSandbox(sb.name) }
                .accessibilityIdentifier("sandbox-confirm-delete")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("sandbox-cancel-delete")
        } message: { _ in
            Text("""
                Removes the container (sbx rm -f) and ends any session running in it. \
                Workspace files on disk are not affected.
                """)
        }
    }
}

private extension Set {
    /// Whether `member` is in the set, as a settable flag: true inserts it,
    /// false removes it (so a row can bind to `$expanded[contains: name]`).
    subscript(contains member: Element) -> Bool {
        get { contains(member) }
        set { if newValue { insert(member) } else { remove(member) } }
    }
}

private struct SandboxRow: View {
    let sb: Sandbox
    @ObservedObject var controller: WorkspaceController
    @Binding var expanded: Bool
    let requestDelete: () -> Void

    private var busy: Bool { controller.sandboxBusy.contains(sb.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                SandboxDetailView(sb: sb, controller: controller, requestDelete: requestDelete)
                    .padding(.top, 6)
            }
        }
    }

    /// The always-visible row, a button that expands it. The chevron rotates
    /// (not crossfades) on toggle.
    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Circle().fill(sb.isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .frame(width: 7, height: 7)
                Text(sb.name)
                Text(sb.agent).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                else { Text(sb.status).font(.caption).foregroundStyle(.secondary) }
            }
            // The gap the Spacer leaves is part of the button too.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sandbox-row-\(sb.name)")
    }
}

/// An expanded sandbox row: what the sandbox was built with (agent, mounts),
/// the commands that create and enter it, and run / stop / rebuild / delete.
private struct SandboxDetailView: View {
    let sb: Sandbox
    @ObservedObject var controller: WorkspaceController
    let requestDelete: () -> Void

    private var busy: Bool { controller.sandboxBusy.contains(sb.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Agent", value: sb.agent)
            LabeledContent("Status", value: sb.status)
            LabeledContent("ID") {
                Text(sb.id).font(.caption.monospaced())
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Mounts (\(sb.workspaces.count))")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(sb.workspaces, id: \.self) { spec in
                let ro = spec.hasSuffix(":ro")
                HStack(spacing: 6) {
                    Image(systemName: ro ? "lock.fill" : "externaldrive.fill")
                        .font(.caption2)
                        .foregroundStyle(ro ? Color.secondary : Color.accentColor)
                    Text((ro ? String(spec.dropLast(3)) : spec).tildeAbbreviated)
                        .font(.subheadline.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    if ro { Text("ro").font(.caption2).foregroundStyle(.secondary) }
                }
            }

            Text("Commands").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
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
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
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
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy \(label) Command", systemImage: "doc.on.doc", action: copy)
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Copy")
            }
            Text(command)
                .font(.caption.monospaced())
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
