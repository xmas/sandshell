import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Windows closing mid-flight, lone observers, released stores. Named for
    /// this file (and fileprivate) so it can't clash with another suite's tag.
    @Tag fileprivate static var workspaceStoreEdgeCase: Self
    /// Tests that read or write a per-test scratch workspace.
    @Tag fileprivate static var workspaceStoreFileSystem: Self
}

// MARK: - Fixtures

fileprivate enum WorkspaceStoreFixture {
    /// 2023-11-14T22:13:20Z: a whole second, so it survives `state.json`'s ISO-8601 dates exactly.
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// A config with values off their defaults, so a loaded one is recognisably this one.
    static func config(primaryAgent: AgentKind = .codex) -> WorkspaceConfig {
        WorkspaceConfig(
            policy: MountPolicy(),
            mcpServers: ["github"],
            primaryAgent: primaryAgent,
            configured: true,
            archiveInterval: 600,
            kits: ["docker.io/example/store-test-kit:1"],
            claudeModel: "opus")
    }

    static func session(in folder: Folder, name: String = "Refactor") -> Session {
        Session(folderID: folder.id, agent: .claude, name: name, order: 0,
                workdir: "/workspace", transcriptID: "transcript-\(name)",
                createdAt: referenceDate, isChat: true)
    }

    /// Waits until the main queue has run everything already on it — including
    /// the store's coalesced notification, which a write queues with
    /// `DispatchQueue.main.async`. The main queue is serial, so a block queued
    /// after that flush runs after it.
    @MainActor
    static func nextMainLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// A unique scratch directory per test, removed when the owning suite instance goes away.
fileprivate final class WorkspaceStoreScratch {
    let base: URL

    init() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandshellWorkspaceStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    /// A workspace root inside the scratch directory with `config.json` already
    /// written, so `WorkspaceStore.shared` loads it rather than building a
    /// default config from the real home folder.
    func makeRoot(_ name: String = "workspace",
                  config: WorkspaceConfig = WorkspaceStoreFixture.config()) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try config.save(root: root)
        return root
    }
}

/// Stands in for a window's `WorkspaceController`: an object to observe or write as.
fileprivate final class WorkspaceStoreTestWindow {}

/// Where one observer's notifications land. Kept apart from the window so the
/// observe closure doesn't hold the window, and dropping the window really closes it.
fileprivate final class WorkspaceStoreNotificationLog {
    private(set) var batches: [Set<WorkspaceStore.Part>] = []
    func record(_ parts: Set<WorkspaceStore.Part>) { batches.append(parts) }
}

extension WorkspaceStore {
    /// Writes `part` back unchanged: the store doesn't diff, so this still counts as a change.
    fileprivate func rewrite(_ part: Part, by writer: AnyObject) {
        switch part {
        case .state: setState(state, by: writer)
        case .config: setConfig(config, by: writer)
        }
    }
}

// MARK: - Opening and sharing

@MainActor
@Suite(.tags(.workspaceStoreFileSystem))
struct WorkspaceStoreSharingTests {
    private let scratch = WorkspaceStoreScratch()

