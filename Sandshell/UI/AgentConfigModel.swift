import AppKit
import Observation

/// Custom agents for a workspace: the app-global registry of agents defined by
/// `kind: sandbox` kits (`AgentProfileStore`), each with a toggle choosing
/// whether this workspace offers it. Unlike kits, nothing here rebuilds a
/// sandbox — every agent gets its own container the first time it's used —
/// so changes apply immediately.
@MainActor
@Observable
final class AgentConfigModel {
    private(set) var registry: [AgentProfile]
    private(set) var enabled: Set<String>
    var newRef = ""
    private(set) var adding = false
    var error: String?

    @ObservationIgnored private let apply: ([AgentKind]) -> Void

    init(enabled: [AgentKind], apply: @escaping ([AgentKind]) -> Void) {
        self.registry = AgentProfileStore.all
        self.enabled = Set(enabled.map(\.rawValue))
        self.apply = apply
    }

    /// Enabled agents in registry order.
    var enabledAgents: [AgentKind] { registry.map(\.kind).filter { enabled.contains($0.rawValue) } }

    /// Whether this workspace offers `agent` — each row's toggle. Applies at once.
    subscript(isOffered agent: String) -> Bool {
        get { enabled.contains(agent) }
        set {
            if newValue { enabled.insert(agent) } else { enabled.remove(agent) }
            apply(enabledAgents)
        }
    }

    /// The registered agent's display name — each row's name field.
    subscript(displayNameFor agent: String) -> String {
        get { registry.first { $0.agent == agent }?.displayName ?? "" }
        set { edit(agent) { $0.displayName = newValue } }
    }

    /// The registered agent's SF Symbol — the More Symbols… picker.
    subscript(iconFor agent: String) -> String {
        get { registry.first { $0.agent == agent }?.icon ?? "" }
        set { setIcon(newValue, for: agent) }
    }

    func setIcon(_ symbol: String, for agent: String) { edit(agent) { $0.icon = symbol } }

    func setColor(_ hex: String, for agent: String) { edit(agent) { $0.colorHex = hex } }

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

    /// Change the agent's profile as registered now — not a copy a row captured
    /// earlier — and drop the change if it's been removed meanwhile.
    private func edit(_ agent: String, _ change: (inout AgentProfile) -> Void) {
        guard var profile = registry.first(where: { $0.agent == agent }) else { return }
        change(&profile)
        update(profile)
    }

    func remove(_ profile: AgentProfile) {
        AgentProfileStore.remove(profile.agent)
        registry = AgentProfileStore.all
        if enabled.remove(profile.agent) != nil { apply(enabledAgents) }
    }

    func browse() {
        guard let url = NSOpenPanel.chooseKit(prompt: "Add Agent",
                                              message: "Choose an agent kit folder or .zip (spec.yaml with kind: sandbox).")
        else { return }
        // A folder's URL ends in "/"; the stored kit ref doesn't.
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        add(path)
    }
}
