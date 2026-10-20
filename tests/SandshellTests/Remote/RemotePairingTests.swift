import CoreImage
import Foundation
import Testing
@testable import Sandshell

/// A device store in its own defaults suite, gone after the test.
@MainActor
fileprivate final class Scratch {
    let suite = "sandshell-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let devices: RemoteDevices
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    lazy var pairing = RemotePairing(devices: devices, now: { [unowned self] in self.clock })

    init() {
        defaults = UserDefaults(suiteName: suite)!
        devices = RemoteDevices(defaults: defaults)
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }
}

@MainActor
struct RemotePairingTests {
    @Test func codesAreSixDigits() {
        for _ in 0..<50 {
            let code = RemotePairing.newCode()
            #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        }
    }

    @Test func theRightCodePairsOnce() throws {
        let s = Scratch()
        let offer = s.pairing.start()
        guard case .paired(let device, let token) = s.pairing.redeem(code: offer.code, secret: nil, name: "iPhone") else {
            Issue.record("didn't pair"); return
        }
        #expect(device.name == "iPhone")
        #expect(s.devices.device(forToken: token)?.id == device.id)
        #expect(s.pairing.offer == nil)
        #expect(s.pairing.redeem(code: offer.code, secret: nil, name: "again") == .noOffer)
    }

    @Test func aCodeTypedWithASpaceStillPairs() {
        let s = Scratch()
        let offer = s.pairing.start()
        let typed = offer.code.prefix(3) + " " + offer.code.suffix(3)
        guard case .paired = s.pairing.redeem(code: String(typed), secret: nil, name: "PC") else {
            Issue.record("didn't pair"); return
        }
    }

    @Test func theLinksSecretPairs() {
        let s = Scratch()
        let offer = s.pairing.start()
        guard case .paired = s.pairing.redeem(code: nil, secret: offer.secret, name: "Mac") else {
            Issue.record("didn't pair"); return
        }
    }

    @Test(.tags(.edgeCase)) func fiveWrongCodesEndTheOffer() {
        let s = Scratch()
        let offer = s.pairing.start()
        let wrong = offer.code == "000000" ? "111111" : "000000"
        for _ in 1..<RemotePairing.maxWrongTries {
            #expect(s.pairing.redeem(code: wrong, secret: nil, name: "x") == .wrongCode)
        }
        #expect(s.pairing.redeem(code: wrong, secret: nil, name: "x") == .locked)
        #expect(s.pairing.redeem(code: offer.code, secret: nil, name: "x") == .noOffer)
        #expect(s.devices.devices.isEmpty)
    }

    @Test(.tags(.edgeCase)) func anOfferRunsOut() {
        let s = Scratch()
        let offer = s.pairing.start()
        s.clock += RemotePairing.lifetime + 1
        #expect(s.pairing.redeem(code: offer.code, secret: nil, name: "x") == .noOffer)
    }

    @Test(.tags(.edgeCase), arguments: [nil, "", "12345"] as [String?])
    func blankOrShortAnswersDontPair(code: String?) {
        let s = Scratch()
        s.pairing.start()
        #expect(s.pairing.redeem(code: code, secret: code, name: "x") == .wrongCode)
    }

    @Test func devicesPersistOnlyTheTokensHash() throws {
        let s = Scratch()
        let (device, token) = s.devices.add(name: "  Work Mac  ")
        #expect(device.name == "Work Mac")
        let saved = String(decoding: try #require(s.defaults.data(forKey: "remoteDevices")), as: UTF8.self)
        #expect(!saved.contains(token))
        #expect(saved.contains(RemoteDevices.hash(token)))
        // Read back by a fresh store.
        #expect(RemoteDevices(defaults: s.defaults).device(forToken: token)?.id == device.id)
    }

    @Test func revokingForgetsTheToken() {
        let s = Scratch()
        let (device, token) = s.devices.add(name: "Phone")
        s.devices.revoke(device.id)
        #expect(s.devices.device(forToken: token) == nil)
        #expect(RemoteDevices(defaults: s.defaults).devices.isEmpty)
    }

    @Test func secretsAreURLSafeAndDistinct() {
        let a = RemoteDevices.newSecret(), b = RemoteDevices.newSecret()
        #expect(a != b)
        #expect(a.count >= 43 && !a.contains { "+/=".contains($0) })
    }
}

@MainActor
struct RemoteAuthTests {
    private func request(path: String = "/api/info", host: String = "127.0.0.1:47820", loopback: Bool = true,
                         headers: [String: String] = [:], method: String = "GET") -> HTTPServer.Request {
        HTTPServer.Request(method: method, path: path, query: [:], headers: headers.merging(["host": host]) { a, _ in a },
                           body: Data(), peer: loopback ? "127.0.0.1" : "10.0.0.12", peerIsLoopback: loopback)
    }

    @Test func aBrowserOnThisMacIsTrusted() {
        #expect(RemoteRoutes.isThisMac(request()))
        #expect(RemoteRoutes.isThisMac(request(host: "localhost:47820")))
    }

    @Test(arguments: [
        ["x-forwarded-for": "100.64.0.7"],
        ["tailscale-user-login": "me@example.com"],
        ["forwarded": "for=10.0.0.12"],
    ])
    func aProxyOnThisMacIsNot(headers: [String: String]) {
        #expect(!RemoteRoutes.isThisMac(request(headers: headers)))
    }

    @Test func anotherMachineIsNot() {
        #expect(!RemoteRoutes.isThisMac(request(loopback: false)))
        // Loopback, but for another name: a DNS-rebinding page, or a proxy.
        #expect(!RemoteRoutes.isThisMac(request(host: "rowan-mentor-pro.local:47820")))
    }

    @Test func aPairedDevicesCookieGetsIn() {
        let s = Scratch()
        let routes = RemoteRoutes(hub: .shared, devices: s.devices, pairing: s.pairing)
        let (device, token) = s.devices.add(name: "iPhone")
        let r = request(loopback: false, headers: ["cookie": "a=b; \(RemoteRoutes.cookieName)=\(token); c=d"])
        #expect(routes.caller(r) == .device(device.id))
        #expect(routes.caller(request(loopback: false)) == nil)
        #expect(routes.caller(request(loopback: false, headers: ["cookie": "\(RemoteRoutes.cookieName)=nope"])) == nil)
        #expect(s.devices.devices.first?.lastAddress == "10.0.0.12")
    }

    @Test func unpairedDevicesAreAskedToPair() {
        let s = Scratch()
        let routes = RemoteRoutes(hub: .shared, devices: s.devices, pairing: s.pairing)
        routes.homeNetwork = true
        guard case .response(let r) = routes.handle(request(host: "127.0.0.1:47820", loopback: false)) else {
            Issue.record("expected a response"); return
        }
        #expect(r.status == 401)
        #expect(String(decoding: r.body, as: UTF8.self).contains("\"pairing\":\"required\""))
    }

    @Test func pairingSetsTheCookie() throws {
        let s = Scratch()
        let routes = RemoteRoutes(hub: .shared, devices: s.devices, pairing: s.pairing)
        let offer = s.pairing.start()
        var r = request(path: "/api/pair", loopback: false, headers: ["x-sandshell": "1"], method: "POST")
        r = HTTPServer.Request(method: r.method, path: r.path, query: [:], headers: r.headers,
                               body: Data(#"{"code":"\#(offer.code)","name":"iPhone"}"#.utf8), peer: r.peer)
        guard case .response(let response) = routes.handle(r) else { Issue.record("expected a response"); return }
        #expect(response.status == 200)
        let cookie = try #require(response.headers["Set-Cookie"])
        #expect(cookie.hasPrefix(RemoteRoutes.cookieName + "="))
        #expect(cookie.contains("HttpOnly") && cookie.contains("SameSite=Strict") && !cookie.contains("Secure"))
        #expect(s.devices.devices.map(\.name) == ["iPhone"])
    }

    @Test(arguments: [
        ("a=1; sandshell_device=tok; b=2", "tok"),
        ("sandshell_device=", nil),
        (nil, nil),
        ("other=1", nil),
    ] as [(String?, String?)])
    func cookies(header: String?, value: String?) {
        #expect(RemoteRoutes.cookie("sandshell_device", in: header) == value)
    }
}

@MainActor
struct RemotePairingQRTests {
    @Test func theQRCodeReadsBackAsTheLink() throws {
        let link = "http://Rowan-Mentor-Pro.local:47820/pair#" + RemoteDevices.newSecret()
        let image = try #require(RemoteDevicesView.qrImage(link))
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        // Scaled up, as it's shown: the detector wants more than one pixel a module.
        let big = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let read = detector.features(in: big).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(read == [link])
    }
}

struct RemoteAddressTests {
    @Test(arguments: [
        ("127.0.0.1:47820", "127.0.0.1", 47820),
        ("[::1]:47820", "::1", 47820),
        ("Rowan-Mentor-Pro.local:47820", "rowan-mentor-pro.local", 47820),
        ("mac.tail1234.ts.net", "mac.tail1234.ts.net", nil),
        ("[fe80::1]", "fe80::1", nil),
    ] as [(String, String, UInt16?)])
    func hostHeaders(header: String, name: String, port: UInt16?) {
        let parsed = RemoteAddresses.hostName(header)
        #expect(parsed.name == name)
        #expect(parsed.port == port)
    }

    @Test(arguments: [("en0", true), ("en12", true), ("bridge100", false), ("utun3", false), ("awdl0", false),
                      ("lo0", false), ("enx", false)])
    func homeInterfaces(name: String, home: Bool) {
        #expect(RemoteAddresses.isHomeInterface(name) == home)
    }

    @Test func addressesListThisMacFirst() {
        let list = RemoteAddresses.current(port: 47820, homeNetwork: false, tailnet: ["mac.tail1.ts.net"])
        #expect(list.first?.url.absoluteString == "http://127.0.0.1:47820/")
        #expect(list.last?.url.absoluteString == "http://mac.tail1.ts.net:47820/")
        #expect(list.last?.kind == .tailnet)
        #expect(!list.contains { $0.kind == .homeNetwork })
    }
}
