import SwiftUI

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

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var filtered: [HubKit] {
        let q = trimmedQuery
        guard !q.isEmpty else { return kits }
        return kits.filter { $0.name.localizedStandardContains(q) || $0.description.localizedStandardContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Docker Hub kits").font(.title3.bold())
                    Text("docker.io/\(namespace) · ^[\(kits.count) kit](inflect: true)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless).help("Reload from Docker Hub").disabled(loading)
            }
            .padding(16)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter kits", text: $query).textFieldStyle(.plain).focused($searchFocused)
                if !query.isEmpty {
                    Button("Clear Filter", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .stroke(Color(nsColor: .separatorColor))
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            content
            Divider()
            HStack {
                // With no kits the error is the empty state itself; here it only
                // flags a failed reload over the list already shown.
                if let error, !kits.isEmpty { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        let shown = filtered
        if loading {
            VStack(spacing: 10) { ProgressView(); Text("Fetching kits from Docker Hub…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            Group {
                if kits.isEmpty, let error {
                    ContentUnavailableView("No Kits Loaded", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else if kits.isEmpty {
                    ContentUnavailableView("No Kits Found", systemImage: "shippingbox",
                                           description: Text("docker.io/\(namespace) has no kits published."))
                } else {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { kit in
                        KitHubRow(kit: kit, registered: added.contains(kit.ref) || isRegistered(kit.ref)) {
                            onAdd(kit)
                            added.insert(kit.ref)
                        }
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
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
}

/// One published kit: what it is, how much it's used, and Add.
private struct KitHubRow: View {
    let kit: HubKit
    let registered: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cube.fill").font(.system(size: 16)).foregroundStyle(.green)
                .frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(kit.shortName).fontWeight(.medium)
                    Text(kit.ref).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if !kit.description.isEmpty {
                    Text(kit.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 10) {
                    Label("\(kit.pullCount.formatted(.number.notation(.compactName))) pulls",
                          systemImage: "arrow.down.circle")
                    if let d = kit.lastUpdated {
                        Label(Format.relative(d), systemImage: "clock")
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(registered ? "Added" : "Add", action: onAdd)
                .disabled(registered)
                .accessibilityIdentifier("hub-kit-add")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}
