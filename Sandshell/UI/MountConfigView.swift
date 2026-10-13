import AppKit
import SwiftUI

/// Editable state behind `MountConfigView`. Built from a `MountPolicy`; emits a
/// new policy on confirm. Enforces the sbx mount cap (`MountPolicy.mountLimit`).
@MainActor
final class MountConfigModel: ObservableObject {
    let home: URL
    let root: URL

    struct Suggestion: Identifiable { let id = UUID(); let url: URL; var enabled: Bool }

    /// The common `$HOME` folders, each toggleable (mounted read-only).
    @Published var suggestions: [Suggestion]
    /// User-added folders beyond the suggestions (each rw or ro).
    @Published var others: [MountSpec]
    /// UI-only: reveal the agent config dot-folder list (off by default).
    @Published var showDotFolders = false

    /// The saved policy this editor started from; drives dirty/revert/highlight.
    private(set) var baseline: MountPolicy

    init(home: URL, root: URL, policy: MountPolicy) {
        self.home = home
        self.root = root
        self.suggestions = []
        self.others = []
        self.baseline = policy
        load(from: policy)
        self.baseline = self.policy()   // canonical baseline (so isDirty starts false)
    }

    /// Populate the editable state from a policy (used by init and `revert`).
    private func load(from policy: MountPolicy) {
        let fm = FileManager.default
        let selectedPaths = Set(policy.selections.map { $0.path.standardizedFileURL.path })
        let suggestionURLs = MountPolicy.defaultReadOnlyFolders
            .map { home.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        suggestions = suggestionURLs.map {
            Suggestion(url: $0, enabled: selectedPaths.contains($0.standardizedFileURL.path))
        }
        let suggestionPaths = Set(suggestionURLs.map { $0.standardizedFileURL.path })
        others = policy.selections.filter { !suggestionPaths.contains($0.path.standardizedFileURL.path) }
    }

    // MARK: Dirty tracking / revert

    /// Whether the editor differs from the saved baseline (order-independent).
    var isDirty: Bool {
        Set(policy().selections) != Set(baseline.selections)
    }

    /// Discard edits, restoring the saved baseline.
    func revert() { load(from: baseline) }

    /// Adopt the current state as the new saved baseline (after Apply).
    func commitBaseline() { baseline = policy() }

    private var baselineReadonlyByPath: [String: Bool] {
        Dictionary(baseline.selections.map { ($0.path.standardizedFileURL.path, $0.readonly) },
                   uniquingKeysWith: { a, _ in a })
    }

    func isChanged(_ suggestion: Suggestion) -> Bool {
        suggestion.enabled != (baselineReadonlyByPath[suggestion.url.standardizedFileURL.path] != nil)
    }

    func isChanged(other spec: MountSpec) -> Bool {
        baselineReadonlyByPath[spec.path.standardizedFileURL.path] != spec.readonly
    }

    /// Managed agent config/state mounts that will actually be bound (`.claude`
    /// mounted surgically). Pure — no seeding side effects.
    var agentMounts: [MountSpec] {
        MountPolicy.agentMountSpecs(home: home)
    }

    /// Live total: root + (agent mounts) + enabled suggestions + others.
    var mountCount: Int {
        1 + agentMounts.count + suggestions.filter(\.enabled).count + others.count
    }

    var atLimit: Bool { mountCount >= MountPolicy.mountLimit }

    func policy() -> MountPolicy {
        var selections = suggestions.filter(\.enabled).map { MountSpec(path: $0.url, readonly: true) }
        selections += others
        return MountPolicy(selections: selections)
    }

    func shortPath(_ url: URL) -> String {
        let p = url.path, h = home.path
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        return p
    }

    /// Prompt for folders to add (skips duplicates and respects the cap).
    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Add folders to mount in the sandbox"
        guard panel.runModal() == .OK else { return }

        var existing = Set(others.map { $0.path.standardizedFileURL.path })
        existing.formUnion(suggestions.map { $0.url.standardizedFileURL.path })
        existing.insert(root.standardizedFileURL.path)
        for url in panel.urls {
            guard !existing.contains(url.standardizedFileURL.path) else { continue }
            guard mountCount < MountPolicy.mountLimit else { break }
            others.append(MountSpec(path: url, readonly: true))
            existing.insert(url.standardizedFileURL.path)
        }
    }

    /// Flip a user-added folder between read-only and read-write.
    func toggleReadonly(_ spec: MountSpec) {
        guard let i = others.firstIndex(where: { $0.path == spec.path }) else { return }
        others[i].readonly.toggle()
    }

    func removeOther(_ spec: MountSpec) {
        others.removeAll { $0.path.standardizedFileURL.path == spec.path.standardizedFileURL.path }
    }
}

