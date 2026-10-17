import AppKit
import SwiftUI

/// A known MCP server the user can enable, registered individually via
/// `sbx mcp add <name> <addArgs…> --skip_auth` (no bundles). From the Docker
/// Sandboxes MCP runbook.
struct MCPServerDef: Identifiable, Hashable {
    let name: String
    let detail: String       // host (remote) or a short "local" note
    let addArgs: [String]    // args after `sbx mcp add <name>`
    var id: String { name }
    /// Remote (`--url`) servers use hosted OAuth; local (`--command`) don't.
    var isRemote: Bool { addArgs.first == "--url" }
}

enum MCPCatalog {
    static let servers: [MCPServerDef] = [
        .init(name: "notion",     detail: "mcp.notion.com",   addArgs: ["--url", "https://mcp.notion.com/mcp"]),
        .init(name: "atlassian",  detail: "mcp.atlassian.com", addArgs: ["--url", "https://mcp.atlassian.com/v1/mcp"]),
        .init(name: "grafana",    detail: "mcp.grafana.com",  addArgs: ["--url", "https://mcp.grafana.com/mcp"]),
        .init(name: "granola",    detail: "mcp.granola.ai",   addArgs: ["--url", "https://mcp.granola.ai/mcp"]),
        .init(name: "linear",     detail: "mcp.linear.app",   addArgs: ["--url", "https://mcp.linear.app/mcp"]),
        .init(name: "miro",       detail: "mcp.miro.com",     addArgs: ["--url", "https://mcp.miro.com/mcp"]),
        .init(name: "stripe",     detail: "mcp.stripe.com",   addArgs: ["--url", "https://mcp.stripe.com"]),
        .init(name: "playwright", detail: "npx @playwright/mcp (local)",
              addArgs: ["--command", "npx", "--args", "@playwright/mcp@latest"]),
    ]
    static func server(named name: String) -> MCPServerDef? { servers.first { $0.name == name } }
}

/// Editable MCP configuration (gateway URL + the enabled server set) with dirty
/// tracking, so Settings can force an Apply/Revert choice on leaving.
@MainActor
final class MCPConfigModel: ObservableObject {
    @Published var urlString: String
    @Published var servers: [String]

    private var baselineURL: String
    private var baselineServers: [String]

    init(url: URL, servers: [String]) {
        self.urlString = url.absoluteString
        self.servers = servers
        self.baselineURL = url.absoluteString
        self.baselineServers = servers
    }

    var isDirty: Bool { urlString != baselineURL || servers != baselineServers }

    /// The entered URL if it parses to an absolute http(s) URL, else nil.
    func resolvedURL() -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    func add(_ name: String) {
        let s = name.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !servers.contains(s) else { return }
        servers.append(s)
    }

    func remove(_ name: String) { servers.removeAll { $0 == name } }

    func commitBaseline() { baselineURL = urlString; baselineServers = servers }

    func revert() { urlString = baselineURL; servers = baselineServers }
}

/// Settings ▸ MCP pane. Edit the gateway URL and the list of MCP servers
/// loaded into containers via `sbx mcp load`.
struct MCPPaneView: View {
    @ObservedObject var model: MCPConfigModel
    @ObservedObject var controller: WorkspaceController
    let onConfirm: (_ servers: [String], _ url: URL) -> Void
    let onCancel: () -> Void

    @State private var jsonText = ""
    /// "Add from JSON" is registering the servers pasted.
    @State private var addingJSON = false
    @State private var showInfo = false
    @FocusState private var urlFocused: Bool

    private var urlValid: Bool { model.resolvedURL() != nil }

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
        VStack(spacing: 0) {
            Form {
                Section("Gateway") {
                    TextField("SBX_MCP_URL", text: $model.urlString,
                              prompt: Text(Workspace.defaultMCPURL.absoluteString))
                        .textFieldStyle(.roundedBorder)
                        .focused($urlFocused)
                        .onSubmit { urlFocused = false }   // Return commits and releases
                    if !model.urlString.isEmpty && !urlValid {
                        Text("Enter a valid http(s) URL.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Toggle(isOn: selection(row.name)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.name)
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                    if let error = controller.mcpErrors[row.name] {
                                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                    }
                                }
                            }
                            Spacer()
                            if row.remote { authControl(name: row.name, addArgs: row.addArgs) }
                            if row.custom {
                                Button { controller.removeMCP(row.name) } label: {
                                    Image(systemName: "trash")
                                }
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
                Section {
                    TextEditor(text: $jsonText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 92)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.25)))
                    if let error = controller.mcpAddError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    HStack {
                        Spacer()
                        Button("Add from JSON") {
                            let text = jsonText
                            addingJSON = true
                            Task {
                                // Cleared once every server in it is added: text with
                                // none, or one that failed, stays to fix.
                                if await controller.addMCPFromJSON(text), jsonText == text { jsonText = "" }
                                addingJSON = false
                            }
                        }
                        .disabled(addingJSON || jsonText.trimmingCharacters(in: .whitespaces).isEmpty)
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
            .formStyle(.grouped)
            // Press Return (commit) or Escape to leave the URL field.
            .onExitCommand { urlFocused = false }

            Divider()
            HStack(spacing: 10) {
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        Text("Authenticate registers a server with sbx and runs the gateway’s "
                             + "hosted OAuth in your browser (no bundles). Enabling a server "
                             + "loads it into running containers immediately via sbx mcp load. "
                             + "De-selecting takes effect when the container is next recreated "
                             + "(sbx has no live unload). Workspace files are always preserved.")
                            .font(.callout).padding().frame(width: 320)
                    }
                Button { controller.refreshMCPStatus() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh registration + auth status from sbx")
                Spacer()
                Button("Revert", action: onCancel).disabled(!model.isDirty)
                Button("Apply & Rebuild") {
                    if let url = model.resolvedURL() { onConfirm(model.servers, url) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty || !urlValid)
            }
            .padding(12)
        }
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        .onAppear { controller.refreshMCPStatus() }
        // After a server authenticates / is added, auto-enable it.
        .onChange(of: controller.mcpJustAuthenticated) { _, name in
            if let name { model.add(name); controller.mcpJustAuthenticated = nil }
        }
    }

    /// Per-server auth control: progress while busy, a green-dot Unauthorize when
    /// authorized, otherwise Authenticate (noting an expired credential).
    @ViewBuilder
    private func authControl(name: String, addArgs: [String]?) -> some View {
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

    /// Toggle binding for a catalog server's membership in the selected set.
    private func selection(_ name: String) -> Binding<Bool> {
        Binding(get: { model.servers.contains(name) },
                set: { $0 ? model.add(name) : model.remove(name) })
    }
}
