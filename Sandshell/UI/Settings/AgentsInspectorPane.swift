import SwiftUI

/// Agents pane for the inspector: register custom (kit-defined) agents and pick
/// which this workspace offers. Applies immediately — nothing to rebuild.
struct AgentsInspectorPane: View {
    let controller: WorkspaceController   // only read to build the model

    var body: some View {
        PaneModelHost { [controller] in
            AgentConfigModel(enabled: controller.customAgents,
                             apply: { [weak controller] in controller?.setCustomAgents($0) })
        } content: { model in
            AgentConfigView(model: model)
        }
    }
}