/// Mount-configuration UI, shown on first open of a workspace and reused by
/// Settings. Lets the user pick which host folders the sandbox can see, with a
/// hard stop at the sbx mount limit.
struct MountConfigView: View {
    @ObservedObject var model: MountConfigModel
    var confirmTitle: String
    /// Explanation shown by the (i) button next to the confirm action.
    var confirmInfo: String
    /// Title for the secondary button ("Cancel" first-run, "Revert" in Settings).
    var cancelTitle: String = "Cancel"
    /// When true (Settings), Apply/Revert are enabled only when there are unsaved
    /// changes, and changed rows are highlighted. When false (first-run), the
    /// confirm action is always enabled.
    var requireChanges: Bool = false
    var onConfirm: (MountPolicy) -> Void
    var onCancel: () -> Void
    /// When embedded (e.g. in the setup wizard) the header/footer + fixed frame
    /// are dropped — the host provides the title and Next/Back navigation.
    var embedded: Bool = false

    @State private var showInfo = false

    private var actionsEnabled: Bool { !requireChanges || model.isDirty }

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Mounts").font(.headline)
                    Text("Choose which folders this workspace's sandboxes can access.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 10)
                Divider()
            }
            ScrollView { content.padding() }
            if !embedded {
                Divider()
                footer
            }
        }
        return embedded ? AnyView(stack) : AnyView(stack.frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Workspace root (always mounted rw).
            section("Workspace") {
                row(icon: "folder.fill", title: model.shortPath(model.root), tag: "rw") {
                    Text("Root").foregroundStyle(.secondary).font(.caption)
                }
            }

            // Suggested read-only folders.
            if !model.suggestions.isEmpty {
                section("Suggested folders (read-only)") {
                    ForEach($model.suggestions) { $s in
                        HStack(spacing: 6) {
                            changeDot(requireChanges && model.isChanged(s))
                            Toggle(isOn: $s.enabled) {
                                Label(model.shortPath(s.url), systemImage: "lock")
                            }
                            .disabled(!s.enabled && model.atLimit)
                        }
                    }
                }
            }

            // Other user-added folders.
            section("Other folders") {
                ForEach(model.others) { spec in
                    HStack(spacing: 6) {
                        changeDot(requireChanges && model.isChanged(other: spec))
                        Label(model.shortPath(spec.path), systemImage: spec.readonly ? "lock" : "pencil")
                        Spacer()
                        // Click to flip read-only ↔ read-write (applies on Apply & Rebuild).
                        Button {
                            model.toggleReadonly(spec)
                        } label: {
                            Text(spec.readonly ? "ro" : "rw")
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(spec.readonly ? Color.secondary : Color.orange)
                                .frame(minWidth: 22)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help(spec.readonly ? "Read-only — click to make read-write" : "Read-write — click to make read-only")
                        .accessibilityIdentifier("mount-access-toggle")
                        Button {
                            model.removeOther(spec)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button {
                    model.addFolders()
                } label: { Label("Add Folder…", systemImage: "plus") }
                    .disabled(model.atLimit)
            }

            // Managed agent config/state mounts — always mounted; info only.
            // `.claude` is mounted surgically (specific subpaths), some read-only.
            section("Agent configuration") {
                Toggle("Show agent config mounts", isOn: $model.showDotFolders)
                if model.showDotFolders {
                    ForEach(model.agentMounts) { spec in
                        Label(model.shortPath(spec.path),
                              systemImage: spec.readonly ? "lock" : "pencil")
                            .foregroundStyle(.secondary)
                    }
                    Text("Always mounted read-write — agents need these for settings, history, and auth.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: model.atLimit ? "exclamationmark.triangle.fill" : "externaldrive")
                .foregroundStyle(model.atLimit ? .orange : .secondary)
            Text("\(model.mountCount) / \(MountPolicy.mountLimit) mounts")
                .font(.callout)
                .foregroundStyle(model.atLimit ? .orange : .secondary)
            if model.atLimit {
                Text("limit reached").font(.caption).foregroundStyle(.orange)
            }
            if requireChanges && model.isDirty {
                Text("• Unsaved changes").font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("What does “\(confirmTitle)” do?")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                Text(confirmInfo)
                    .font(.callout)
                    .frame(width: 280, alignment: .leading)
                    .padding(12)
            }
            Button(cancelTitle, role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(!actionsEnabled)
            Button(confirmTitle) { onConfirm(model.policy()) }
                .keyboardShortcut(.defaultAction)
                .disabled(!actionsEnabled)
        }
        .padding()
    }

    /// A small orange dot marking a row that differs from the saved baseline
    /// (occupies fixed space so rows stay aligned).
    private func changeDot(_ visible: Bool) -> some View {
        Circle()
            .fill(visible ? Color.orange : Color.clear)
            .frame(width: 7, height: 7)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func row<Trailing: View>(icon: String, title: String, tag: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            trailing()
        }
    }
}
