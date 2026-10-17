import SwiftUI

/// A folder's settings, in its Settings window (`SettingsWindowController`).
/// A fixed-size view with a System-Settings-style tab strip at the top and the
/// selected pane below; Esc closes the window. The frame is fixed so switching
/// panes never resizes the window.
struct InspectorView: View {
    @ObservedObject var controller: WorkspaceController
    /// The pane shown, which the Settings window can change too.
    let selection: InspectorSelection
    let onClose: () -> Void
    var onPaneChange: (InspectorPane) -> Void = { _ in }

    private var pane: InspectorPane { selection.pane }

    /// Post (object: the workspace's controller) to open its settings on a tab
    /// (userInfo "pane": an `InspectorPane` raw value).
    static let openRequest = Notification.Name("SandshellOpenSettingsPane")

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            paneContent
                .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight, alignment: .top)
                .clipped()
        }
        .frame(width: InspectorMetrics.paneWidth + 20)
        .background(.windowBackground)
        // Esc closes (no Done button: it's a window, with a close button).
        .background {
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .onChange(of: pane) { _, p in onPaneChange(p) }
    }

    /// Settings-style row of tinted icon tabs.
    private var tabStrip: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(InspectorPane.allCases.filter { $0 != .git }) { p in
                TabButton(pane: p, isSelected: pane == p) { selection.select(p) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .general:
            GeneralPaneView(controller: controller)
        case .sandboxes:
            SandboxesPaneView(controller: controller)
        case .folders:
            FoldersPaneView(controller: controller)
        case .mounts:
            MountsInspectorPane(controller: controller)
        case .kits:
            KitsInspectorPane(controller: controller)
        case .agents:
            AgentsInspectorPane(controller: controller)
        case .mcp:
            MCPInspectorPane(controller: controller)
        case .git:
            StubPaneView(title: "Git & Remote", symbol: "arrow.triangle.branch",
                         note: "Auto-commit and remotes in Phase 6.")
        case .terminal:
            TerminalPaneView(theme: controller.theme)
        }
    }
}

/// The Settings window's selected pane, kept by its window controller so the
/// window can switch panes without rebuilding the view (and the panes' edits).
@MainActor
@Observable
final class InspectorSelection {
    private(set) var pane: InspectorPane

    init(_ pane: InspectorPane) { self.pane = Self.tab(for: pane) }

    func select(_ pane: InspectorPane) {
        let tab = Self.tab(for: pane)
        if tab != self.pane { self.pane = tab }
    }

    /// Git & Remote has no tab yet: it opens on General.
    private static func tab(for pane: InspectorPane) -> InspectorPane { pane == .git ? .general : pane }
}

/// One tab in the inspector strip: a tinted rounded-square icon + label, with a
/// full selection highlight behind the selected tab (matches the Settings look).
private struct TabButton: View {
    let pane: InspectorPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(pane.color)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: pane.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Text(pane.title).font(.system(size: 11))
                    .foregroundStyle(.primary).lineLimit(1)
            }
            .frame(width: 70)
            .padding(.vertical, 5)
            .background(isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear,
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("inspector-tab-\(pane.rawValue)")
    }
}

/// The per-root inspector panes. All app settings live here — there is no
/// separate global Settings window.
enum InspectorPane: String, CaseIterable, Identifiable {
    case general, sandboxes, folders, mounts, kits, agents, mcp, git, terminal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mcp: "MCP"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .sandboxes: "shippingbox.fill"
        case .folders: "folder.fill"
        case .mounts: "externaldrive.fill"
        case .kits: "cube.fill"
        case .agents: "person.crop.square.fill"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .git: "arrow.triangle.branch"
        case .terminal: "terminal.fill"
        }
    }

    /// The tab's tint.
    var color: Color {
        switch self {
        case .general: .gray
        case .sandboxes: .brown
        case .folders: .indigo
        case .mounts: .blue
        case .kits: .green
        case .agents: .pink
        case .mcp: .purple
        case .git: .orange
        case .terminal: .teal
        }
    }
}

/// Kits pane for the inspector: choose which registered kits apply to this
/// workspace. Added kits go in with `sbx kit add`; other changes rebuild.
private struct KitsInspectorPane: View {
    @ObservedObject var controller: WorkspaceController
    @StateObject private var model: KitConfigModel
    @State private var pending: Pending?

    private enum Pending { case add, rebuild }

    init(controller: WorkspaceController) {
        self.controller = controller
        _model = StateObject(wrappedValue: {
            let model = KitConfigModel(enabledRefs: controller.kits)
            model.onAgentKit = { [weak controller] profile in
                guard let controller else { return }
                controller.setCustomAgents(controller.customAgents + [profile.kind])
            }
            return model
        }())
    }

