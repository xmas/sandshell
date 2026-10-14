import AppKit
import SwiftUI

/// The per-root settings inspector, shown as a native macOS sheet from the
/// sidebar gear. A fixed-size view with a System-Settings-style tab strip at the
/// top, the selected pane in the middle, and a Done button pinned at the bottom
/// (also bound to Esc). The frame is fixed so switching panes never resizes or
/// repositions the sheet.
struct InspectorView: View {
    @ObservedObject var controller: WorkspaceController
    let onClose: () -> Void
    @State private var pane: InspectorPane = .general

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            paneContent
                .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight, alignment: .top)
                .clipped()
            Divider()
            footer
        }
        .frame(width: InspectorMetrics.paneWidth + 20)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Settings-style row of tinted icon tabs.
    private var tabStrip: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(InspectorPane.allCases) { p in
                TabButton(pane: p, isSelected: pane == p) { pane = p }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)   // Esc dismisses
                .accessibilityIdentifier("inspector-close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                    .fill(Color(pane.color))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: pane.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white))
                Text(pane.title).font(.system(size: 11))
                    .foregroundStyle(.primary).lineLimit(1)
            }
            .frame(width: 70)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                                     : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inspector-tab-\(pane.rawValue)")
    }
}

/// The per-root inspector panes. All app settings live here — there is no
/// separate global Settings window.
enum InspectorPane: String, CaseIterable, Identifiable {
    case general, sandboxes, folders, mounts, kits, mcp, git, terminal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mcp: return "MCP"
        default: return rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .sandboxes: return "shippingbox.fill"
        case .folders: return "folder.fill"
        case .mounts: return "externaldrive.fill"
        case .kits: return "cube.fill"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .git: return "arrow.triangle.branch"
        case .terminal: return "terminal.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .general: return .systemGray
        case .sandboxes: return .systemBrown
        case .folders: return .systemIndigo
        case .mounts: return .systemBlue
        case .kits: return .systemGreen
        case .mcp: return .systemPurple
        case .git: return .systemOrange
        case .terminal: return .systemTeal
        }
    }
}

/// Kits pane for the inspector: choose which registered kits apply to this
/// workspace. Kits are fixed at `sbx create`, so applying rebuilds the sandbox.
private struct KitsInspectorPane: View {
    @ObservedObject var controller: WorkspaceController
    @StateObject private var model: KitConfigModel
    @State private var confirming = false

    init(controller: WorkspaceController) {
        self.controller = controller
        _model = StateObject(wrappedValue: KitConfigModel(enabledRefs: controller.kits))
    }

    var body: some View {
        let agent = controller.primaryAgent
        KitConfigView(
            model: model,
            onConfirm: { _ in confirming = true },
            onCancel: { model.revert() },
            startup: controller.kitStartupStatus(for: agent),
            onShowLog: { controller.openKitLog(for: agent) },
            onRefreshStartup: { controller.refreshKitStartup(for: agent) },
            onRebuild: { confirming = true })
        .confirmationDialog("Apply kit changes and rebuild?", isPresented: $confirming) {
            Button("Apply & Rebuild") {
                controller.applyKits(model.enabledRefs)
                model.commitBaseline()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The workspace’s container(s) will be stopped and recreated with the new kit set, "
                 + "ending any running sessions. Workspace files are preserved.")
        }
    }
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
            Button("Apply & Rebuild") {
                controller.applyConfiguration(policy: model.policy())
                model.commitBaseline()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The workspace’s container(s) will be stopped and recreated with the new mounts, "
                 + "ending any running sessions. Workspace files are preserved.")
        }
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
