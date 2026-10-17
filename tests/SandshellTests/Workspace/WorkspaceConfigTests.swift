import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Unusual-but-real inputs: legacy fields, explicit nulls, odd kit references.
    /// Named for this file so it can't collide with another suite's tag.
    @Tag fileprivate static var workspaceConfigEdgeCase: Self
}

// MARK: - Fixtures

/// The smallest config.json `WorkspaceConfig` accepts: only the required policy.
fileprivate let minimalWorkspaceConfigJSON = #"{"policy":{"selections":[]}}"#

fileprivate let workspaceConfigTestMCPURL = URL(string: "https://mcp.example.com/gateway")!

fileprivate func decodeWorkspaceConfig(_ json: String) throws -> WorkspaceConfig {
    try JSONDecoder().decode(WorkspaceConfig.self, from: Data(json.utf8))
}

/// Decodes the minimal config plus extra top-level members, e.g. `"configured":true`.
fileprivate func decodeWorkspaceConfig(with members: String) throws -> WorkspaceConfig {
    try decodeWorkspaceConfig("{" + #""policy":{"selections":[]},"# + members + "}")
}

/// A config with every field moved off its default.
fileprivate func makeCustomizedWorkspaceConfig() -> WorkspaceConfig {
    var theme = ThemePreferences()
    theme.terminalThemeName = "Dracula"
    theme.sidebarAlwaysDark = false
    theme.detailVibrancy = 1.5
    var config = WorkspaceConfig(
        policy: MountPolicy(selections: [
            MountSpec(path: URL(fileURLWithPath: "/srv/reference", isDirectory: true), readonly: true),
            MountSpec(path: URL(fileURLWithPath: "/srv/scratch", isDirectory: true), readonly: false),
        ]),
        mcpServers: ["github", "filesystem"],
        mcpURL: workspaceConfigTestMCPURL,
        primaryAgent: .codex,
        configured: true,
        archiveInterval: 600,
        theme: theme,
        kits: ["docker.io/sbx/github-ssh-kit:latest"],
        imageChannel: .custom,
        customImage: "ghcr.io/example/sandbox:1.2",
        claudeModel: "opus",
        claudeEffort: "high",
        schemaVersion: 3)
    config.sandshellKits = ["sandshell-codex"]
    config.customAgents = [AgentKind(rawValue: "my-kit-agent")]
    return config
}

/// `WorkspaceConfig` isn't `Equatable`, so compare it field by field.
fileprivate func expectSameWorkspaceConfig(
    _ actual: WorkspaceConfig,
    _ expected: WorkspaceConfig,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual.schemaVersion == expected.schemaVersion, "schemaVersion", sourceLocation: sourceLocation)
    #expect(actual.policy.selections.map(\.spec) == expected.policy.selections.map(\.spec),
            "policy", sourceLocation: sourceLocation)
    #expect(actual.mcpServers == expected.mcpServers, "mcpServers", sourceLocation: sourceLocation)
    #expect(actual.mcpURL == expected.mcpURL, "mcpURL", sourceLocation: sourceLocation)
    #expect(actual.primaryAgent == expected.primaryAgent, "primaryAgent", sourceLocation: sourceLocation)
    #expect(actual.configured == expected.configured, "configured", sourceLocation: sourceLocation)
    #expect(actual.archiveInterval == expected.archiveInterval, "archiveInterval", sourceLocation: sourceLocation)
    #expect(actual.theme == expected.theme, "theme", sourceLocation: sourceLocation)
    #expect(actual.kits == expected.kits, "kits", sourceLocation: sourceLocation)
    #expect(actual.sandshellKits == expected.sandshellKits, "sandshellKits", sourceLocation: sourceLocation)
    #expect(actual.imageChannel == expected.imageChannel, "imageChannel", sourceLocation: sourceLocation)
    #expect(actual.customImage == expected.customImage, "customImage", sourceLocation: sourceLocation)
    #expect(actual.claudeModel == expected.claudeModel, "claudeModel", sourceLocation: sourceLocation)
    #expect(actual.claudeEffort == expected.claudeEffort, "claudeEffort", sourceLocation: sourceLocation)
    #expect(actual.customAgents == expected.customAgents, "customAgents", sourceLocation: sourceLocation)
}