    @Test func openingAFolderBootstrapsItsControlFiles() throws {
        let root = try scratch.makeRoot()

        let store = try WorkspaceStore.shared(root: root)

        #expect(store.root == root)
        #expect(FileManager.default.fileExists(atPath: WorkspaceState.stateURL(root: root).path),
                "Opening a folder writes its state.json")
        let gitignore = WorkspaceState.controlDir(root: root).appendingPathComponent(".gitignore")
        let contents = try String(contentsOf: gitignore, encoding: .utf8)
        let ignored = Set(contents.split(separator: "\n").map(String.init))
        #expect(ignored == ["state.json", "status/", "statusline.sh"])
    }

    @Test func aFreshFolderStartsWithJustTheExpandedRootFolder() throws {
        let root = try scratch.makeRoot()

        let store = try WorkspaceStore.shared(root: root)

        let rootFolder = try #require(store.state.folders.first, "The root folder row is always seeded")
        #expect(store.state.folders.count == 1)
        #expect(rootFolder.isRoot)
        #expect(store.state.expandedFolderIDs == [rootFolder.id])
        #expect(store.state.sessions.isEmpty)
        #expect(store.state.schemaVersion == 2)
    }

    @Test func theStoreHoldsTheStateItSaved() throws {
        let root = try scratch.makeRoot()

        let store = try WorkspaceStore.shared(root: root)

        let onDisk = try #require(try WorkspaceState.load(root: root))
        #expect(store.state.folders == onDisk.folders, "Memory and state.json agree after opening")
        #expect(store.state.expandedFolderIDs == onDisk.expandedFolderIDs)
    }

    @Test func openingAFolderLoadsItsSavedState() throws {
        let root = try scratch.makeRoot()
        let rootFolder = Folder(relativePath: "", order: -1)
        let web = Folder(relativePath: "apps/web", order: 0)
        let session = WorkspaceStoreFixture.session(in: web)
        let saved = WorkspaceState(folders: [rootFolder, web], sessions: [session],
                                   expandedFolderIDs: [rootFolder.id, web.id])
        try saved.save(root: root)

        let store = try WorkspaceStore.shared(root: root)

        #expect(store.state.folders == saved.folders)
        #expect(store.state.sessions == [session], "Saved sessions come back as they were")
        #expect(store.state.expandedFolderIDs == saved.expandedFolderIDs)
    }

    @Test func openingAFolderLoadsItsSavedConfig() throws {
        let root = try scratch.makeRoot()

        let store = try WorkspaceStore.shared(root: root)

        #expect(store.config.primaryAgent == .codex)
        #expect(store.config.mcpServers == ["github"])
        #expect(store.config.configured)
        #expect(store.config.archiveInterval == 600)
        #expect(store.config.kits == ["docker.io/example/store-test-kit:1"])
        #expect(store.config.claudeModel == "opus")
    }

    /// `""` is the folder's own path; the rest are other spellings of it.
    @Test(arguments: ["", "/", "/.", "/./"])
    func aFolderAlreadyOpenGetsTheSameStore(suffix: String) throws {
        let root = try scratch.makeRoot()
        let first = try WorkspaceStore.shared(root: root)

        let alias = URL(fileURLWithPath: root.path + suffix)
        let second = try WorkspaceStore.shared(root: alias)

        #expect(first === second, "Every window on one folder shares one store: \(alias.path) is \(root.path)")
    }

    @Test func differentFoldersGetDifferentStores() throws {
        let one = try scratch.makeRoot("one")
        let two = try scratch.makeRoot("two", config: WorkspaceStoreFixture.config(primaryAgent: .claude))

        let first = try WorkspaceStore.shared(root: one)
        let second = try WorkspaceStore.shared(root: two)

        #expect(first !== second, "Each folder has its own store")
        #expect(first.config.primaryAgent == .codex, "Each store reads its own folder's config.json")
        #expect(second.config.primaryAgent == .claude, "Each store reads its own folder's config.json")
    }

    @Test(.tags(.workspaceStoreEdgeCase))
    func theSharingTableDoesNotKeepAStoreAlive() throws {
        let root = try scratch.makeRoot()
        var store: WorkspaceStore? = try WorkspaceStore.shared(root: root)
        weak var released = store

        store = nil

        #expect(released == nil, "Only windows hold a store; once they're gone so is it")
    }

    @Test(.tags(.workspaceStoreEdgeCase))
    func aFolderOpenedAgainAfterItsStoreWentAwayIsReadFromDisk() throws {
        let root = try scratch.makeRoot()
        let writer = WorkspaceStoreTestWindow()
        var store: WorkspaceStore? = try WorkspaceStore.shared(root: root)
        weak var released = store
        var unsaved = try #require(store).state
        let rootFolder = try #require(unsaved.folders.first)
        unsaved.sessions.append(WorkspaceStoreFixture.session(in: rootFolder))
        try #require(store).setState(unsaved, by: writer)
        store = nil
        try #require(released == nil, "The store must be gone for reopening to read the folder again")
        try WorkspaceStoreFixture.config(primaryAgent: .gemini).save(root: root)

        let reopened = try WorkspaceStore.shared(root: root)

        #expect(reopened.state.sessions.isEmpty, "The released store's unsaved session went with it")
        #expect(reopened.config.primaryAgent == .gemini, "config.json is read again")
    }
}

// MARK: - Writes

@MainActor
@Suite(.tags(.workspaceStoreFileSystem))
struct WorkspaceStoreWriteTests {
    private let scratch = WorkspaceStoreScratch()
    let root: URL
    let store: WorkspaceStore
    private let writer = WorkspaceStoreTestWindow()

    init() throws {
        root = try scratch.makeRoot()
        store = try WorkspaceStore.shared(root: root)
    }

