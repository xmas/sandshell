import SwiftUI

/// Agents pane for the inspector: register custom (kit-defined) agents and pick
/// which this workspace offers. Applies immediately — nothing to rebuild.
struct AgentsInspectorPane: View {
    @StateObject private var model: AgentConfigModel

    init(controller: WorkspaceController) {
        _model = StateObject(wrappedValue: AgentConfigModel(
            enabled: controller.customAgents, apply: { [weak controller] in controller?.setCustomAgents($0) }))
    }

    var body: some View { AgentConfigView(model: model) }
}
