import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Boundary and malformed-input cases for workspace state (fileprivate so it can't clash with other suites' tags).
    @Tag fileprivate static var workspaceStateEdgeCase: Self
    /// Reading pre-folders-model or pre-schema-2 `state.json` files.
    @Tag fileprivate static var workspaceStateLegacyFormat: Self
    /// Tests that read or write a per-test scratch directory.
    @Tag fileprivate static var workspaceStateFileSystem: Self
}

// MARK: - Fixtures

/// JSON helpers using the same date strategy as `WorkspaceState.load`/`save`.
fileprivate enum WorkspaceStateJSON {
    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encode(value))
    }

    /// The top-level JSON object of `data`.
    static func object(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try #require(parsed as? [String: Any], "Expected a JSON object", sourceLocation: sourceLocation)
    }
}

fileprivate enum WorkspaceStateFixture {
    /// 2023-11-14T22:13:20Z: a whole second, so it survives an ISO-8601 round trip exactly.
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let referenceDateISO = "2023-11-14T22:13:20Z"

    /// A state with every field populated, including optional session fields and flags.
    static func populatedState() -> WorkspaceState {
        let rootFolder = Folder(relativePath: "", order: -1)
        let app = Folder(relativePath: "apps/web", order: 0)
        var chat = Session(folderID: app.id, agent: .claude, name: "Refactor", order: 0,
                           workdir: "/workspace/apps/web", transcriptID: "transcript-1",
                           createdAt: referenceDate, isChat: true)
        chat.isNamedByUser = true
        chat.lastActiveAt = referenceDate.addingTimeInterval(3_600)
        let shell = Session(folderID: rootFolder.id, agent: .shell, name: "Shell", order: 1,
                            workdir: "/workspace", createdAt: referenceDate.addingTimeInterval(60),
                            containerAgent: .claude)
        return WorkspaceState(
            schemaVersion: 2,
            folders: [rootFolder, app],
            sessions: [chat, shell],
            expandedFolderIDs: [rootFolder.id, app.id],
            archiveWatermarks: [chat.id.uuidString: referenceDate],
            appliedMountSignatures: ["sandshell-claude": "sig-1"],
            ignoredKitDrift: ["sandshell-claude": ["docker.io/kits/extra"]],
            slugAgent: .claude)
    }

    /// `WorkspaceState` isn't Equatable, so compare it field by field.
    static func expectSameState(_ actual: WorkspaceState, _ expected: WorkspaceState,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.schemaVersion == expected.schemaVersion, "schemaVersion", sourceLocation: sourceLocation)
        #expect(actual.folders == expected.folders, "folders", sourceLocation: sourceLocation)
        #expect(actual.sessions == expected.sessions, "sessions", sourceLocation: sourceLocation)
        #expect(actual.expandedFolderIDs == expected.expandedFolderIDs, "expandedFolderIDs", sourceLocation: sourceLocation)
        #expect(actual.archiveWatermarks == expected.archiveWatermarks, "archiveWatermarks", sourceLocation: sourceLocation)
        #expect(actual.appliedMountSignatures == expected.appliedMountSignatures, "appliedMountSignatures",
                sourceLocation: sourceLocation)
        #expect(actual.ignoredKitDrift == expected.ignoredKitDrift, "ignoredKitDrift", sourceLocation: sourceLocation)
        #expect(actual.slugAgent == expected.slugAgent, "slugAgent", sourceLocation: sourceLocation)
    }

    static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Writes raw bytes to `<root>/.sandshell/state.json`, creating the directories.
    static func writeStateFile(_ contents: String, root: URL) throws {
        try FileManager.default.createDirectory(at: WorkspaceState.controlDir(root: root),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: WorkspaceState.stateURL(root: root))
    }
}

/// A unique scratch directory per test, removed when the owning suite instance goes away.
/// `root` (a workspace root inside it) is not created up front, so tests can start from nothing.
fileprivate final class WorkspaceStateScratchDirectory {
    let base: URL
    let root: URL

    init() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandshellWorkspaceStateTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }
}

// MARK: - Folder

struct WorkspaceStateFolderTests {
    @Test(arguments: [
        ("", true),
        ("src", false),
        ("apps/web", false),
        (" ", false),
        ("/", false),
    ])
    func isRootOnlyForTheEmptyPath(relativePath: String, expected: Bool) {
        let folder = Folder(relativePath: relativePath, order: 0)
        #expect(folder.isRoot == expected)
    }

    @Test func eachFolderGetsItsOwnIDByDefault() {
        let first = Folder(relativePath: "src", order: 0)
        let second = Folder(relativePath: "src", order: 0)
        #expect(first.id != second.id)
        #expect(first != second, "Identity is part of equality")
    }

    @Test func encodesOnlyTheCurrentKeys() throws {
        let folder = Folder(relativePath: "apps/web", order: 3)
        let object = try WorkspaceStateJSON.object(WorkspaceStateJSON.encode(folder))
        let expectedKeys: Set<String> = ["id", "relativePath", "order"]
        #expect(Set(object.keys) == expectedKeys, "The legacy folderName key is never written")
        #expect(object["id"] as? String == folder.id.uuidString)
        #expect(object["relativePath"] as? String == "apps/web")
        #expect(object["order"] as? Int == 3)
    }

    @Test(arguments: [("", 0), ("apps/web", -2), ("a b/ü", 99)])
    func roundTripsThroughJSON(relativePath: String, order: Int) throws {
        let folder = Folder(relativePath: relativePath, order: order)
        let decoded = try WorkspaceStateJSON.roundTrip(folder)
        #expect(decoded == folder)
    }

