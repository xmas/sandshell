import Foundation
import Testing
@testable import Sandshell

/// `PathFixer`'s login-shell probe (Sbx/PathFixer.swift): reading PATH out of
/// what an interactive login shell prints, where the user's rc files may
/// print first.
struct PathFixerEnvProbeTests {
    private let marker = "\n\(PathFixer.envMarker)\n"

    @Test func probeOutputGivesPath() throws {
        let path = try #require(PathFixer.parseEnvProbe(marker + "/opt/homebrew/bin:/usr/bin\n"))
        #expect(path == "/opt/homebrew/bin:/usr/bin")
    }

    @Test("Whatever an rc file prints before the probe is skipped", arguments: [
        "Welcome back!\n",
        "Last login: Sat Oct 17 09:12:01 on ttys001\nfortune: be kind\n",
        "[oh-my-zsh] Would you like to update? [Y/n] ",   // a prompt with no newline
    ])
    func bannerBeforeTheProbeIsSkipped(banner: String) throws {
        let path = try #require(PathFixer.parseEnvProbe(banner + marker + "/usr/local/bin:/usr/bin\n"))
        #expect(path == "/usr/local/bin:/usr/bin", "The banner isn't taken for PATH")
    }

    @Test(.tags(.edgeCase))
    func outputAfterTheProbeIsIgnored() throws {
        let path = try #require(PathFixer.parseEnvProbe(marker + "/usr/bin\nlogged out, bye\n"))
        #expect(path == "/usr/bin")
    }

    @Test("Without the marker nothing is imported", .tags(.edgeCase), arguments: [
        "",
        "/usr/bin:/bin\n",
        "zsh: command not found: brew\n",
    ])
    func outputWithoutTheMarkerImportsNothing(raw: String) {
        #expect(PathFixer.parseEnvProbe(raw) == nil)
    }

    /// The probe through a real (non-interactive, so rc-file-free) `/bin/sh`.
    @Test(.timeLimit(.minutes(1)))
    func probeScriptPrintsWhatTheParseReads() throws {
        let proc = Process()
        proc.executableURL = URL(filePath: "/bin/sh")
        proc.arguments = ["-c", "echo 'a banner'; " + PathFixer.envProbeScript]
        proc.environment = ["PATH": "/sandshell-test/bin:/usr/bin:/bin"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let path = try #require(PathFixer.parseEnvProbe(String(decoding: data, as: UTF8.self)))
        #expect(path == "/sandshell-test/bin:/usr/bin:/bin")
    }
}
