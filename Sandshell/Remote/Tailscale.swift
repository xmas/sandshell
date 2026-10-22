import Foundation

/// This Mac on Tailscale, read from its CLI (`tailscale status --json`):
/// Remote Control answers at its tailnet name, so paired devices reach a chat
/// from anywhere — over WireGuard, which encrypts what plain HTTP doesn't.
enum Tailscale {
    struct Status: Equatable, Sendable {
        /// Connected to the tailnet.
        let running: Bool
        /// "rowan-mentor-pro.tailf110dc.ts.net" (MagicDNS), lowercased.
        let dnsName: String?
        /// 100.x and fd7a:… addresses.
        let ips: [String]
        /// The tailnet issues HTTPS certificates (`tailscale serve --https`).
        let httpsCertificates: Bool

        /// Host names devices on the tailnet may use for this Mac.
        var hosts: [String] { running ? (dnsName.map { [$0] } ?? []) + ips.filter { !$0.contains(":") } : [] }
    }

    /// Where the CLI is: the app's own, the one it installs, or Homebrew's.
    static func cliPath(fileManager: FileManager = .default) -> String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { cliPath() != nil }

    /// `tailscale status --json`, parsed.
    static func parse(_ json: Data) -> Status? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: json) else { return nil }
        let me = value["Self"]
        let dns = me?["DNSName"]?.string.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return Status(running: value["BackendState"]?.string == "Running",
                      dnsName: dns.flatMap { $0.isEmpty ? nil : $0 },
                      ips: me?["TailscaleIPs"]?.array?.compactMap(\.string) ?? [],
                      httpsCertificates: !(value["CertDomains"]?.array ?? []).isEmpty)
    }

    /// How long the CLI gets to answer.
    static let timeout: TimeInterval = 5

    /// The status now (nil: not installed, or the CLI couldn't say).
    @concurrent static func status() async -> Status? {
        guard let cli = cliPath() else { return nil }
        let process = Process()
        process.executableURL = URL(filePath: cli)
        process.arguments = ["status", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A CLI that doesn't answer (Tailscale switching accounts or tailnets,
        // its daemon busy) is stopped after a few seconds: otherwise this read
        // never ends, and Remote Control keeps saying what it last knew.
        nonisolated(unsafe) let running = process
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if running.isRunning { running.terminate() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let status = parse(data) else {
            Log.info(.app, "remote: tailscale status --json gave no status (exit \(process.terminationStatus), \(data.count) bytes)")
            return nil
        }
        return status
    }
}
