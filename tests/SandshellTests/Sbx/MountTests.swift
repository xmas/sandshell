import Foundation
import Testing
@testable import Sandshell

// Tests for `MountSpec` (Sbx/Workspace.swift), `Workspace`'s defaults, and
// `MountPolicy` (Sbx/MountPolicy.swift).
//
// Pure tests use absolute paths under top-level folders that don't exist
// (`/srv`, `/sandshell-home`), so `URL(fileURLWithPath:)` never finds a real
// directory. Filesystem tests run in a fresh temporary directory per test,
// with a fake `$HOME` inside it.

extension Tag {
    @Tag static var mountEdgeCase: Self
    @Tag static var mountFileSystem: Self
}

// MARK: - MountSpec

struct MountSpecTests {
    @Test("A path without a suffix parses as a read-write mount", arguments: [
        "/srv/data",
        "/srv/My Folder/Work",
        "/srv/data/nested/deeper",
    ])
    func plainPathIsReadWrite(spec: String) {
        let mount = MountSpec(spec: spec)
        #expect(mount.path.path == spec)
        #expect(mount.readonly == false)
    }

    @Test("A trailing :ro suffix marks the mount read-only and is stripped from the path", arguments: [
        ("/srv/data:ro", "/srv/data"),
        ("/srv/My Folder:ro", "/srv/My Folder"),
        ("/srv/data/:ro", "/srv/data"),
        ("/srv/data:ro:ro", "/srv/data:ro"),
    ])
    func readOnlySuffixIsParsed(spec: String, expectedPath: String) {
        let mount = MountSpec(spec: spec)
        #expect(mount.readonly, "\(spec) ends in :ro")
        #expect(mount.path.path == expectedPath, "exactly one trailing :ro is removed")
    }

    @Test("Anything other than an exact trailing :ro stays part of a read-write path",
          .tags(.mountEdgeCase),
          arguments: [
              "/srv/data:RO",
              "/srv/data:rw",
              "/srv/data:ro/sub",
              "/srv/data-ro",
              "/srv/dataro",
          ])
    func nearMissSuffixStaysInPath(spec: String) {
        let mount = MountSpec(spec: spec)
        #expect(mount.readonly == false, "only an exact, lowercase trailing :ro means read-only")
        #expect(mount.path.path == spec)
    }

    @Test func pathInitializerDefaultsToReadWrite() {
        let mount = MountSpec(path: URL(fileURLWithPath: "/srv/data"))
        #expect(mount.readonly == false)
        #expect(mount.spec == "/srv/data")
    }

    @Test(arguments: [false, true])
    func specRendersReadOnlySuffixOnlyWhenReadOnly(readonly: Bool) {
        let mount = MountSpec(path: URL(fileURLWithPath: "/srv/My Folder"), readonly: readonly)
        #expect(mount.spec == (readonly ? "/srv/My Folder:ro" : "/srv/My Folder"))
    }

    @Test("Parsing then rendering gives back the same string", arguments: [
        "/srv/data",
        "/srv/data:ro",
        "/srv/My Folder:ro",
        "/srv/data:ro:ro",
        "/",
        "/:ro",
    ])
    func specRoundTrips(spec: String) {
        #expect(MountSpec(spec: spec).spec == spec)
    }

    @Test("A trailing slash on the path is dropped when rendering", .tags(.mountEdgeCase), arguments: [
        ("/srv/data/", "/srv/data"),
        ("/srv/data/:ro", "/srv/data:ro"),
    ])
    func trailingSlashIsDroppedWhenRendering(spec: String, expected: String) {
        #expect(MountSpec(spec: spec).spec == expected)
    }

    @Test func parsedSpecEqualsTheEquivalentPathSpec() {
        let parsed = MountSpec(spec: "/srv/data:ro")
        let built = MountSpec(path: URL(fileURLWithPath: "/srv/data"), readonly: true)
        #expect(parsed == built)
    }

    @Test func idIsTheRenderedSpec() {
        let readOnly = MountSpec(path: URL(fileURLWithPath: "/srv/data"), readonly: true)
        let readWrite = MountSpec(path: URL(fileURLWithPath: "/srv/data"), readonly: false)
        #expect(readOnly.id == "/srv/data:ro")
        #expect(readWrite.id == "/srv/data")
        #expect(readOnly.id != readWrite.id, "the same folder ro and rw must be distinct rows")
    }

