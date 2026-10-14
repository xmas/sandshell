import Foundation
import SwiftUI

/// The sandbox itself, as it reports from inside: a Linux virtual machine
/// with its own kernel and distribution, sharing Mac folders over virtiofs.
struct SandboxSystem: Equatable, Sendable {
    var kernel: String          // "7.0.14"
    var arch: String            // "aarch64"
    var distribution: String?   // "Ubuntu 26.04.1 LTS"
    var cpus: Int?
    var memory: String?         // "8.9 GiB"
    /// Mount point → filesystem type (e.g. "virtiofs"), for the shared folders.
    var mountTypes: [String: String]

    /// "Ubuntu 26.04" from "Ubuntu 26.04.1 LTS".
    var shortDistribution: String? {
        guard let d = distribution else { return nil }
        let words = d.split(separator: " ")
        guard words.count >= 2 else { return d }
        let version = words[1].split(separator: ".").prefix(2).joined(separator: ".")
        return "\(words[0]) \(version)"
    }

    /// The probe run inside the sandbox; prints key=value lines.
    static let probe = #"echo "kernel=$(uname -r)"; echo "arch=$(uname -m)"; . /etc/os-release 2>/dev/null && echo "distro=$PRETTY_NAME"; echo "cpus=$(nproc 2>/dev/null)"; awk '/MemTotal/{print "memkb="$2}' /proc/meminfo; awk '$1=="host"{print "mount="$2" "$3}' /proc/mounts"#

    init?(probeOutput: String) {
        var values: [String: String] = [:]
        var mounts: [String: String] = [:]
        for line in probeOutput.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            if key == "mount" {
                let parts = value.split(separator: " ")
                if parts.count == 2 { mounts[String(parts[0])] = String(parts[1]) }
            } else {
                values[key] = value
            }
        }
        guard let kernel = values["kernel"], !kernel.isEmpty else { return nil }
        self.kernel = kernel.split(separator: "-").first.map(String.init) ?? kernel
        arch = values["arch"] ?? ""
        distribution = values["distro"].flatMap { $0.isEmpty ? nil : $0 }
        cpus = values["cpus"].flatMap(Int.init)
        memory = values["memkb"].flatMap(Double.init).map { String(format: "%.1f GiB", $0 / 1_048_576) }
        mountTypes = mounts
    }
}

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
        let path = folder.standardizedFileURL.path
        let containing = mounts
            .filter { path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
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

    /// The footer line: short, always visible.
    var summary: String {
        switch mode {
        case .readWrite: return "Sandbox · read-write"
        case .readOnly: return "Sandbox · read-only"
        case .notShared: return "Not shared with the sandbox"
        }
    }

    var symbol: String {
        switch mode {
        case .readWrite: return "lock.open"
        case .readOnly: return "lock"
        case .notShared: return "eye.slash"
        }
    }
}

/// The popover behind the Files footer's sandbox line.
struct SandboxAccessView: View {
    let access: SandboxAccess

    private static func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Shared with sandbox “\(access.sandbox)”").font(.headline)
            } icon: {
                Image(systemName: "shippingbox")
            }

            Group {
                switch access.mode {
                case .readWrite:
                    row("lock.open", .orange, "Read-write",
                        "The agent in the sandbox can create, change and delete files here. "
                        + "Its changes appear on your Mac immediately, and yours inside the sandbox.")
                case .readOnly:
                    row("lock", .green, "Read-only",
                        "The sandbox can read these files but can't change or delete them.")
                case .notShared:
                    row("eye.slash", .secondary, "Not shared",
                        "This folder isn't mounted into the sandbox, so the agent can't see it.")
                }
                row("cpu", .secondary, "The sandbox",
                    access.system.map { s in
                        "A Linux virtual machine with its own kernel: Linux \(s.kernel) (\(s.arch))"
                            + (s.distribution.map { ", \($0)" } ?? "")
                            + (s.cpus.map { ", \($0) CPUs" } ?? "") + (s.memory.map { ", \($0) memory" } ?? "")
                            + ". The agent runs inside it, not on your Mac."
                    } ?? "A Linux virtual machine with its own kernel. The agent runs inside it, not on your Mac.")
                row("externaldrive", .secondary, "How it's shared",
                    "A \(access.mountType ?? "virtiofs") mount at the same path inside the VM — the same files, not a copy. "
                    + "On your Mac: \(access.hostFileSystem ?? "local disk")"
                    + (access.volumeName.map { " volume “\($0)”" } ?? "") + ".")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(access.created ? "EVERYTHING THIS SANDBOX CAN SEE" : "WHAT THIS SANDBOX WILL SEE")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(access.mounts, id: \.self) { m in
                    HStack(spacing: 6) {
                        Image(systemName: m.readOnly ? "lock" : "lock.open")
                            .foregroundStyle(m.readOnly ? Color.green : Color.orange)
                            .frame(width: 14)
                        Text(Self.short(m.path)).font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(m.readOnly ? "read-only" : "read-write").font(.caption).foregroundStyle(.secondary)
                    }
                    .fontWeight(m == access.mount ? .semibold : .regular)
                }
            }

            row("eye.slash", .secondary, "Not visible to the sandbox",
                "Everything else on your Mac. And the sandbox's own files (its /tmp, its home "
                + "folder) stay inside it — they don't show up here.")
            row("key", .secondary, "Sign-ins",
                "Credentials Docker Sandboxes holds (like your Claude login) are added by its "
                + "network proxy, not stored as files in the sandbox.")
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ symbol: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
