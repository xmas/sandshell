import Foundation
import Testing
@testable import Sandshell

fileprivate extension Tag {
    /// Inputs at the edges of what `SbxCommand` handles: shell metacharacters,
    /// empty values, half-set options, unusual names.
    @Tag static var sbxCommandEdgeCase: Self
}

/// `SbxCommand` builds the shell text and argv that put a session's agent in
/// its sandbox. The terminal tests read `launchCommand`'s output back the way
/// `/bin/sh` would (`Shell.words`), so they check the argv and `bash -c` body
/// that actually run rather than string fragments.
///
/// Two inputs come from the host and aren't injectable: `LANG` (read, never
/// set, via `Expected.lang`) and the opt-in `inferenceGatewayURL` default.
/// The gateway is detected from the command's own output (`HostDefaults`), so
/// these tests never read or write defaults; env comparisons ignore its pairs
/// and the few tests whose result it changes are enabled or disabled by it.
struct SbxCommandTests {
    typealias Options = SbxCommand.ClaudeOptions
    typealias ProcessTag = SbxCommand.ProcessTag

    // MARK: - shellQuote

    struct ShellQuoting {
        @Test(arguments: ["abc", "ABC123", "/opt/homebrew/bin/sbx", "claude-opus-4-5", "a_b.c",
                          "user@host:/path", "K=V,W+X", "--resume", "café", "日本語"])
        func safeTokensAreLeftBare(token: String) {
            #expect(SbxCommand.shellQuote(token) == token)
        }

        @Test(.tags(.sbxCommandEdgeCase), arguments: [
            ("", "''"),
            ("a b", "'a b'"),
            ("it's", #"'it'\''s'"#),
            ("'", #"''\'''"#),
            ("$HOME", "'$HOME'"),
            ("~/x", "'~/x'"),
            ("a;b", "'a;b'"),
            ("a&b|c", "'a&b|c'"),
            ("*", "'*'"),
            ("a?b", "'a?b'"),
            ("#comment", "'#comment'"),
            ("`id`", "'`id`'"),
            ("(x)", "'(x)'"),
            ("!", "'!'"),
            (#"back\slash"#, #"'back\slash'"#),
            (#"{"k":1}"#, #"'{"k":1}'"#),
            ("line1\nline2", "'line1\nline2'"),
            ("tab\there", "'tab\there'"),
            ("🙂", "'🙂'"),
        ] as [(String, String)])
        func unsafeTokensAreSingleQuoted(token: String, expected: String) {
            #expect(SbxCommand.shellQuote(token) == expected)
        }

        @Test(.tags(.sbxCommandEdgeCase), arguments: [
            "", "plain", "a b", "it's", "''", #"'\''"#, "$(rm -rf ~)", "line1\nline2",
            " leading", "trailing ", "日本 語", "🙂'🙂",
        ])
        func quotedTokensReadBackAsOneWord(token: String) {
            #expect(Shell.words(SbxCommand.shellQuote(token)) == [token],
                    "the shell should see exactly the original token")
        }

        /// A quote that a combining mark, variation selector or joiner makes
        /// one Character with what follows is still a quote to the shell.
        @Test(.tags(.sbxCommandEdgeCase), arguments: [
            "'\u{301}x", "x'\u{301}; rm -rf ~; '", "a'\u{FE0F}b", "'\u{200D}x", "it'\u{301}s 'ok'",
        ])
        func quotesJoinedToTheNextCharacterAreEscaped(token: String) {
            #expect(Shell.words(SbxCommand.shellQuote(token)) == [token],
                    "an unescaped quote would end the quoting early")
        }
    }

    // MARK: - ProcessTag

    struct ProcessTags {
        @Test func pairsNameTheSessionAndThisLaunch() {
            let session = UUID()
            let tag = ProcessTag(session: session)
            #expect(tag.pairs == ["SANDSHELL_SESSION=\(session.uuidString)",
                                  "SANDSHELL_LAUNCH=\(tag.launch.uuidString)"])
        }

        @Test func eachTagIsANewLaunchOfTheSameSession() {
            let session = UUID()
            let first = ProcessTag(session: session)
            let second = ProcessTag(session: session)
            #expect(first.launch != second.launch, "every launch gets its own id")
            #expect(first.pairs[0] == second.pairs[0], "the session tag stays the same")
        }
    }

    // MARK: - reapScript

    struct ReapScripts {
        @Test func gracefulReapTermsThenKillsOnlyWhatItTermed() {
            let match = "SANDSHELL_LAUNCH=\(UUID().uuidString)"
            #expect(SbxCommand.reapScript(match: match)
                    == "M=\(match); f=; " + Expected.reapScan("TERM", then: " && f=1")
                    + #"; [ -z "$f" ] || { sleep 1; "# + Expected.reapScan("KILL") + "; }; true")
        }

        @Test func immediateReapKillsAtOnce() {
            let match = "SANDSHELL_SESSION=\(UUID().uuidString)"
            #expect(SbxCommand.reapScript(match: match, immediate: true)
                    == "M=\(match); " + Expected.reapScan("KILL") + "; true")
        }

        @Test(.tags(.sbxCommandEdgeCase), arguments: [false, true])
        func matchIsShellQuoted(immediate: Bool) {
            let script = SbxCommand.reapScript(match: "A B'C", immediate: immediate)
            #expect(script.hasPrefix(#"M='A B'\''C'; "#))
        }

