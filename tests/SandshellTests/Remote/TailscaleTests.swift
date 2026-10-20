import Foundation
import Testing
@testable import Sandshell

struct TailscaleStatusTests {
    @Test func aConnectedMac() throws {
        let json = """
        {"BackendState":"Running","CertDomains":["rowan-mentor-pro.tailf110dc.ts.net"],
         "Self":{"DNSName":"Rowan-Mentor-Pro.tailf110dc.ts.net.","TailscaleIPs":["100.72.200.61","fd7a:115c:a1e0::1a31:c83e"]}}
        """
        let status = try #require(Tailscale.parse(Data(json.utf8)))
        #expect(status.running)
        #expect(status.dnsName == "rowan-mentor-pro.tailf110dc.ts.net")
        #expect(status.httpsCertificates)
        // Names a browser puts in Host: the MagicDNS name and the IPv4 address.
        #expect(status.hosts == ["rowan-mentor-pro.tailf110dc.ts.net", "100.72.200.61"])
    }

    @Test(.tags(.edgeCase)) func signedOutOrStopped() throws {
        let json = #"{"BackendState":"NeedsLogin","CertDomains":null,"Self":{"DNSName":"","TailscaleIPs":null}}"#
        let status = try #require(Tailscale.parse(Data(json.utf8)))
        #expect(!status.running)
        #expect(status.dnsName == nil)
        #expect(!status.httpsCertificates)
        #expect(status.hosts.isEmpty)
    }

    @Test(.tags(.edgeCase)) func notJSON() {
        #expect(Tailscale.parse(Data("tailscale: not running".utf8)) == nil)
    }
}

@MainActor
struct RemoteTailnetHostTests {
    private func status(_ host: String, routes: RemoteRoutes) -> Int {
        let r = HTTPServer.Request(method: "GET", path: "/", query: [:], headers: ["host": host], body: Data(),
                                   peer: "100.101.1.2")
        guard case .response(let response) = routes.handle(r) else { return 0 }
        return response.status
    }

    @Test func theTailnetsNamesAreServedOnlyWhileOn() {
        let routes = RemoteRoutes(hub: .shared)
        routes.port = 47820
        #expect(status("mac.tail1.ts.net:47820", routes: routes) == 403)
        routes.tailnetNames = ["mac.tail1.ts.net", "100.72.200.61"]
        #expect(status("mac.tail1.ts.net:47820", routes: routes) != 403)
        #expect(status("100.72.200.61:47820", routes: routes) != 403)
        #expect(status("mac.tail1.ts.net:9999", routes: routes) == 403)
        #expect(status("other.tail1.ts.net:47820", routes: routes) == 403)
    }
}
