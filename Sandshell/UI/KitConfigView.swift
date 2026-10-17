import SwiftUI

/// Settings ▸ Kits pane (peer to Mounts). Lists registered kits with a checkbox
/// to apply them to this workspace; Apply & Rebuild recreates the sandbox.
struct KitConfigView: View {
    @Bindable var model: KitConfigModel
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
                KitDriftSection(drift: drift, onIgnore: onIgnoreDrift, onAdopt: onAdoptDrift, onRebuild: onRebuild)
            }
            if let startup, startup.fetchError == nil {
                KitStartupSection(startup: startup, onRefresh: onRefreshStartup, onShowLog: onShowLog,
                                  onRebuild: onRebuild)
            }
            Section {
                if model.registry.isEmpty {
                    Text("No kits added yet. Add a folder, .zip, or OCI reference below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.registry) { kit in
                        KitRow(kit: kit, isOn: $model[isEnabled: kit.ref],
                               outcome: startup?.entries.first { $0.ref == kit.ref }?.outcome,
                               onToggleDefault: { model.setDefault(kit.ref, !kit.isDefault) },
                               onRemove: { model.removeFromRegistry(kit.ref) })
                    }
                }
                if !embedded, !model.missingDefaults.isEmpty {
                    HStack(spacing: 8) {
                        Label {
                            Text("\(model.missingDefaults.count) default kit\(model.missingDefaults.count == 1 ? " is" : "s are") turned off in this workspace.")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "star")
                        }
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Enable Defaults", action: model.enableDefaults)
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
                KitRefAddRow(ref: $model.newRef, prompt: "Folder path, .zip, or OCI reference (docker.io/sbx/…)",
                             onBrowse: model.browse, onAdd: { model.add($0) })
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
        // wizard, matching MountConfigView's embedded handling.
        .frame(width: embedded ? nil : InspectorMetrics.paneWidth,
              height: embedded ? nil : InspectorMetrics.paneHeight)
        .sheet(isPresented: $browsingHub) {
            KitHubBrowserView(isRegistered: { model.isRegistered($0) },
                              onAdd: { model.add(hub: $0) })
        }
    }
}

// MARK: Kit drift

/// The sandbox's kits differ from this workspace's list: kits it has that the
/// workspace doesn't (adopt or drop them) and kits it lacks (rebuild).
private struct KitDriftSection: View {
    let drift: KitDrift
    let onIgnore: (() -> Void)?
    let onAdopt: (() -> Void)?
    let onRebuild: (() -> Void)?