        @Test(.tags(.sbxCommandEdgeCase), arguments: [false, true])
        func signalPlaceholderNeverRewritesTheMatch(immediate: Bool) {
            let script = SbxCommand.reapScript(match: "SIGNAL=SIGHUP", immediate: immediate)
            #expect(script.hasPrefix("M=SIGNAL=SIGHUP; "), "only the scan's -SIG placeholder becomes TERM/KILL")
        }
    }

    // MARK: - Proxy auth, run

    /// The proxy-auth line as `/bin/sh` runs it, against a credentials file in
    /// a temporary home: what claude gets in its environment.
    struct ProxyAuthRun {
        static let placeholder = #"{"claudeAiOauth":{"accessToken":"sk-placeholder","refreshToken":"rt-placeholder","expiresAt":1792549819937,"#

        /// `CLAUDE_CODE_OAUTH_TOKEN` and `CLAUDE_CODE_OAUTH_SCOPES` after the line runs with `credentials` (nil: no file).
        static func run(credentials: String?) throws -> (token: String, scopes: String) {
            let home = FileManager.default.temporaryDirectory.appending(path: "sandshell-proxyauth-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: home) }
            try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
            if let credentials { try credentials.write(to: home.appending(path: ".claude/.credentials.json"), atomically: true, encoding: .utf8) }
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", SbxCommand.proxyAuthSetup + #" printf '%s\n%s' "$CLAUDE_CODE_OAUTH_TOKEN" "$CLAUDE_CODE_OAUTH_SCOPES""#]
            process.environment = ["HOME": home.path(percentEncoded: false), "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return (lines.first ?? "", lines.count > 1 ? lines[1] : "")
        }

        @Test("The token comes with the scopes its file lists — claude.ai connectors need user:mcp_servers")
        func scopesFromTheFile() throws {
            let result = try Self.run(credentials: Self.placeholder
                + #""scopes":["user:file_upload","user:inference","user:mcp_servers","user:profile","user:sessions:claude_code"]}}"#)
            #expect(result.token == "sk-placeholder")
            #expect(result.scopes == "user:file_upload user:inference user:mcp_servers user:profile user:sessions:claude_code")
        }

        @Test("A file that lists no scopes gets Claude Code's usual set, not inference alone")
        func defaultScopes() throws {
            let result = try Self.run(credentials: Self.placeholder + #""scopes":[]}}"#)
            #expect(result.token == "sk-placeholder")
            #expect(result.scopes == SbxCommand.defaultOAuthScopes)
            #expect(result.scopes.contains("user:mcp_servers"))
        }

        @Test("No credentials file: neither is set")
        func noFile() throws {
            let result = try Self.run(credentials: nil)
            #expect(result.token.isEmpty && result.scopes.isEmpty)
        }
    }

    // MARK: - launchCommand / sessionScript (terminal sessions)

    struct TerminalLaunch {
        let home = Fixture.missingHome()

        @Test(.disabled(if: HostDefaults.inferenceGatewayConfigured, "the host app's inference gateway adds env pairs"))
        func shellCommandLineIsExact() {
            let command = SbxCommand.launchCommand(containerName: "proj-shell", workdir: "/Users/me/proj", agent: .shell,
                                                   sbxPath: "/opt/homebrew/bin/sbx", home: home, mcpURL: nil)
            let env = Expected.baseEnv(home: home).map(SbxCommand.shellQuote).joined(separator: " ")
            #expect(command == "/opt/homebrew/bin/sbx exec -it -w /Users/me/proj proj-shell env -u MCP_GATEWAY_URL \(env) bash -c '\(Expected.pathSetup) exec bash'")
        }

        @Test func headRunsSbxExecWithATTYInTheWorkdir() throws {
            let launch = try Fixture.terminal(agent: .shell, home: home)
            #expect(launch.head == [Fixture.sbxPath, "exec", "-it", "-w", Fixture.workdir, Fixture.container])
        }

        @Test(.tags(.sbxCommandEdgeCase))
        func emptyWorkdirOmitsTheFlag() throws {
            let launch = try Fixture.terminal(agent: .shell, home: home, workdir: "")
            #expect(launch.head == [Fixture.sbxPath, "exec", "-it", Fixture.container],
                    "no workdir means no `-w`, so sbx uses the container's default")
        }

        @Test(.tags(.sbxCommandEdgeCase))
        func pathsWithSpacesAreQuoted() throws {
            let command = SbxCommand.launchCommand(containerName: "my proj", workdir: "/Users/me/My Project", agent: .shell,
                                                   sbxPath: "/Applications/My Tools/sbx", home: home, mcpURL: nil)
            #expect(command.hasPrefix("'/Applications/My Tools/sbx' exec -it -w '/Users/me/My Project' 'my proj' env -u MCP_GATEWAY_URL "))
            let launch = try Invocation(Shell.words(command))
            #expect(launch.head == ["/Applications/My Tools/sbx", "exec", "-it", "-w", "/Users/me/My Project", "my proj"])
        }

        // MARK: env

        @Test func envCarriesTerminalLocaleToolchainAndHostClaudeConfig() throws {
            let launch = try Fixture.terminal(agent: .shell, home: home)
            #expect(launch.envIgnoringGateway == Expected.baseEnv(home: home))
        }

        @Test func localeIsAlwaysUTF8() throws {
            let launch = try Fixture.terminal(agent: .shell, home: home)
            let pair = try #require(launch.env.first(where: { $0.hasPrefix("LANG=") }))
            let lang = pair.dropFirst("LANG=".count)
            #expect(lang.uppercased().contains("UTF-8"), "\(pair) wouldn't render UTF-8 / box-drawing glyphs")
        }

        @Test func codexHomeFollowsTheHostsCodexDir() throws {
            try Fixture.withCodexHome { codexHome in
                let launch = try Fixture.terminal(agent: .codex, home: codexHome)
                #expect(launch.envIgnoringGateway == Expected.baseEnv(home: codexHome) + ["CODEX_HOME=\(codexHome)/.codex"])
            }
        }

        @Test func missingHostCodexDirKeepsTheSandboxCodexHome() throws {
            let launch = try Fixture.terminal(agent: .codex, home: home)
            #expect(launch.env.contains(where: { $0.hasPrefix("CODEX_HOME=") }) == false,
                    "an unmounted ~/.codex mustn't replace sbx's own CODEX_HOME")
        }

        @Test func mcpGatewayURLIsForwarded() throws {
            let mcp = try #require(URL(string: "http://host.docker.internal:8811/mcp"))
            let launch = try Fixture.terminal(agent: .claude, home: home, mcpURL: mcp)
            #expect(launch.envIgnoringGateway == Expected.baseEnv(home: home) + ["SBX_MCP_URL=http://host.docker.internal:8811/mcp"])
        }

        @Test(.tags(.sbxCommandEdgeCase))
        func envPairsAreShellQuotedOnTheCommandLine() throws {
            let mcp = try #require(URL(string: "http://host.docker.internal:8811/mcp?token=a&b=c"))
            let command = Fixture.terminalCommand(agent: .claude, home: home, mcpURL: mcp)
            #expect(command.contains(" 'SBX_MCP_URL=http://host.docker.internal:8811/mcp?token=a&b=c' "))
        }

        @Test func statusFeedEnvNamesTheDirAndSession() throws {
            let options = Options(statusDir: "/ws/.sandshell/status", sessionID: "5F0C6B1E")
            let launch = try Fixture.terminal(agent: .claude, home: home, claude: options)
            #expect(launch.envIgnoringGateway == Expected.baseEnv(home: home)
                    + ["SANDSHELL_STATUS_DIR=/ws/.sandshell/status", "SANDSHELL_SESSION_ID=5F0C6B1E"])
        }

        @Test(.tags(.sbxCommandEdgeCase),
              arguments: [("/ws/.sandshell/status", nil), (nil, "5F0C6B1E"), (nil, nil)] as [(String?, String?)])
        func statusFeedEnvNeedsBothDirAndSession(statusDir: String?, sessionID: String?) throws {
            let launch = try Fixture.terminal(agent: .claude, home: home,
                                              claude: Options(statusDir: statusDir, sessionID: sessionID))
            #expect(launch.env.contains(where: { $0.hasPrefix("SANDSHELL_STATUS_DIR=") || $0.hasPrefix("SANDSHELL_SESSION_ID=") }) == false,
                    "the status feed's env is all or nothing")
        }

        @Test func everyOptionalPairAppearsInOrderWithTheProcessTagLast() throws {
            try Fixture.withCodexHome { codexHome in
                let mcp = try #require(URL(string: "http://host.docker.internal:8811/mcp"))
                let tag = ProcessTag(session: UUID())
                let options = Options(statusDir: "/ws/.sandshell/status", sessionID: "S1")
                let launch = try Fixture.terminal(agent: .claude, home: codexHome, mcpURL: mcp, claude: options, tag: tag)
                #expect(launch.envIgnoringGateway == Expected.baseEnv(home: codexHome) + [
                    "CODEX_HOME=\(codexHome)/.codex",
                    "SBX_MCP_URL=http://host.docker.internal:8811/mcp",
                    "SANDSHELL_STATUS_DIR=/ws/.sandshell/status",
                    "SANDSHELL_SESSION_ID=S1",
                ] + tag.pairs, "base, CODEX_HOME, MCP, status feed, then the process tag")
            }
        }

        // MARK: program

        @Test(arguments: [nil, "5f0c6b1e-2d3a-4c5b-8e9f-0a1b2c3d4e5f"] as [String?])
        func shellRunsBashAfterPathSetup(resumeID: String?) throws {
            let launch = try Fixture.terminal(agent: .shell, home: home, resumeID: resumeID)
            #expect(launch.body == Expected.pathSetup + " exec bash", "a shell runs plain bash and has nothing to resume")
        }

        @Test(.tags(.sbxCommandEdgeCase), arguments: [nil, Options(), Options(model: "", effort: "")] as [Options?])
        func claudeRunsPlainWithoutOptions(options: Options?) throws {
            let launch = try Fixture.terminal(agent: .claude, home: home, claude: options)
            #expect(launch.body == Expected.pathSetup + " exec claude", "no options, or an empty model and effort, add no flags")
        }

        @Test func claudeFlagsComeInResumeModelEffortSettingsOrder() throws {
            let options = Options(model: "claude-opus-4-5", effort: "high", statusScriptPath: "/ws/.sandshell/status/feed.sh")
            let launch = try Fixture.terminal(agent: .claude, home: home,
                                              resumeID: "5f0c6b1e-2d3a-4c5b-8e9f-0a1b2c3d4e5f", claude: options)
            #expect(launch.body == Expected.pathSetup + #" exec claude --resume 5f0c6b1e-2d3a-4c5b-8e9f-0a1b2c3d4e5f --model claude-opus-4-5 --effort high --settings '{"statusLine":{"type":"command","command":"/ws/.sandshell/status/feed.sh"}}'"#)
        }

        @Test(.tags(.sbxCommandEdgeCase))
        func claudeArgumentsAreQuotedInsideTheBashBody() throws {
            let command = Fixture.terminalCommand(agent: .claude, home: home, resumeID: "it's", claude: Options(model: "opus[1m]"))
            #expect(command.contains(#"--model '\''opus[1m]'\''"#), "the body's own quotes are escaped for the outer shell")
            let launch = try Invocation(Shell.words(command))
            #expect(launch.body == Expected.pathSetup + #" exec claude --resume 'it'\''s' --model 'opus[1m]'"#)
        }

        @Test(arguments: [
            (nil, "codex"),
            ("0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", "codex resume 0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"),
            ("it's", #"codex resume 'it'\''s'"#),
        ] as [(String?, String)])
        func codexStartsFreshOrResumesByID(resumeID: String?, program: String) throws {
            let launch = try Fixture.terminal(agent: .codex, home: home, resumeID: resumeID)
            #expect(launch.body == Expected.pathSetup + " exec " + program)
        }

        @Test(arguments: [(.shell, "bash"), (.codex, "codex"), (.gemini, "gemini")] as [(AgentKind, String)])
        func claudeOptionsAndProxyAuthOnlyAffectClaude(agent: AgentKind, program: String) throws {
            let options = Options(model: "claude-opus-4-5", effort: "high", statusScriptPath: "/ws/feed.sh", sbxProxyAuth: true)
            let launch = try Fixture.terminal(agent: agent, home: home, claude: options)
            #expect(launch.body == Expected.pathSetup + " exec " + program,
                    "model, effort, status feed and proxy auth are Claude-only")
        }

        @Test(arguments: [AgentKind.copilot, .cursor, .devin, .dockerAgent, .droid, .gemini, .kiro, .opencode])
        func otherBuiltinsRunTheirOwnCommand(agent: AgentKind) throws {
            let launch = try Fixture.terminal(agent: agent, home: home)
            #expect(launch.body == Expected.pathSetup + " exec \(agent.rawValue)")
        }

        @Test func unregisteredCustomAgentRunsItsName() throws {
            let agent = AgentKind(rawValue: "sandshell-test-\(UUID().uuidString.lowercased())")
            let launch = try Fixture.terminal(agent: agent, home: home)
            #expect(launch.body == Expected.pathSetup + " exec " + agent.rawValue)
        }

        @Test(.tags(.sbxCommandEdgeCase), arguments: ["kit agent ", "kit;agent$(x)-", "it's-"])
        func unregisteredCustomAgentNameIsShellQuoted(prefix: String) throws {
            let agent = AgentKind(rawValue: prefix + UUID().uuidString)
            let launch = try Fixture.terminal(agent: agent, home: home)
            #expect(launch.body == Expected.pathSetup + " exec " + SbxCommand.shellQuote(agent.rawValue),
                    "bash -c mustn't split or interpret the id")
        }

        // MARK: proxy auth & inference gateway

        @Test func proxyAuthIsOptIn() throws {
            #expect(Options().sbxProxyAuth == false, "proxy auth should be off by default")
            let launch = try Fixture.terminal(agent: .claude, home: home, claude: Options())
            #expect(launch.body.contains("CLAUDE_CODE_OAUTH_TOKEN") == false, "claude shouldn't get the placeholder token unasked")
        }

        @Test(.disabled(if: HostDefaults.inferenceGatewayConfigured, "the inference gateway brings its own auth"))
        func proxyAuthHandsClaudeThePlaceholderToken() throws {
            let launch = try Fixture.terminal(agent: .claude, home: home, claude: Options(sbxProxyAuth: true))
            #expect(launch.body == Expected.pathSetup + " " + Expected.proxyAuth + " exec claude")
        }

        @Test(.enabled(if: HostDefaults.inferenceGatewayConfigured, "needs inferenceGatewayURL in the host app's defaults"))
        func inferenceGatewayRoutesClaudeInsteadOfProxyAuth() throws {
            let mcp = try #require(URL(string: "http://host.docker.internal:8811/mcp"))
            let tag = ProcessTag(session: UUID())
            let launch = try Fixture.terminal(agent: .claude, home: home, mcpURL: mcp, claude: Options(sbxProxyAuth: true), tag: tag)
            #expect(launch.body == Expected.pathSetup + " exec claude", "the gateway brings its own auth")
            let gateway = try #require(launch.env.firstIndex(where: { $0.hasPrefix("ANTHROPIC_BASE_URL=") }))
            let mcpIndex = try #require(launch.env.firstIndex(of: "SBX_MCP_URL=http://host.docker.internal:8811/mcp"))
            #expect(launch.env.dropFirst(gateway + 1).first == "ANTHROPIC_AUTH_TOKEN=sandshell-inference-gateway")
            #expect(mcpIndex < gateway)
            #expect(Array(launch.env.suffix(2)) == tag.pairs)
        }

        // MARK: sessionScript

        @Test func sessionScriptExecsTheLaunchCommand() {
            let tag = ProcessTag(session: UUID())
            let options = Options(model: "claude-opus-4-5", sbxProxyAuth: true)
            let script = SbxCommand.sessionScript(containerName: Fixture.container, workdir: Fixture.workdir, agent: .claude,
                                                  sbxPath: Fixture.sbxPath, home: home, mcpURL: nil,
                                                  resumeID: "abc", claude: options, tag: tag)
            let command = SbxCommand.launchCommand(containerName: Fixture.container, workdir: Fixture.workdir, agent: .claude,
                                                   sbxPath: Fixture.sbxPath, home: home, mcpURL: nil,
                                                   resumeID: "abc", claude: options, tag: tag)
            #expect(script == "#!/bin/sh\nexec " + command + "\n", "the script should exec exactly the launch command")
        }
    }

    // MARK: - acpArguments (chat sessions)

    struct ChatLaunch {
        let home = Fixture.missingHome()

        @Test func acpAgentsAreClaudeCodexAndGemini() {
            #expect(SbxCommand.acpAgents == [.claude, .codex, .gemini])
        }

        @Test(arguments: [AgentKind.claude, .codex, .gemini])
        func acpAgentsGetAChatLaunch(agent: AgentKind) {
            #expect(SbxCommand.supportsACP(agent))
            #expect(Fixture.chat(agent: agent, home: home) != nil)
        }

        @Test(arguments: [AgentKind.shell, .copilot, .cursor, .devin, .dockerAgent, .droid, .kiro, .opencode,
                          AgentKind(rawValue: "my-kit-agent")])
        func otherAgentsHaveNoChatLaunch(agent: AgentKind) {
            #expect(SbxCommand.supportsACP(agent) == false)
            #expect(Fixture.chat(agent: agent, home: home) == nil, "\(agent.rawValue) has no ACP entry point")
        }

        @Test func agentDefaultsToClaude() throws {
            let implicit = try #require(SbxCommand.acpArguments(containerName: Fixture.container, workdir: Fixture.workdir,
                                                                home: home, mcpURL: nil))
            let explicit = SbxCommand.acpArguments(agent: .claude, containerName: Fixture.container, workdir: Fixture.workdir,
                                                   home: home, mcpURL: nil)
            #expect(implicit == explicit, "acpArguments without an agent should launch a Claude chat")
        }

        @Test func headRunsSbxExecOnPlainStdioInTheWorkdir() throws {
            let chat = try Fixture.parsedChat(agent: .claude, home: home)
            #expect(chat.head == ["exec", "-i", "-w", Fixture.workdir, Fixture.container])
        }

        @Test(.tags(.sbxCommandEdgeCase))
        func emptyWorkdirOmitsTheFlag() throws {
            let chat = try Fixture.parsedChat(agent: .gemini, home: home, workdir: "")
            #expect(chat.head == ["exec", "-i", Fixture.container])
        }

        @Test(.tags(.sbxCommandEdgeCase))
        func argvIsPassedUnquoted() throws {
            let args = try #require(SbxCommand.acpArguments(agent: .gemini, containerName: "my proj",
                                                            workdir: "/Users/me/My Project", home: home, mcpURL: nil))
            let chat = try Invocation(args)
            #expect(chat.head == ["exec", "-i", "-w", "/Users/me/My Project", "my proj"])
        }

        // MARK: env

        @Test func envMatchesTerminalsPlusTheClaudeModel() throws {
            let mcp = try #require(URL(string: "http://host.docker.internal:8811/mcp"))
            let tag = ProcessTag(session: UUID())
            let chat = try Fixture.parsedChat(agent: .claude, home: home, mcpURL: mcp, tag: tag, claudeModel: "claude-opus-4-5")
            #expect(chat.envIgnoringGateway == Expected.baseEnv(home: home)
                    + ["SBX_MCP_URL=http://host.docker.internal:8811/mcp"]
                    + tag.pairs
                    + ["ANTHROPIC_MODEL=claude-opus-4-5", "ANTHROPIC_CUSTOM_MODEL_OPTION=claude-opus-4-5"])
        }

        @Test(.tags(.sbxCommandEdgeCase), arguments: [nil, ""] as [String?])
        func missingClaudeModelAddsNoModelEnv(model: String?) throws {
            let chat = try Fixture.parsedChat(agent: .claude, home: home, claudeModel: model)
            #expect(chat.envIgnoringGateway == Expected.baseEnv(home: home))
        }

        @Test(arguments: [AgentKind.codex, .gemini])
        func claudeModelOnlyAppliesToClaude(agent: AgentKind) throws {
            let chat = try Fixture.parsedChat(agent: agent, home: home, claudeModel: "claude-opus-4-5")
            #expect(chat.env.contains(where: { $0.hasPrefix("ANTHROPIC_MODEL=") || $0.hasPrefix("ANTHROPIC_CUSTOM_MODEL_OPTION=") }) == false,
                    "the workspace's Claude model mustn't reach a \(agent.rawValue) chat")
        }

        @Test(.tags(.sbxCommandEdgeCase))
        func envPairsAreNotShellQuoted() throws {
            let mcp = try #require(URL(string: "http://host.docker.internal:8811/mcp?token=a&b=c"))
            let chat = try Fixture.parsedChat(agent: .claude, home: home, mcpURL: mcp, claudeModel: "claude opus")
            #expect(chat.env.contains("SBX_MCP_URL=http://host.docker.internal:8811/mcp?token=a&b=c"))
            #expect(chat.env.contains("ANTHROPIC_MODEL=claude opus"))
        }

        @Test func codexHomeFollowsTheHostsCodexDir() throws {
            try Fixture.withCodexHome { codexHome in
                let chat = try Fixture.parsedChat(agent: .codex, home: codexHome)
                #expect(chat.envIgnoringGateway == Expected.baseEnv(home: codexHome) + ["CODEX_HOME=\(codexHome)/.codex"])
            }
        }

        // MARK: program

        @Test(arguments: [AgentKind.claude, .codex, .gemini])
        func launchMarkerIsTheFirstThingSaid(agent: AgentKind) throws {
            let chat = try Fixture.parsedChat(agent: agent, home: home)
            #expect(chat.body.hasPrefix(Expected.launchEcho + Expected.pathSetup + " "))
        }

        /// Claude and Codex run their pinned npm adapters (Claude's through the
        /// sandshell-claude kit's wrapper when it's there); Gemini speaks ACP itself.
        @Test(arguments: [AgentKind.claude, .codex, .gemini])
        func eachAgentRunsItsOwnACPEntryPoint(agent: AgentKind) throws {
            let chat = try Fixture.parsedChat(agent: agent, home: home)
            let program = try #require(Expected.acpProgram[agent], "no expected ACP program for \(agent.rawValue)")
            #expect(chat.body == Expected.launchEcho + Expected.pathSetup + " " + program)
        }

        @Test(.disabled(if: HostDefaults.inferenceGatewayConfigured, "the inference gateway brings its own auth"))
        func proxyAuthPrecedesTheClaudeAdapter() throws {
            let chat = try Fixture.parsedChat(agent: .claude, home: home, sbxProxyAuth: true)
            #expect(chat.body == Expected.launchEcho + Expected.pathSetup + " " + Expected.proxyAuth + " " + Expected.claudeACP)
        }

        @Test(arguments: [AgentKind.codex, .gemini])
        func proxyAuthOnlyAppliesToClaude(agent: AgentKind) throws {
            let requested = try Fixture.parsedChat(agent: agent, home: home, sbxProxyAuth: true)
            let plain = try Fixture.parsedChat(agent: agent, home: home, sbxProxyAuth: false)
            #expect(requested.body == plain.body, "Claude's proxy auth mustn't change a \(agent.rawValue) chat")
        }

        @Test(.enabled(if: HostDefaults.inferenceGatewayConfigured, "needs inferenceGatewayURL in the host app's defaults"))
        func inferenceGatewayReplacesProxyAuthInChats() throws {
            let chat = try Fixture.parsedChat(agent: .claude, home: home, sbxProxyAuth: true)
            #expect(chat.body == Expected.launchEcho + Expected.pathSetup + " " + Expected.claudeACP)
            #expect(chat.env.contains("ANTHROPIC_AUTH_TOKEN=sandshell-inference-gateway"))
        }
    }

    // MARK: - Adapters, markers, bundled kits

    struct Adapters {
        @Test(arguments: [SbxCommand.claudeACPVersion, SbxCommand.codexACPVersion])
        func versionsArePinnedExactly(version: String) {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            #expect(parts.count == 3, "\(version) should be major.minor.patch")
            #expect(parts.allSatisfy({ Int($0) != nil }), "\(version) should be a pinned version, not a range or tag")
        }

        @Test func packagesNameTheirPinnedVersions() {
            #expect(SbxCommand.claudeACPPackage == "@agentclientprotocol/claude-agent-acp@\(SbxCommand.claudeACPVersion)")
            #expect(SbxCommand.codexACPPackage == "@agentclientprotocol/codex-acp@\(SbxCommand.codexACPVersion)")
        }

        @Test func markersAreDistinct() {
            let markers = [SbxCommand.launchMarker, SbxCommand.installingMarker, SbxCommand.extrasMarker]
            #expect(Set(markers).count == markers.count, "the chat tells these stderr lines apart")
        }

        @Test(.tags(.sbxCommandEdgeCase),
              arguments: [SbxCommand.launchMarker, SbxCommand.installingMarker, SbxCommand.extrasMarker])
        func markersAreSafeInsideDoubleQuotes(marker: String) {
            #expect(marker.isEmpty == false)
            #expect(marker.contains(where: { "\"$`\\\n".contains($0) }) == false,
                    "the scripts echo \(marker) inside double quotes")
        }

        @Test(arguments: ["sandshell-claude", "sandshell-codex"])
        func bundledKitsShipSandshellsOwnKits(kit: String) throws {
            let kits = try #require(SbxCommand.bundledKits, "the app bundle should carry kits/")
            #expect(kits.lastPathComponent == "kits")
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: kits.appending(path: kit).path(percentEncoded: false),
                                                        isDirectory: &isDirectory)
            #expect(exists && isDirectory.boolValue, "\(kit) should be a folder in the bundled kits")
        }
    }
}