    @Test func readOnlyFlagIsPartOfIdentity() {
        // Built from an array: a Set literal with duplicate elements is not
        // guaranteed to be accepted.
        let mounts = Set([
            MountSpec(spec: "/srv/data"),
            MountSpec(spec: "/srv/data"),
            MountSpec(spec: "/srv/data:ro"),
        ])
        #expect(mounts.count == 2, "equal rw specs collapse; the ro spec of the same folder stays distinct")
    }

    @Test func codableRoundTripPreservesValue() throws {
        let original = MountSpec(path: URL(fileURLWithPath: "/srv/My Folder"), readonly: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MountSpec.self, from: data)
        #expect(decoded == original)
        #expect(decoded.spec == "/srv/My Folder:ro")
    }

    // MARK: shortPath(home:)

    @Test("shortPath collapses the home folder to ~", arguments: [
        ("/sandshell-home/me", "~"),
        ("/sandshell-home/me/", "~"),
        ("/sandshell-home/me/Documents", "~/Documents"),
        ("/sandshell-home/me/a/b c", "~/a/b c"),
        ("/sandshell-home/meadow", "/sandshell-home/meadow"),
        ("/sandshell-home", "/sandshell-home"),
        ("/srv/data", "/srv/data"),
    ])
    func shortPathCollapsesHome(path: String, expected: String) {
        let mount = MountSpec(path: URL(fileURLWithPath: path))
        #expect(mount.shortPath(home: "/sandshell-home/me") == expected)
    }

    @Test func shortPathOmitsTheReadOnlySuffix() {
        let mount = MountSpec(spec: "/sandshell-home/me/Documents:ro")
        #expect(mount.shortPath(home: "/sandshell-home/me") == "~/Documents")
    }
}

// MARK: - Workspace

struct MountWorkspaceTests {
    let workspace = Workspace(rootURL: URL(fileURLWithPath: "/srv/project"), containerName: "project")

    @Test func initializerDefaults() {
        #expect(workspace.rootURL.path == "/srv/project")
        #expect(workspace.containerName == "project")
        #expect(workspace.policy == MountPolicy())
        #expect(workspace.mcpServers.isEmpty)
        #expect(workspace.mcpURL == Workspace.defaultMCPURL)
        #expect(workspace.primaryAgent == AgentKind.claude)
        #expect(workspace.kits.isEmpty)
        #expect(workspace.imageChannel == ImageChannel.stable)
        #expect(workspace.customImage.isEmpty)
    }

    @Test func defaultMCPURLIsDockerGateway() {
        #expect(Workspace.defaultMCPURL.absoluteString == "https://gateway.docker.com")
    }

    @Test("templateImage uses the workspace's channel and custom image", arguments: [
        (ImageChannel.stable, nil),
        (ImageChannel.nightly, "docker/sandbox-templates:claude-code-docker-nightly"),
        (ImageChannel.custom, "registry.example/sandbox:1"),
    ] as [(ImageChannel, String?)])
    func templateImageFollowsChannel(channel: ImageChannel, expected: String?) {
        var sut = workspace
        sut.imageChannel = channel
        sut.customImage = "  registry.example/sandbox:1 \n"
        #expect(sut.templateImage(for: .claude) == expected)
    }

    @Test(arguments: ImageChannel.allCases)
    func templateImageIsNilForCustomAgents(channel: ImageChannel) {
        var sut = workspace
        sut.imageChannel = channel
        sut.customImage = "registry.example/sandbox:1"
        #expect(sut.templateImage(for: AgentKind(rawValue: "my-kit-agent")) == nil,
                "-t would replace a kit agent's own image")
    }
}

// MARK: - MountPolicy (no filesystem)

struct MountPolicyTests {
    @Test func defaultPolicyHasNoSelections() {
        #expect(MountPolicy().selections.isEmpty)
    }

    @Test func mountLimitIsTheSbxCap() {
        #expect(MountPolicy.mountLimit == 24)
    }

    @Test func agentMountsAreReadWriteInFixedOrder() {
        let expectedSeeds: [MountPolicy.AgentMount.Seed] = [.directory, .directory, .ifPresent]
        #expect(MountPolicy.agentMounts.map(\.subpath) == [".agents", ".claude", ".codex"])
        #expect(MountPolicy.agentMounts.map(\.seed) == expectedSeeds)
        #expect(MountPolicy.agentMounts.allSatisfy { $0.readonly == false })
    }

