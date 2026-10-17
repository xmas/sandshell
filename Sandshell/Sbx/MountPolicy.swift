import Foundation

/// The mount policy for a workspace: an explicit, user-curated set of mounts on
/// top of the always-present workspace root and the managed agent dot-folders.
///
/// This is curated rather than rule-based because `sbx` cannot create a sandbox
/// with too many bind mounts (it fails with `sailor: ConfigError` at ~25), so
/// the set must stay bounded (`mountLimit`). The default seeds a few common
/// read-only folders; the user adjusts it via the mount-config UI. Any change
/// ⇒ stop + rm + recreate the container.
struct MountPolicy: Codable, Hashable {
    /// User-curated mounts beyond the workspace root and the managed agent
    /// dot-folders. Each is rw or ro; display/apply order is preserved.
    var selections: [MountSpec]

    init(selections: [MountSpec] = []) {
        self.selections = selections
    }

    /// Max bind mounts per sandbox. `sbx create` fails above this (empirically
    /// 24 OK / 25+ → `failed to add nic: sailor: ConfigError`). See GA plan §3.
    static let mountLimit = 24

    /// A managed agent config/state mount under `$HOME`, always present on top of
    /// the workspace root and user selections. These carry the agent's config,
    /// history, and MCP state in and out of the container.
    ///
    /// These are mounted **whole-directory** because `sbx` only accepts directory
    /// mounts — a file mount path is rejected with "workspace path exists but is
    /// not a directory", and there is no `-v`/`--mount` flag. Claude authenticates
    /// from `~/.claude/.credentials.json` and reads `settings.json`/`mcp.json`/
    /// `.claude.json` at the top of `~/.claude`; since none of those *files* can
    /// be mounted individually, `~/.claude` must be mounted as a directory for
    /// auth, settings, MCP sync, and history to work. (Surgical *file* mounting —
    /// the original goal — is therefore impossible with sbx; a curated
    /// CLAUDE_CONFIG_DIR would be the only way to narrow exposure.)
    struct AgentMount: Hashable {
        /// Path relative to `$HOME` (e.g. `".claude"`). Must be a directory.
        var subpath: String
        var readonly: Bool
        /// How to ensure the host directory exists before mounting (bind-mounting
        /// a missing host path fails, so rw persistence targets must be seeded).
        var seed: Seed

        enum Seed: Hashable {
            /// Mount only if it already exists on the host (host-managed dirs).
            case ifPresent
            /// `mkdir -p` the directory first (rw persistence dirs).
            case directory
        }
    }

    /// The managed agent state/config dirs, in display/apply order. All mounted
    /// rw so the agents can persist auth, settings, MCP state, and history.
    static let agentMounts: [AgentMount] = [
        AgentMount(subpath: ".agents", readonly: false, seed: .directory),
        AgentMount(subpath: ".claude", readonly: false, seed: .directory),
        AgentMount(subpath: ".codex",  readonly: false, seed: .ifPresent),
    ]

    /// The agent mounts that will actually be bound, as `MountSpec`s — pure (no
    /// side effects), suitable for UI count/display. A mount is included when it
    /// is seeded (always created) or already present on the host.
    static func agentMountSpecs(home: URL) -> [MountSpec] {
        agentMounts.compactMap { m in
            let url = home.appending(path: m.subpath, directoryHint: .isDirectory)
            let willExist = m.seed != .ifPresent || isFolder(url.path)
            return willExist ? MountSpec(path: url, readonly: m.readonly) : nil
        }
    }

    /// Whether `path` is a folder (or a link to one): `sbx create` mounts only
    /// folders and fails the whole create on a file.
    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Create the host paths for seeded agent mounts. Call before `sbx create`.
    static func seedAgentMounts(home: URL) {
        let fm = FileManager.default
        for m in agentMounts {
            let url = home.appending(path: m.subpath, directoryHint: .isDirectory)
            switch m.seed {
            case .ifPresent:
                break
            case .directory:
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    /// Common `$HOME` folders seeded read-only in a fresh workspace's policy.
    static let defaultReadOnlyFolders = ["Downloads", "Documents", "Pictures", "Desktop"]

    /// The default policy for a new workspace: the existing common folders ro.
    static func makeDefault(home: URL) -> MountPolicy {
        let selections = defaultReadOnlyFolders
            .map { MountSpec(path: home.appending(path: $0, directoryHint: .isDirectory), readonly: true) }
            .filter { isFolder($0.path.path) }
        return MountPolicy(selections: selections)
    }

    /// Resolve the final mount set for `sbx create`, in priority order:
    /// 1. workspace `root` (rw); 2. managed agent mounts (`agentMounts`,
    /// `.claude` surgical); 3. user `selections`. Only folders that exist are
    /// kept (a file or missing path is skipped); de-duped by path, capped at
    /// `mountLimit`. Essentials (root + dot-folders) come first so the cap only
    /// ever drops user selections — `dropped` lists what was cut (never silent).
    func resolved(home: URL, root: URL) -> (mounts: [MountSpec], dropped: [MountSpec]) {
        var ordered: [MountSpec] = []
        var seen: Set<String> = []

        func add(_ spec: MountSpec) {
            let path = spec.path.standardizedFileURL.path
            guard !seen.contains(path), Self.isFolder(path) else { return }
            seen.insert(path)
            ordered.append(spec)
        }

        add(MountSpec(path: root, readonly: false))
        // The managed agent config/state mounts (`.claude` surgically) so
        // Codex/Claude can persist history + MCP state and read config on the
        // host. Seed rw targets first so bind-mounting them never fails.
        Self.seedAgentMounts(home: home)
        for spec in Self.agentMountSpecs(home: home) {
            add(spec)
        }
        let rootPath = root.standardizedFileURL.path
        for spec in selections where spec.path.standardizedFileURL.path != rootPath {
            add(spec)
        }

        if ordered.count > Self.mountLimit {
            return (Array(ordered.prefix(Self.mountLimit)), Array(ordered.suffix(from: Self.mountLimit)))
        }
        return (ordered, [])
    }
}