    var body: some View {
        let agent = controller.primaryAgent
        KitConfigView(
            model: model,
            onConfirm: { _ in pending = model.isAdditionsOnly ? .add : .rebuild },
            onCancel: { model.revert() },
            startup: controller.kitStartupStatus(for: agent),
            onShowLog: { controller.openKitLog(for: agent) },
            onRefreshStartup: {
                controller.refreshKitStartup(for: agent)
                controller.refreshKitDrift(for: agent)
            },
            onRebuild: { pending = .rebuild },
            drift: controller.kitDrift[agent],
            onAdoptDrift: { adoptDrift(for: agent) },
            onIgnoreDrift: { controller.ignoreKitDrift(for: agent) })
        .onAppear { controller.refreshKitDrift(for: agent) }
        .confirmationDialog(pending == .add ? "Add kits to the sandbox?" : "Apply kit changes and rebuild?",
                            item: $pending) { action in
            Button(action == .add ? "Add to Sandbox" : "Apply & Rebuild") { applyKits(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            if action == .add {
                Text("Each new kit is added with sbx kit add, which recreates the container with the kit appended "
                     + "and keeps agent state; running sessions in it end. Where sbx can’t add a kit in place, "
                     + "the sandbox is rebuilt instead. Workspace files are preserved.")
            } else {
                Text("The workspace’s container(s) will be stopped and recreated with the new kit set, "
                     + "ending any running sessions. Workspace files are preserved.")
            }
        }
    }

    /// Add the kits the sandbox has that the workspace didn't list, here too.
    private func adoptDrift(for agent: AgentKind) {
        let refs = controller.kitDrift[agent]?.extra ?? []
        controller.adoptKitDrift(for: agent)
        model.adopt(refs)
    }

    /// Apply the edited kit set (added in place, or rebuilt) and make it the
    /// one edits are measured from.
    private func applyKits(_ action: Pending) {
        controller.applyKits(model.enabledRefs, rebuild: action == .rebuild)
        model.commitBaseline()
    }
}

/// Agents pane for the inspector: register custom (kit-defined) agents and pick
/// which this workspace offers. Applies immediately — nothing to rebuild.
private struct AgentsInspectorPane: View {
    @StateObject private var model: AgentConfigModel

    init(controller: WorkspaceController) {
        _model = StateObject(wrappedValue: AgentConfigModel(
            enabled: controller.customAgents, apply: { [weak controller] in controller?.setCustomAgents($0) }))
    }

    var body: some View { AgentConfigView(model: model) }
}

/// Mounts pane for the inspector: edits the workspace mount policy and applies it
/// (rebuilding the container) on confirmation. Switching panes discards edits.
private struct MountsInspectorPane: View {
    @ObservedObject var controller: WorkspaceController
    @StateObject private var model: MountConfigModel
    @State private var confirming = false

    init(controller: WorkspaceController) {
        self.controller = controller
        _model = StateObject(wrappedValue: MountConfigModel(
            home: controller.home, root: controller.rootURL, policy: controller.policy))
    }

    var body: some View {
        MountConfigView(
            model: model,
            confirmTitle: "Apply & Rebuild",
            confirmInfo: "Saves these mount changes and rebuilds the workspace’s container(s): "
                + "each is stopped and recreated with the new mounts, which ends any sessions "
                + "currently running in it. Files in the workspace are preserved.",
            cancelTitle: "Revert",
            requireChanges: true,
            onConfirm: { _ in confirming = true },
            onCancel: { model.revert() })
        .confirmationDialog("Apply mount changes and rebuild?", isPresented: $confirming) {
            Button("Apply & Rebuild", action: applyMounts)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The workspace’s container(s) will be stopped and recreated with the new mounts, "
                 + "ending any running sessions. Workspace files are preserved.")
        }
    }

    /// Save the edited mounts and rebuild, then make them the baseline.
    private func applyMounts() {
        controller.applyConfiguration(policy: model.policy())
        model.commitBaseline()
    }
}

/// MCP pane for the inspector: edits the enabled MCP servers + gateway URL and
/// applies them (rebuilding the container) on confirmation.
private struct MCPInspectorPane: View {
    @ObservedObject var controller: WorkspaceController
    @StateObject private var model: MCPConfigModel

    init(controller: WorkspaceController) {
        self.controller = controller
        _model = StateObject(wrappedValue: MCPConfigModel(
            url: controller.mcpURL, servers: controller.mcpServers))
    }

    var body: some View {
        MCPPaneView(
            model: model,
            controller: controller,
            onConfirm: { servers, url in
                controller.applyMCP(servers: servers, url: url)
                model.commitBaseline()
            },
            onCancel: { model.revert() })
        .onAppear { controller.refreshMCPStatus() }
    }
}


/// Shared size of the inspector sheet's pane area; every pane view fixes its
/// own frame to these so switching tabs never resizes the sheet.
enum InspectorMetrics {
    static let paneWidth: CGFloat = 780
    static let paneHeight: CGFloat = 720
}