    @Test func defaultReadOnlyFoldersAreTheCommonHomeFolders() {
        #expect(MountPolicy.defaultReadOnlyFolders == ["Downloads", "Documents", "Pictures", "Desktop"])
    }

    @Test func codableRoundTripPreservesSelectionsAndOrder() throws {
        let policy = MountPolicy(selections: [
            MountSpec(spec: "/srv/My Folder:ro"),
            MountSpec(spec: "/srv/work"),
            MountSpec(spec: "/srv/archive:ro"),
        ])
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(MountPolicy.self, from: data)
        #expect(decoded == policy)
    }

    @Test("Decodes the policy shape stored in config.json")
    func decodesPersistedJSON() throws {
        let json = #"""
        {"selections":[
          {"path":"file:///srv/Documents/","readonly":true},
          {"path":"file:///srv/Work%20Stuff","readonly":false}
        ]}
        """#
        let policy = try JSONDecoder().decode(MountPolicy.self, from: Data(json.utf8))
        #expect(policy.selections.map(\.spec) == ["/srv/Documents:ro", "/srv/Work Stuff"])
    }
}

// MARK: - MountPolicy (filesystem)

/// Each test gets its own scratch folder holding a fake home and a workspace
/// root; `deinit` removes it.
@Suite(.tags(.mountFileSystem))
final class MountPolicyFileSystemTests {
    let scratch: URL
    let home: URL
    let root: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandshellMountTests-\(UUID().uuidString)", isDirectory: true)
        home = scratch.appendingPathComponent("home", isDirectory: true)
        root = scratch.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Helpers

    func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A new folder directly inside the scratch folder.
    func makeFolder(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try makeDirectory(url)
        return url
    }

    func homePath(_ subpath: String) -> String {
        home.appendingPathComponent(subpath).path
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: agentMountSpecs(home:)

    @Test func agentMountSpecsListsSeededDirsButSkipsMissingCodex() {
        let specs = MountPolicy.agentMountSpecs(home: home)
        #expect(specs.map(\.path.path) == [homePath(".agents"), homePath(".claude")])
        #expect(specs.allSatisfy { $0.readonly == false })
    }

    @Test func agentMountSpecsIncludesCodexWhenPresent() throws {
        try makeDirectory(home.appendingPathComponent(".codex"))
        let specs = MountPolicy.agentMountSpecs(home: home)
        #expect(specs.map(\.spec) == [homePath(".agents"), homePath(".claude"), homePath(".codex")])
    }

    @Test func agentMountSpecsCreatesNothing() {
        _ = MountPolicy.agentMountSpecs(home: home)
        #expect(exists(homePath(".agents")) == false, "agentMountSpecs is documented as side-effect free")
        #expect(exists(homePath(".claude")) == false)
    }

    @Test("A regular file named ~/.codex is not mounted", .tags(.mountEdgeCase))
    func agentMountSpecsSkipsACodexFile() throws {
        try Data("not a folder".utf8).write(to: home.appendingPathComponent(".codex"))

        let paths = MountPolicy.agentMountSpecs(home: home).map(\.path.path)
        let seededOnly = [homePath(".agents"), homePath(".claude")]

        #expect(paths == seededOnly, "`sbx create` accepts only folders")
    }

    @Test("A link at ~/.codex to a folder is mounted", .tags(.mountEdgeCase))
    func agentMountSpecsFollowsACodexLink() throws {
        let target = try makeFolder("codex-home")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex"), withDestinationURL: target)

        let paths = MountPolicy.agentMountSpecs(home: home).map(\.path.path)

        #expect(paths == [homePath(".agents"), homePath(".claude"), homePath(".codex")])
    }

    // MARK: seedAgentMounts(home:)

    @Test func seedCreatesOnlyTheDirectoryMounts() {
        MountPolicy.seedAgentMounts(home: home)
        #expect(isDirectory(home.appendingPathComponent(".agents")))
        #expect(isDirectory(home.appendingPathComponent(".claude")))
        #expect(exists(homePath(".codex")) == false, ".codex is mounted only if present, never created")
    }

    @Test func seedIsIdempotentAndKeepsExistingContents() throws {
        let claude = home.appendingPathComponent(".claude")
        try makeDirectory(claude)
        let settings = claude.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings)

        MountPolicy.seedAgentMounts(home: home)
        MountPolicy.seedAgentMounts(home: home)

        #expect(FileManager.default.contents(atPath: settings.path) == Data("{}".utf8))
        #expect(isDirectory(home.appendingPathComponent(".agents")))
    }

    @Test func seedCreatesAMissingHomeFolder() {
        let missingHome = scratch.appendingPathComponent("not-yet/home")
        MountPolicy.seedAgentMounts(home: missingHome)
        #expect(isDirectory(missingHome.appendingPathComponent(".agents")))
        #expect(isDirectory(missingHome.appendingPathComponent(".claude")))
    }

    @Test(.tags(.mountEdgeCase))
    func seedLeavesAFileInPlaceAndStillSeedsTheRest() throws {
        let agents = home.appendingPathComponent(".agents")
        try Data("not a folder".utf8).write(to: agents)

        MountPolicy.seedAgentMounts(home: home)

        #expect(isDirectory(agents) == false)
        #expect(FileManager.default.contents(atPath: agents.path) == Data("not a folder".utf8))
        #expect(isDirectory(home.appendingPathComponent(".claude")), "one failed seed must not stop the next")
    }

    // MARK: makeDefault(home:)

    @Test("makeDefault keeps the common folders that exist, read-only, in a fixed order", arguments: [
        ([], []),
        (["Desktop", "Music", "Downloads"], ["Downloads", "Desktop"]),
        (["Desktop", "Pictures", "Documents", "Downloads"], ["Downloads", "Documents", "Pictures", "Desktop"]),
    ] as [([String], [String])])
    func makeDefaultKeepsExistingCommonFolders(existing: [String], expected: [String]) throws {
        for name in existing {
            try makeDirectory(home.appendingPathComponent(name))
        }

        let specs = MountPolicy.makeDefault(home: home).selections.map(\.spec)
        let expectedSpecs = expected.map { homePath($0) + ":ro" }

        #expect(specs == expectedSpecs,
                "order follows defaultReadOnlyFolders, not creation order; other folders are ignored")
    }

    @Test("makeDefault skips a common folder name that is a file", .tags(.mountEdgeCase))
    func makeDefaultSkipsFiles() throws {
        try Data("not a folder".utf8).write(to: home.appendingPathComponent("Downloads"))
        try makeDirectory(home.appendingPathComponent("Desktop"))

        let specs = MountPolicy.makeDefault(home: home).selections.map(\.spec)

        #expect(specs == [homePath("Desktop") + ":ro"])
    }

    // MARK: resolved(home:root:)

    @Test func resolvedOrdersRootThenAgentMountsThenSelections() throws {
        let docs = try makeFolder("Docs")
        let work = try makeFolder("Work")
        let policy = MountPolicy(selections: [MountSpec(path: docs, readonly: true), MountSpec(path: work)])

        let result = policy.resolved(home: home, root: root)

        #expect(result.mounts.map(\.spec) == [
            root.path,
            homePath(".agents"),
            homePath(".claude"),
            docs.path + ":ro",
            work.path,
        ])
        #expect(result.dropped.isEmpty)
    }

    @Test func resolvedSeedsTheAgentDirectories() {
        _ = MountPolicy().resolved(home: home, root: root)
        #expect(isDirectory(home.appendingPathComponent(".agents")))
        #expect(isDirectory(home.appendingPathComponent(".claude")))
    }

    @Test func resolvedPlacesAnExistingCodexAfterClaude() throws {
        try makeDirectory(home.appendingPathComponent(".codex"))
        let extra = try makeFolder("Extra")

        let mounts = MountPolicy(selections: [MountSpec(path: extra)]).resolved(home: home, root: root).mounts

        #expect(mounts.map(\.path.path) == [
            root.path, homePath(".agents"), homePath(".claude"), homePath(".codex"), extra.path,
        ])
    }

    @Test func resolvedSkipsMissingSelectionsWithoutReportingThem() throws {
        let present = try makeFolder("Present")
        let missing = scratch.appendingPathComponent("Missing")
        let policy = MountPolicy(selections: [MountSpec(path: missing, readonly: true), MountSpec(path: present)])

        let result = policy.resolved(home: home, root: root)

        #expect(result.mounts.map(\.path.path) == [root.path, homePath(".agents"), homePath(".claude"), present.path])
        #expect(result.dropped.isEmpty, "dropped lists only what the cap cut")
    }

    @Test(.tags(.mountEdgeCase))
    func resolvedSkipsAMissingRoot() {
        let missingRoot = scratch.appendingPathComponent("gone")
        let mounts = MountPolicy().resolved(home: home, root: missingRoot).mounts
        #expect(mounts.map(\.path.path) == [homePath(".agents"), homePath(".claude")])
    }

    @Test("The root is mounted once, read-write, however a selection spells it",
          .tags(.mountEdgeCase), arguments: [false, true])
    func resolvedNeverDuplicatesTheRoot(readonly: Bool) throws {
        let spellings = [
            root,
            URL(fileURLWithPath: root.path + "/"),
            URL(fileURLWithPath: root.path + "/sub/.."),
        ]
        let policy = MountPolicy(selections: spellings.map { MountSpec(path: $0, readonly: readonly) })

        let mounts = policy.resolved(home: home, root: root).mounts

        let first = try #require(mounts.first)
        #expect(first.path.path == root.path)
        #expect(first.readonly == false, "the workspace root is always read-write")
        let rootPath = root.standardizedFileURL.path
        #expect(mounts.filter { $0.path.standardizedFileURL.path == rootPath }.count == 1)
        #expect(mounts.count == 3, "only the root, .agents and .claude")
    }

    @Test func selectionDuplicatingAnAgentMountKeepsTheAgentMount() {
        let claudeReadOnly = MountSpec(path: home.appendingPathComponent(".claude"), readonly: true)

        let mounts = MountPolicy(selections: [claudeReadOnly]).resolved(home: home, root: root).mounts

        #expect(mounts.map(\.spec) == [root.path, homePath(".agents"), homePath(".claude")],
                "~/.claude stays read-write and appears once")
    }

    @Test(.tags(.mountEdgeCase))
    func duplicateSelectionsKeepTheFirstSpelling() throws {
        let shared = try makeFolder("Shared")
        let selections = [
            MountSpec(path: shared, readonly: true),
            MountSpec(path: URL(fileURLWithPath: shared.path + "/"), readonly: false),
            MountSpec(path: URL(fileURLWithPath: scratch.path + "/elsewhere/../Shared"), readonly: false),
        ]

        let mounts = MountPolicy(selections: selections).resolved(home: home, root: root).mounts

        #expect(mounts.count == 4, "the root, .agents, .claude and one Shared")
        #expect(mounts.last == selections[0], "the first spelling, read-only, wins")
    }

    /// Root + `.agents` + `.claude` are 3 essentials, so 21 selections fill
    /// the 24-mount cap exactly and each one beyond it is dropped.
    @Test("The cap keeps the first 24 mounts and reports the rest, in order",
          arguments: [(1, 0), (21, 0), (22, 1), (30, 9)])
    func resolvedCapsAtTheMountLimit(selectionCount: Int, expectedDropped: Int) throws {
        let selections = try (0..<selectionCount).map { index in
            let folder = try makeFolder("selection-\(index)")
            return MountSpec(path: folder, readonly: index.isMultiple(of: 2))
        }

        let result = MountPolicy(selections: selections).resolved(home: home, root: root)

        #expect(result.mounts.count == 3 + selectionCount - expectedDropped)
        #expect(result.mounts.count <= MountPolicy.mountLimit)
        #expect(result.mounts.prefix(3).map(\.path.path) == [root.path, homePath(".agents"), homePath(".claude")],
                "essentials are never dropped")
        #expect(Array(result.mounts.dropFirst(3)) == Array(selections.prefix(selectionCount - expectedDropped)))
        #expect(result.dropped == Array(selections.suffix(expectedDropped)))
    }

    @Test("A regular file in the selections is not mounted", .tags(.mountEdgeCase))
    func resolvedSkipsRegularFiles() throws {
        let file = scratch.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)
        let folder = try makeFolder("Folder")
        let policy = MountPolicy(selections: [MountSpec(path: file, readonly: true), MountSpec(path: folder)])

        let mounts = policy.resolved(home: home, root: root).mounts
        let mountsTheFile = mounts.contains(where: { $0.path.path == file.path })

        #expect(mounts.last?.path.path == folder.path, "the folder after the file is still mounted")
        #expect(mountsTheFile == false, "`sbx create` rejects a file mount and fails the whole create")
    }
}
