import SwiftUI

/// MCP pane for the inspector: edits the enabled MCP servers + gateway URL and
/// applies them (rebuilding the container) on confirmation.
struct MCPInspectorPane: View {
    @ObservedObject var controller: WorkspaceController

    var body: some View {
        PaneModelHost {
            MCPConfigModel(url: controller.mcpURL, servers: controller.mcpServers)
        } content: { model in
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
}