    @Test func setStateReplacesTheState() throws {
        let rootFolder = try #require(store.state.folders.first)
        let session = WorkspaceStoreFixture.session(in: rootFolder)
        var new = store.state
        new.sessions = [session]
        new.appliedMountSignatures = ["sandshell-claude": "sig-1"]

        store.setState(new, by: writer)

        #expect(store.state.sessions == [session])
        #expect(store.state.appliedMountSignatures == ["sandshell-claude": "sig-1"])
        #expect(store.state.folders == [rootFolder], "Fields the write kept are unchanged")
    }

    @Test func setConfigReplacesTheConfig() {
        var new = store.config
        new.primaryAgent = .gemini
        new.mcpServers = []
        new.customImage = "ghcr.io/example/sandbox:2"

        store.setConfig(new, by: writer)

        #expect(store.config.primaryAgent == .gemini)
        #expect(store.config.mcpServers.isEmpty)
        #expect(store.config.customImage == "ghcr.io/example/sandbox:2")
        #expect(store.config.claudeModel == "opus", "Fields the write kept are unchanged")
    }

    @Test func anotherWindowOnTheFolderSeesTheWrite() throws {
        let rootFolder = try #require(store.state.folders.first)
        let session = WorkspaceStoreFixture.session(in: rootFolder)
        var newState = store.state
        newState.sessions = [session]
        var newConfig = store.config
        newConfig.primaryAgent = .claude

        store.setState(newState, by: writer)
        store.setConfig(newConfig, by: writer)

        let otherWindowsStore = try WorkspaceStore.shared(root: root)
        #expect(otherWindowsStore.state.sessions == [session])
        #expect(otherWindowsStore.config.primaryAgent == .claude)
    }

    @Test func writesStayInMemoryUntilTheCallerSaves() throws {
        let rootFolder = try #require(store.state.folders.first)
        var newState = store.state
        newState.sessions = [WorkspaceStoreFixture.session(in: rootFolder)]
        var newConfig = store.config
        newConfig.primaryAgent = .claude

        store.setState(newState, by: writer)
        store.setConfig(newConfig, by: writer)

        let stateOnDisk = try #require(try WorkspaceState.load(root: root))
        let configOnDisk = try #require(try WorkspaceConfig.load(root: root))
        #expect(stateOnDisk.sessions.isEmpty, "The store doesn't write state.json; the controller saves")
        #expect(configOnDisk.primaryAgent == .codex, "The store doesn't write config.json; the controller saves")
    }
}

// MARK: - Telling the other windows

@MainActor
@Suite(.tags(.workspaceStoreFileSystem), .timeLimit(.minutes(1)))
struct WorkspaceStoreNotificationTests {
    private let scratch = WorkspaceStoreScratch()
    let store: WorkspaceStore
    private let windowA = WorkspaceStoreTestWindow()
    private let windowB = WorkspaceStoreTestWindow()
    private let windowC = WorkspaceStoreTestWindow()

    init() throws {
        store = try WorkspaceStore.shared(root: try scratch.makeRoot())
    }

    /// Registers `window` with `store` and returns the log its notifications land in.
    private func watch(_ store: WorkspaceStore, as window: AnyObject) -> WorkspaceStoreNotificationLog {
        let log = WorkspaceStoreNotificationLog()
        store.observe(window) { log.record($0) }
        return log
    }

    private func watch(as window: AnyObject) -> WorkspaceStoreNotificationLog {
        watch(store, as: window)
    }