/// The config's JSON as a dictionary, to check what is (and isn't) written.
fileprivate func encodedWorkspaceConfigObject(
    _ config: WorkspaceConfig,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
    return try #require(object as? [String: Any], "A config encodes as a JSON object", sourceLocation: sourceLocation)
}

/// The kit fields of a config.json, as written before `sandshellKits` existed
/// (field omitted) or after it (field present).
fileprivate struct StoredKitFields: Encodable {
    var policy = MountPolicy()
    var kits: [String]
    var sandshellKits: [String]?
}

// MARK: - Initializer

struct WorkspaceConfigTests {
    @Test func initializerFillsInDefaults() {
        let config = WorkspaceConfig(policy: MountPolicy())
        #expect(config.schemaVersion == 1)
        #expect(config.policy == MountPolicy())
        #expect(config.mcpServers.isEmpty)
        #expect(config.mcpURL == Workspace.defaultMCPURL)
        #expect(config.primaryAgent == .claude)
        #expect(config.configured == false, "A new workspace hasn't had its mounts confirmed yet")
        #expect(config.archiveInterval == WorkspaceConfig.defaultArchiveInterval)
        #expect(config.theme == nil, "No theme means the root inherits the global default")
        #expect(config.kits.isEmpty)
        #expect(config.sandshellKits == nil, "nil means the registry's defaults apply")
        #expect(config.imageChannel == .stable)
        #expect(config.customImage.isEmpty)
        #expect(config.claudeModel == nil)
        #expect(config.claudeEffort == nil)
        #expect(config.customAgents.isEmpty)
    }

    @Test func defaultArchiveIntervalIsThirtyMinutes() {
        #expect(WorkspaceConfig.defaultArchiveInterval == 30 * 60)
    }

    @Test func initializerKeepsEveryValueGiven() {
        var theme = ThemePreferences()
        theme.terminalThemeName = "Dracula"
        let policy = MountPolicy(selections: [
            MountSpec(path: URL(fileURLWithPath: "/srv/reference", isDirectory: true), readonly: true),
        ])

        let config = WorkspaceConfig(
            policy: policy,
            mcpServers: ["github"],
            mcpURL: workspaceConfigTestMCPURL,
            primaryAgent: .codex,
            configured: true,
            archiveInterval: 600,
            theme: theme,
            kits: ["docker.io/sbx/github-ssh-kit:latest"],
            imageChannel: .nightly,
            customImage: "ghcr.io/example/sandbox:1.2",
            claudeModel: "opus",
            claudeEffort: "high",
            schemaVersion: 3)

        #expect(config.schemaVersion == 3)
        #expect(config.policy == policy)
        #expect(config.mcpServers == ["github"])
        #expect(config.mcpURL == workspaceConfigTestMCPURL)
        #expect(config.primaryAgent == .codex)
        #expect(config.configured)
        #expect(config.archiveInterval == 600)
        #expect(config.theme == theme)
        #expect(config.kits == ["docker.io/sbx/github-ssh-kit:latest"])
        #expect(config.imageChannel == .nightly)
        #expect(config.customImage == "ghcr.io/example/sandbox:1.2")
        #expect(config.claudeModel == "opus")
        #expect(config.claudeEffort == "high")
        #expect(config.sandshellKits == nil, "The initializer takes no sandshellKits, so they stay on the registry's defaults")
        #expect(config.customAgents.isEmpty)
    }
}

// MARK: - Decoding

extension WorkspaceConfigTests {
    struct Decoding {
        @Test func onlyPolicyIsRequired() throws {
            let config = try decodeWorkspaceConfig(minimalWorkspaceConfigJSON)
            expectSameWorkspaceConfig(config, WorkspaceConfig(policy: MountPolicy()))
        }

        @Test func missingPolicyIsAnError() throws {
            let error = try #require(throws: DecodingError.self) {
                try decodeWorkspaceConfig(#"{"configured":true,"kits":[]}"#)
            }
            guard case .keyNotFound(let key, _) = error else {
                Issue.record("Expected keyNotFound for policy, got \(error)")
                return
            }
            #expect(key.stringValue == "policy")
        }

