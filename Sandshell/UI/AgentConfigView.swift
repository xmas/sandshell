import AppKit
import SwiftUI

/// Custom agents for a workspace: the app-global registry of agents defined by
/// `kind: sandbox` kits (`AgentProfileStore`), each with a toggle choosing
/// whether this workspace offers it. Unlike kits, nothing here rebuilds a
/// sandbox — every agent gets its own container the first time it's used —
/// so changes apply immediately.
@MainActor
final class AgentConfigModel: ObservableObject {
    @Published private(set) var registry: [AgentProfile]
    @Published private(set) var enabled: Set<String>
    @Published var newRef = ""
    @Published private(set) var adding = false
    @Published var error: String?

    private let apply: ([AgentKind]) -> Void

    init(enabled: [AgentKind], apply: @escaping ([AgentKind]) -> Void) {
        self.registry = AgentProfileStore.all
        self.enabled = Set(enabled.map(\.rawValue))
        self.apply = apply
    }

    /// Enabled agents in registry order.
    var enabledAgents: [AgentKind] { registry.map(\.kind).filter { enabled.contains($0.rawValue) } }

    func binding(for agent: String) -> Binding<Bool> {
        Binding(get: { self.enabled.contains(agent) },
                set: { on in
                    if on { self.enabled.insert(agent) } else { self.enabled.remove(agent) }
                    self.apply(self.enabledAgents)
                })
    }

    /// Register the agent a kit defines (folder, ZIP, git or OCI reference) and
    /// offer it here. Reads the kit with `sbx kit inspect`, which can pull.
    func add(_ ref: String, enable: Bool = true) {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !adding else { return }
        adding = true
        error = nil
        Task {
            defer { adding = false }
            do {
                let profile = try await AgentProfileStore.register(kitRef: trimmed)
                registry = AgentProfileStore.all
                if enable, enabled.insert(profile.agent).inserted { apply(enabledAgents) }
                if enable { newRef = "" }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Re-read a registered agent's kit (display name, description, image).
    func refresh(_ profile: AgentProfile) {
        guard let ref = profile.kitRef else { return }
        add(ref, enable: false)
    }

    func update(_ profile: AgentProfile) {
        AgentProfileStore.upsert(profile)
        registry = AgentProfileStore.all
    }

    func remove(_ profile: AgentProfile) {
        AgentProfileStore.remove(profile.agent)
        registry = AgentProfileStore.all
        if enabled.remove(profile.agent) != nil { apply(enabledAgents) }
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Agent"
        panel.message = "Choose an agent kit folder or .zip (spec.yaml with kind: sandbox)."
        if panel.runModal() == .OK, let url = panel.url { add(url.path) }
    }
}

/// Settings ▸ Agents pane.
struct AgentConfigView: View {
    @ObservedObject var model: AgentConfigModel
    @State private var pickingSymbolFor: AgentProfile?

    var body: some View {
        Form {
            Section {
                if model.registry.isEmpty {
                    Text("No custom agents yet. Add a kit that defines one (kind: sandbox) below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.registry) { row($0) }
                }
            } header: {
                Text("Custom Agents")
            } footer: {
                Text("A kit with kind: sandbox defines a whole agent — its image, entrypoint and credentials — "
                     + "rather than extending one. Turned-on agents appear in + New Session; each gets its own "
                     + "sandbox the first time you start it. Custom agents always run their kit's image: the "
                     + "General ▸ Sandbox Image choice applies to built-in agents only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    Button("Choose Folder…") { model.browse() }.disabled(model.adding)
                    TextField("Kit reference", text: $model.newRef,
                              prompt: Text("Kit folder, .zip, git+https://… or OCI reference"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.add(model.newRef) }
                    if model.adding { ProgressView().controlSize(.small) }
                    Button("Add") { model.add(model.newRef) }
                        .disabled(model.adding || model.newRef.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("agents-add")
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Add an agent")
            }

            Section {
                Text(AgentKind.builtins.map(\.displayName).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Built in")
            }
        }
        .formStyle(.grouped)
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        .sheet(item: $pickingSymbolFor) { profile in
            SymbolPickerView(selection: Binding(
                get: { profile.icon },
                set: { var p = profile; p.icon = $0; model.update(p) }))
        }
    }

    @ViewBuilder private func row(_ profile: AgentProfile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Menu {
                ForEach(AgentProfile.symbols, id: \.self) { symbol in
                    Button { var p = profile; p.icon = symbol; model.update(p) } label: {
                        Label(symbol, systemImage: symbol)
                    }
                }
                Divider()
                Button("More Symbols…") { pickingSymbolFor = profile }
            } label: {
                BadgeMark(color: .hex(profile.colorHex), content: .symbol(profile.icon), side: 28)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .help("Choose the agent's icon")

            VStack(alignment: .leading, spacing: 4) {
                TextField("Display name", text: Binding(
                    get: { profile.displayName },
                    set: { var p = profile; p.displayName = $0; model.update(p) }),
                          prompt: Text("Display name"))
                    .labelsHidden()
                    .textFieldStyle(.plain).fontWeight(.medium)
                    .accessibilityIdentifier("agent-display-name")
                if let summary = profile.summary, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text([profile.agent, profile.kitRef, profile.image.map { "image \($0)" }].compactMap { $0 }
                        .joined(separator: " · "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    ForEach(AgentProfile.palette, id: \.self) { hex in
                        Circle().fill(Color(NSColor.hex(hex)))
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Color.primary.opacity(hex == profile.colorHex ? 0.8 : 0), lineWidth: 2)
                                .padding(-2))
                            .onTapGesture { var p = profile; p.colorHex = hex; model.update(p) }
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
            Toggle("Offer in this workspace", isOn: model.binding(for: profile.agent))
                .labelsHidden()
                .toggleStyle(.switch).controlSize(.small)
                .help("Offer this agent in this workspace’s New Session menu")
                .accessibilityIdentifier("agent-enabled-toggle")
            if profile.kitRef != nil {
                Button { model.refresh(profile) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.adding)
                    .help("Re-read the kit (name, description, image)")
            }
            Button { model.remove(profile) } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Remove from the agent list (existing sandboxes stay)")
        }
        .padding(.vertical, 2)
    }
}
