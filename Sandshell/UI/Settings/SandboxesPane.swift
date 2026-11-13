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
                ClaudeAccountRow(controller: controller)
            } header: {
                Text("This folder")
            } footer: {
                if controller.isGitRepository == false {
                    Text("Needs a git repository.").foregroundStyle(.secondary)
                }
            }
            Section {
                if let error = controller.sandboxesError {
                    Text("Couldn’t list sandboxes: \(error)")
                        .font(.role(.meta)).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("sandboxes-error")
                }
                if controller.sandboxesLoading && controller.allSandboxes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading sandboxes…").foregroundStyle(.secondary)
                    }
                } else if controller.allSandboxes.isEmpty && controller.sandboxesError == nil {
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

/// Settings ▸ Sandboxes ▸ This folder: which Claude account its sandboxes use
/// — this Mac's `~/.claude`, or one of its own (`ClaudeAccounts`), say a
/// personal one on a work Mac whose Claude is managed.
struct ClaudeAccountRow: View {
    @ObservedObject var controller: WorkspaceController
    @State private var naming = false
    @State private var newName = ""
    /// sbx's global Anthropic credential would stand in for the account's own sign-in.
    @State private var overridden = false

    private static let thisMac = "\u{0}mac"
    private static let newAccount = "\u{0}new"

    private var names: [String] {
        var names = ClaudeAccounts.names(home: controller.home)
        if let current = controller.claudeAccount, !names.contains(current) { names.append(current) }
        return names
    }

    private var sandbox: String { controller.containerName(for: .claude) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(get: { controller.claudeAccount ?? Self.thisMac }, set: { pick in
                if pick == Self.newAccount {
                    newName = ""
                    naming = true
                } else {
                    controller.setClaudeAccount(pick == Self.thisMac ? nil : pick)
                }
            })) {
                Text("This Mac’s (~/.claude)").tag(Self.thisMac)
                ForEach(names, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New Account…").tag(Self.newAccount)
            } label: {
                Text("Claude account")
                Text("Its own account: a folder just for this folder’s sandboxes (~/.sandshell/claude-accounts/<name>), "
                     + "so Claude in them signs in on its own — run /login in a session there. The Mac’s own Claude "
                     + "never uses it. Takes effect when the sandbox is next rebuilt.")
            }
            .accessibilityIdentifier("sandboxes-claude-account")
            if overridden, let account = controller.claudeAccount {
                Label(ClaudeAccounts.overriddenWarning(account: account, sandbox: sandbox), systemImage: "exclamationmark.triangle.fill")
                    .font(.role(.meta))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if controller.claudeAccount != nil {
                Button("Rebuild Now") { controller.rebuildAll() }
                    .help("Make this folder’s sandboxes again with the account’s folder mounted (running sessions stop)")
            }
        }
        .alert("New Claude Account", isPresented: $naming) {
            TextField("personal", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if ClaudeAccounts.isValid(name) { controller.setClaudeAccount(name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A name for its folder: letters, digits, “.”, “_” and “-”.")
        }
        .task(id: controller.claudeAccount) {
            guard controller.claudeAccount != nil else { overridden = false; return }
            let scopes = await SbxClient.shared.anthropicSecretScopes(sandbox: sandbox)
            overridden = scopes.global && !scopes.own
        }
    }
}
