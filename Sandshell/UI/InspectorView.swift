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
                InspectorTabButton(pane: p, isSelected: pane == p) { selection.select(p) }
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
