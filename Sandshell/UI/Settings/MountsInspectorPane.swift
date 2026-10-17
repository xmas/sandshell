import SwiftUI

/// Mounts pane for the inspector: edits the workspace mount policy and applies it
/// (rebuilding the container) on confirmation. Switching panes discards edits.
struct MountsInspectorPane: View {
    @ObservedObject var controller: WorkspaceController
    @State private var confirming = false

    var body: some View {
        PaneModelHost {
            MountConfigModel(home: controller.home, root: controller.rootURL, policy: controller.policy)
        } content: { model in
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
                Button("Apply & Rebuild") { applyMounts(model) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The workspace’s container(s) will be stopped and recreated with the new mounts, "
                     + "ending any running sessions. Workspace files are preserved.")
            }
        }
    }

    /// Save the edited mounts and rebuild, then make them the baseline.
    private func applyMounts(_ model: MountConfigModel) {
        controller.applyConfiguration(policy: model.policy())
        model.commitBaseline()
    }
}
