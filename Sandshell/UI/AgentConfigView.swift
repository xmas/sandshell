import SwiftUI

/// Settings ▸ Agents pane.
struct AgentConfigView: View {
    @Bindable var model: AgentConfigModel
    @State private var pickingSymbolFor: AgentProfile?

    var body: some View {
        Form {
            Section {
                if model.registry.isEmpty {
                    Text("No custom agents yet. Add a kit that defines one (kind: sandbox) below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.registry) { profile in
                        AgentProfileRow(profile: profile, model: model) { pickingSymbolFor = profile }
                    }
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
                KitRefAddRow(ref: $model.newRef, prompt: "Kit folder, .zip, git+https://… or OCI reference",
                             busy: model.adding, addID: "agents-add", onBrowse: model.browse, onAdd: { model.add($0) })
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
            SymbolPickerView(selection: $model[iconFor: profile.agent])
        }
    }
}

/// One custom agent: its badge (icon and colour), name and kit, whether this
/// workspace offers it, re-read and remove.
private struct AgentProfileRow: View {
    let profile: AgentProfile
    @Bindable var model: AgentConfigModel
    let onMoreSymbols: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Menu {
                ForEach(AgentProfile.symbols, id: \.self) { symbol in
                    Button(symbol, systemImage: symbol) { model.setIcon(symbol, for: profile.agent) }
                }
                Divider()
                Button("More Symbols…", action: onMoreSymbols)
            } label: {
                BadgeMark(color: .hex(profile.colorHex), content: .symbol(profile.icon), side: 28)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .accessibilityLabel("Icon for \(profile.displayName)")
            .help("Choose the agent's icon")

            VStack(alignment: .leading, spacing: 4) {
                TextField("Display name", text: $model[displayNameFor: profile.agent],
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
                    ForEach(AgentProfile.palette.enumerated(), id: \.element) { index, hex in
                        Button { model.setColor(hex, for: profile.agent) } label: {
                            Circle().fill(Color(NSColor.hex(hex)))
                                .frame(width: 13, height: 13)
                                .overlay {
                                    Circle().stroke(Color.primary.opacity(hex == profile.colorHex ? 0.8 : 0), lineWidth: 2)
                                        .padding(-2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color \(index + 1)")
                        .accessibilityAddTraits(hex == profile.colorHex ? .isSelected : [])
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
            Toggle("Offer in this workspace", isOn: $model[isOffered: profile.agent])
                .labelsHidden()
                .toggleStyle(.switch).controlSize(.small)
                .help("Offer this agent in this workspace’s New Session menu")
                .accessibilityIdentifier("agent-enabled-toggle")
            if profile.kitRef != nil {
                Button("Re-read Kit for \(profile.displayName)", systemImage: "arrow.clockwise") {
                    model.refresh(profile)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless).disabled(model.adding)
                .help("Re-read the kit (name, description, image)")
            }
            Button { model.remove(profile) } label: {
                Label("Remove \(profile.displayName)", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from the agent list (existing sandboxes stay)")
        }
        .padding(.vertical, 2)
    }
}
