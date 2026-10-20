import SwiftUI

/// Remote Control over Tailscale: its switch, and what Tailscale says now.
struct RemoteTailscaleRow: View {
    @ObservedObject var hub: RemoteHub

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { hub.tailscaleOn }, set: { hub.setTailscale($0) })) {
                Text("Tailscale").font(.role(.bodyEmphasis))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!Tailscale.isInstalled && !hub.tailscaleOn)
            .accessibilityIdentifier("remote-tailscale")
            Text(note).font(.role(.meta)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !Tailscale.isInstalled {
                Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                    .font(.role(.meta))
            }
        }
        .onAppear { hub.refreshTailscale() }
    }

    private var note: String {
        guard Tailscale.isInstalled else {
            return "Install Tailscale on this Mac and your devices to reach your chats from anywhere."
        }
        guard let status = hub.tailscale, status.running else {
            return "Tailscale isn’t connected on this Mac — open it and sign in."
        }
        return hub.tailscaleOn
            ? "Paired devices on your tailnet can open the chat — at home or away."
            : "Turn on to reach your chats from your devices on Tailscale, wherever they are."
    }
}