    @Test func decodesTheCurrentFormat() throws {
        let id = UUID()
        let folder = try WorkspaceStateJSON.decode(
            Folder.self, from: #"{"id":"\#(id.uuidString)","relativePath":"apps/web","order":4}"#)
        #expect(folder == Folder(id: id, relativePath: "apps/web", order: 4))
    }

    /// `relativePath` wins whenever it holds a string (even `""`, the root); a missing
    /// or `null` one falls back to the legacy `folderName`.
    @Test(.tags(.workspaceStateLegacyFormat), arguments: [
        (#"{"folderName":"alpha","order":1}"#, "alpha"),
        (#"{"relativePath":"apps/web","folderName":"alpha"}"#, "apps/web"),
        (#"{"relativePath":null,"folderName":"alpha"}"#, "alpha"),
        (#"{"relativePath":"","folderName":"alpha"}"#, ""),
    ])
    func relativePathFallsBackToLegacyFolderName(json: String, expectedPath: String) throws {
        let folder = try WorkspaceStateJSON.decode(Folder.self, from: json)
        #expect(folder.relativePath == expectedPath)
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func emptyObjectDecodesAsTheRootFolderAtOrderZero() throws {
        let folder = try WorkspaceStateJSON.decode(Folder.self, from: "{}")
        #expect(folder.relativePath == "")
        #expect(folder.isRoot)
        #expect(folder.order == 0)
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func missingIDGetsAFreshUUIDOnEveryDecode() throws {
        let json = #"{"relativePath":"src","order":0}"#
        let first = try WorkspaceStateJSON.decode(Folder.self, from: json)
        let second = try WorkspaceStateJSON.decode(Folder.self, from: json)
        #expect(first.id != second.id)
    }

    @Test(.tags(.workspaceStateEdgeCase), arguments: [
        #"{"id":"not-a-uuid","relativePath":"src","order":0}"#,
        #"{"relativePath":42}"#,
        #"{"folderName":["alpha"]}"#,
        #"{"relativePath":"src","order":"first"}"#,
    ])
    func malformedFieldsThrow(json: String) {
        #expect(throws: DecodingError.self) {
            try WorkspaceStateJSON.decode(Folder.self, from: json)
        }
    }
}

// MARK: - Session

struct WorkspaceStateSessionTests {
    @Test func initLeavesOptionalFieldsUnsetAndStampsNow() {
        let before = Date()
        let session = Session(folderID: UUID(), agent: .claude, name: "Chat", order: 0, workdir: "/workspace")
        let after = Date()
        #expect(session.transcriptID == nil)
        #expect(session.containerAgent == nil)
        #expect(session.isChat == false)
        #expect(session.isNamedByUser == false)
        #expect(session.lastActiveAt == nil)
        #expect(session.createdAt >= before, "createdAt defaults to the creation time")
        #expect(session.createdAt <= after, "createdAt defaults to the creation time")
    }

    @Test(arguments: [
        (agent: "claude", containerOverride: nil, expected: "claude"),
        (agent: "shell", containerOverride: "claude", expected: "claude"),
        (agent: "shell", containerOverride: "codex", expected: "codex"),
        (agent: "my-kit-agent", containerOverride: nil, expected: "my-kit-agent"),
    ] as [(agent: String, containerOverride: String?, expected: String)])
    func containerAgentKindPrefersTheOverride(testCase: (agent: String, containerOverride: String?, expected: String)) {
        let session = Session(folderID: UUID(), agent: AgentKind(rawValue: testCase.agent), name: "", order: 0,
                              workdir: "", containerAgent: testCase.containerOverride.map { AgentKind(rawValue: $0) })
        #expect(session.containerAgentKind == AgentKind(rawValue: testCase.expected))
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func agentOnlyJSONDecodesWithDefaults() throws {
        let session = try WorkspaceStateJSON.decode(Session.self, from: #"{"agent":"claude"}"#)
        #expect(session.agent == .claude)
        #expect(session.name == "")
        #expect(session.order == 0)
        #expect(session.workdir == "")
        #expect(session.transcriptID == nil)
        #expect(session.containerAgent == nil)
        #expect(session.createdAt == .distantPast, "Files predating createdAt decode as distantPast")
        #expect(session.lastActiveAt == nil, "Files predating lastActiveAt decode without one")
        #expect(session.isChat == false)
        #expect(session.isNamedByUser == false)
    }

    @Test func decodesEveryField() throws {
        let id = UUID()
        let folderID = UUID()
        let json = #"""
            {"id":"\#(id.uuidString)","folderID":"\#(folderID.uuidString)","agent":"shell","name":"Build",
             "order":3,"workdir":"/workspace/app","transcriptID":"t-42",
             "createdAt":"\#(WorkspaceStateFixture.referenceDateISO)","containerAgent":"codex",
             "chat":true,"namedByUser":true}
            """#
        let session = try WorkspaceStateJSON.decode(Session.self, from: json)
        var expected = Session(id: id, folderID: folderID, agent: .shell, name: "Build", order: 3,
                               workdir: "/workspace/app", transcriptID: "t-42",
                               createdAt: WorkspaceStateFixture.referenceDate, containerAgent: .codex, isChat: true)
        expected.isNamedByUser = true
        #expect(session == expected)
    }

    @Test func customAgentIdentityDecodesInsteadOfThrowing() throws {
        let session = try WorkspaceStateJSON.decode(Session.self, from: #"{"agent":"my-kit-agent"}"#)
        #expect(session.agent == AgentKind(rawValue: "my-kit-agent"))
        #expect(session.agent.isBuiltin == false)
    }

    @Test func missingAgentThrowsKeyNotFound() throws {
        let error = try #require(throws: DecodingError.self) {
            try WorkspaceStateJSON.decode(Session.self, from: #"{"name":"orphan","order":1}"#)
        }
        guard case .keyNotFound(let key, _) = error else {
            Issue.record("Expected keyNotFound for agent, got \(error)")
            return
        }
        #expect(key.stringValue == "agent")
    }

    @Test(.tags(.workspaceStateEdgeCase), arguments: [
        #"{"agent":null}"#,
        #"{"agent":42}"#,
        #"{"agent":"claude","folderID":"nope"}"#,
        #"{"agent":"claude","createdAt":"yesterday"}"#,
        #"{"agent":"claude","chat":"yes"}"#,
        #"{"agent":"claude","order":1.5}"#,
    ])
    func malformedFieldsThrow(json: String) {
        #expect(throws: DecodingError.self) {
            try WorkspaceStateJSON.decode(Session.self, from: json)
        }
    }

    @Test(.tags(.workspaceStateLegacyFormat))
    func legacyProjectIDBecomesTheFolderID() throws {
        let projectID = UUID()
        let session = try WorkspaceStateJSON.decode(
            Session.self, from: #"{"agent":"claude","projectID":"\#(projectID.uuidString)"}"#)
        #expect(session.folderID == projectID)
    }

    @Test(.tags(.workspaceStateLegacyFormat))
    func folderIDWinsOverLegacyProjectID() throws {
        let folderID = UUID()
        let projectID = UUID()
        let json = #"{"agent":"claude","folderID":"\#(folderID.uuidString)","projectID":"\#(projectID.uuidString)"}"#
        let session = try WorkspaceStateJSON.decode(Session.self, from: json)
        #expect(session.folderID == folderID)
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func swiftPropertyNamesAreNotTheFlagKeys() throws {
        // The flags persist as "chat" / "namedByUser"; the Swift names are ignored as unknown keys.
        let session = try WorkspaceStateJSON.decode(
            Session.self, from: #"{"agent":"claude","isChat":true,"isNamedByUser":true}"#)
        #expect(session.isChat == false)
        #expect(session.isNamedByUser == false)
    }

    @Test func encodingOmitsUnsetOptionalsAndFalseFlags() throws {
        let session = Session(folderID: UUID(), agent: .claude, name: "A", order: 1, workdir: "/w",
                              createdAt: WorkspaceStateFixture.referenceDate)
        let object = try WorkspaceStateJSON.object(WorkspaceStateJSON.encode(session))
        let expectedKeys: Set<String> = ["id", "folderID", "agent", "name", "order", "workdir", "createdAt"]
        #expect(Set(object.keys) == expectedKeys)
    }

    @Test func encodingWritesSetFieldsUnderTheirPersistedKeys() throws {
        var session = Session(folderID: UUID(), agent: .shell, name: "Shell", order: 2, workdir: "/w",
                              transcriptID: "t-1", createdAt: WorkspaceStateFixture.referenceDate,
                              containerAgent: .claude, isChat: true)
        session.isNamedByUser = true
        let object = try WorkspaceStateJSON.object(WorkspaceStateJSON.encode(session))
        let expectedKeys: Set<String> = ["id", "folderID", "agent", "name", "order", "workdir", "createdAt",
                                         "transcriptID", "containerAgent", "chat", "namedByUser"]
        #expect(Set(object.keys) == expectedKeys, "No legacy projectID key and no isChat/isNamedByUser keys")
        #expect(object["agent"] as? String == "shell", "AgentKind encodes as a bare string")
        #expect(object["containerAgent"] as? String == "claude")
        #expect(object["transcriptID"] as? String == "t-1")
        #expect(object["chat"] as? Bool == true)
        #expect(object["namedByUser"] as? Bool == true)
        #expect(object["createdAt"] as? String == WorkspaceStateFixture.referenceDateISO)
    }

    /// The sidebar's order and "Xm ago" survive a relaunch (xmas-sandshell-e7q.81).
    @Test func lastActiveAtPersistsAsAnISO8601Date() throws {
        var session = Session(folderID: UUID(), agent: .claude, name: "A", order: 0, workdir: "/w",
                              createdAt: WorkspaceStateFixture.referenceDate)
        session.lastActiveAt = WorkspaceStateFixture.referenceDate
        let object = try WorkspaceStateJSON.object(WorkspaceStateJSON.encode(session))
        #expect(object["lastActiveAt"] as? String == WorkspaceStateFixture.referenceDateISO)

        let json = #"{"agent":"claude","lastActiveAt":"\#(WorkspaceStateFixture.referenceDateISO)"}"#
        let decoded = try WorkspaceStateJSON.decode(Session.self, from: json)
        #expect(decoded.lastActiveAt == WorkspaceStateFixture.referenceDate)
    }

    struct RenameCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let pinned: Bool
        let newName: String
        /// The name and pin after it; nil: nothing changes.
        let expected: (name: String, pinned: Bool)?
    }

    @Test(arguments: [
        RenameCase(testDescription: "a new name pins it", pinned: false, newName: "Release", expected: ("Release", true)),
        RenameCase(testDescription: "a new name, trimmed", pinned: true, newName: "  Release \n", expected: ("Release", true)),
        RenameCase(testDescription: "the same automatic name pins it", pinned: false, newName: "Fix login",
                   expected: ("Fix login", true)),
        RenameCase(testDescription: "empty unpins and keeps the name", pinned: true, newName: "", expected: ("Fix login", false)),
        RenameCase(testDescription: "the same pinned name", pinned: true, newName: "Fix login", expected: nil),
        RenameCase(testDescription: "the same pinned name, padded", pinned: true, newName: " Fix login\t", expected: nil),
        RenameCase(testDescription: "empty when already automatic", pinned: false, newName: "", expected: nil),
        RenameCase(testDescription: "blank when already automatic", pinned: false, newName: "  \n", expected: nil),
    ])
    func renamedChangesOnlyNameAndPin(_ testCase: RenameCase) {
        var session = Session(folderID: UUID(), agent: .claude, name: "Fix login", order: 3, workdir: "/workspace",
                              transcriptID: "t-1", createdAt: WorkspaceStateFixture.referenceDate, isChat: true)
        session.isNamedByUser = testCase.pinned
        let renamed = session.renamed(to: testCase.newName)
        if let expected = testCase.expected {
            var want = session
            want.name = expected.name
            want.isNamedByUser = expected.pinned
            #expect(renamed == want)
        } else {
            #expect(renamed == nil, "nothing to save or undo")
        }
    }

    @Test(arguments: [false, true])
    func roundTripsThroughJSON(withOptionalFields: Bool) throws {
        var session = Session(folderID: UUID(), agent: AgentKind(rawValue: "my-kit-agent"), name: "Named",
                              order: 7, workdir: "/workspace/app",
                              transcriptID: withOptionalFields ? "t-1" : nil,
                              createdAt: WorkspaceStateFixture.referenceDate,
                              containerAgent: withOptionalFields ? .codex : nil,
                              isChat: withOptionalFields)
        session.isNamedByUser = withOptionalFields
        session.lastActiveAt = withOptionalFields ? WorkspaceStateFixture.referenceDate.addingTimeInterval(60) : nil
        session.transcriptWorkdir = withOptionalFields ? "/workspace/old" : nil
        let decoded = try WorkspaceStateJSON.roundTrip(session)
        #expect(decoded == session)
    }

    /// A session whose folder moved while it ran finds its conversation under the
    /// old cwd until its next launch takes it along (xmas-sandshell-e7q.84).
    @Test func transcriptWorkdirPersistsAndIsWhereItsConversationIs() throws {
        var session = Session(folderID: UUID(), agent: .claude, name: "A", order: 0, workdir: "/ws/server",
                              createdAt: WorkspaceStateFixture.referenceDate)
        #expect(session.conversationWorkdir == "/ws/server")
        #expect(try WorkspaceStateJSON.object(WorkspaceStateJSON.encode(session))["transcriptWorkdir"] == nil,
                "Absent unless set")

        session.transcriptWorkdir = "/ws/api"
        #expect(session.conversationWorkdir == "/ws/api")
        let object = try WorkspaceStateJSON.object(WorkspaceStateJSON.encode(session))
        #expect(object["transcriptWorkdir"] as? String == "/ws/api")
        #expect(try WorkspaceStateJSON.decode(Session.self, from: #"{"agent":"claude"}"#).transcriptWorkdir == nil,
                "Files predating it decode without one")
    }
}

// MARK: - WorkspaceState coding

struct WorkspaceStateCodingTests {
    @Test func initDefaultsToSchemaTwoWithNothingInIt() {
        let state = WorkspaceState()
        #expect(state.schemaVersion == 2)
        #expect(state.folders.isEmpty)
        #expect(state.sessions.isEmpty)
        #expect(state.expandedFolderIDs.isEmpty)
        #expect(state.archiveWatermarks.isEmpty)
        #expect(state.appliedMountSignatures.isEmpty)
        #expect(state.ignoredKitDrift.isEmpty)
        #expect(state.slugAgent == nil)
    }

    @Test(.tags(.workspaceStateLegacyFormat))
    func emptyObjectDecodesAsSchemaOne() throws {
        let state = try WorkspaceStateJSON.decode(WorkspaceState.self, from: "{}")
        #expect(state.schemaVersion == 1, "A file without schemaVersion predates schema 2")
        #expect(state.folders.isEmpty)
        #expect(state.sessions.isEmpty)
        #expect(state.expandedFolderIDs.isEmpty)
        #expect(state.archiveWatermarks.isEmpty)
        #expect(state.appliedMountSignatures.isEmpty)
        #expect(state.ignoredKitDrift.isEmpty)
    }

    @Test(.tags(.workspaceStateLegacyFormat))
    func legacyProjectKeysBecomeFolders() throws {
        let id = UUID()
        let json = #"""
            {"schemaVersion":1,
             "projects":[{"id":"\#(id.uuidString)","folderName":"alpha","order":2}],
             "expandedProjectIDs":["\#(id.uuidString)"]}
            """#
        let state = try WorkspaceStateJSON.decode(WorkspaceState.self, from: json)
        #expect(state.folders == [Folder(id: id, relativePath: "alpha", order: 2)])
        #expect(state.expandedFolderIDs == [id])
    }

    @Test(.tags(.workspaceStateLegacyFormat, .workspaceStateEdgeCase))
    func presentButEmptyCurrentKeysWinOverLegacyKeys() throws {
        let id = UUID()
        let json = #"""
            {"folders":[],"projects":[{"id":"\#(id.uuidString)","folderName":"alpha"}],
             "expandedFolderIDs":[],"expandedProjectIDs":["\#(id.uuidString)"]}
            """#
        let state = try WorkspaceStateJSON.decode(WorkspaceState.self, from: json)
        #expect(state.folders.isEmpty)
        #expect(state.expandedFolderIDs.isEmpty)
    }

    @Test func encodingAlwaysWritesCoreKeysButNotEmptyKitDrift() throws {
        let object = try WorkspaceStateJSON.object(WorkspaceStateJSON.encode(WorkspaceState()))
        let expectedKeys: Set<String> = ["schemaVersion", "folders", "sessions", "expandedFolderIDs",
                                         "archiveWatermarks", "appliedMountSignatures"]
        #expect(Set(object.keys) == expectedKeys, "Empty ignoredKitDrift and the legacy keys are omitted")
        #expect(object["schemaVersion"] as? Int == 2)
    }

    /// Sandboxes keep their names when the primary agent changes (xmas-sandshell-e7q.44).
    @Test(arguments: ["claude", "my-kit-agent"])
    func slugAgentPersistsWhenSet(agent: String) throws {
        let state = WorkspaceState(slugAgent: AgentKind(rawValue: agent))
        let object = try WorkspaceStateJSON.object(WorkspaceStateJSON.encode(state))
        #expect(object["slugAgent"] as? String == agent)
        #expect(try WorkspaceStateJSON.roundTrip(state).slugAgent == AgentKind(rawValue: agent))
    }

    /// The bare slug stays with the agent it was for when the primary agent changes,
    /// whether or not its sandbox exists yet (xmas-sandshell-e7q.44).
    @Test func theFirstPrimaryChangePinsTheSlugToTheOldPrimary() {
        var state = WorkspaceState()
        let first = state.pinSlugAgent(.claude)
        #expect(first)
        #expect(state.slugAgent == .claude)
        let second = state.pinSlugAgent(.codex)
        #expect(second == false, "A later change keeps the first pin")
        #expect(state.slugAgent == .claude)
    }

    @Test func encodingWritesIgnoredKitDriftWhenPresent() throws {
        let drift = ["sandshell-claude": ["kit-a", "kit-b"]]
        let object = try WorkspaceStateJSON.object(WorkspaceStateJSON.encode(WorkspaceState(ignoredKitDrift: drift)))
        #expect(object["ignoredKitDrift"] as? [String: [String]] == drift)
    }

    @Test func roundTripsEveryField() throws {
        let state = WorkspaceStateFixture.populatedState()
        let decoded = try WorkspaceStateJSON.roundTrip(state)
        WorkspaceStateFixture.expectSameState(decoded, state)
    }

    @Test(.tags(.workspaceStateEdgeCase), arguments: [0, 1, 7])
    func schemaVersionIsPreservedVerbatim(schemaVersion: Int) throws {
        let decoded = try WorkspaceStateJSON.roundTrip(WorkspaceState(schemaVersion: schemaVersion))
        #expect(decoded.schemaVersion == schemaVersion)
    }

    @Test(.tags(.workspaceStateEdgeCase), arguments: [
        #"{"schemaVersion":"two"}"#,
        #"{"folders":{}}"#,
        #"{"expandedFolderIDs":["nope"]}"#,
        #"{"archiveWatermarks":{"s":721692800}}"#,
        #"{"appliedMountSignatures":{"sandbox":1}}"#,
        #"{"ignoredKitDrift":{"sandbox":"kit-a"}}"#,
    ])
    func malformedTopLevelFieldsThrow(json: String) {
        #expect(throws: DecodingError.self) {
            try WorkspaceStateJSON.decode(WorkspaceState.self, from: json)
        }
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func oneUndecodableSessionFailsTheWholeState() {
        let json = #"{"sessions":[{"agent":"claude","name":"fine"},{"name":"no agent"}]}"#
        #expect(throws: DecodingError.self) {
            try WorkspaceStateJSON.decode(WorkspaceState.self, from: json)
        }
    }
}

// MARK: - Folder moves

/// Renaming a folder moves the rows nested in it and the sessions working in it
/// (xmas-sandshell-e7q.78); trashing one takes the nested rows too.
struct WorkspaceStateFolderMoveTests {
    private let root = URL(fileURLWithPath: "/ws", isDirectory: true)
    private let rootFolder = Folder(relativePath: "", order: -1)
    private let proj = Folder(relativePath: "proj", order: 0)
    private let web = Folder(relativePath: "proj/web", order: 1)
    private let deep = Folder(relativePath: "proj/web/deep", order: 2)
    private let sibling = Folder(relativePath: "proj-old", order: 3)
    private let other = Folder(relativePath: "other/proj", order: 4)

    private func session(_ name: String, in folder: Folder, workdir: String) -> Session {
        Session(folderID: folder.id, agent: .claude, name: name, order: 0, workdir: workdir,
                createdAt: WorkspaceStateFixture.referenceDate)
    }

    private func state(sessions: [Session] = []) -> WorkspaceState {
        WorkspaceState(folders: [rootFolder, proj, web, deep, sibling, other], sessions: sessions)
    }

    @Test(arguments: [
        ("/ws/api", "/ws/server"),                      // the folder itself
        ("/ws/api/src", "/ws/server/src"),              // inside it
        ("/ws/api/src/lib", "/ws/server/src/lib"),
    ])
    func aWorkdirInTheMovedFolderFollowsIt(workdir: String, expected: String) {
        #expect(Session.workdir(workdir, movedFrom: "/ws/api", to: "/ws/server") == expected)
    }

    @Test(.tags(.workspaceStateEdgeCase), arguments: ["/ws/api-v2", "/ws/apis", "/ws", "/elsewhere/api", ""])
    func aWorkdirOutsideItStays(workdir: String) {
        #expect(Session.workdir(workdir, movedFrom: "/ws/api", to: "/ws/server") == nil)
    }

    @Test func theRowsNestedInAFolderAreThoseUnderItsPath() {
        let nested = state().folders(nestedIn: proj.id)
        #expect(nested.map(\.id) == [web.id, deep.id], "Not proj-old, whose name only starts the same")
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func theRootAndUnknownFoldersHaveNoNestedRows() {
        #expect(state().folders(nestedIn: rootFolder.id).isEmpty, "Every folder is under the root: it isn't a nest")
        #expect(state().folders(nestedIn: UUID()).isEmpty)
    }

    @Test func movingAFolderMovesTheRowsNestedInIt() {
        var moved = state()
        moved.moveFolder(proj.id, to: "app", root: root)
        let paths = Dictionary(uniqueKeysWithValues: moved.folders.map { ($0.id, $0.relativePath) })
        #expect(paths[proj.id] == "app")
        #expect(paths[web.id] == "app/web")
        #expect(paths[deep.id] == "app/web/deep")
        #expect(paths[sibling.id] == "proj-old")
        #expect(paths[other.id] == "other/proj")
        #expect(paths[rootFolder.id] == "")
    }

    @Test func movingAFolderMovesTheSessionsWorkingInIt() {
        let inProj = session("proj", in: proj, workdir: "/ws/proj")
        let inWeb = session("web", in: web, workdir: "/ws/proj/web")
        let restored = session("restored", in: web, workdir: "/ws/proj/web/src")
        let inSibling = session("sibling", in: sibling, workdir: "/ws/proj-old")
        let elsewhere = session("elsewhere", in: proj, workdir: "/Users/test/other")
        var moved = state(sessions: [inProj, inWeb, restored, inSibling, elsewhere])

        moved.moveFolder(proj.id, to: "app", root: root)

        let workdirs = Dictionary(uniqueKeysWithValues: moved.sessions.map { ($0.name, $0.workdir) })
        #expect(workdirs["proj"] == "/ws/app")
        #expect(workdirs["web"] == "/ws/app/web", "A nested folder's sessions follow too")
        #expect(workdirs["restored"] == "/ws/app/web/src", "A session in a subdirectory keeps it")
        #expect(workdirs["sibling"] == "/ws/proj-old")
        #expect(workdirs["elsewhere"] == "/Users/test/other", "A cwd outside the folder didn't move")
    }

    /// A running agent keeps filing its conversation under the cwd it started in
    /// (xmas-sandshell-e7q.84): the session remembers it until its next launch.
    @Test func aRunningSessionRemembersTheCwdItsAgentFilesUnder() {
        let running = session("running", in: proj, workdir: "/ws/proj/src")
        let stopped = session("stopped", in: proj, workdir: "/ws/proj")
        var moved = state(sessions: [running, stopped])

        moved.moveFolder(proj.id, to: "app", root: root, running: [running.id])

        let byName = Dictionary(uniqueKeysWithValues: moved.sessions.map { ($0.name, $0) })
        #expect(byName["running"]?.workdir == "/ws/app/src")
        #expect(byName["running"]?.transcriptWorkdir == "/ws/proj/src")
        #expect(byName["running"]?.conversationWorkdir == "/ws/proj/src")
        #expect(byName["stopped"]?.transcriptWorkdir == nil, "Its conversation moved with the folder")
    }

    @Test func movingAgainWhileItRunsKeepsTheCwdItStartedIn() {
        let running = session("running", in: proj, workdir: "/ws/proj")
        var moved = state(sessions: [running])

        moved.moveFolder(proj.id, to: "app", root: root, running: [running.id])
        moved.moveFolder(proj.id, to: "server", root: root, running: [running.id])

        #expect(moved.sessions.first?.workdir == "/ws/server")
        #expect(moved.sessions.first?.transcriptWorkdir == "/ws/proj")
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func movingBackToTheCwdItStartedInForgetsIt() {
        let running = session("running", in: proj, workdir: "/ws/proj")
        var moved = state(sessions: [running])

        moved.moveFolder(proj.id, to: "app", root: root, running: [running.id])
        moved.moveFolder(proj.id, to: "proj", root: root)

        #expect(moved.sessions.first?.workdir == "/ws/proj")
        #expect(moved.sessions.first?.transcriptWorkdir == nil)
    }

    @Test(.tags(.workspaceStateEdgeCase), arguments: [true, false])
    func movingTheRootOrAnUnknownFolderChangesNothing(theRoot: Bool) {
        let inRoot = session("root", in: rootFolder, workdir: "/ws")
        var moved = state(sessions: [inRoot])
        moved.moveFolder(theRoot ? rootFolder.id : UUID(), to: "elsewhere", root: root)
        #expect(moved.folders == state().folders)
        #expect(moved.sessions == [inRoot])
    }
}

// MARK: - Paths

struct WorkspaceStatePathTests {
    private let root = URL(fileURLWithPath: "/Volumes/Work/my app", isDirectory: true)

    @Test func controlDirIsDotSandshellInsideTheRoot() {
        #expect(WorkspaceState.controlDir(root: root).path == "/Volumes/Work/my app/.sandshell")
    }

    @Test func stateFileLivesInTheControlDir() {
        #expect(WorkspaceState.stateURL(root: root).path == "/Volumes/Work/my app/.sandshell/state.json")
    }

    @Test func defaultRootIsSandshellInTheHomeDirectory() {
        // Only computes the URL; nothing under the home directory is touched.
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sandshell").path
        #expect(WorkspaceBootstrap.defaultRoot.path == expected)
    }
}

// MARK: - Persistence (save / load)

@Suite(.tags(.workspaceStateFileSystem))
struct WorkspaceStatePersistenceTests {
    private let scratch = WorkspaceStateScratchDirectory()
    private var root: URL { scratch.root }

    @Test func loadReturnsNilWhenTheRootDoesNotExist() throws {
        let loaded = try WorkspaceState.load(root: root)
        #expect(loaded == nil)
    }

    @Test func loadReturnsNilWhenThereIsNoStateFile() throws {
        try FileManager.default.createDirectory(at: WorkspaceState.controlDir(root: root),
                                                withIntermediateDirectories: true)
        let loaded = try WorkspaceState.load(root: root)
        #expect(loaded == nil)
    }

    @Test func saveCreatesMissingDirectories() throws {
        try WorkspaceState().save(root: root)
        #expect(WorkspaceStateFixture.directoryExists(at: WorkspaceState.controlDir(root: root)))
        #expect(FileManager.default.fileExists(atPath: WorkspaceState.stateURL(root: root).path))
    }

    @Test func saveThenLoadRoundTripsEveryField() throws {
        let state = WorkspaceStateFixture.populatedState()
        try state.save(root: root)
        let loadedState = try WorkspaceState.load(root: root)
        let loaded = try #require(loadedState)
        WorkspaceStateFixture.expectSameState(loaded, state)
    }

    @Test func saveWritesPrettyPrintedSortedKeysWithISO8601Dates() throws {
        try WorkspaceState(archiveWatermarks: ["s": WorkspaceStateFixture.referenceDate]).save(root: root)
        let text = try String(contentsOf: WorkspaceState.stateURL(root: root), encoding: .utf8)
        #expect(text.contains(WorkspaceStateFixture.referenceDateISO), "Dates are ISO-8601 strings")
        #expect(text.contains("\n"), "Output is pretty-printed")
        let applied = try #require(text.range(of: "appliedMountSignatures"))
        let schema = try #require(text.range(of: "schemaVersion"))
        #expect(applied.lowerBound < schema.lowerBound, "Keys are written in sorted order")
    }

    @Test func saveReplacesThePreviousState() throws {
        try WorkspaceStateFixture.populatedState().save(root: root)
        let replacement = WorkspaceState(folders: [Folder(relativePath: "", order: 0)])
        try replacement.save(root: root)
        let loadedState = try WorkspaceState.load(root: root)
        let loaded = try #require(loadedState)
        WorkspaceStateFixture.expectSameState(loaded, replacement)
    }

    @Test(.tags(.workspaceStateLegacyFormat))
    func loadMigratesLegacyKeysFromDisk() throws {
        let id = UUID()
        try WorkspaceStateFixture.writeStateFile(
            #"{"projects":[{"id":"\#(id.uuidString)","folderName":"alpha","order":0}]}"#, root: root)
        let loadedState = try WorkspaceState.load(root: root)
        let loaded = try #require(loadedState)
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.folders == [Folder(id: id, relativePath: "alpha", order: 0)])
    }

    @Test(.tags(.workspaceStateEdgeCase), arguments: ["", "{ not json", "[]"])
    func loadThrowsForAMalformedFile(contents: String) throws {
        try WorkspaceStateFixture.writeStateFile(contents, root: root)
        #expect(throws: DecodingError.self) {
            try WorkspaceState.load(root: root)
        }
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func loadRejectsNumericDates() throws {
        // `load` decodes ISO-8601 only; a file written with the default (numeric) date strategy fails.
        try WorkspaceStateFixture.writeStateFile(#"{"archiveWatermarks":{"s":721692800}}"#, root: root)
        #expect(throws: DecodingError.self) {
            try WorkspaceState.load(root: root)
        }
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func loadThrowsWhenStateFileIsADirectory() throws {
        try FileManager.default.createDirectory(at: WorkspaceState.stateURL(root: root),
                                                withIntermediateDirectories: true)
        do {
            _ = try WorkspaceState.load(root: root)
            Issue.record("Expected load to throw: state.json exists but is a directory")
        } catch {
            // Expected: the existence check passes but the read fails.
        }
    }
}

// MARK: - Bootstrap (openOrCreate)

@Suite(.tags(.workspaceStateFileSystem))
struct WorkspaceBootstrapTests {
    private let scratch = WorkspaceStateScratchDirectory()
    private var root: URL { scratch.root }
    private var gitignoreURL: URL { WorkspaceState.controlDir(root: root).appendingPathComponent(".gitignore") }
    private static let defaultGitignore = "state.json\nstatus/\nstatusline.sh\n"

    private func writeGitignore(_ contents: String) throws {
        try FileManager.default.createDirectory(at: WorkspaceState.controlDir(root: root),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: gitignoreURL)
    }

    private func readGitignore() throws -> String {
        try String(contentsOf: gitignoreURL, encoding: .utf8)
    }

    @Test func freshRootCreatesTheWorkspaceOnDisk() throws {
        try WorkspaceBootstrap.openOrCreate(root: root)
        #expect(WorkspaceStateFixture.directoryExists(at: root))
        #expect(WorkspaceStateFixture.directoryExists(at: WorkspaceState.controlDir(root: root)))
        #expect(FileManager.default.fileExists(atPath: WorkspaceState.stateURL(root: root).path))
        #expect(FileManager.default.fileExists(atPath: gitignoreURL.path))
    }

    @Test func freshRootSeedsOneExpandedRootFolder() throws {
        let state = try WorkspaceBootstrap.openOrCreate(root: root)
        #expect(state.schemaVersion == 2)
        #expect(state.sessions.isEmpty)
        #expect(state.folders.count == 1)
        let rootFolder = try #require(state.folders.first)
        #expect(rootFolder.isRoot)
        #expect(rootFolder.order == -1, "min(order) over no folders is 0, and the root goes one below it")
        #expect(state.expandedFolderIDs == [rootFolder.id])
    }

    @Test func freshRootPersistsTheStateItReturns() throws {
        let state = try WorkspaceBootstrap.openOrCreate(root: root)
        let loadedState = try WorkspaceState.load(root: root)
        let loaded = try #require(loadedState)
        WorkspaceStateFixture.expectSameState(loaded, state)
    }

    @Test func freshRootWritesTheDefaultGitignore() throws {
        try WorkspaceBootstrap.openOrCreate(root: root)
        #expect(try readGitignore() == Self.defaultGitignore)
    }

    @Test func reopeningIsIdempotent() throws {
        let first = try WorkspaceBootstrap.openOrCreate(root: root)
        let gitignoreAfterFirst = try readGitignore()
        let second = try WorkspaceBootstrap.openOrCreate(root: root)
        #expect(second.folders == first.folders, "No second root folder, same id and order")
        #expect(second.expandedFolderIDs == first.expandedFolderIDs)
        #expect(second.schemaVersion == 2)
        #expect(try readGitignore() == gitignoreAfterFirst)
    }

    @Test(arguments: [
        ("", "state.json\nstatus/\nstatusline.sh\n"),
        ("node_modules", "node_modules\nstate.json\nstatus/\nstatusline.sh\n"),
        ("node_modules\n", "node_modules\nstate.json\nstatus/\nstatusline.sh\n"),
        ("state.json\n", "state.json\nstatus/\nstatusline.sh\n"),
        ("status/\n", "status/\nstate.json\nstatusline.sh\n"),
        ("status\n", "status\nstate.json\nstatus/\nstatusline.sh\n"),
    ])
    func existingGitignoreGainsOnlyMissingEntries(existing: String, expected: String) throws {
        try writeGitignore(existing)
        try WorkspaceBootstrap.openOrCreate(root: root)
        #expect(try readGitignore() == expected)
    }

    @Test(arguments: [
        "state.json\nstatus/\nstatusline.sh\n",
        "statusline.sh\nstatus/\nstate.json",
        "# Sandshell\n  state.json\t\nstatus/ \nstatusline.sh\n*.log\n",
    ])
    func gitignoreListingEveryEntryIsLeftUntouched(existing: String) throws {
        try writeGitignore(existing)
        try WorkspaceBootstrap.openOrCreate(root: root)
        #expect(try readGitignore() == existing, "Entries match after trimming spaces and tabs, in any order")
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func crlfGitignoreListingEveryEntryIsLeftUntouched() throws {
        let existing = "state.json\r\nstatus/\r\nstatusline.sh\r\n"
        try writeGitignore(existing)
        try WorkspaceBootstrap.openOrCreate(root: root)
        let contents = try readGitignore()
        withKnownIssue("""
            openOrCreate splits .gitignore with split(separator: "\\n"), but "\\r\\n" is a single Swift \
            Character, so CRLF lines never match and all three entries are appended again.
            """) {
            #expect(contents == existing)
        }
    }

    @Test(arguments: [
        ([0, 3], -1),
        ([5, 2], 1),
        ([-3, 7], -4),
    ])
    func missingRootFolderIsInsertedFirstBelowTheLowestOrder(orders: [Int], expectedRootOrder: Int) throws {
        let folders = orders.enumerated().map { Folder(relativePath: "folder-\($0.offset)", order: $0.element) }
        let expandedID = try #require(folders.first?.id)
        try WorkspaceState(folders: folders, expandedFolderIDs: [expandedID]).save(root: root)

        let state = try WorkspaceBootstrap.openOrCreate(root: root)

        let rootFolder = try #require(state.folders.first)
        #expect(rootFolder.isRoot)
        #expect(rootFolder.order == expectedRootOrder)
        #expect(Array(state.folders.dropFirst()) == folders, "Existing folders keep their ids, order and position")
        #expect(state.expandedFolderIDs == [expandedID, rootFolder.id], "The new root is appended as expanded")
    }

    @Test func existingRootFolderIsKeptAsIs() throws {
        let other = Folder(relativePath: "alpha", order: 1)
        let rootFolder = Folder(relativePath: "", order: 4)
        try WorkspaceState(folders: [other, rootFolder], expandedFolderIDs: [other.id]).save(root: root)

        let state = try WorkspaceBootstrap.openOrCreate(root: root)

        #expect(state.folders == [other, rootFolder], "No second root, and nothing is reordered")
        #expect(state.expandedFolderIDs == [other.id], "A collapsed root stays collapsed")
    }

    @Test func createsDirectoriesForNonRootFolders() throws {
        let folders = [
            Folder(relativePath: "", order: 0),
            Folder(relativePath: "alpha", order: 1),
            Folder(relativePath: "nested/deep/beta", order: 2),
        ]
        try WorkspaceState(folders: folders).save(root: root)

        try WorkspaceBootstrap.openOrCreate(root: root)

        #expect(WorkspaceStateFixture.directoryExists(at: root.appendingPathComponent("alpha", isDirectory: true)))
        #expect(WorkspaceStateFixture.directoryExists(
            at: root.appendingPathComponent("nested/deep/beta", isDirectory: true)))
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func aFolderDirectoryThatCannotBeCreatedIsSkipped() throws {
        let folders = [Folder(relativePath: "", order: 0), Folder(relativePath: "blocked", order: 1)]
        try WorkspaceState(folders: folders).save(root: root)
        let blocker = root.appendingPathComponent("blocked", isDirectory: false)
        try Data("not a directory".utf8).write(to: blocker)

        let state = try WorkspaceBootstrap.openOrCreate(root: root)

        #expect(state.folders == folders, "The folder row survives even though its directory can't be made")
        #expect(WorkspaceStateFixture.directoryExists(at: blocker) == false, "The file in the way is left alone")
    }

    @Test(.tags(.workspaceStateLegacyFormat))
    func schemaOneSessionsAreStampedInTheOldTreeOrder() throws {
        let rootFolder = Folder(relativePath: "", order: 0)
        let one = Folder(relativePath: "one", order: 2)
        let two = Folder(relativePath: "two", order: 1)
        func session(_ name: String, in folder: Folder, order: Int) -> Session {
            Session(folderID: folder.id, agent: .claude, name: name, order: order, workdir: "/workspace",
                    createdAt: WorkspaceStateFixture.referenceDate)
        }
        let a = session("a", in: one, order: 1)
        let b = session("b", in: one, order: 0)
        let c = session("c", in: rootFolder, order: 0)
        let d = session("d", in: two, order: 3)
        let e = session("e", in: two, order: 1)
        try WorkspaceState(schemaVersion: 1, folders: [rootFolder, one, two], sessions: [a, b, c, d, e]).save(root: root)

        let state = try WorkspaceBootstrap.openOrCreate(root: root)

        #expect(state.schemaVersion == 2)
        #expect(state.sessions.map(\.id) == [a, b, c, d, e].map(\.id), "Only dates change; the array isn't reordered")
        let allRestamped = state.sessions.allSatisfy { $0.createdAt > WorkspaceStateFixture.referenceDate }
        #expect(allRestamped, "Every session in a known folder gets a synthetic createdAt")
        let newestFirst = state.sessions.sorted { $0.createdAt > $1.createdAt }
        #expect(newestFirst.map(\.name) == ["c", "e", "d", "b", "a"],
                "Folders by order (root 0, two 1, one 2), then sessions by order within each")
        let gaps = zip(newestFirst, newestFirst.dropFirst()).map { $0.createdAt.timeIntervalSince($1.createdAt) }
        let oneSecondApart = gaps.allSatisfy { abs($0 - 1) < 0.001 }
        #expect(oneSecondApart, "Synthetic timestamps are one second apart: \(gaps)")
        let persisted = try WorkspaceState.load(root: root)
        #expect(persisted?.schemaVersion == 2, "The migration is saved")
    }

    @Test(.tags(.workspaceStateLegacyFormat, .workspaceStateEdgeCase))
    func schemaOneSessionInAnUnknownFolderKeepsItsCreatedAt() throws {
        let rootFolder = Folder(relativePath: "", order: 0)
        let orphan = Session(folderID: UUID(), agent: .codex, name: "orphan", order: 0, workdir: "/workspace",
                             createdAt: WorkspaceStateFixture.referenceDate)
        try WorkspaceState(schemaVersion: 1, folders: [rootFolder], sessions: [orphan]).save(root: root)

        let state = try WorkspaceBootstrap.openOrCreate(root: root)

        let migrated = try #require(state.sessions.first)
        #expect(migrated.createdAt == WorkspaceStateFixture.referenceDate)
        #expect(state.schemaVersion == 2)
    }

    @Test(arguments: [2, 3])
    func schemaTwoOrLaterKeepsSessionDates(schemaVersion: Int) throws {
        let rootFolder = Folder(relativePath: "", order: 0)
        let session = Session(folderID: rootFolder.id, agent: .claude, name: "s", order: 0, workdir: "/workspace",
                              createdAt: WorkspaceStateFixture.referenceDate)
        try WorkspaceState(schemaVersion: schemaVersion, folders: [rootFolder], sessions: [session]).save(root: root)

        let state = try WorkspaceBootstrap.openOrCreate(root: root)

        #expect(state.schemaVersion == schemaVersion)
        #expect(state.sessions == [session])
    }

    @Test(.tags(.workspaceStateLegacyFormat))
    func legacyProjectsFileMigratesEndToEnd() throws {
        let projectID = UUID()
        let sessionID = UUID()
        try WorkspaceStateFixture.writeStateFile(#"""
            {
              "projects": [{"id": "\#(projectID.uuidString)", "folderName": "alpha", "order": 0}],
              "expandedProjectIDs": ["\#(projectID.uuidString)"],
              "sessions": [{
                "id": "\#(sessionID.uuidString)",
                "projectID": "\#(projectID.uuidString)",
                "agent": "claude", "name": "One", "order": 0, "workdir": "/workspace/alpha"
              }]
            }
            """#, root: root)

        let state = try WorkspaceBootstrap.openOrCreate(root: root)

        #expect(state.schemaVersion == 2)
        #expect(state.folders.map(\.relativePath) == ["", "alpha"])
        let rootFolder = try #require(state.folders.first)
        #expect(rootFolder.order == -1)
        #expect(state.expandedFolderIDs == [projectID, rootFolder.id])
        let session = try #require(state.sessions.first)
        #expect(session.id == sessionID)
        #expect(session.folderID == projectID)
        #expect(session.createdAt != .distantPast, "Migration stamps a real creation time")
        #expect(WorkspaceStateFixture.directoryExists(at: root.appendingPathComponent("alpha", isDirectory: true)))
        let saved = try String(contentsOf: WorkspaceState.stateURL(root: root), encoding: .utf8)
        #expect(saved.contains("\"folders\""))
        #expect(saved.contains("\"projects\"") == false, "The file is rewritten in the current format")
    }

    @Test(.tags(.workspaceStateEdgeCase), arguments: [
        "",
        "{ not json",
        #"{"sessions":[{"name":"no agent"}]}"#,
    ])
    func undecodableStateFileIsReplacedWithAFreshState(contents: String) throws {
        // Documents current behavior: `try?` swallows the decode error and the file is overwritten.
        try WorkspaceStateFixture.writeStateFile(contents, root: root)

        let state = try WorkspaceBootstrap.openOrCreate(root: root)

        #expect(state.folders.count == 1)
        #expect(state.folders.first?.isRoot == true)
        #expect(state.sessions.isEmpty)
        let reloaded = try WorkspaceState.load(root: root)
        #expect(reloaded?.folders == state.folders, "The unreadable file was overwritten with the fresh state")
    }

    @Test(.tags(.workspaceStateEdgeCase))
    func rootThatIsARegularFileThrows() throws {
        try FileManager.default.createDirectory(at: scratch.base, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: scratch.base.appendingPathComponent("workspace", isDirectory: false))
        do {
            try WorkspaceBootstrap.openOrCreate(root: root)
            Issue.record("Expected openOrCreate to throw when the root path is a regular file")
        } catch {
            // Expected: the root can't be created as a directory.
        }
        #expect(WorkspaceStateFixture.directoryExists(at: root) == false)
    }
}
