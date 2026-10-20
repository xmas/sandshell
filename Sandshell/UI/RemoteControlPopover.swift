import SwiftUI

/// The pane strip antenna's popover: a chat's Remote Control switch and,
/// while it's on, the address to open it at.
struct RemoteControlPopover: View {
    @ObservedObject var hub: RemoteHub
    let sessionID: UUID
    /// Remote Control is on for the chat.
    @State var isOn: Bool
    /// The switch was flipped.
    let setOn: (Bool) -> Void
    @State private var copied = false

    private var url: URL? { hub.localURL(for: sessionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text("Remote Control").font(.role(.title))
                } icon: {
                    Image(systemName: isOn ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(isOn ? Color.accentColor : .secondary)
                }
                Spacer(minLength: 12)
                Toggle("Remote Control", isOn: Binding(get: { isOn }, set: { isOn = $0; copied = false; setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityIdentifier("remote-switch")
            }

            Text(isOn ? "Open this chat's address in a browser to follow it and drive it — send messages, "
                        + "answer the agent's questions, stop a turn."
                      : "Turn it on to follow and drive this chat from a browser.")
                .font(.role(.meta)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isOn {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ON THIS MAC").font(.role(.meta, weight: .semibold)).foregroundStyle(.secondary)
                    if let url {
                        Text(url.absoluteString)
                            .font(.role(.code))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("remote-url")
                        HStack(spacing: 8) {
                            Button(copied ? "Copied" : "Copy Address") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                copied = true
                            }
                            Button("Open in Browser") { NSWorkspace.shared.open(url) }
                                .keyboardShortcut(.defaultAction)
                        }
                        .controlSize(.small)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Starting…").font(.role(.meta)).foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR PHONE AND OTHER COMPUTERS").font(.role(.meta, weight: .semibold)).foregroundStyle(.secondary)
                    Text("Not yet — the address only opens on this Mac. Pairing over your home network "
                         + "and Tailscale come next.")
                        .font(.role(.meta)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    /// The popover's content controller, at its real size from the start: one
    /// that sizes itself only once it's up is placed for a taller first guess
    /// and ends up far below the antenna. It follows the content after that
    /// (the address shows when Remote Control goes on).
    @MainActor static func controller(_ view: RemoteControlPopover) -> NSViewController {
        let host = NSHostingController(rootView: view)
        let size = host.sizeThatFits(in: NSSize(width: 340, height: 2000))
        host.view.frame.size = size
        host.preferredContentSize = size
        host.sizingOptions = [.preferredContentSize]
        return host
    }
}
