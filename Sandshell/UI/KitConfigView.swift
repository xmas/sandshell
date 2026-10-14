import AppKit
import SwiftUI

/// Editable kit selection for a workspace: the app-global registry of kits the
/// user has added, with a checkbox per kit choosing which apply here. Added
/// kits are applied in place (`sbx kit add`); any other change rebuilds.
@MainActor
final class KitConfigModel: ObservableObject {
    @Published var registry: [KitRef]
    @Published var enabled: Set<String>
    @Published var newRef: String = ""
    /// Said under "Add a kit" (e.g. an agent kit went to Agents instead).
    @Published var notice: String?
    /// A `kind: sandbox` kit was added here: it defines an agent, so it's
    /// registered as one; the host offers it in this workspace (nil = can't).
    var onAgentKit: ((AgentProfile) -> Void)?

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

    func binding(for ref: String) -> Binding<Bool> {
        Binding(get: { self.enabled.contains(ref) },
                set: { if $0 { self.enabled.insert(ref) } else { self.enabled.remove(ref) } })
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
    /// gets its display name + summary when `fillMetadata`.
    private func enrich(_ ref: String, fillMetadata: Bool) {
        Task { @MainActor in
            guard let info = await SbxClient.shared.kitInspect(ref) else { return }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []   // any (directory or .zip)
        panel.prompt = "Add Kit"
        panel.message = "Choose a kit folder or .zip."
        if panel.runModal() == .OK, let url = panel.url { add(url.path) }
    }

    /// Remove a kit from the app registry (and deselect it here).
    func removeFromRegistry(_ ref: String) {
        KitStore.remove(ref)
        registry = KitStore.all
        enabled.remove(ref)
    }
}

/// Settings ▸ Kits pane (peer to Mounts). Lists registered kits with a checkbox
/// to apply them to this workspace; Apply & Rebuild recreates the sandbox.
struct KitConfigView: View {
    @ObservedObject var model: KitConfigModel
    var onConfirm: ([String]) -> Void = { _ in }
    var onCancel: () -> Void = {}
    /// When embedded (setup wizard) the Apply/Revert footer + fixed frame are
    /// dropped — the host provides navigation.
    var embedded: Bool = false
    /// Last kit startup reading for the workspace's sandbox (nil = none yet /
    /// not applicable, e.g. the setup wizard). Drives the "Sandbox startup"
    /// section and the per-kit status pills.
    var startup: KitStartupStatus? = nil
    var onShowLog: (() -> Void)? = nil
    var onRefreshStartup: (() -> Void)? = nil
    /// Force-rebuild the sandbox (the only way a changed kit is loaded).
    var onRebuild: (() -> Void)? = nil
    /// Kits the sandbox has that the workspace config doesn't (or vice versa).
    var drift: KitDrift? = nil
    var onAdoptDrift: (() -> Void)? = nil
    var onIgnoreDrift: (() -> Void)? = nil

    @State private var browsingHub = false

    var body: some View {
        Form {
            if let drift, !drift.isEmpty {
                driftSection(drift)
            }
            if let startup, startup.fetchError == nil {
                startupSection(startup)
            }
            Section {
                if model.registry.isEmpty {
                    Text("No kits added yet. Add a folder, .zip, or OCI reference below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.registry) { kit in row(kit) }
                }
                if !embedded, !model.missingDefaults.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "star").foregroundStyle(.secondary)
                        Text("\(model.missingDefaults.count) default kit\(model.missingDefaults.count == 1 ? " is" : "s are") turned off in this workspace.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Enable Defaults") { model.enableDefaults() }
                            .controlSize(.small)
                            .accessibilityIdentifier("kits-enable-defaults")
                    }
                }
            } header: {
                Text("Kits")
            } footer: {
                Text("Kits extend the sandbox agent with extra credentials, network policy, env, "
                     + "files, and startup steps. Turning a kit on adds it to the running sandbox "
                     + "(sbx kit add) where sbx can; turning one off — or a kit sbx can't add in place — "
                     + "rebuilds the workspace's sandbox(es). ★ marks a default: it is preselected "
                     + "for every new workspace.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    Button("Choose Folder…") { model.browse() }
                    TextField("Folder path, .zip, or OCI reference (docker.io/sbx/…)", text: $model.newRef)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.add(model.newRef) }
                    Button("Add") { model.add(model.newRef) }
                        .disabled(model.newRef.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("kits-notice")
                }
                HStack(spacing: 8) {
                    Button {
                        browsingHub = true
                    } label: {
                        Label("Browse Docker Hub…", systemImage: "shippingbox.and.arrow.backward")
                    }
                    .accessibilityIdentifier("kits-browse-hub")
                    Text("Official kits from docker.io/\(KitHub.officialNamespace)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Add a kit")
            }

            if !embedded {
                Section {
                    HStack {
                        Spacer()
                        Button("Revert", action: onCancel).disabled(!model.isDirty)
                        Button(model.isAdditionsOnly ? "Add to Sandbox" : "Apply & Rebuild") { onConfirm(model.enabledRefs) }
                            .disabled(!model.isDirty)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Embedded (setup wizard) sizes to whatever the host step area provides
        // (the wizard window is 580pt wide) — forcing the 780pt inspector-pane
        // width here clipped every row's leading text against the narrower
        // wizard, matching MountConfigView's embedded handling right above.
        .frame(width: embedded ? nil : InspectorMetrics.paneWidth,
              height: embedded ? nil : InspectorMetrics.paneHeight)
        .sheet(isPresented: $browsingHub) {
            KitHubBrowserView(isRegistered: { model.isRegistered($0) },
                              onAdd: { model.add(hub: $0) })
        }
    }

    // MARK: Kit drift

    @ViewBuilder private func driftSection(_ drift: KitDrift) -> some View {
        Section {
            if !drift.extra.isEmpty {
                driftRows(drift.extra, label: "not in this workspace")
                HStack {
                    Text("Added outside Sandshell (e.g. sbx kit add). A rebuild uses this workspace’s kit list and would drop "
                         + (drift.extra.count == 1 ? "it." : "them."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let onIgnoreDrift {
                        Button("Drop on Next Rebuild", action: onIgnoreDrift)
                            .accessibilityIdentifier("kits-drift-ignore")
                    }
                    if let onAdoptDrift {
                        Button("Adopt into Workspace", action: onAdoptDrift)
                            .accessibilityIdentifier("kits-drift-adopt")
                    }
                }
            }
            if !drift.missing.isEmpty {
                driftRows(drift.missing, label: "missing from the sandbox")
                HStack {
                    Text("Rebuild to apply this workspace’s kit list.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let onRebuild { Button("Rebuild Sandbox", action: onRebuild) }
                }
            }
        } header: {
            Text("Sandbox kits differ · \(drift.containerName)")
        }
    }

    @ViewBuilder private func driftRows(_ refs: [String], label: String) -> some View {
        ForEach(refs, id: \.self) { ref in
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.blue)
                Text(KitStartupParser.kitName(forRef: ref)).fontWeight(.medium)
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(ref).font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: Sandbox startup

    @ViewBuilder private func startupSection(_ startup: KitStartupStatus) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                startupIcon(startup)
                VStack(alignment: .leading, spacing: 2) {
                    Text(startupHeadline(startup)).fontWeight(.medium)
                    Text(startupSubline(startup)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let onRefreshStartup {
                    Button { onRefreshStartup() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Re-read the startup log")
                }
                if let onShowLog {
                    Button("Show Log", action: onShowLog)
                        .accessibilityIdentifier("kits-show-startup-log")
                }
                if let onRebuild {
                    Button("Rebuild Sandbox", action: onRebuild)
                        .accessibilityIdentifier("kits-rebuild-sandbox")
                }
            }
            ForEach(startup.problems) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        statusPill(entry.outcome)
                        Text(entry.name).font(.system(size: 12, design: .monospaced))
                    }
                    ForEach(Array(entry.detail.prefix(3).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        } header: {
            Text("Sandbox startup · \(startup.containerName)")
        } footer: {
            Text("Each kit’s startup steps run inside the sandbox right after it is created. "
                 + "A failing step stops the remaining kits; a warning means the kit continued without something it wanted. "
                 + KitStartupBannerView.rebuildHint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func startupIcon(_ startup: KitStartupStatus) -> some View {
        if startup.isInProgress {
            ProgressView().controlSize(.small)
        } else if startup.problems.contains(where: { if case .failed = $0.outcome { return true }; return false }) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else if startup.hasProblems {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func startupHeadline(_ startup: KitStartupStatus) -> String {
        if startup.isInProgress {
            let names = startup.installing.map(\.name)
            return names.isEmpty ? "Kits still installing…" : "Still installing: \(names.joined(separator: ", "))"
        }
        if startup.report?.isAborted == true { return "Startup stopped early — a kit failed" }
        let n = startup.problems.count
        if n == 0 { return startup.entries.isEmpty ? "No kits applied" : "All kits started" }
        return n == 1 ? "1 kit had a problem" : "\(n) kits had problems"
    }

    private func startupSubline(_ startup: KitStartupStatus) -> String {
        var parts: [String] = []
        let ok = startup.entries.filter { $0.outcome == .ok || $0.outcome == .noSteps }.count
        if ok > 0 { parts.append("\(ok) ok") }
        let warn = startup.entries.filter { $0.outcome == .warning }.count
        if warn > 0 { parts.append("\(warn) warning\(warn == 1 ? "" : "s")") }
        let failed = startup.entries.filter { if case .failed = $0.outcome { return true }; return false }.count
        if failed > 0 { parts.append("\(failed) failed") }
        let skipped = startup.entries.filter { $0.outcome == .skipped }.count
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if let started = startup.report?.startedAt {
            parts.append("ran " + RelativeDateTimeFormatter().localizedString(for: started, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func statusPill(_ outcome: KitStartupOutcome) -> some View {
        let (label, color): (String, Color) = {
            switch outcome {
            case .ok: return ("ok", .green)
            case .noSteps: return ("not run", .orange)
            case .running: return ("installing…", .secondary)
            case .warning: return ("warning", .orange)
            case .failed(let code): return ("failed · exit \(code)", .red)
            case .skipped: return ("skipped", .orange)
            }
        }()
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .accessibilityIdentifier("kit-status-pill")
    }

    // MARK: Rows

    @ViewBuilder private func row(_ kit: KitRef) -> some View {
        Toggle(isOn: model.binding(for: kit.ref)) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kit.title).fontWeight(.medium)
                        if let entry = startup?.entries.first(where: { $0.ref == kit.ref }) {
                            statusPill(entry.outcome)
                        }
                    }
                    if let summary = kit.summary, !summary.isEmpty {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(kit.ref).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { model.setDefault(kit.ref, !kit.isDefault) } label: {
                    Image(systemName: kit.isDefault ? "star.fill" : "star")
                        .foregroundStyle(kit.isDefault ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(kit.isDefault
                      ? "Default: preselected in every new workspace. Click to unset. The toggle still opts this workspace out."
                      : "Make this a default: on in every new workspace, and turned on here now.")
                .accessibilityIdentifier("kit-default-toggle")
                Button { model.removeFromRegistry(kit.ref) } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from the kit list")
            }
        }
    }
}


// MARK: - Docker Hub browser

/// Sheet listing the kits published in Docker Hub's `sbx` namespace, with
/// type-to-filter and one-click Add (registers `docker.io/sbx/<name>:latest`).
struct KitHubBrowserView: View {
    var namespace: String = KitHub.officialNamespace
    let isRegistered: (String) -> Bool
    let onAdd: (HubKit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kits: [HubKit] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @State private var added: Set<String> = []
    @FocusState private var searchFocused: Bool

    private var filtered: [HubKit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return kits }
        return kits.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Docker Hub kits").font(.title3.bold())
                    Text("docker.io/\(namespace) · \(kits.count) kits").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload from Docker Hub").disabled(loading)
            }
            .padding(16)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter kits", text: $query).textFieldStyle(.plain).focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
            .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            content
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if loading {
            VStack(spacing: 10) { ProgressView(); Text("Fetching kits from Docker Hub…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            Text(kits.isEmpty ? "No kits found." : "No kits match “\(query)”.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { kit in
                        row(kit)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    private func row(_ kit: HubKit) -> some View {
        let registered = added.contains(kit.ref) || isRegistered(kit.ref)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cube.fill").font(.system(size: 16)).foregroundStyle(.green)
                .frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(kit.shortName).fontWeight(.medium)
                    Text(kit.ref).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if !kit.description.isEmpty {
                    Text(kit.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 10) {
                    Label(formatPulls(kit.pullCount), systemImage: "arrow.down.circle")
                    if let d = kit.lastUpdated {
                        Label(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()), systemImage: "clock")
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(registered ? "Added" : "Add") {
                onAdd(kit)
                added.insert(kit.ref)
            }
            .disabled(registered)
            .accessibilityIdentifier("hub-kit-add")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            kits = try await KitHub.fetchKits(namespace: namespace)
        } catch {
            self.error = "Couldn’t reach Docker Hub: \(error.localizedDescription)"
        }
        loading = false
        searchFocused = true
    }

    private func formatPulls(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk pulls", Double(n) / 1000) : "\(n) pulls"
    }
}
