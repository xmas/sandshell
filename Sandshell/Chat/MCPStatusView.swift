import SwiftUI

/// The chat's MCP servers as Claude Code sees them in this session, in groups
/// by where they're configured (`MCPServerList`): each server one line —
/// open it for what it runs, why it failed, its tools, Reconnect and
/// Turn On / Off. A group's menu turns many off (or on) at once.
struct MCPStatusView: View {
    @ObservedObject var session: ChatSession
    @State private var busy: String?
    @State private var error: String?
    @State private var open: Set<String> = []
    @State private var toolsShown: Set<String> = []
    @State private var query = ""
    /// Groups folded shut, by source (kept between popovers).
    @AppStorage("mcpPanel.collapsedSources") private var collapsedStore = ""

    /// Past this many, a filter field shows.
    private static let filterThreshold = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let servers = session.mcpServers {
                if servers.isEmpty {
                    ContentUnavailableView("No MCP Servers", systemImage: "server.rack",
                                           description: Text("Add them to ~/.claude.json, or to the project’s .mcp.json."))
                } else {
                    if servers.count > Self.filterThreshold {
                        TextField("Filter", text: $query, prompt: Text("Filter servers"))
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        Divider()
                    }
                    list(servers)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Asking Claude…").foregroundStyle(.secondary) }
                    .padding(14)
            }
            if let error {
                Text(error).font(.role(.meta)).foregroundStyle(.red).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .frame(width: 420)
        .task { refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MCP Servers").font(.role(.title))
            if let servers = session.mcpServers, !servers.isEmpty {
                Text(MCPServerList.summary(servers)).font(.role(.meta)).foregroundStyle(.secondary)
            }
            Spacer()
            if busy == "*" { ProgressView().controlSize(.small) }
            Button("Check Again", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless).help("Check again")
        }
        .padding([.horizontal, .top], 14).padding(.bottom, 8)
    }

    private func list(_ servers: [ChatSession.MCPServer]) -> some View {
        let groups = MCPServerList.groups(servers, matching: query)
        let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(groups) { group in
                    let shut = !filtering && collapsed.contains(group.source)
                    Section {
                        if !shut {
                            ForEach(group.servers) { server in
                                MCPServerRow(server: server, isBusy: busy == server.name || busy == group.source,
                                             isOpen: $open[contains: server.name],
                                             showsTools: $toolsShown[contains: server.name],
                                             reconnect: { reconnect(server) },
                                             toggleEnabled: { toggleEnabled(server) })
                                Divider().padding(.leading, 14)
                            }
                        }
                    } header: {
                        groupHeader(group, shut: shut)
                    }
                }
                if groups.isEmpty {
                    Text("No servers match “\(query)”.").foregroundStyle(.secondary).padding(14)
                }
            }
        }
        .frame(maxHeight: 460)
    }

    private func groupHeader(_ group: MCPServerList.Group, shut: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                setCollapsed(group.source, !shut)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.mark(9, weight: .semibold))
                        .rotationEffect(.degrees(shut ? 0 : 90))
                        .foregroundStyle(.secondary)
                    Text(group.title).font(.role(.bodyEmphasis))
                    Text(MCPServerList.summary(group.servers)).font(.role(.meta)).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.title), \(group.servers.count) servers")
            .accessibilityValue(shut ? "Collapsed" : "Expanded")
            Spacer()
            if busy == group.source { ProgressView().controlSize(.mini) }
            Menu {
                let notConnected = group.notConnected
                if !notConnected.isEmpty {
                    Button("Turn Off ^[\(notConnected.count) Server](inflect: true) Not Connected") {
                        setEnabled(notConnected, false, group: group.source)
                    }
                }
                if !group.on.isEmpty {
                    Button("Turn Off All ^[\(group.on.count) Server](inflect: true)") {
                        setEnabled(group.on, false, group: group.source)
                    }
                }
                if !group.off.isEmpty {
                    Button("Turn On All ^[\(group.off.count) Server](inflect: true)") {
                        setEnabled(group.off, true, group: group.source)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy != nil)
            .help("Turn \(group.title) servers on or off")
            .accessibilityLabel("\(group.title) actions")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
    }

    private var collapsed: Set<String> {
        Set(collapsedStore.split(separator: "\n").map(String.init))
    }

    private func setCollapsed(_ source: String, _ shut: Bool) {
        var set = collapsed
        if shut { set.insert(source) } else { set.remove(source) }
        collapsedStore = set.sorted().joined(separator: "\n")
    }

    private func refresh() {
        run("*") { try await session.refreshMCP() }
    }

    private func reconnect(_ server: ChatSession.MCPServer) {
        run(server.name) { try await session.reconnectMCP(server.name) }
    }

    private func toggleEnabled(_ server: ChatSession.MCPServer) {
        run(server.name) { try await session.setMCP(server.name, enabled: server.status == "disabled") }
    }

    /// One at a time (the list updates as each goes), stopping at the first error.
    private func setEnabled(_ servers: [ChatSession.MCPServer], _ enabled: Bool, group: String) {
        let names = servers.map(\.name)
        run(group) {
            for name in names { try await session.setMCP(name, enabled: enabled) }
        }
    }

    private func run(_ key: String, _ work: @escaping () async throws -> Void) {
        busy = key
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "connected": .green
        case "failed": .red
        case "needs-auth": .orange
        case "disabled": .gray
        default: .yellow
        }
    }

    static func label(_ status: String) -> String {
        switch status {
        case "connected": "Connected"
        case "failed": "Failed"
        case "needs-auth": "Needs sign-in"
        case "disabled": "Off"
        default: "Connecting…"
        }
    }
}

private extension Set {
    /// Whether `member` is in the set; setting it inserts or removes it
    /// (a `Binding<Bool>` through `$set[contains: member]`).
    subscript(contains member: Element) -> Bool {
        get { contains(member) }
        set { if newValue { insert(member) } else { remove(member) } }
    }
}
