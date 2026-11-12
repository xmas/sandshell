import SwiftUI

/// Settings ▸ General ▸ Remote Control (every folder): the feature's master
/// switch, and the paired devices. Off, nothing is served and no chat shows
/// its antenna; each chat's own switch is kept for when it's back on.
struct RemoteControlSettingsSection: View {
    @ObservedObject var hub: RemoteHub
    @ObservedObject var devices: RemoteDevices
    @State private var keepAwake = KeepAwake.isEnabledForRemote

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { hub.isEnabled }, set: { hub.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Remote Control")
                    Text(hub.isEnabled
                         ? "Chats you turn it on for (the antenna in their title strip) can be followed and driven "
                           + "from a browser — on this Mac, or on devices you pair."
                         : "Off: Sandshell serves nothing, and chats don't show the antenna.")
                        .font(.role(.meta)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("settings-remote-control")
            if hub.isEnabled {
                LabeledContent("Paired devices") {
                    HStack {
                        Text(devices.devices.isEmpty ? "None" : "\(devices.devices.count)")
                            .foregroundStyle(.secondary)
                        Button("Manage…") { RemoteDevicesWindowController.shared.show() }
                    }
                }
                Toggle(isOn: $keepAwake) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep this Mac awake for Remote Control")
                        Text("While it’s on its power adapter, so your devices can reach it.")
                            .font(.role(.meta)).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: keepAwake) { _, on in KeepAwake.isEnabledForRemote = on }
            }
        } header: {
            Text("Remote Control — all folders")
        }
    }
}
