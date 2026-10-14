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
                    Button { controller.refreshSandboxes() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                    .accessibilityIdentifier("sandboxes-refresh")
                }
            }
            if !running.isEmpty {
                Section("Running (\(running.count))") {
                    ForEach(running) { sb in
                        SandboxRow(sb: sb, controller: controller, expanded: expansion(sb)) { pendingDelete = sb }
                    }
                }
            }
            if !inactive.isEmpty {
                Section("Inactive (\(inactive.count))") {
                    ForEach(inactive) { sb in
                        SandboxRow(sb: sb, controller: controller, expanded: expansion(sb)) { pendingDelete = sb }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        .onAppear { controller.refreshSandboxes() }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { sb in
            Button("Delete Sandbox", role: .destructive) {
                controller.deleteSandbox(sb.name); pendingDelete = nil
            }
            .accessibilityIdentifier("sandbox-confirm-delete")
            Button("Cancel", role: .cancel) { pendingDelete = nil }
                .accessibilityIdentifier("sandbox-cancel-delete")
        } message: { _ in
            Text("Removes the container (sbx rm -f) and ends any session running in it. "
                 + "Workspace files on disk are not affected.")
        }
    }

    private func expansion(_ sb: Sandbox) -> Binding<Bool> {
        Binding(get: { expanded.contains(sb.name) },
                set: { if $0 { expanded.insert(sb.name) } else { expanded.remove(sb.name) } })
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
            if expanded { detail.padding(.top, 6) }
        }
    }

    /// The always-visible row. The chevron rotates (not crossfades) on toggle.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12)
            Circle().fill(sb.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(sb.name).fontWeight(.medium)
            Text(sb.agent).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            else { Text(sb.status).font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
        // One pressable element, so VoiceOver (and AX automation) can expand it.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { expanded.toggle() }
        .accessibilityIdentifier("sandbox-row-\(sb.name)")
    }

    private var detail: some View {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Agent", value: sb.agent)
                LabeledContent("Status", value: sb.status)
                LabeledContent("ID") {
                    Text(sb.id).font(.system(size: 10, design: .monospaced))
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
                        Text(Self.shortPath(ro ? String(spec.dropLast(3)) : spec))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        if ro { Text("ro").font(.caption2).foregroundStyle(.secondary) }
                    }
                }

                Text("Commands").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                commandBlock("Create", controller.createCommandDisplay(for: sb))
                commandBlock("Launch", controller.launchCommandDisplay(for: sb))

                actions.padding(.top, 8)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A labeled, monospaced, selectable command with a copy button.
    private func commandBlock(_ label: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.caption2) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Copy")
            }
            Text(command)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if sb.isRunning {
                Button("Stop") { controller.stopSandbox(sb.name) }
                    .accessibilityIdentifier("sandbox-stop-\(sb.name)")
            } else {
                Button("Run") { controller.startSandbox(sb.name) }
                    .accessibilityIdentifier("sandbox-run-\(sb.name)")
            }
            Button("Rebuild") { controller.rebuildSandbox(sb) }
                .accessibilityIdentifier("sandbox-rebuild-\(sb.name)")
            Spacer()
            Button("Delete", role: .destructive, action: requestDelete)
                .accessibilityIdentifier("sandbox-delete-\(sb.name)")
        }
        .disabled(busy)
    }

    /// Collapse `$HOME` to `~` for compact mount display.
    private static func shortPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }
}
