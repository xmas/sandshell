import AppKit
import Observation

/// Editable kit selection for a workspace: the app-global registry of kits the
/// user has added, with a checkbox per kit choosing which apply here. Added
/// kits are applied in place (`sbx kit add`); any other change rebuilds.
@MainActor
@Observable
final class KitConfigModel {
    var registry: [KitRef]
    var enabled: Set<String>
    var newRef: String = ""
    /// Said under "Add a kit" (e.g. an agent kit went to Agents instead).
    var notice: String?
    /// A `kind: sandbox` kit was added here: it defines an agent, so it's
    /// registered as one; the host offers it in this workspace (nil = can't).
    @ObservationIgnored var onAgentKit: ((AgentProfile) -> Void)?

    private var baseline: Set<String>

    init(enabledRefs: [String]) {
        var reg = KitStore.all
        // Surface any enabled-but-unregistered refs so they still show + toggle.
        for ref in enabledRefs where !reg.contains(where: { $0.ref == ref }) {
            reg.append(KitRef(ref: ref))
        }
        self.registry = reg
        let on = Set(enabledRefs)
        self.enabled = on
        self.baseline = on
    }

    var isDirty: Bool { enabled != baseline }
    /// The pending change only turns kits on — applied with `sbx kit add`, no rebuild.
    var isAdditionsOnly: Bool { isDirty && enabled.isSuperset(of: baseline) }
    /// Enabled refs in registry order.
    var enabledRefs: [String] { registry.map(\.ref).filter { enabled.contains($0) } }

    func revert() { enabled = baseline }

    /// Kits the sandbox already has were adopted into the workspace: show them
    /// enabled and treat them as applied.
    func adopt(_ refs: [String]) {
        registry = KitStore.all
        for ref in refs where !registry.contains(where: { $0.ref == ref }) { registry.append(KitRef(ref: ref)) }
        enabled.formUnion(refs)
        baseline.formUnion(refs)
    }
    func commitBaseline() { baseline = enabled }

    /// Whether `ref` applies in this workspace — each kit row's toggle.
    subscript(isEnabled ref: String) -> Bool {
        get { enabled.contains(ref) }
        set { if newValue { enabled.insert(ref) } else { enabled.remove(ref) } }
    }

    /// Add a kit to the registry by reference (path or OCI), auto-selecting it.
    /// A non-directory reference gets its display name + summary filled in
    /// asynchronously from `sbx kit inspect`.
    func add(_ ref: String) {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let kit = KitStore.add(trimmed)
        registry = KitStore.all
        if !registry.contains(where: { $0.ref == kit.ref }) { registry.append(kit) }
        enabled.insert(kit.ref)
        newRef = ""
        notice = nil
        enrich(kit.ref, fillMetadata: kit.displayName == nil)
    }

    /// Add a kit picked in the Docker Hub browser (metadata comes with it).
    func add(hub kit: HubKit) {
        KitStore.add(kit.ref)
        KitStore.update(kit.ref, displayName: kit.shortName, summary: kit.description)
        registry = KitStore.all
        enabled.insert(kit.ref)
        notice = nil
        enrich(kit.ref, fillMetadata: kit.description.isEmpty)
    }

    func isRegistered(_ ref: String) -> Bool { registry.contains { $0.ref == ref } }

    /// Flag a registry kit as a default for new workspaces (app-global). Starring
    /// also enables it in *this* workspace — "default" means on everywhere,
    /// including here — while the toggle stays free as a per-workspace opt-out.
    /// Un-starring leaves this workspace's toggle as it is.
    func setDefault(_ ref: String, _ on: Bool) {
        KitStore.setDefault(ref, on)
        registry = KitStore.all
        if on { enabled.insert(ref) }
    }

    /// Registry defaults not enabled in this workspace.
    var missingDefaults: [KitRef] { registry.filter { $0.isDefault && !enabled.contains($0.ref) } }

    func enableDefaults() { for kit in missingDefaults { enabled.insert(kit.ref) } }

    /// Read the kit with `sbx kit inspect`: an agent kit (`kind: sandbox`)
    /// can't go in as `--kit`, so it moves to the agent registry; any other
    /// gets its display name + summary when `fillMetadata`. A kit sbx can't
    /// read stays added, with a notice saying so.
    private func enrich(_ ref: String, fillMetadata: Bool) {
        Task { @MainActor in
            guard let info = await SbxClient.shared.kitInspect(ref) else {
                notice = "Couldn’t read “\(ref)” with sbx kit inspect — check the reference."
                return
            }
            KitStore.learn(ref, from: info)
            if info.kind == "sandbox" {
                KitStore.remove(ref)
                registry = KitStore.all
                enabled.remove(ref)
                do {
                    let profile = try await AgentProfileStore.register(kitRef: ref)
                    if let onAgentKit {
                        onAgentKit(profile)
                        notice = "“\(profile.displayName)” defines an agent, not a kit — it’s been added under Agents "
                            + "and is offered in New Session."
                    } else {
                        notice = "“\(profile.displayName)” defines an agent, not a kit — it’s been added to your agents "
                            + "(Settings ▸ Agents)."
                    }
                } catch {
                    notice = error.localizedDescription
                }
                return
            }
            guard fillMetadata else { return }
            KitStore.update(ref, displayName: info.title, summary: info.description)
            registry = KitStore.all
        }
    }

    /// Pick a kit directory or .zip via a file panel.
    func browse() {
        guard let url = NSOpenPanel.chooseKit(prompt: "Add Kit", message: "Choose a kit folder or .zip.") else { return }
        // A folder's URL ends in "/"; the stored ref doesn't.
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        add(path)
    }

    /// Remove a kit from the app registry (and deselect it here).
    func removeFromRegistry(_ ref: String) {
        KitStore.remove(ref)
        registry = KitStore.all
        enabled.remove(ref)
    }
}
