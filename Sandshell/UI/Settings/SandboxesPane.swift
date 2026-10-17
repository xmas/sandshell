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