    var body: some View {
        Section {
            if !drift.extra.isEmpty {
                ForEach(drift.extra, id: \.self) { KitDriftRow(ref: $0, label: "not in this workspace") }
                HStack {
                    Text("Added outside Sandshell (e.g. sbx kit add). A rebuild uses this workspace’s kit list and would drop "
                         + (drift.extra.count == 1 ? "it." : "them."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let onIgnore {
                        Button("Drop on Next Rebuild", action: onIgnore)
                            .accessibilityIdentifier("kits-drift-ignore")
                    }
                    if let onAdopt {
                        Button("Adopt into Workspace", action: onAdopt)
                            .accessibilityIdentifier("kits-drift-adopt")
                    }
                }
            }
            if !drift.missing.isEmpty {
                ForEach(drift.missing, id: \.self) { KitDriftRow(ref: $0, label: "missing from the sandbox") }
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
}

/// One kit in the drift list, with how it differs.
private struct KitDriftRow: View {
    let ref: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(KitStartupParser.kitName(forRef: ref)).fontWeight(.medium)
            } icon: {
                Image(systemName: "shippingbox.fill").foregroundStyle(.blue)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(ref).font(.caption.monospaced())
                .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: Sandbox startup

/// The last kit startup reading: a verdict with its actions, then each kit that
/// had a problem and the first lines of what it said.
private struct KitStartupSection: View {
    let startup: KitStartupStatus
    let onRefresh: (() -> Void)?
    let onShowLog: (() -> Void)?
    let onRebuild: (() -> Void)?

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if startup.isInProgress {
                    ProgressView().controlSize(.small)
                } else if startup.problems.contains(where: { if case .failed = $0.outcome { true } else { false } }) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                } else if startup.hasProblems {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(startup.headline).fontWeight(.medium)
                    Text(startup.tally).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let onRefresh {
                    Button("Re-read Startup Log", systemImage: "arrow.clockwise", action: onRefresh)
                        .labelStyle(.iconOnly)
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
                        KitStatusPill(outcome: entry.outcome)
                        Text(entry.name).font(.callout.monospaced())
                    }
                    ForEach(entry.detail.prefix(3).enumerated(), id: \.offset) { _, line in
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
}

extension KitStartupStatus {
    /// The Kits pane's verdict: still installing, stopped early, or how many
    /// kits had problems.
    var headline: String {
        if isInProgress {
            let names = installing.map(\.name)
            return names.isEmpty ? "Kits still installing…" : "Still installing: \(names.formatted())"
        }
        if report?.isAborted == true { return "Startup stopped early — a kit failed" }
        let n = problems.count
        if n == 0 { return entries.isEmpty ? "No kits applied" : "All kits started" }
        return n == 1 ? "1 kit had a problem" : "\(n) kits had problems"
    }

    /// Kits by outcome and when startup ran ("2 ok · 1 warning · ran 5m ago").
    var tally: String {
        var parts: [String] = []
        let ok = entries.count(where: { $0.outcome == .ok || $0.outcome == .noSteps })
        if ok > 0 { parts.append("\(ok) ok") }
        let warn = entries.count(where: { $0.outcome == .warning })
        if warn > 0 { parts.append(String(AttributedString(localized: "^[\(warn) warning](inflect: true)").characters)) }
        let failed = entries.count(where: { if case .failed = $0.outcome { true } else { false } })
        if failed > 0 { parts.append("\(failed) failed") }
        let skipped = entries.count(where: { $0.outcome == .skipped })
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if let started = report?.startedAt {
            parts.append("ran " + Format.relative(started))
        }
        return parts.joined(separator: " · ")
    }
}

/// A kit's startup outcome as a small tinted capsule.
private struct KitStatusPill: View {
    let outcome: KitStartupOutcome

    var body: some View {
        let (label, color): (String, Color) = switch outcome {
        case .ok: ("ok", .green)
        case .noSteps: ("not run", .orange)
        case .running: ("installing…", .secondary)
        case .warning: ("warning", .orange)
        case .failed(let code): ("failed · exit \(code)", .red)
        case .skipped: ("skipped", .orange)
        }
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.quaternary, in: .capsule)
            .foregroundStyle(color)
            .accessibilityIdentifier("kit-status-pill")
    }
}

// MARK: Rows

/// One registered kit: whether it applies here, what it is, its startup
/// outcome, the default star and Remove.
private struct KitRow: View {
    let kit: KitRef
    @Binding var isOn: Bool
    /// The kit's outcome in the last startup reading (nil = none).
    let outcome: KitStartupOutcome?
    let onToggleDefault: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kit.title).fontWeight(.medium)
                        if case let agent?? = KitStore.requiredAgent(kit.ref) {
                            Text("\(AgentKind(rawValue: agent).displayName) only")
                                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quinary, in: .capsule)
                                .help("Made for \(AgentKind(rawValue: agent).displayName): other agents' sandboxes leave it out.")
                        }
                        if let outcome {
                            KitStatusPill(outcome: outcome)
                        }
                    }
                    if let summary = kit.summary, !summary.isEmpty {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(kit.ref).font(.caption.monospaced())
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(action: onToggleDefault) {
                    Label("Default Kit: \(kit.title)", systemImage: kit.isDefault ? "star.fill" : "star")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(kit.isDefault ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(kit.isDefault
                      ? "Default: preselected in every new workspace. Click to unset. The toggle still opts this workspace out."
                      : "Make this a default: on in every new workspace, and turned on here now.")
                .accessibilityAddTraits(kit.isDefault ? .isSelected : [])
                .accessibilityIdentifier("kit-default-toggle")
                Button(action: onRemove) {
                    Label("Remove \(kit.title)", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from the kit list")
            }
        }
    }
}
