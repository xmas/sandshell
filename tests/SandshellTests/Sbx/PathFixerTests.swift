import Foundation
import Testing
@testable import Sandshell

/// `PathFixer`'s login-shell probe (Sbx/PathFixer.swift): reading PATH and
/// SBX_MCP_URL out of what an interactive login shell prints, where the
/// user's rc files may print first.
struct PathFixerEnvProbeTests {
    private let marker = "\n\(PathFixer.envMarker)\n"

    @Test func extraVarsAreSBXMCPURLAlone() {
        // The parse below reads one extra line, in this order.
        #expect(PathFixer.extraEnvVars == ["SBX_MCP_URL"])
    }

    @Test func probeOutputGivesPathAndExtras() throws {
        let (path, extras) = try #require(PathFixer.parseEnvProbe(marker + "/opt/homebrew/bin:/usr/bin\nhttps://mcp.test\n"))
        #expect(path == "/opt/homebrew/bin:/usr/bin")
        #expect(extras == ["SBX_MCP_URL": "https://mcp.test"])
    }

    @Test("Whatever an rc file prints before the probe is skipped", arguments: [
        "Welcome back!\n",
        "Last login: Sat Oct 17 09:12:01 on ttys001\nfortune: be kind\n",
        "[oh-my-zsh] Would you like to update? [Y/n] ",   // a prompt with no newline
    ])
    func bannerBeforeTheProbeIsSkipped(banner: String) throws {
        let (path, extras) = try #require(PathFixer.parseEnvProbe(banner + marker + "/usr/local/bin:/usr/bin\nhttps://mcp.test\n"))
        #expect(path == "/usr/local/bin:/usr/bin", "The banner isn't taken for PATH")
        #expect(extras == ["SBX_MCP_URL": "https://mcp.test"], "PATH isn't taken for SBX_MCP_URL")
    }

    @Test(.tags(.edgeCase))
    func outputAfterTheProbeIsIgnored() throws {
        let (path, extras) = try #require(PathFixer.parseEnvProbe(marker + "/usr/bin\n\nlogged out, bye\n"))
        #expect(path == "/usr/bin")
        #expect(extras.isEmpty)
    }

    @Test("An unset or empty SBX_MCP_URL isn't imported", .tags(.edgeCase))
    func emptyExtraIsNotImported() throws {
        let (path, extras) = try #require(PathFixer.parseEnvProbe(marker + "/usr/bin\n\n"))
        #expect(path == "/usr/bin")
        #expect(extras.isEmpty)
    }

    @Test("Without the marker nothing is imported", .tags(.edgeCase), arguments: [
        "",
        "/usr/bin:/bin\nhttps://mcp.test\n",
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
        proc.environment = ["PATH": "/sandshell-test/bin:/usr/bin:/bin", "SBX_MCP_URL": "https://mcp.test"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let (path, extras) = try #require(PathFixer.parseEnvProbe(String(decoding: data, as: UTF8.self)))
        #expect(path == "/sandshell-test/bin:/usr/bin:/bin")
        #expect(extras == ["SBX_MCP_URL": "https://mcp.test"])
    }
}
