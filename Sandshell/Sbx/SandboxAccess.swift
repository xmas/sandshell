import Foundation
import SwiftUI

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

    init(folder: URL, sandbox: String, mounts: [Mount], created: Bool) {
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
                row("externaldrive", .secondary, "How it's shared",
                    "A virtiofs mount at the same path inside the sandbox — the same files, not a copy. "
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
