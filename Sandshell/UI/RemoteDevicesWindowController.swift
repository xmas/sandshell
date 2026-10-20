import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Remote Control ▸ Devices: pair a phone or another computer (a QR code, a
/// 6-digit code, or the link by AirDrop), and see or revoke paired devices.
@MainActor
final class RemoteDevicesWindowController: NSWindowController {
    static let shared = RemoteDevicesWindowController()

    private init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        window.title = "Remote Control Devices"
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.contentMinSize = NSSize(width: 380, height: 420)
        window.contentViewController = NSHostingController(rootView: RemoteDevicesView(
            hub: .shared, devices: .shared, pairing: .shared))
        (window.contentViewController as? NSHostingController<RemoteDevicesView>)?.sizingOptions = []
        window.setFrameAutosaveName("RemoteControlDevices")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Show the window; `pair` opens a pairing straight away.
    func show(pair: Bool = false) {
        if pair, RemotePairing.shared.current == nil { RemoteHub.shared.startPairing() }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct RemoteDevicesView: View {
    @ObservedObject var hub: RemoteHub
    @ObservedObject var devices: RemoteDevices
    @ObservedObject var pairing: RemotePairing

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pairSection
                Divider()
                devicesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Pairing

    /// Which address the device pairs at — it stays paired at that one only
    /// (a browser keeps its pairing per address): Tailscale for a phone that
    /// goes out, the home network for a computer that stays.
    @State private var pairOver: RemoteAddresses.Address.Kind?

    /// The kinds of address other devices can use now, Tailscale first.
    private var reachable: [RemoteAddresses.Address.Kind] {
        [.tailnet, .homeNetwork].filter { kind in hub.addresses.contains { $0.kind == kind } }
    }

    /// Where a device opens the pairing link (this Mac's own address would only work here).
    private var pairBase: URL? {
        let kind = pairOver.flatMap { reachable.contains($0) ? $0 : nil } ?? reachable.first
        return hub.addresses.first { $0.kind == kind }?.url
    }

    @ViewBuilder private var pairSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair a Device").font(.role(.title))
            if !hub.homeNetwork || !hub.tailscaleOn {
                VStack(alignment: .leading, spacing: 10) {
                    if !hub.homeNetwork {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: Binding(get: { hub.homeNetwork }, set: { hub.setHomeNetwork($0) })) {
                                Text("Home network").font(.role(.bodyEmphasis))
                            }
                            .toggleStyle(.switch).controlSize(.small)
                            Text("For computers and phones on this Wi-Fi. Only devices you pair can use it.")
                                .font(.role(.meta)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !hub.tailscaleOn { RemoteTailscaleRow(hub: hub) }
                }
            }
            if reachable.count > 1 {
                Picker("Pair over", selection: Binding(get: { pairOver ?? reachable[0] }, set: { pairOver = $0 })) {
                    ForEach(reachable, id: \.self) { kind in
                        Text(kind == .tailnet ? "Tailscale" : "Home network").tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Text((pairOver ?? reachable[0]) == .tailnet
                     ? "For a device with Tailscale: it reaches your chats at home or away."
                     : "For a device that stays on this Wi-Fi.")
                    .font(.role(.meta)).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let offer = pairing.offer, offer.expires > context.date {
                    offerView(offer, now: context.date)
                } else {
                    idleView
                }
            }
        }
    }

    @ViewBuilder private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let paired = pairing.lastPaired {
                Label("Paired “\(paired.name)”", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text("Scan a code with your phone's camera, AirDrop the link, or type a code into Sandshell "
                 + "in the device's browser. Each pairing works once, for five minutes.")
                .font(.role(.meta)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(pairing.lastPaired == nil ? "Pair a Device" : "Pair Another Device") { hub.startPairing() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func offerView(_ offer: RemotePairing.Offer, now: Date) -> some View {
        let link = pairBase.map { $0.appending(path: "pair").absoluteString + "#" + offer.secret }
        let left = max(0, Int(offer.expires.timeIntervalSince(now)))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                if let link, let qr = Self.qrImage(link) {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: 148, height: 148)
                        .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("QR code for the pairing link")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("CODE").font(.role(.meta, weight: .semibold)).foregroundStyle(.secondary)
                    Text(offer.code.prefix(3) + " " + offer.code.suffix(3))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("remote-pair-code")
                    Text(String(format: "Expires in %d:%02d", left / 60, left % 60))
                        .font(.role(.meta)).foregroundStyle(.secondary).monospacedDigit()
                    if let base = pairBase {
                        Text("On the device, open").font(.role(.meta)).foregroundStyle(.secondary)
                        Text(base.absoluteString).font(.role(.code)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                if let link, let url = URL(string: link) {
                    Button("Send with AirDrop") {
                        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
                    }
                    .help("AirDrop the one-time pairing link to your iPhone or another Mac")
                }
                Button("New Code") { hub.startPairing() }
                Button("Stop") { hub.cancelPairing() }
            }
            .controlSize(.small)
            if pairBase == nil {
                Text("Turn on the home network first: the link and QR code need an address other devices can reach.")
                    .font(.role(.meta)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Devices

    @ViewBuilder private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired Devices").font(.role(.title))
            if devices.devices.isEmpty {
                Text("None yet.").font(.role(.meta)).foregroundStyle(.secondary)
            }
            ForEach(devices.devices) { device in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: Self.symbol(for: device.name)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.role(.bodyEmphasis))
                        Text(Self.detail(device)).font(.role(.meta)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke") {
                        guard Alerts.confirm("Revoke “\(device.name)”?",
                                             "It won't be able to see or drive your chats until you pair it again.",
                                             confirm: "Revoke", destructive: true) else { return }
                        hub.revoke(device.id)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    static func detail(_ device: RemoteDevice) -> String {
        var parts = ["Paired " + Format.ago(device.pairedAt)]
        if let seen = device.lastSeen { parts.append("last seen " + Format.ago(seen)) }
        if let address = device.lastAddress { parts.append(address) }
        return parts.joined(separator: " · ")
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") || n.contains("android") || n.contains("phone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("windows") || n.contains("pc") { return "pc" }
        return "laptopcomputer"
    }
}
