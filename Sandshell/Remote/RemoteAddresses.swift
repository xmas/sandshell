import Darwin
import Foundation
import SystemConfiguration

/// Where devices can reach this Mac's Remote Control server.
enum RemoteAddresses {
    struct Address: Hashable, Sendable {
        enum Kind: Sendable { case thisMac, homeNetwork, tailnet }
        let kind: Kind
        /// http://host:port/ — a session's page is `<url>s/<id>`.
        let url: URL

        var title: String {
            switch kind {
            case .thisMac: "This Mac"
            case .homeNetwork: "Home network"
            case .tailnet: "Tailscale"
            }
        }
    }

    static let loopbackNames: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// The Mac's Bonjour name ("Rowan-Mentor-Pro"), as in "Rowan-Mentor-Pro.local".
    static var localHostName: String? { SCDynamicStoreCopyLocalHostName(nil) as String? }

    /// Wi-Fi and Ethernet IPv4 addresses — not loopback, VM bridges or VPN tunnels.
    static func lanIPv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [String] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  isHomeInterface(String(cString: ifa.pointee.ifa_name)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append(String(decoding: host.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self))
            }
        }
        return found.filter { !$0.hasPrefix("169.254.") }
    }

    /// Wi-Fi and Ethernet interfaces are en0, en1…; bridges (VMs), utun (VPNs,
    /// Tailscale), awdl and llw (AirDrop) aren't the home network.
    static func isHomeInterface(_ name: String) -> Bool {
        name.hasPrefix("en") && name.dropFirst(2).allSatisfy(\.isNumber)
    }

    /// Host names devices on the home network may use for this Mac.
    static func homeNetworkHosts() -> [String] {
        (localHostName.map { ["\($0).local"] } ?? []) + lanIPv4()
    }

    /// The addresses to show for `port`: this Mac's, then the home network's
    /// (when it's on) — its .local name first, then its IPs (for devices that
    /// can't look .local names up).
    static func current(port: UInt16, homeNetwork: Bool, tailnet: [String] = []) -> [Address] {
        var list = [Address(kind: .thisMac, url: URL(string: "http://127.0.0.1:\(port)/")!)]
        if homeNetwork {
            list += homeNetworkHosts().compactMap { host in
                URL(string: "http://\(host):\(port)/").map { Address(kind: .homeNetwork, url: $0) }
            }
        }
        list += tailnet.compactMap { host in URL(string: "https://\(host)/").map { Address(kind: .tailnet, url: $0) } }
        return list
    }

    /// The host name in a `Host` header ("[::1]:47820" → "::1", "a.local:80" → "a.local"), lowercased.
    static func hostName(_ header: String) -> (name: String, port: UInt16?) {
        var host = header.lowercased()
        var port: UInt16?
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") {
                let rest = host[host.index(after: close)...]
                if rest.hasPrefix(":") { port = UInt16(rest.dropFirst()) }
                host = String(host[host.index(after: host.startIndex)..<close])
            }
        } else if let colon = host.lastIndex(of: ":"), host.firstIndex(of: ":") == colon {
            port = UInt16(host[host.index(after: colon)...])
            host = String(host[..<colon])
        }
        return (host, port)
    }
}