// MARK: - Helpers

extension SbxCommandTests {
    fileprivate enum Fixture {
        static let sbxPath = "/opt/homebrew/bin/sbx"
        static let container = "proj-claude"
        static let workdir = "/Users/me/proj"

        /// A home path unique to the caller under the temporary directory, never
        /// created — so the host has no `~/.codex` there and nothing needs cleaning up.
        static func missingHome() -> String {
            FileManager.default.temporaryDirectory
                .appending(path: "SbxCommandTests-\(UUID().uuidString)", directoryHint: .notDirectory)
                .path(percentEncoded: false)
        }

        /// Runs `body` with a fresh temporary home holding a `.codex` directory,
        /// removed afterwards.
        static func withCodexHome(_ body: (String) throws -> Void) throws {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "SbxCommandTests-\(UUID().uuidString)", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: root.appending(path: ".codex", directoryHint: .isDirectory),
                                                    withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try body(root.path(percentEncoded: false))
        }

        static func terminalCommand(agent: AgentKind, home: String, workdir: String = Fixture.workdir, mcpURL: URL? = nil,
                                    resumeID: String? = nil, claude: SbxCommand.ClaudeOptions? = nil,
                                    tag: SbxCommand.ProcessTag? = nil) -> String {
            SbxCommand.launchCommand(containerName: container, workdir: workdir, agent: agent, sbxPath: sbxPath,
                                     home: home, mcpURL: mcpURL, resumeID: resumeID, claude: claude, tag: tag)
        }

        /// `launchCommand`'s output read back into words the way `/bin/sh` would.
        static func terminal(agent: AgentKind, home: String, workdir: String = Fixture.workdir, mcpURL: URL? = nil,
                             resumeID: String? = nil, claude: SbxCommand.ClaudeOptions? = nil,
                             tag: SbxCommand.ProcessTag? = nil,
                             sourceLocation: SourceLocation = #_sourceLocation) throws -> Invocation {
            let command = terminalCommand(agent: agent, home: home, workdir: workdir, mcpURL: mcpURL,
                                          resumeID: resumeID, claude: claude, tag: tag)
            return try Invocation(Shell.words(command), sourceLocation: sourceLocation)
        }

        static func chat(agent: AgentKind, home: String, workdir: String = Fixture.workdir, mcpURL: URL? = nil,
                         sbxProxyAuth: Bool = false, tag: SbxCommand.ProcessTag? = nil,
                         claudeModel: String? = nil) -> [String]? {
            SbxCommand.acpArguments(agent: agent, containerName: container, workdir: workdir, home: home, mcpURL: mcpURL,
                                    sbxProxyAuth: sbxProxyAuth, tag: tag, claudeModel: claudeModel)
        }

        static func parsedChat(agent: AgentKind, home: String, workdir: String = Fixture.workdir, mcpURL: URL? = nil,
                               sbxProxyAuth: Bool = false, tag: SbxCommand.ProcessTag? = nil,
                               claudeModel: String? = nil,
                               sourceLocation: SourceLocation = #_sourceLocation) throws -> Invocation {
            let args = try #require(chat(agent: agent, home: home, workdir: workdir, mcpURL: mcpURL,
                                         sbxProxyAuth: sbxProxyAuth, tag: tag, claudeModel: claudeModel),
                                    "\(agent.rawValue) should have a chat launch", sourceLocation: sourceLocation)
            return try Invocation(args, sourceLocation: sourceLocation)
        }
    }

    /// An `sbx` argv split into its parts:
    /// `<head…> env -u MCP_GATEWAY_URL <pairs…> bash -c <body>`.
    fileprivate struct Invocation {
        var head: [String]
        var env: [String]
        var body: String

        init(_ argv: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
            let marker = ["env", "-u", "MCP_GATEWAY_URL"]
            let start = try #require(argv.indices.first(where: { argv[$0...].starts(with: marker) }),
                                     "no `env -u MCP_GATEWAY_URL` in \(argv)", sourceLocation: sourceLocation)
            try #require(argv.count >= start + marker.count + 3, "argv too short: \(argv)", sourceLocation: sourceLocation)
            try #require(Array(argv.suffix(3).prefix(2)) == ["bash", "-c"],
                         "argv should end in one `bash -c <body>`: \(argv)", sourceLocation: sourceLocation)
            head = Array(argv[..<start])
            env = Array(argv[(start + marker.count)..<(argv.count - 3)])
            body = argv[argv.count - 1]
        }

        /// `env` without the opt-in inference gateway's pairs, which depend on
        /// the host app's defaults.
        var envIgnoringGateway: [String] {
            env.filter { !$0.hasPrefix("ANTHROPIC_BASE_URL=") && !$0.hasPrefix("ANTHROPIC_AUTH_TOKEN=") }
        }
    }

    fileprivate enum Shell {
        /// Splits a command line into words as `/bin/sh` would, for the subset
        /// `SbxCommand.shellQuote` emits: bare words, `'…'` spans and `\'`.
        static func words(_ line: String) -> [String] {
            var words: [String] = []
            var word = String.UnicodeScalarView()
            var inWord = false, quoted = false, escaped = false
            for scalar in line.unicodeScalars {
                if quoted {
                    if scalar == "'" { quoted = false } else { word.append(scalar) }
                } else if escaped {
                    word.append(scalar)
                    escaped = false
                } else if scalar == "'" {
                    quoted = true
                    inWord = true
                } else if scalar == "\\" {
                    escaped = true
                    inWord = true
                } else if scalar == " " {
                    if inWord {
                        words.append(String(word))
                        word = String.UnicodeScalarView()
                        inWord = false
                    }
                } else {
                    word.append(scalar)
                    inWord = true
                }
            }
            if inWord { words.append(String(word)) }
            return words
        }
    }

    /// The in-sandbox shell text `SbxCommand` is expected to emit.
    fileprivate enum Expected {
        static let pathSetup = #"P="$PATH"; [ -d "/home/agent/.cargo/bin" ] && P="/home/agent/.cargo/bin:$P"; [ -d "$HOME/bin" ] && P="$HOME/bin:$P"; [ -d "$HOME/.local/bin" ] && P="$HOME/.local/bin:$P"; export PATH="$P";"#

        static let proxyAuth = #"F="$HOME/.claude/.credentials.json"; T=$(sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p' "$F" 2>/dev/null); if [ -n "$T" ]; then export CLAUDE_CODE_OAUTH_TOKEN="$T"; S=$(sed -n 's/.*"scopes":\[\([^]]*\)\].*/\1/p' "$F" 2>/dev/null | tr -d '"' | tr ',' ' '); export CLAUDE_CODE_OAUTH_SCOPES="${S:-user:inference user:profile user:sessions:claude_code user:mcp_servers user:file_upload}"; fi;"#

        static var launchEcho: String { #"echo "\#(SbxCommand.launchMarker)" >&2; "# }

        static let geminiACP = #"command -v gemini >/dev/null || { echo "sandshell: gemini isn't installed in this sandbox's image" >&2; exit 127; }; exec gemini --acp"#

        static var codexACP: String {
            let v = SbxCommand.codexACPVersion
            return #"export NO_BROWSER=1; H="$HOME/.codex"; if [ "${CODEX_HOME:-$H}" = "$H" ] && [ ! -s "$H/auth.json" ] && [ -n "$SBX_CRED_OPENAI_MODE" ]; then mkdir -p "$H" && printf '%s' '{"OPENAI_API_KEY":"proxy-managed"}' > "$H/auth.json"; fi; D="$HOME/.sandshell/acp/codex-acp-\#(v)"; B="$D/node_modules/.bin/codex-acp"; if [ ! -x "$B" ]; then echo "\#(SbxCommand.installingMarker)" >&2; mkdir -p "$HOME/.sandshell/acp"; T=$(mktemp -d "$D.tmp.XXXXXX"); if npm install --silent --no-audit --no-fund --prefix "$T" @agentclientprotocol/codex-acp@\#(v) >&2; then [ -x "$B" ] || rm -rf "$D"; mv -T "$T" "$D" 2>/dev/null || rm -rf "$T"; else rm -rf "$T"; echo "sandshell: couldn't install @agentclientprotocol/codex-acp@\#(v)" >&2; exit 1; fi; fi; exec "$B""#
        }

        static var claudeACP: String {
            let v = SbxCommand.claudeACPVersion
            return #"export CLAUDE_CODE_EXECUTABLE="$(command -v claude)"; D="$HOME/.sandshell/acp/\#(v)"; B="$D/node_modules/.bin/claude-agent-acp"; if [ ! -x "$B" ]; then echo "\#(SbxCommand.installingMarker)" >&2; mkdir -p "$HOME/.sandshell/acp"; T=$(mktemp -d "$D.tmp.XXXXXX"); if npm install --silent --no-audit --no-fund --omit=optional --prefix "$T" @agentclientprotocol/claude-agent-acp@\#(v) >&2; then [ -x "$B" ] || rm -rf "$D"; mv -T "$T" "$D" 2>/dev/null || rm -rf "$T"; else rm -rf "$T"; echo "sandshell: couldn't install @agentclientprotocol/claude-agent-acp@\#(v)" >&2; exit 1; fi; fi; W="$HOME/.sandshell/sandshell-acp.mjs"; if [ -f "$W" ]; then echo "\#(SbxCommand.extrasMarker)" >&2; export SANDSHELL_ACP_DIR="$D"; exec node "$W"; fi; exec "$B""#
        }

        /// Each chat agent's ACP entry point, as it follows the launch marker
        /// and PATH setup (without proxy auth).
        static var acpProgram: [AgentKind: String] {
            [.claude: claudeACP, .codex: codexACP, .gemini: geminiACP]
        }

        /// The `/proc` scan `reapScript` runs once per signal (`then` runs after each kill).
        static func reapScan(_ signal: String, then: String = "") -> String {
            #"for d in /proc/[0-9]*; do { tr '\0' '\n' < "$d/environ"; } 2>/dev/null | grep -qxF "$M" && kill -\#(signal) "${d#/proc/}" 2>/dev/null\#(then); done"#
        }

        /// The locale forwarded into the container: the host's `LANG` when it's
        /// UTF-8, else `C.UTF-8`. Read from this process, never set.
        static var lang: String {
            let host = ProcessInfo.processInfo.environment["LANG"] ?? ""
            return host.uppercased().contains("UTF-8") ? host : "C.UTF-8"
        }

        /// Env pairs every session gets, for a host home without `~/.codex`.
        static func baseEnv(home: String) -> [String] {
            ["COLORTERM=truecolor", "TERM=xterm-256color", "LANG=\(lang)",
             "CARGO_HOME=/home/agent/.cargo", "RUSTUP_HOME=/home/agent/.rustup",
             "CLAUDE_CONFIG_DIR=\(home)/.claude"]
        }
    }

    /// Whether the host app's defaults turn on the opt-in inference gateway
    /// (`inferenceGatewayURL`), which adds env pairs and replaces proxy auth.
    /// Detected from a launch's own env, so the tests never touch defaults.
    fileprivate enum HostDefaults {
        static var inferenceGatewayConfigured: Bool {
            let args = SbxCommand.acpArguments(agent: .gemini, containerName: "probe", workdir: "",
                                               home: Fixture.missingHome(), mcpURL: nil) ?? []
            return args.contains("ANTHROPIC_AUTH_TOKEN=sandshell-inference-gateway")
        }
    }
}