    @Test(arguments: [WorkspaceStore.Part.state, .config])
    func everyOtherWindowIsToldWhichPartChanged(part: WorkspaceStore.Part) async {
        let logA = watch(as: windowA)
        let logB = watch(as: windowB)
        let logC = watch(as: windowC)

        store.rewrite(part, by: windowA)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logB.batches == [[part]], "Every other window is told once, naming the part")
        #expect(logC.batches == [[part]], "Every other window is told once, naming the part")
        #expect(logA.batches.isEmpty, "The writer isn't told about its own change")
    }

    @Test func theNotificationComesOnTheNextMainLoopTurn() async {
        _ = watch(as: windowA)
        let logB = watch(as: windowB)

        store.rewrite(.state, by: windowA)

        #expect(logB.batches.isEmpty, "Nobody is told during the write itself")
        await WorkspaceStoreFixture.nextMainLoopTurn()
        #expect(logB.batches == [[.state]])
    }

    @Test func writesInOneTurnAreCoalescedIntoOneNotification() async {
        let logA = watch(as: windowA)
        let logB = watch(as: windowB)

        store.rewrite(.state, by: windowA)
        store.rewrite(.state, by: windowA)
        store.rewrite(.config, by: windowA)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logB.batches == [[.state, .config]], "One notification naming both parts")
        #expect(logA.batches.isEmpty, "The writer isn't told about its own changes")
    }

    @Test func eachWriterIsToldOnlyWhatTheOtherChanged() async {
        let logA = watch(as: windowA)
        let logB = watch(as: windowB)

        store.rewrite(.state, by: windowA)
        store.rewrite(.config, by: windowB)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logA.batches == [[.config]], "A wrote the state, so it hears only of B's config write")
        #expect(logB.batches == [[.state]], "B wrote the config, so it hears only of A's state write")
    }

    @Test func twoWindowsWritingTheSamePartAreEachToldOfTheOthersWrite() async {
        let logA = watch(as: windowA)
        let logB = watch(as: windowB)

        store.rewrite(.state, by: windowA)
        store.rewrite(.state, by: windowB)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logA.batches == [[.state]])
        #expect(logB.batches == [[.state]])
    }

    @Test func aWriterThatIsNotObservingIsReportedToEveryWindow() async {
        let logA = watch(as: windowA)
        let logB = watch(as: windowB)

        store.rewrite(.config, by: windowC)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logA.batches == [[.config]], "A writer that isn't a window is someone else to every window")
        #expect(logB.batches == [[.config]], "A writer that isn't a window is someone else to every window")
    }

    @Test func laterWritesStartANewNotification() async {
        _ = watch(as: windowA)
        let logB = watch(as: windowB)

        store.rewrite(.state, by: windowA)
        await WorkspaceStoreFixture.nextMainLoopTurn()
        store.rewrite(.config, by: windowA)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logB.batches == [[.state], [.config]], "The second batch carries only what changed since the first")
    }

    @Test(.tags(.workspaceStoreEdgeCase))
    func aLoneWindowIsNeverNotifiedOfItsOwnWrites() async {
        let logA = watch(as: windowA)

        store.rewrite(.state, by: windowA)
        store.rewrite(.config, by: windowA)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logA.batches.isEmpty, "With one window there's nobody else to tell")
    }

    @Test(.tags(.workspaceStoreEdgeCase))
    func aLoneWindowIsNotNotifiedEvenOfAStrangersWrite() async {
        let logA = watch(as: windowA)

        store.rewrite(.state, by: windowC)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logA.batches.isEmpty, "With one observer the store assumes it is the only writer and skips notifying")
    }

    @Test(.tags(.workspaceStoreEdgeCase))
    func aClosedWindowIsForgottenBeforeTheWrite() async throws {
        let logA = watch(as: windowA)
        var closing: WorkspaceStoreTestWindow? = WorkspaceStoreTestWindow()
        weak var closed = closing
        let logClosed = watch(as: try #require(closing))
        closing = nil
        try #require(closed == nil)

        store.rewrite(.state, by: windowA)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logClosed.batches.isEmpty, "A closed window's handler never runs")
        #expect(logA.batches.isEmpty, "Only the writer is left, so there's nobody to tell")
    }

    @Test(.tags(.workspaceStoreEdgeCase))
    func aWindowClosedBeforeTheNotificationIsSkipped() async throws {
        let logA = watch(as: windowA)
        var closing: WorkspaceStoreTestWindow? = WorkspaceStoreTestWindow()
        weak var closed = closing
        let logClosed = watch(as: try #require(closing))
        let logC = watch(as: windowC)

        store.rewrite(.state, by: windowA)
        closing = nil
        try #require(closed == nil)
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logClosed.batches.isEmpty, "Closed between the write and the notification")
        #expect(logC.batches == [[.state]], "The windows still open are told")
        #expect(logA.batches.isEmpty, "The writer isn't told about its own change")
    }

    @Test(.tags(.workspaceStoreEdgeCase))
    func aStoreReleasedBeforeTheNotificationTellsNobody() async throws {
        let root = try scratch.makeRoot("released")
        var transient: WorkspaceStore? = try WorkspaceStore.shared(root: root)
        weak var released = transient
        let logA = watch(try #require(transient), as: windowA)
        let logB = watch(try #require(transient), as: windowB)

        try #require(transient).rewrite(.state, by: windowA)
        transient = nil
        try #require(released == nil, "The queued notification holds the store weakly")
        await WorkspaceStoreFixture.nextMainLoopTurn()

        #expect(logA.batches.isEmpty, "A released store's queued notification goes nowhere")
        #expect(logB.batches.isEmpty, "A released store's queued notification goes nowhere")
    }
}