        @Test(.tags(.workspaceConfigEdgeCase))
        func explicitNullsFallBackToDefaults() throws {
            let config = try decodeWorkspaceConfig(with: """
                "schemaVersion":null,"mcpServers":null,"mcpURL":null,"primaryAgent":null,\
                "configured":null,"archiveInterval":null,"theme":null,"kits":null,\
                "imageChannel":null,"customImage":null,"claudeModel":null,"claudeEffort":null,\
                "customAgents":null,"sandshellKits":null
                """)
            expectSameWorkspaceConfig(config, WorkspaceConfig(policy: MountPolicy()))
        }

        @Test func everyStoredFieldIsRead() throws {
            let config = try decodeWorkspaceConfig("""
                {
                  "schemaVersion": 2,
                  "policy": {"selections": [{"path": "file:///srv/reference/", "readonly": true}]},
                  "mcpServers": ["github"],
                  "mcpURL": "https://mcp.example.com/gateway",
                  "primaryAgent": "gemini",
                  "configured": true,
                  "archiveInterval": 90,
                  "theme": {"terminalThemeName": "Dracula"},
                  "kits": ["docker.io/sbx/github-ssh-kit:latest"],
                  "sandshellKits": ["sandshell-claude"],
                  "imageChannel": "nightly",
                  "customImage": "ghcr.io/example/sandbox:1.2",
                  "claudeModel": "sonnet",
                  "claudeEffort": "low",
                  "customAgents": ["my-kit-agent"]
                }
                """)
            #expect(config.schemaVersion == 2)
            #expect(config.policy.selections.map(\.spec) == ["/srv/reference:ro"])
            #expect(config.mcpServers == ["github"])
            #expect(config.mcpURL == workspaceConfigTestMCPURL)
            #expect(config.primaryAgent == .gemini)
            #expect(config.configured)
            #expect(config.archiveInterval == 90)
            #expect(config.theme?.terminalThemeName == "Dracula")
            #expect(config.kits == ["docker.io/sbx/github-ssh-kit:latest"])
            #expect(config.sandshellKits == ["sandshell-claude"])
            #expect(config.imageChannel == .nightly)
            #expect(config.customImage == "ghcr.io/example/sandbox:1.2")
            #expect(config.claudeModel == "sonnet")
            #expect(config.claudeEffort == "low")
            #expect(config.customAgents == [AgentKind(rawValue: "my-kit-agent")])
        }

        @Test(arguments: [
            #""configured":"yes""#,
            #""schemaVersion":"1""#,
            #""archiveInterval":"30""#,
            #""kits":"docker.io/sbx/github-ssh-kit:latest""#,
            #""mcpServers":[1]"#,
            #""primaryAgent":7"#,
            #""customAgents":"claude""#,
        ])
        func wronglyTypedValueIsAnError(member: String) throws {
            let error = try #require(throws: DecodingError.self) {
                try decodeWorkspaceConfig(with: member)
            }
            guard case .typeMismatch(_, _) = error else {
                Issue.record("Expected typeMismatch for \(member), got \(error)")
                return
            }
        }

        /// A channel this build doesn't know (say, from a newer Sandshell) makes
        /// the whole file unreadable rather than falling back to `.stable`.
        @Test(.tags(.workspaceConfigEdgeCase))
        func unknownImageChannelIsAnError() throws {
            let error = try #require(throws: DecodingError.self) {
                try decodeWorkspaceConfig(with: #""imageChannel":"beta""#)
            }
            guard case .dataCorrupted(_) = error else {
                Issue.record("Expected dataCorrupted, got \(error)")
                return
            }
        }

        @Test(arguments: ImageChannel.allCases)
        func everyImageChannelDecodes(channel: ImageChannel) throws {
            let config = try decodeWorkspaceConfig(with: "\"imageChannel\":\"\(channel.rawValue)\"")
            #expect(config.imageChannel == channel)
        }

