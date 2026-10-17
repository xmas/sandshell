import SwiftUI

/// Kits pane for the inspector: choose which registered kits apply to this
/// workspace. Added kits go in with `sbx kit add`; other changes rebuild.
struct KitsInspectorPane: View {
    @ObservedObject var controller: WorkspaceController
    @State private var pending: Pending?

    private enum Pending { case add, rebuild }

    var body: some View {
        let agent = controller.primaryAgent
        PaneModelHost { [controller] in
            let model = KitConfigModel(enabledRefs: controller.kits)
            model.onAgentKit = { [weak controller] profile in
                guard let controller else { return }
                controller.setCustomAgents(controller.customAgents + [profile.kind])
            }
            return model
        } content: { model in
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
                onAdoptDrift: { adoptDrift(for: agent, into: model) },
                onIgnoreDrift: { controller.ignoreKitDrift(for: agent) })
            .onAppear { controller.refreshKitDrift(for: agent) }
            .confirmationDialog(pending == .add ? "Add kits to the sandbox?" : "Apply kit changes and rebuild?",
                                item: $pending) { action in
                Button(action == .add ? "Add to Sandbox" : "Apply & Rebuild") { applyKits(action, from: model) }
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
    }

    /// Add the kits the sandbox has that the workspace didn't list, here too.
    private func adoptDrift(for agent: AgentKind, into model: KitConfigModel) {
        let refs = controller.kitDrift[agent]?.extra ?? []
        controller.adoptKitDrift(for: agent)
        model.adopt(refs)
    }

    /// Apply the edited kit set (added in place, or rebuilt) and make it the
    /// one edits are measured from.
    private func applyKits(_ action: Pending, from model: KitConfigModel) {
        controller.applyKits(model.enabledRefs, rebuild: action == .rebuild)
        model.commitBaseline()
    }
}
