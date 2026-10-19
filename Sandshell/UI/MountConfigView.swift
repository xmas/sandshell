import SwiftUI

/// Mount-configuration UI, shown on first open of a workspace and reused by
/// Settings. Lets the user pick which host folders the sandbox can see, with a
/// hard stop at the sbx mount limit.
struct MountConfigView: View {
    let model: MountConfigModel
    var confirmTitle: String
    /// Explanation shown by the (i) button next to the confirm action.
    var confirmInfo: String
    /// Title for the secondary button ("Cancel" first-run, "Revert" in Settings).
    var cancelTitle: String = "Cancel"
    /// When true (Settings), Apply/Revert are enabled only when there are unsaved
    /// changes, and changed rows are highlighted. When false (first-run), the
    /// confirm action is always enabled.
    var requireChanges: Bool = false
    var onConfirm: (MountPolicy) -> Void
    var onCancel: () -> Void
    /// When embedded (e.g. in the setup wizard) the header/footer + fixed frame
    /// are dropped — the host provides the title and Next/Back navigation.
    var embedded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Mounts").font(.role(.title))
                    Text("Choose which folders this workspace's sandboxes can access.")
                        .font(.role(.meta)).foregroundStyle(.secondary)
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 10)
                Divider()
            }
            ScrollView { MountList(model: model, requireChanges: requireChanges).padding() }
            if !embedded {
                Divider()
                MountConfigFooter(model: model, confirmTitle: confirmTitle, confirmInfo: confirmInfo,
                                  cancelTitle: cancelTitle, requireChanges: requireChanges,
                                  onConfirm: onConfirm, onCancel: onCancel)
            }
        }
        // Embedded sizes to the host's step area; otherwise the fixed pane size.
        .frame(width: embedded ? nil : InspectorMetrics.paneWidth,
               height: embedded ? nil : InspectorMetrics.paneHeight)
    }
}

/// The mounts, by group: the workspace root, the suggested and other folders,
/// and the managed agent mounts.
private struct MountList: View {
    @Bindable var model: MountConfigModel
    let requireChanges: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Workspace root (always mounted rw).
            MountSection(title: "Workspace") {
                HStack {
                    Label(model.shortPath(model.root), systemImage: "folder.fill")
                    Spacer()
                    Text("Root").foregroundStyle(.secondary).font(.role(.meta))
                }
            }

            // Suggested read-only folders.
            if !model.suggestions.isEmpty {
                MountSection(title: "Suggested folders (read-only)") {
                    ForEach($model.suggestions) { $s in
                        HStack(spacing: 6) {
                            ChangeDot(visible: requireChanges && model.isChanged(s))
                            Toggle(isOn: $s.enabled) {
                                Label(model.shortPath(s.url), systemImage: "lock")
                            }
                            .disabled(!s.enabled && model.atLimit)
                        }
                    }
                }
            }

            // Other user-added folders. Keyed by path: ro/rw is edited in place.
            MountSection(title: "Other folders") {
                ForEach(model.others, id: \.path) { spec in
                    HStack(spacing: 6) {
                        ChangeDot(visible: requireChanges && model.isChanged(other: spec))
                        Label(model.shortPath(spec.path), systemImage: spec.readonly ? "lock" : "pencil")
                        Spacer()
                        // Click to flip read-only ↔ read-write (applies on Apply & Rebuild).
                        Button {
                            model.toggleReadonly(spec)
                        } label: {
                            Text(spec.readonly ? "ro" : "rw")
                                .font(.role(.code, weight: .semibold))
                                .foregroundStyle(spec.readonly ? Color.secondary : Color.orange)
                                .frame(minWidth: 22)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.quinary, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .help(spec.readonly ? "Read-only — click to make read-write" : "Read-write — click to make read-only")
                        .accessibilityLabel(spec.readonly ? "Read-only" : "Read-write")
                        .accessibilityIdentifier("mount-access-toggle")
                        Button("Remove \(model.shortPath(spec.path))", systemImage: "minus.circle") {
                            model.removeOther(spec)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…", systemImage: "plus", action: model.addFolders)
                    .disabled(model.atLimit)
            }

            // Managed agent config/state mounts — always mounted; info only.
            // Whole directories (`.agents`, `.claude`, `.codex` if present), all read-write.
            MountSection(title: "Agent configuration") {
                Toggle("Show agent config mounts", isOn: $model.showDotFolders)
                if model.showDotFolders {
                    ForEach(model.agentMounts) { spec in
                        Label(model.shortPath(spec.path),
                              systemImage: spec.readonly ? "lock" : "pencil")
                            .foregroundStyle(.secondary)
                    }
                    Text("Always mounted read-write — agents need these for settings, history, and auth.")
                        .font(.role(.meta)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The mount count against the sbx limit, unsaved changes, and the actions.
private struct MountConfigFooter: View {
    let model: MountConfigModel
    let confirmTitle: String
    let confirmInfo: String
    let cancelTitle: String
    let requireChanges: Bool
    let onConfirm: (MountPolicy) -> Void
    let onCancel: () -> Void

    @State private var showInfo = false

    private var actionsEnabled: Bool { !requireChanges || model.isDirty }

    var body: some View {
        HStack {
            Image(systemName: model.atLimit ? "exclamationmark.triangle.fill" : "externaldrive")
                .foregroundStyle(model.atLimit ? .orange : .secondary)
            Text("\(model.mountCount) / \(MountPolicy.mountLimit) mounts")
                .font(.role(.body))
                .foregroundStyle(model.atLimit ? .orange : .secondary)
            if model.atLimit {
                Text("limit reached").font(.role(.meta)).foregroundStyle(.orange)
            }
            if requireChanges && model.isDirty {
                Text("• Unsaved changes").font(.role(.meta)).foregroundStyle(.orange)
            }
            Spacer()
            Button("About \(confirmTitle)", systemImage: "info.circle") {
                showInfo.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("What does “\(confirmTitle)” do?")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                Text(confirmInfo)
                    .font(.role(.body))
                    .frame(width: 280, alignment: .leading)
                    .padding(12)
            }
            Button(cancelTitle, role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(!actionsEnabled)
            Button(confirmTitle) { onConfirm(model.policy()) }
                .keyboardShortcut(.defaultAction)
                .disabled(!actionsEnabled)
        }
        .padding()
    }
}

/// A small orange dot marking a row that differs from the saved baseline
/// (occupies fixed space so rows stay aligned).
private struct ChangeDot: View {
    let visible: Bool

    var body: some View {
        Circle()
            .fill(visible ? Color.orange : Color.clear)
            .frame(width: 7, height: 7)
    }
}

/// A titled group of mount rows.
private struct MountSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.role(.meta, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
    }
}