        /// Taken as written: no clamping of zero, fractional, or negative values.
        @Test(arguments: [0, 1, 90.5, 86_400, -5] as [TimeInterval])
        func archiveIntervalIsTakenAsWritten(seconds: TimeInterval) throws {
            let config = try decodeWorkspaceConfig(with: "\"archiveInterval\":\(seconds)")
            #expect(config.archiveInterval == seconds)
        }

        @Test func unknownKeysAreIgnored() throws {
            let config = try decodeWorkspaceConfig(with: #""futureSetting":{"nested":[1,2,3]},"configured":true"#)
            #expect(config.configured, "Known fields still decode next to ones this build doesn't know")
        }

        @Test func customPrimaryAgentDecodes() throws {
            let config = try decodeWorkspaceConfig(with: #""primaryAgent":"my-kit-agent""#)
            #expect(config.primaryAgent.rawValue == "my-kit-agent")
            #expect(config.primaryAgent.isBuiltin == false)
        }
    }
}

// MARK: - Legacy kit migration

extension WorkspaceConfigTests {
    /// Builds before `sandshellKits` kept Sandshell's own kits in `kits`;
    /// decoding moves them over.
    struct LegacyKitMigration {
        struct Scenario: Sendable, CustomTestStringConvertible {
            var name: String
            var storedKits: [String]
            var storedSandshellKits: [String]?
            var expectedKits: [String]
            var expectedSandshellKits: [String]?
            var testDescription: String { name }
        }

        static let cases: [Scenario] = [
            Scenario(name: "both own kits among others, field absent",
                     storedKits: ["docker.io/sbx/git-ssh-sign-kit:latest", "sandshell-claude",
                                  "docker.io/sbx/github-ssh-kit:latest", "sandshell-codex"],
                     storedSandshellKits: nil,
                     expectedKits: ["docker.io/sbx/git-ssh-sign-kit:latest", "docker.io/sbx/github-ssh-kit:latest"],
                     expectedSandshellKits: ["sandshell-claude", "sandshell-codex"]),
            Scenario(name: "appended after the ones already in the field",
                     storedKits: ["sandshell-claude"],
                     storedSandshellKits: ["sandshell-codex"],
                     expectedKits: [],
                     expectedSandshellKits: ["sandshell-codex", "sandshell-claude"]),
            Scenario(name: "already in the field is not added again",
                     storedKits: ["sandshell-claude"],
                     storedSandshellKits: ["sandshell-claude"],
                     expectedKits: [],
                     expectedSandshellKits: ["sandshell-claude"]),
            Scenario(name: "an empty field still takes a legacy kit",
                     storedKits: ["sandshell-codex"],
                     storedSandshellKits: [],
                     expectedKits: [],
                     expectedSandshellKits: ["sandshell-codex"]),
            // Moved verbatim: the path isn't turned back into the bare name.
            Scenario(name: "bundled path form",
                     storedKits: ["/Applications/Sandshell.app/Contents/Resources/kits/sandshell-claude"],
                     storedSandshellKits: nil,
                     expectedKits: [],
                     expectedSandshellKits: ["/Applications/Sandshell.app/Contents/Resources/kits/sandshell-claude"]),
            Scenario(name: "no own kits leaves the field absent",
                     storedKits: ["docker.io/sbx/github-ssh-kit:latest"],
                     storedSandshellKits: nil,
                     expectedKits: ["docker.io/sbx/github-ssh-kit:latest"],
                     expectedSandshellKits: nil),
            Scenario(name: "no own kits keeps an empty field empty",
                     storedKits: ["docker.io/sbx/github-ssh-kit:latest"],
                     storedSandshellKits: [],
                     expectedKits: ["docker.io/sbx/github-ssh-kit:latest"],
                     expectedSandshellKits: []),
            Scenario(name: "look-alike refs stay in kits",
                     storedKits: ["sandshell-claude-dev", "my-kits/sandshell-codex", "SANDSHELL-CLAUDE"],
                     storedSandshellKits: nil,
                     expectedKits: ["sandshell-claude-dev", "my-kits/sandshell-codex", "SANDSHELL-CLAUDE"],
                     expectedSandshellKits: nil),
        ]

