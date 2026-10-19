import SwiftUI

/// The popover behind the Files footer's sandbox line.
struct SandboxAccessView: View {
    let access: SandboxAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Shared with sandbox “\(access.sandbox)”").font(.role(.title))
            } icon: {
                Image(systemName: "shippingbox")
            }

            Group {
                switch access.mode {
                case .readWrite:
                    SandboxAccessRow(symbol: "lock.open", tint: .orange, title: "Read-write",
                                     text: "The agent in the sandbox can create, change and delete files here. "
                                        + "Its changes appear on your Mac immediately, and yours inside the sandbox.")
                case .readOnly:
                    SandboxAccessRow(symbol: "lock", tint: .green, title: "Read-only",
                                     text: "The sandbox can read these files but can't change or delete them.")
                case .notShared:
                    SandboxAccessRow(symbol: "eye.slash", tint: .secondary, title: "Not shared",
                                     text: "This folder isn't mounted into the sandbox, so the agent can't see it.")
                }
                SandboxAccessRow(symbol: "cpu", tint: .secondary, title: "The sandbox",
                                 text: "A Linux virtual machine with its own kernel"
                                    + (access.system.map { ": \($0.details)" } ?? "")
                                    + ". The agent runs inside it, not on your Mac.")
                SandboxAccessRow(symbol: "externaldrive", tint: .secondary, title: "How it's shared",
                                 text: "A \(access.mountType ?? "virtiofs") mount at the same path inside the VM — the same files, not a copy. "
                                    + "On your Mac: \(access.hostFileSystem ?? "local disk")"
                                    + (access.volumeName.map { " volume “\($0)”" } ?? "") + ".")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(access.created ? "EVERYTHING THIS SANDBOX CAN SEE" : "WHAT THIS SANDBOX WILL SEE")
                    .font(.role(.meta, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(access.mounts, id: \.self) { m in
                    HStack(spacing: 6) {
                        Image(systemName: m.readOnly ? "lock" : "lock.open")
                            .foregroundStyle(m.readOnly ? Color.green : Color.orange)
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        Text(m.path.tildeAbbreviated).font(.role(.code))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(m.readOnly ? "read-only" : "read-write").font(.role(.meta)).foregroundStyle(.secondary)
                    }
                    .bold(m == access.mount)
                }
            }

            SandboxAccessRow(symbol: "eye.slash", tint: .secondary, title: "Not visible to the sandbox",
                             text: "Everything else on your Mac. And the sandbox's own files (its /tmp, its home "
                                + "folder) stay inside it — they don't show up here.")
            SandboxAccessRow(symbol: "key", tint: .secondary, title: "Sign-ins",
                             text: "Credentials Docker Sandboxes holds (like your Claude login) are added by its "
                                + "network proxy, not stored as files in the sandbox.")
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One explained row of the panel: a symbol beside a title and its text.
private struct SandboxAccessRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.role(.bodyEmphasis))

                Text(text).font(.role(.body)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
