import Foundation
import Network
import Testing
@testable import Sandshell

/// What arrived so far on a connection, parsed.
fileprivate func parse(_ text: String) -> HTTPServer.Parsed {
    HTTPServer.parse(Data(text.utf8), peer: "127.0.0.1")
}

struct HTTPRequestParsingTests {
    @Test func aGetWithAQuery() throws {
        guard case .request(let r) = parse("GET /api/events?session=abc%20d HTTP/1.1\r\nHost: 127.0.0.1:47820\r\n\r\n") else {
            Issue.record("not parsed"); return
        }
        #expect(r.method == "GET")
        #expect(r.path == "/api/events")
        #expect(r.query["session"] == "abc d")
        #expect(r.headers["host"] == "127.0.0.1:47820")
        #expect(r.segments == ["api", "events"])
    }

    @Test func aPostWaitsForItsWholeBody() throws {
        let head = "POST /api/sessions/x/send HTTP/1.1\r\nContent-Length: 10\r\nX-Sandshell: 1\r\n\r\n"
        guard case .incomplete = parse(head + "{\"text\":") else { Issue.record("should wait for the body"); return }
        guard case .request(let r) = parse(head + "{\"text\":1}") else { Issue.record("not parsed"); return }
        #expect(r.body == Data("{\"text\":1}".utf8))
        #expect(r.headers["x-sandshell"] == "1")
    }

    @Test func headersArriveInPieces() {
        guard case .incomplete = parse("GET / HTTP/1.1\r\nHost: x\r\n") else { Issue.record("should wait"); return }
    }

    @Test(.tags(.edgeCase)) func aPercentEncodedPathIsDecoded() {
        guard case .request(let r) = parse("GET /s/a%2Fb HTTP/1.1\r\n\r\n") else { Issue.record("not parsed"); return }
        #expect(r.path == "/s/a/b")
    }

    @Test(.tags(.edgeCase), arguments: [
        ("GARBAGE\r\n\r\n", 400),
        ("POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\n", 400),
        ("POST / HTTP/1.1\r\nContent-Length: 999999999999\r\n\r\n", 413),
    ])
    func badRequestsAreRefused(text: String, status: Int) {
        guard case .invalid(let got) = parse(text) else { Issue.record("should be refused"); return }
        #expect(got == status)
    }

    @Test(.tags(.edgeCase)) func endlessHeadersAreRefused() {
        let huge = "GET / HTTP/1.1\r\n" + String(repeating: "X-Pad: 0123456789\r\n", count: 5000)
        guard case .invalid(431) = parse(huge) else { Issue.record("should be refused"); return }
    }
}

struct HTTPServerAddressTests {
    @Test(arguments: [
        (NWEndpoint.hostPort(host: "127.0.0.1", port: 80), true),
        (.hostPort(host: "::1", port: 80), true),
        (.hostPort(host: "10.0.0.5", port: 80), false),
        (.hostPort(host: "fe80::1", port: 80), false),
    ])
    func loopbackPeers(endpoint: NWEndpoint, loopback: Bool) {
        #expect(HTTPServer.isLoopback(endpoint) == loopback)
    }
}

@MainActor
struct RemoteRoutesTests {
    @Test(arguments: [
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A], "image/png"),
        ([0xFF, 0xD8, 0xFF, 0xE0], "image/jpeg"),
        ([0x47, 0x49, 0x46, 0x38], "image/gif"),
        ([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50], "image/webp"),
        ([0x00, 0x01], "application/octet-stream"),
    ] as [([UInt8], String)])
    func imageTypes(bytes: [UInt8], type: String) {
        #expect(RemoteRoutes.imageType(Data(bytes)) == type)
    }

    @Test(arguments: [
        ("127.0.0.1:47820", 200),
        ("localhost:47820", 200),
        ("[::1]:47820", 200),
        ("evil.example", 403),
        ("127.0.0.1.evil.example:47820", 403),
    ])
    func onlyThisServersHostNamesAreServed(host: String, status: Int) {
        let routes = RemoteRoutes(hub: RemoteHub.shared)
        routes.port = 47820
        let request = HTTPServer.Request(method: "GET", path: "/api/info", query: [:], headers: ["host": host],
                                         body: Data(), peer: "127.0.0.1", peerIsLoopback: true)
        guard case .response(let r) = routes.handle(request) else { Issue.record("expected a response"); return }
        #expect(r.status == status)
    }

    @Test func postsNeedTheMarkerHeader() {
        let routes = RemoteRoutes(hub: RemoteHub.shared)
        let request = HTTPServer.Request(method: "POST", path: "/api/sessions/\(UUID().uuidString)/cancel", query: [:],
                                         headers: ["host": "127.0.0.1:47820"], body: Data(), peer: "127.0.0.1",
                                         peerIsLoopback: true)
        guard case .response(let r) = routes.handle(request) else { Issue.record("expected a response"); return }
        #expect(r.status == 403)
    }

    @Test func anUnknownSessionIsNotFound() {
        let routes = RemoteRoutes(hub: RemoteHub.shared)
        let request = HTTPServer.Request(method: "POST", path: "/api/sessions/\(UUID().uuidString)/cancel", query: [:],
                                         headers: ["host": "127.0.0.1:47820", "x-sandshell": "1"], body: Data(),
                                         peer: "127.0.0.1", peerIsLoopback: true)
        guard case .response(let r) = routes.handle(request) else { Issue.record("expected a response"); return }
        #expect(r.status == 404)
    }
}
