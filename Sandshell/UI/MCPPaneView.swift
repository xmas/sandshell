import SwiftUI

/// Settings ▸ MCP pane. Edit the gateway URL and the list of MCP servers
/// loaded into containers via `sbx mcp load`.
struct MCPPaneView: View {
    let model: MCPConfigModel
    @ObservedObject var controller: WorkspaceController
    let onConfirm: (_ servers: [String], _ url: URL) -> Void
    let onCancel: () -> Void

    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                MCPGatewaySection(model: model, urlFocused: $urlFocused)
                MCPServersSection(model: model, controller: controller)
                MCPAddServersSection(controller: controller)
            }
            .formStyle(.grouped)
            // Press Return (commit) or Escape to leave the URL field.
            .onExitCommand { urlFocused = false }

            Divider()
            MCPPaneActions(model: model, controller: controller, onConfirm: onConfirm, onCancel: onCancel)
        }
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        // After a server authenticates / is added, auto-enable it — including one
        // that finished while this pane was closed or another pane was showing.
        .onChange(of: controller.mcpJustAuthenticated, initial: true) { _, name in
            adoptAuthenticated(name)
        }
    }

    /// Enable a server the controller just authenticated or added, then clear
    /// the controller's one-shot flag.
    private func adoptAuthenticated(_ name: String?) {
        guard let name else { return }
        model.add(name)
        controller.mcpJustAuthenticated = nil
    }
}

/// The gateway URL, with a note while it isn't a valid http(s) URL.
private struct MCPGatewaySection: View {
    @Bindable var model: MCPConfigModel
    var urlFocused: FocusState<Bool>.Binding

    var body: some View {
        Section("Gateway") {
            TextField("SBX_MCP_URL", text: $model.urlString,
                      prompt: Text(Workspace.defaultMCPURL.absoluteString))
                .textFieldStyle(.roundedBorder)
                .focused(urlFocused)
                .onSubmit { urlFocused.wrappedValue = false }   // Return commits and releases
            if !model.urlString.isEmpty && model.resolvedURL() == nil {
                Text("Enter a valid http(s) URL.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// The servers: catalog suggestions and registered ones, each with its toggle,
/// auth control and (for a registered one outside the catalog) Remove.
private struct MCPServersSection: View {
    @Bindable var model: MCPConfigModel
    @ObservedObject var controller: WorkspaceController

    /// A row in the Servers list: a catalog suggestion and/or a registered server.
    private struct Row: Identifiable {
        let name: String, detail: String
        let remote: Bool
        let addArgs: [String]?   // nil for already-registered (re-auth via name)
        let custom: Bool         // registered but not in the catalog → removable
        var id: String { name }
    }

    /// Catalog suggestions first (in order), then any other registered servers.
    private var rows: [Row] {
        var out: [Row] = []
        var seen = Set<String>()
        for def in MCPCatalog.servers {
            out.append(Row(name: def.name, detail: def.detail, remote: def.isRemote,
                           addArgs: def.addArgs, custom: false))
            seen.insert(def.name)
        }
        for (name, remote) in controller.mcpRegistered.sorted(by: { $0.key < $1.key })
        where !seen.contains(name) {
            out.append(Row(name: name, detail: remote ? "registered · remote" : "registered · local",
                           remote: remote, addArgs: nil, custom: true))
        }
        return out
    }

    var body: some View {
        Section {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Toggle(isOn: $model[isEnabled: row.name]) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if row.remote { MCPAuthControl(controller: controller, name: row.name, addArgs: row.addArgs) }
                    if row.custom {
                        Button("Remove \(row.name)", systemImage: "trash") { controller.removeMCP(row.name) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Remove this server (sbx mcp rm)")
                    }
                }
            }
        } header: {
            Text("Servers")
        } footer: {
            Text("Authenticate signs in via the gateway’s hosted OAuth (opens your "
                 + "browser). The toggle loads an authenticated server into the "
                 + "container via sbx mcp load.")
                .font(.caption)
        }
    }
}

/// Per-server auth control: progress while busy, a green-dot Unauthorize when
/// authorized, otherwise Authenticate (noting an expired credential).
private struct MCPAuthControl: View {
    @ObservedObject var controller: WorkspaceController
    let name: String
    let addArgs: [String]?

    var body: some View {
        if controller.mcpBusy.contains(name) {
            ProgressView().controlSize(.small)
        } else {
            switch controller.mcpAuth[name] {
            case "authorized":
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Button("Unauthorize") { controller.unauthorizeMCP(name) }
                        .foregroundStyle(.red)
                }
            case "expired":
                HStack(spacing: 6) {
                    Text("Expired").font(.caption).foregroundStyle(.orange)
                    Button("Re-authenticate") { controller.authenticateMCP(name: name, addArgs: addArgs) }
                }
            default:
                Button("Authenticate") { controller.authenticateMCP(name: name, addArgs: addArgs) }
            }
        }
    }
}

/// Paste a standard MCP config; each server in it is registered via sbx mcp add.
private struct MCPAddServersSection: View {
    let controller: WorkspaceController   // only called, never read

    @State private var jsonText = ""

    var body: some View {
        Section {
            TextEditor(text: $jsonText)
                .font(.subheadline.monospaced())
                .frame(height: 92)
                .overlay {
                    RoundedRectangle(cornerRadius: 5).stroke(.quaternary)
                }
            HStack {
                Spacer()
                Button("Add from JSON", action: addFromJSON)
                    .disabled(jsonText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Add servers")
        } footer: {
            Text("Paste a standard MCP config and each server is registered via "
                 + "sbx mcp add:\n{ \"mcpServers\": { \"name\": { \"command\": \"npx\", "
                 + "\"args\": [\"mcp-remote\", \"https://…/mcp\"] } } }")
                .font(.caption)
        }
    }

    /// Register each server in the pasted MCP JSON, then clear the field.
    private func addFromJSON() {
        controller.addMCPFromJSON(jsonText)
        jsonText = ""
    }
}

/// The bottom bar: what Apply does, Refresh, and Revert / Apply & Rebuild.
private struct MCPPaneActions: View {
    let model: MCPConfigModel
    let controller: WorkspaceController   // only called, never read
    let onConfirm: (_ servers: [String], _ url: URL) -> Void
    let onCancel: () -> Void

    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 10) {
            Button("About MCP Servers", systemImage: "info.circle") { showInfo = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                    Text("Authenticate registers a server with sbx and runs the gateway’s "
                         + "hosted OAuth in your browser (no bundles). Enabling a server "
                         + "loads it into running containers immediately via sbx mcp load. "
                         + "De-selecting takes effect when the container is next recreated "
                         + "(sbx has no live unload). Workspace files are always preserved.")
                        .font(.callout).padding().frame(width: 320)
                }
            Button("Refresh Status", systemImage: "arrow.clockwise") { controller.refreshMCPStatus() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh registration + auth status from sbx")
            Spacer()
            Button("Revert", action: onCancel).disabled(!model.isDirty)
            Button("Apply & Rebuild", action: apply)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty || model.resolvedURL() == nil)
        }
        .padding(12)
    }

    /// Confirm the edited server set with the gateway URL, if the URL is valid.
    private func apply() {
        guard let url = model.resolvedURL() else { return }
        onConfirm(model.servers, url)
    }
}
