import Foundation
import Testing
@testable import Sandshell

/// The berg kit (`kits/berg`, `BergHub`): the hub a sandbox reaches, the
/// arguments and sign-in secret sbx gets, and the kit known by its name
/// however sbx spells it.
struct BergKitTests {
    /// One on this Mac: the sandbox connects to host.docker.internal, which
    /// sbx's proxy (its rules, its secrets) calls localhost.
    @Test(arguments: [
        ("http://localhost:8180", "http://host.docker.internal:8180", "localhost", "localhost:8180"),
        ("http://127.0.0.1:8180/", "http://host.docker.internal:8180", "localhost", "localhost:8180"),
        ("https://localhost", "https://host.docker.internal", "localhost", "localhost:443"),
        ("https://hub.ezdata.xyz", "https://hub.ezdata.xyz", "hub.ezdata.xyz", "hub.ezdata.xyz"),
        ("https://Hub.Example.com/work?x=1", "https://hub.example.com", "hub.example.com", "hub.example.com"),
    ])
    func aHubAsTheSandboxReachesIt(hubURL: String, url: String, host: String, allow: String) throws {
        let hub = try #require(BergHub(hubURL: hubURL))
        #expect(hub.url == url)
        #expect(hub.host == host)
        #expect(hub.allow == allow)
    }

    @Test(arguments: ["", "hub.example.com", "ftp://hub.example.com", "https://"])
    func notAHub(hubURL: String) {
        #expect(BergHub(hubURL: hubURL) == nil)
    }

    /// Only the hub's address is read; the token in the same file isn't kept.
    @Test func theMacsBergConfigGivesTheHub() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sandshell-berg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appending(path: "config.json")
        try Data(#"{"hubURL": "http://localhost:8180", "token": "berg_not-a-real-token", "email": "a@b.c"}"#.utf8).write(to: config)
        let hub = try #require(BergHub.current(config: config))
        #expect(hub == BergHub(hubURL: "http://localhost:8180"))
        #expect(!String(describing: hub).contains("berg_not"))
        #expect(BergHub.current(config: dir.appending(path: "missing.json")) == nil, "Not signed in: no hub")
    }

    @Test func sbxReadsTheTokenItselfOnTheMac() throws {
        let hub = try #require(BergHub(hubURL: "https://hub.example.com"))
        let args = hub.secretArguments(config: URL(filePath: "/Users/someone/Library/Application Support/berg/config.json"))
        #expect(args.prefix(2) == ["secret", "set-custom"])
        #expect(args.contains("BERG_TOKEN"))
        #expect(args.contains("hub.example.com"))
        let command = try #require(args.last)
        #expect(command == "/usr/bin/plutil -extract token raw -o - '/Users/someone/Library/Application Support/berg/config.json'")
        #expect(!args.contains("--value"), "Never the token itself on a command line")
        #expect(!args.contains("--name"), "Cloud-only: sbx refuses it for a local secret")
    }

    @Test func aQuoteInThePathStaysQuoted() throws {
        let hub = try #require(BergHub(hubURL: "https://hub.example.com"))
        let command = try #require(hub.secretArguments(config: URL(filePath: "/tmp/o'brien/config.json")).last)
        #expect(command.hasSuffix(#"'/tmp/o'\''brien/config.json'"#))
    }

    @Test func onlyTheBergKitTakesTheHub() throws {
        let hub = try #require(BergHub(hubURL: "https://hub.example.com"))
        #expect(KitStore.kitArguments(for: ["docker.io/sbx/github-ssh:latest"], hub: hub).isEmpty)
        #expect(KitStore.kitArguments(for: ["berg"], hub: hub)
                == ["--kit-arg", "berg.hub=https://hub.example.com", "--kit-arg", "berg.hubHost=hub.example.com"])
        #expect(KitStore.kitArguments(for: ["berg"], hub: nil).isEmpty, "berg not signed in here: the kit's defaults")
    }

    @Test(arguments: ["berg", "/Applications/Sandshell.app/Contents/Resources/kits/berg",
                      "/Applications/Sandshell.app/Contents/Resources/kits/berg/", "ghcr.io/xmas/berg:0.2.48",
                      "ghcr.io/xmas/berg@sha256:abc"])
    func theKitByAnyOfItsNames(ref: String) {
        #expect(KitStore.bundledKitName(ref) == "berg")
        #expect(KitDrift.normalize(ref, root: URL(filePath: "/tmp")) == "berg", "Not drift")
    }

    @Test func otherKitsAreNotIt() {
        #expect(KitStore.bundledKitName("docker.io/sbx/berg:latest") == nil)
        #expect(KitStore.bundledKitName("/tmp/kits/bergx") == nil)
    }

    @Test func itsForAnyAgent() {
        #expect(KitStore.requiredAgent("berg") == .some(nil))
    }

    /// The kit browser reads a spec's name and summary without a YAML parser.
    @Test func theKitsSpecReads() throws {
        let spec = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "kits/berg/spec.yaml")
        let summary = KitHub.specSummary(try String(contentsOf: spec, encoding: .utf8))
        #expect(summary.displayName == "berg")
        #expect(summary.description.hasPrefix("berg (Iceberg's CLI) and bd"))
        #expect(!summary.description.contains("\n"))
    }

    @Test(arguments: [("displayName: \"Quoted\"\ndescription: 'Single'", "Quoted", "Single"),
                      ("description: plain words\ndisplayName: Plain", "Plain", "plain words")])
    func specValues(yaml: String, name: String, description: String) {
        let summary = KitHub.specSummary(yaml)
        #expect(summary.displayName == name)
        #expect(summary.description == description)
    }
}
