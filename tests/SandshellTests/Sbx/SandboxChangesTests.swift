import Foundation
import Testing
@testable import Sandshell

struct SandboxChangesTests {
    /// 2026-10-17 21:06:58 UTC: when the sandbox was made.
    static let baseline: Double = 1_792_271_218

    static let history = """
    Start-Date: 2026-09-23  17:55:27
    Commandline: apt-get install -yy --no-install-recommends ca-certificates curl gnupg
    Install: curl:arm64 (8.5.0-2ubuntu10.6)
    End-Date: 2026-09-23  17:55:30

    Start-Date: 2026-10-18  09:00:00
    Commandline: apt-get install -y ripgrep jq=1.7.1-3 fd-find:arm64 ./local.deb
    Install: ripgrep:arm64 (14.1.0-1)
    End-Date: 2026-10-18  09:00:05

    Start-Date: 2026-10-19  10:00:00
    Commandline: apt remove -y jq
    End-Date: 2026-10-19  10:00:01

    Start-Date: 2026-10-18  12:00:00
    Commandline: apt install postgresql-client
    End-Date: 2026-10-18  12:00:09
    """

    @Test func aptKeepsWhatWasAskedForSinceTheSandboxWasMadeAndNotRemovedSince() {
        let apt = SandboxChanges.aptRequests(history: Self.history, after: Self.baseline)
        #expect(apt.packages == ["ripgrep", "fd-find", "postgresql-client"])
        #expect(apt.notes == ["./local.deb (a local package file: not captured)"])
    }

    @Test(.tags(.edgeCase))
    func withoutABaselineEveryInstallCounts() {
        let apt = SandboxChanges.aptRequests(history: Self.history, after: nil)
        #expect(apt.packages.first == "ca-certificates")
        #expect(apt.packages.contains("postgresql-client") && !apt.packages.contains("jq"))
    }

    static func probe(_ fields: [String: Any]) -> String {
        var all: [String: Any] = ["baseline": baseline, "aptHistory": history,
                                  "installed": ["ripgrep", "postgresql-client", "curl"]]
        all.merge(fields) { $1 }
        return String(decoding: try! JSONSerialization.data(withJSONObject: all), as: UTF8.self)
    }

    @Test func parsingKeepsOnlyPackagesStillInstalled() throws {
        let changes = try SandboxChanges.parse("Last login: …\n" + Self.probe([
            "python": [["name": "pip", "version": "25.0", "user": false],
                       ["name": "httpie", "version": "3.2.4", "user": true],
                       ["name": "Requests", "version": "2.32.3", "user": false]],
            "npm": [["name": "typescript", "version": "5.9.3", "root": true]],
            "uvTools": ["ruff"], "notes": ["/usr/local/bin/mytool"],
        ]))
        #expect(changes.aptPackages == ["postgresql-client", "ripgrep"])
        #expect(changes.python.map(\.name) == ["Requests", "httpie"])
        #expect(changes.npm.map(\.name) == ["typescript"])
        #expect(changes.uvTools == ["ruff"])
        #expect(changes.notes.contains("/usr/local/bin/mytool (added by hand: not captured)"))
        #expect(changes.summary == "2 apt packages, 2 Python packages, 1 npm package, 1 Python tool")
        #expect(!changes.isEmpty)
    }

    @Test func aProbeErrorOrNoOutputThrows() {
        #expect(throws: SbxError.self) { try SandboxChanges.parse(#"{"error":"python3 is not installed in the sandbox"}"#) }
        #expect(throws: SbxError.self) { try SandboxChanges.parse("sbx: no such sandbox") }
    }

    @Test(arguments: [("msdgc-kiro", "msdgc-kiro-env"), ("My Box_2", "my-box-2-env"), ("a--b", "a-b-env")])
    func kitNames(_ sandbox: String, _ name: String) {
        #expect(SandboxChanges.kitName(for: sandbox) == name)
    }

    @Test func theKitInstallsEachKindAgainWithTheNetworkItNeeds() {
        var changes = SandboxChanges(baseline: Self.baseline)
        changes.aptPackages = ["ripgrep", "postgresql-client"]
        changes.aptHosts = ["ports.ubuntu.com", "apt.postgresql.org"]
        changes.aptFiles = [.init(path: "/etc/apt/sources.list.d/pgdg.list", data: "ZGViIGh0dHA=")]
        changes.python = [.init(name: "httpie", version: "3.2.4", user: true)]
        changes.npm = [.init(name: "@scope/tool", version: "1.0.0", root: false)]
        changes.notes = ["./local.deb (a local package file: not captured)"]
        let spec = changes.kitSpec(name: "box-env", sandbox: "box", agent: "claude",
                                   capturedAt: Date(timeIntervalSince1970: Self.baseline))
        #expect(spec.contains("kind: mixin\nname: box-env\n"))
        #expect(spec.contains("requires:\n  agent: claude\n"))
        #expect(spec.contains("      - 'apt.postgresql.org'\n") && spec.contains("      - 'registry.npmjs.org'\n")
                && spec.contains("      - 'pypi.org'\n"))
        #expect(spec.contains("apt-get install -y --no-install-recommends ''ripgrep'' ''postgresql-client''"))
        #expect(spec.contains("printf %s ''ZGViIGh0dHA='' | base64 -d > ''/etc/apt/sources.list.d/pgdg.list''"))
        #expect(spec.contains("pip install --user --break-system-packages ''httpie==3.2.4''"))
        #expect(spec.contains("npm install -g --no-audit --no-fund ''@scope/tool@1.0.0'''\n      user: \"1000\""))
        #expect(spec.contains("#   ./local.deb (a local package file: not captured)"))
        // The sources go in before apt-get update reads them.
        #expect(spec.range(of: "base64 -d")!.lowerBound < spec.range(of: "apt-get update")!.lowerBound)
    }

    @Test(.tags(.edgeCase))
    func nothingAddedStillMakesAValidKit() {
        let spec = SandboxChanges().kitSpec(name: "box-env", sandbox: "box", agent: "shell")
        #expect(spec.contains("setup:\n  install:\n    - command: 'true'"))
        #expect(!spec.contains("permissions:"))
    }
}
