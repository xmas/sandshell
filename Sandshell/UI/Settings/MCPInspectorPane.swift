import SwiftUI

/// MCP pane for the inspector: edits the enabled MCP servers + gateway URL and
/// applies them (rebuilding the container) on confirmation.
struct MCPInspectorPane: View {
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
