import Foundation

/// What a sandbox can do with a folder on this Mac, for the Files pane's
/// reminder that these are shared files: which sandbox, read-write or
/// read-only, how it's shared, and what else that sandbox can (and can't) see.
struct SandboxAccess: Equatable {
    struct Mount: Equatable, Hashable {
        let path: String
        let readOnly: Bool
    }
    enum Mode: Equatable { case readWrite, readOnly, notShared }

    let sandbox: String
    /// Access to the folder itself (from the mount that contains it).
    let mode: Mode
    /// The shared folder that contains it (the folder or an ancestor).
    let mount: Mount?
    /// Everything shared with the sandbox.
    let mounts: [Mount]
    /// The sandbox exists (mounts are its real ones, not the planned ones).
    let created: Bool
    /// The Mac side: "APFS" etc., and the volume's name.
    let hostFileSystem: String?
    let volumeName: String?
    /// What the sandbox is (once it has been asked).
    let system: SandboxSystem?

    /// How the folder is mounted inside: "virtiofs" (the sandbox's word for it).
    var mountType: String? { mount.flatMap { system?.mountTypes[$0.path] } }

    /// The Files title strip: "Ubuntu 26.04 VM · Linux 7.0.14 · virtiofs read-write".
    var titleSummary: String {
        var parts: [String] = []
        if let system {
            parts.append("\(system.shortDistribution ?? "Linux") VM · Linux \(system.kernel)")
        } else {
            parts.append("Linux VM “\(sandbox)”")
        }
        switch mode {
        case .readWrite: parts.append("\(mountType ?? "virtiofs") read-write")
        case .readOnly: parts.append("\(mountType ?? "virtiofs") read-only")
        case .notShared: parts.append("not shared")
        }
        return parts.joined(separator: " · ")
    }

    init(folder: URL, sandbox: String, mounts: [Mount], created: Bool, system: SandboxSystem? = nil) {
        self.system = system
        self.sandbox = sandbox
        self.mounts = mounts
        self.created = created
        let path = Self.sandboxPath(for: folder.standardizedFileURL.path, mounts: mounts)
        let containing = mounts
            .filter { Self.path(path, isIn: $0.path) }
            .max { $0.path.count < $1.path.count }
        mount = containing
        mode = containing.map { $0.readOnly ? .readOnly : .readWrite } ?? .notShared

        var fs = statfs()
        if statfs(path, &fs) == 0 {
            let name = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            hostFileSystem = name == "apfs" ? "APFS" : name.uppercased()
        } else {
            hostFileSystem = nil
        }
        volumeName = (try? folder.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
    }

    /// `path` as the sandbox sees it. A mount appears inside at the path it was
    /// shared by, so a folder reached another way (/private/tmp/x for a mounted
    /// /tmp/x, or through a symlink) goes through the mount that holds it once
    /// links are resolved; a path no mount holds comes back unchanged.
    static func sandboxPath(for path: String, mounts: [Mount]) -> String {
        if mounts.contains(where: { Self.path(path, isIn: $0.path) }) { return path }
        let real = URL(fileURLWithPath: path).realPath
        let resolved = mounts.map { (mount: $0, real: URL(fileURLWithPath: $0.path).realPath) }
        guard let best = resolved.filter({ Self.path(real, isIn: $0.real) }).max(by: { $0.real.count < $1.real.count })
        else { return path }
        return best.mount.path + real.dropFirst(best.real.count)
    }

    private static func path(_ path: String, isIn folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The footer line: short, always visible.
    var summary: String {
        switch mode {
        case .readWrite: "Sandbox · read-write"
        case .readOnly: "Sandbox · read-only"
        case .notShared: "Not shared with the sandbox"
        }
    }

    var symbol: String {
        switch mode {
        case .readWrite: "lock.open"
        case .readOnly: "lock"
        case .notShared: "eye.slash"
        }
    }
}
