import SwiftUI

/// The pane strip antenna's popover: a chat's Remote Control switch and,
/// while it's on, the addresses to open it at — on this Mac, and on the home
/// network for paired devices — with the home network switch and pairing.
struct RemoteControlPopover: View {
    @ObservedObject var hub: RemoteHub
    @ObservedObject var devices: RemoteDevices = .shared
    let sessionID: UUID
    /// Remote Control is on for the chat.
    @State var isOn: Bool
    /// The switch was flipped.
    let setOn: (Bool) -> Void
    @State private var copied: URL?

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
                Toggle("Remote Control", isOn: Binding(get: { isOn }, set: { isOn = $0; copied = nil; setOn($0) }))
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
                addresses
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { hub.homeNetwork }, set: { hub.setHomeNetwork($0) })) {
                        Text("Home network").font(.role(.bodyEmphasis))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityIdentifier("remote-home-network")
                    Text(hub.homeNetwork ? "Paired devices on this Wi-Fi can open the chat. Nothing else can."
                                         : "Turn on to reach this chat from your phone or another computer on this Wi-Fi.")
                        .font(.role(.meta)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Pair a Device…") { RemoteDevicesWindowController.shared.show(pair: true) }
                    if !devices.devices.isEmpty {
                        Button("\(devices.devices.count) Paired…") { RemoteDevicesWindowController.shared.show() }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    @ViewBuilder private var addresses: some View {
        let list = hub.addresses
        if list.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…").font(.role(.meta)).foregroundStyle(.secondary)
            }
        }
        ForEach(Array(list.enumerated()), id: \.element) { index, address in
            let url = address.url.appending(path: "s/\(sessionID.uuidString)")
            VStack(alignment: .leading, spacing: 4) {
                // One heading per kind: the home network can have a name and IPs.
                if index == 0 || list[index - 1].kind != address.kind {
                    Text(address.title.uppercased()).font(.role(.meta, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(url.absoluteString)
                    .font(.role(.code))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("remote-url")
                HStack(spacing: 8) {
                    Button(copied == url ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copied = url
                    }
                    if address.kind == .thisMac {
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    } else {
                        // AirDrop, Messages, Mail…: send it to the device.
                        ShareLink(item: url) { Text("Share…") }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// The popover's content controller, at its real size from the start: one
    /// that sizes itself only once it's up is placed for a taller first guess
    /// and ends up far below the antenna. It follows the content after that
    /// (the addresses show when Remote Control goes on).
    @MainActor static func controller(_ view: RemoteControlPopover) -> NSViewController {
        let host = NSHostingController(rootView: view)
        let size = host.sizeThatFits(in: NSSize(width: 360, height: 2000))
        host.view.frame.size = size
        host.preferredContentSize = size
        host.sizingOptions = [.preferredContentSize]
        return host
    }
}
