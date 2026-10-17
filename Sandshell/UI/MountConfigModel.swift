import AppKit
import Observation

/// Editable state behind `MountConfigView`. Built from a `MountPolicy`; emits a
/// new policy on confirm. Enforces the sbx mount cap (`MountPolicy.mountLimit`).
@MainActor
@Observable
final class MountConfigModel {
    let home: URL
    let root: URL

    struct Suggestion: Identifiable { let id = UUID(); let url: URL; var enabled: Bool }

    /// The common `$HOME` folders, each toggleable (mounted read-only).
    var suggestions: [Suggestion]
    /// User-added folders beyond the suggestions (each rw or ro).
    var others: [MountSpec]
    /// UI-only: reveal the agent config dot-folder list (off by default).
    var showDotFolders = false

    /// Managed agent config/state mounts that will actually be bound (whole
    /// directories, all read-write). Pure — no seeding side effects. Read once:
    /// `home` doesn't change.
    let agentMounts: [MountSpec]

    /// The saved policy this editor started from; drives dirty/revert/highlight.
    private(set) var baseline: MountPolicy

    init(home: URL, root: URL, policy: MountPolicy) {
        self.home = home
        self.root = root
        self.suggestions = []
        self.others = []
        self.agentMounts = MountPolicy.agentMountSpecs(home: home)
        self.baseline = policy
        load(from: policy)
        self.baseline = self.policy()   // canonical baseline (so isDirty starts false)
    }

    /// Populate the editable state from a policy (used by init and `revert`).
    private func load(from policy: MountPolicy) {
        let fm = FileManager.default
        let selectedPaths = Set(policy.selections.map { $0.path.standardizedFileURL.path })
        let suggestionURLs = MountPolicy.defaultReadOnlyFolders
            .map { home.appending(path: $0) }
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

    /// Live total: root + (agent mounts) + enabled suggestions + others.
    var mountCount: Int {
        1 + agentMounts.count + suggestions.count(where: \.enabled) + others.count
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