        @Test(arguments: LegacyKitMigration.cases)
        func ownKitsMoveOutOfKits(scenario: Scenario) throws {
            let stored = StoredKitFields(kits: scenario.storedKits, sandshellKits: scenario.storedSandshellKits)
            let config = try JSONDecoder().decode(WorkspaceConfig.self, from: JSONEncoder().encode(stored))
            #expect(config.kits == scenario.expectedKits)
            #expect(config.sandshellKits == scenario.expectedSandshellKits,
                    "nil (registry defaults) must stay nil unless a legacy kit is found")
        }

        @Test(.tags(.workspaceConfigEdgeCase))
        func ownKitListedTwiceIsMovedOnce() throws {
            let config = try decodeWorkspaceConfig(
                with: #""kits":["sandshell-claude","docker.io/sbx/github-ssh-kit:latest","sandshell-claude"]"#)
            #expect(config.kits == ["docker.io/sbx/github-ssh-kit:latest"])
            #expect(config.sandshellKits == ["sandshell-claude"], "sbx create would get the kit twice")
        }

        @Test(.tags(.workspaceConfigEdgeCase))
        func ownKitAlreadyOnAndListedTwiceInLegacyKitsStaysOnce() throws {
            let config = try decodeWorkspaceConfig(
                with: #""sandshellKits":["sandshell-codex"],"kits":["sandshell-claude","sandshell-codex","sandshell-claude"]"#)
            #expect(config.kits.isEmpty)
            #expect(config.sandshellKits == ["sandshell-codex", "sandshell-claude"])
        }
    }
}

// MARK: - Encoding

extension WorkspaceConfigTests {
    struct Encoding {
        @Test func unsetOptionalsAreLeftOut() throws {
            let object = try encodedWorkspaceConfigObject(WorkspaceConfig(policy: MountPolicy()))
            let alwaysWritten: Set<String> = [
                "schemaVersion", "policy", "mcpServers", "mcpURL", "primaryAgent", "configured",
                "archiveInterval", "kits", "imageChannel", "customImage", "customAgents",
            ]
            #expect(Set(object.keys) == alwaysWritten, "theme, sandshellKits, claudeModel and claudeEffort are omitted while nil")
        }

        @Test(arguments: ["theme", "sandshellKits", "claudeModel", "claudeEffort"])
        func setOptionalIsWritten(key: String) throws {
            let object = try encodedWorkspaceConfigObject(makeCustomizedWorkspaceConfig())
            #expect(object.keys.contains(key), "\(key) should be written once set")
        }

        @Test func agentsChannelAndGatewayAreWrittenAsPlainStrings() throws {
            let object = try encodedWorkspaceConfigObject(makeCustomizedWorkspaceConfig())
            #expect(object["primaryAgent"] as? String == "codex")
            #expect(object["customAgents"] as? [String] == ["my-kit-agent"])
            #expect(object["imageChannel"] as? String == "custom")
            #expect(object["mcpURL"] as? String == "https://mcp.example.com/gateway")
        }

        @Test func roundTripKeepsEveryField() throws {
            let original = makeCustomizedWorkspaceConfig()
            let decoded = try JSONDecoder().decode(WorkspaceConfig.self, from: JSONEncoder().encode(original))
            expectSameWorkspaceConfig(decoded, original)
        }

        @Test(arguments: [nil, [], ["sandshell-codex"]] as [[String]?])
        func roundTripKeepsSandshellKitChoice(sandshellKits: [String]?) throws {
            var original = WorkspaceConfig(policy: MountPolicy())
            original.sandshellKits = sandshellKits
            let decoded = try JSONDecoder().decode(WorkspaceConfig.self, from: JSONEncoder().encode(original))
            #expect(decoded.sandshellKits == sandshellKits,
                    "nil (registry defaults) and [] (all off) must stay distinct")
        }
    }
}

// MARK: - Recognizing Sandshell's own kits

extension WorkspaceConfigTests {
    /// `KitStore.isSandshellKit` decides what the legacy migration moves.
    struct SandshellKitRecognition {
        @Test(arguments: [
            "sandshell-claude",
            "sandshell-codex",
            "/kits/sandshell-claude",
            "/Applications/Sandshell.app/Contents/Resources/kits/sandshell-claude",
            "/Users/someone/Code/xmas-sandshell/kits/sandshell-codex",
        ])
        func recognizesOwnKits(ref: String) {
            #expect(KitStore.isSandshellKit(ref))
        }

        @Test(.tags(.workspaceConfigEdgeCase), arguments: [
            "",
            "sandshell",
            "sandshell-gemini",
            "sandshell-claude-dev",
            "SANDSHELL-CLAUDE",
            " sandshell-claude",
            "sandshell-claude/",
            "/srv/mykits/sandshell-claude",
            "my-kits/sandshell-codex",
            "/srv/kits/sandshell-claude/spec.yaml",
            "docker.io/sbx/git-ssh-sign-kit:latest",
        ])
        func rejectsLookAlikes(ref: String) {
            #expect(KitStore.isSandshellKit(ref) == false)
        }
    }
}

// MARK: - Persistence

extension WorkspaceConfigTests {
    /// Each test gets its own temporary workspace root, removed afterwards.
    final class Persistence {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceConfigTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        var configURL: URL { WorkspaceConfig.url(root: root) }
        var controlDirPath: String { root.appendingPathComponent(".sandshell", isDirectory: true).path }

        func writeConfigFile(_ text: String) throws {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: configURL)
        }

        static let unreadableContents = [
            "",
            "{",
            "null",
            "[]",
            #"{"kits":[]}"#,
            """
            <<<<<<< HEAD
            {"policy":{"selections":[]}}
            =======
            {"policy":{"selections":[]},"configured":true}
            >>>>>>> other-branch
            """,
        ]

        @Test func configLivesInControlDirectory() {
            #expect(configURL.path == root.path + "/.sandshell/config.json")
        }

        @Test func loadWithoutConfigReturnsNil() throws {
            #expect(try WorkspaceConfig.load(root: root) == nil)
            #expect(FileManager.default.fileExists(atPath: controlDirPath) == false,
                    "Loading must not create the control directory")
        }

        @Test(.tags(.workspaceConfigEdgeCase))
        func loadFromMissingRootReturnsNil() throws {
            let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
            #expect(try WorkspaceConfig.load(root: missing) == nil)
        }

        @Test func saveCreatesControlDirectoryAndFile() throws {
            try WorkspaceConfig(policy: MountPolicy()).save(root: root)

            var isDirectory: ObjCBool = false
            let controlDirExists = FileManager.default.fileExists(atPath: controlDirPath, isDirectory: &isDirectory)
            #expect(controlDirExists)
            #expect(isDirectory.boolValue, ".sandshell should be a directory")
            #expect(FileManager.default.fileExists(atPath: configURL.path))
        }

        @Test func saveThenLoadKeepsEveryField() throws {
            let original = makeCustomizedWorkspaceConfig()
            try original.save(root: root)
            let loaded = try #require(try WorkspaceConfig.load(root: root))
            expectSameWorkspaceConfig(loaded, original)
        }

        @Test func saveReplacesPreviousConfig() throws {
            try makeCustomizedWorkspaceConfig().save(root: root)
            let replacement = WorkspaceConfig(policy: MountPolicy(), primaryAgent: .gemini,
                                              kits: ["docker.io/sbx/git-ssh-sign-kit:latest"])
            try replacement.save(root: root)

            let loaded = try #require(try WorkspaceConfig.load(root: root))
            expectSameWorkspaceConfig(loaded, replacement)
        }

        @Test func savedFileIsPrettyPrintedWithSortedKeys() throws {
            try WorkspaceConfig(policy: MountPolicy()).save(root: root)
            let text = try String(contentsOf: configURL, encoding: .utf8)

            #expect(text.hasPrefix("{\n"), "config.json is tracked in git, so it's written one key per line")
            let keys = ["archiveInterval", "configured", "customAgents", "customImage", "imageChannel",
                        "kits", "mcpServers", "mcpURL", "policy", "primaryAgent", "schemaVersion"]
            let positions = try keys.map { key in
                try #require(text.range(of: "\"\(key)\"")?.lowerBound, "\(key) should be written")
            }
            #expect(positions == positions.sorted(), "Keys are sorted so saves give stable diffs")
        }

        @Test(.tags(.workspaceConfigEdgeCase), arguments: Persistence.unreadableContents)
        func loadOfUnreadableFileThrows(contents: String) throws {
            try writeConfigFile(contents)
            #expect(throws: DecodingError.self) {
                try WorkspaceConfig.load(root: root)
            }
        }

        @Test func legacyKitsAreMovedOnLoadAndStayMovedAfterSave() throws {
            try writeConfigFile(
                #"{"policy":{"selections":[]},"kits":["sandshell-claude","docker.io/sbx/github-ssh-kit:latest"]}"#)

            let loaded = try #require(try WorkspaceConfig.load(root: root))
            #expect(loaded.kits == ["docker.io/sbx/github-ssh-kit:latest"])
            #expect(loaded.sandshellKits == ["sandshell-claude"])

            try loaded.save(root: root)
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
            #expect(object["kits"] as? [String] == ["docker.io/sbx/github-ssh-kit:latest"],
                    "An older Sandshell reading the file must not find the bare kit name in kits")
            #expect(object["sandshellKits"] as? [String] == ["sandshell-claude"])
        }

        @Test func loadOrDefaultReturnsSavedConfig() throws {
            let saved = makeCustomizedWorkspaceConfig()
            try saved.save(root: root)
            let home = root.appendingPathComponent("home", isDirectory: true)

            let config = WorkspaceConfig.loadOrDefault(root: root, home: home)

            expectSameWorkspaceConfig(config, saved)
            let files = try FileManager.default.contentsOfDirectory(atPath: controlDirPath)
            #expect(files == ["config.json"], "A readable config must not be copied aside")
        }

        @Test func aReadableConfigReportsNoProblem() throws {
            let saved = makeCustomizedWorkspaceConfig()
            try saved.save(root: root)
            let home = root.appendingPathComponent("home", isDirectory: true)

            let (config, unreadable) = WorkspaceConfig.loadReportingProblems(root: root, home: home)

            expectSameWorkspaceConfig(config, saved)
            #expect(unreadable == nil)
        }

        /// What the window reports when config.json can't be read: the file, the
        /// copy kept of it before defaults can be saved over it, and why.
        @Test(.tags(.workspaceConfigEdgeCase), arguments: Persistence.unreadableContents)
        func anUnreadableConfigIsCopiedAsideAndReported(contents: String) throws {
            try writeConfigFile(contents)
            let error = try #require(throws: DecodingError.self) { try WorkspaceConfig.load(root: root) }

            let problem = WorkspaceConfig.setAside(root: root, error)

            #expect(problem.file == configURL)
            #expect(problem.reason == error.localizedDescription)
            let copy = try #require(problem.keptAs, "A copy of the unreadable file is kept")
            #expect(copy.deletingLastPathComponent().path == controlDirPath)
            #expect(copy.lastPathComponent.hasPrefix("config.unreadable-"))
            #expect(copy.pathExtension == "json")
            #expect(try String(contentsOf: copy, encoding: .utf8) == contents)
            #expect(try String(contentsOf: configURL, encoding: .utf8) == contents, "The original stays put")
        }

        @Test(.tags(.workspaceConfigEdgeCase))
        func aCopyThatFailsIsReportedAsNotKept() throws {
            // Nothing at config.json: nothing to copy.
            let problem = WorkspaceConfig.setAside(root: root, CocoaError(.fileReadCorruptFile))

            #expect(problem.keptAs == nil)
            #expect(problem.file == configURL)
        }

        @Test(.tags(.workspaceConfigEdgeCase))
        func saveFailsWhenControlDirectoryIsAFile() throws {
            let blocker = root.appendingPathComponent(".sandshell", isDirectory: false)
            try Data("not a directory".utf8).write(to: blocker)

            #expect(throws: CocoaError.self) {
                try WorkspaceConfig(policy: MountPolicy()).save(root: root)
            }
            let contents = try String(contentsOf: blocker, encoding: .utf8)
            #expect(contents == "not a directory", "A failed save leaves the existing file alone")
        }
    }
}
