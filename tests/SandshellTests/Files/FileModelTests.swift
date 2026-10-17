import AppKit
import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Boundaries and odd inputs in the Files model. File-private and uniquely
    /// named so it can't clash with tags other suites declare.
    @Tag fileprivate static var fileModelEdgeCase: Self
    /// Tests that read or write a scratch folder under the temporary directory.
    @Tag fileprivate static var fileModelFileSystem: Self
}

/// Tests for `Files/FileModel.swift` (`GitStatus`, `FilePatch`, `FileNode`,
/// `FileWatcher`) and `FileTreeController.unique(_:in:copy:)`.
///
/// Not covered: `GitStatus.load(for:)` (its porcelain parsing is inline and runs
/// the host's git), `GitStatus.git(_:)`, `GitStatus.change(_:)` and
/// `FilePatch.apply(_:hunk:repo:)` — they all launch `/usr/bin/git`.
struct FileModelTests {

    // MARK: - GitStatus.Change

    struct Changes {
        @Test(arguments: [
            (.modified, "M"), (.added, "A"), (.deleted, "D"),
            (.renamed, "R"), (.untracked, "U"), (.conflicted, "!"),
        ] as [(GitStatus.Change, String)])
        func badgeIsTheTreesOneLetterMark(change: GitStatus.Change, badge: String) {
            #expect(change.badge == badge)
        }

        @Test func everyChangeHasItsOwnBadge() {
            let all: [GitStatus.Change] = [.modified, .added, .deleted, .renamed, .untracked, .conflicted]
            #expect(Set(all.map { $0.badge }).count == all.count, "Two kinds of change must never share a badge")
        }

        /// Modified is orange, new files green, deleted and conflicted red, renamed blue.
        @Test(arguments: [
            (.modified, .systemOrange),
            (.added, .systemGreen), (.untracked, .systemGreen),
            (.deleted, .systemRed), (.conflicted, .systemRed),
            (.renamed, .systemBlue),
        ] as [(GitStatus.Change, NSColor)])
        func colorMatchesTheKindOfChange(change: GitStatus.Change, color: NSColor) {
            #expect(change.color == color, "\(change) should be drawn in \(color)")
        }
    }

    // MARK: - GitStatus values and change(for:)

    struct Status {
        private let scratch: FileModelScratch
        /// A top-level folder that doesn't exist, so `realpath` always fails under it.
        let missingRoot = "/sandshell-missing-\(UUID().uuidString)"

        init() throws {
            scratch = try FileModelScratch()
        }

        @Test func emptyStatusHasNoRepoBranchOrChanges() {
            let empty = GitStatus.empty
            #expect(empty.repoRoot == nil)
            #expect(empty.branch == nil)
            #expect(empty.changes.isEmpty)
            #expect(empty.dirtyFolders.isEmpty)
            #expect(empty == GitStatus(), "`empty` is just a default status")
        }

        @Test func statusesWithTheSameFieldsAreEqual() {
            let status = GitStatus(repoRoot: "/r", branch: "main", changes: ["/r/a": .added], dirtyFolders: ["/r"])
            #expect(status == GitStatus(repoRoot: "/r", branch: "main", changes: ["/r/a": .added], dirtyFolders: ["/r"]))
        }

        /// One variant per field, each differing from the base status in that field only.
        @Test(arguments: [
            GitStatus(repoRoot: "/s", branch: "main", changes: ["/r/a": .added], dirtyFolders: ["/r"]),
            GitStatus(repoRoot: "/r", branch: "dev", changes: ["/r/a": .added], dirtyFolders: ["/r"]),
            GitStatus(repoRoot: "/r", branch: "main", changes: ["/r/a": .modified], dirtyFolders: ["/r"]),
            GitStatus(repoRoot: "/r", branch: "main", changes: ["/r/a": .added], dirtyFolders: []),
        ])
        func statusesDifferWhenAnyFieldDiffers(other: GitStatus) {
            let status = GitStatus(repoRoot: "/r", branch: "main", changes: ["/r/a": .added], dirtyFolders: ["/r"])
            #expect(status != other)
        }

        @Test(arguments: [.modified, .added, .deleted, .renamed, .untracked, .conflicted] as [GitStatus.Change])
        func changeIsFoundByThePathAsGiven(change: GitStatus.Change) {
            let url = URL(fileURLWithPath: missingRoot + "/repo/Sources/main.swift")
            let status = GitStatus(changes: [url.path: change])
            #expect(status.change(for: url) == change)
        }

        @Test func fileWithoutAChangeHasNone() {
            let status = GitStatus(changes: [missingRoot + "/repo/a.txt": .modified])
            #expect(status.change(for: URL(fileURLWithPath: missingRoot + "/repo/b.txt")) == nil)
            #expect(GitStatus.empty.change(for: URL(fileURLWithPath: missingRoot + "/repo/a.txt")) == nil)
        }

        @Test(.tags(.fileModelEdgeCase))
        func folderOfAChangedFileHasNoChangeOfItsOwn() {
            let status = GitStatus(changes: [missingRoot + "/repo/dir/a.txt": .added],
                                   dirtyFolders: [missingRoot + "/repo/dir"])
            #expect(status.change(for: URL(fileURLWithPath: missingRoot + "/repo/dir")) == nil,
                    "Dirty folders are tracked separately from per-file changes")
        }

        @Test(.tags(.fileModelEdgeCase))
        func dotSegmentsAreRemovedBeforeTheSecondLookup() throws {
            let url = URL(fileURLWithPath: missingRoot + "/repo/sub/../a.txt")
            let gitPath = missingRoot + "/repo/a.txt"
            try #require(url.path != gitPath, "The URL must keep its .. segment for this test to mean anything")
            #expect(GitStatus(changes: [gitPath: .deleted]).change(for: url) == .deleted)
        }

        @Test(.tags(.fileModelFileSystem))
        func changeIsFoundByGitsResolvedPathThroughASymlink() throws {
            let real = try scratch.folder("real")
            try scratch.file("real/a.txt", "a")
            let link = try scratch.link("link", to: real)
            let url = link.appending(path: "a.txt", directoryHint: .notDirectory)
            let gitPath = real.appending(path: "a.txt", directoryHint: .notDirectory).realPath
            try #require(url.path != gitPath, "The URL must go through the symlink")

            #expect(GitStatus(changes: [gitPath: .modified]).change(for: url) == .modified,
                    "git reports resolved paths (/tmp/x is /private/tmp/x)")
        }

        @Test(.tags(.fileModelFileSystem))
        func pathAsGivenWinsOverTheResolvedPath() throws {
            let real = try scratch.folder("real")
            try scratch.file("real/a.txt", "a")
            let link = try scratch.link("link", to: real)
            let url = link.appending(path: "a.txt", directoryHint: .notDirectory)
            let gitPath = real.appending(path: "a.txt", directoryHint: .notDirectory).realPath
            try #require(url.path != gitPath)

            let status = GitStatus(changes: [url.path: .added, gitPath: .modified])
            #expect(status.change(for: url) == .added, "The path as given is looked up first")
        }

        @Test(.tags(.fileModelFileSystem, .fileModelEdgeCase))
        func deletedFileInASymlinkedFolderIsFoundByGitsResolvedPath() throws {
            let real = try scratch.folder("real")
            let link = try scratch.link("link", to: real)
            let url = link.appending(path: "gone.txt", directoryHint: .notDirectory)
            let gitPath = real.realPath + "/gone.txt"
            try #require(FileManager.default.fileExists(atPath: url.path) == false)
            try #require(url.path != gitPath)

            let status = GitStatus(changes: [gitPath: .deleted])
            #expect(status.change(for: url) == .deleted, "A deleted file's open tab finds the \"D\" through its resolved folder")
        }
    }

    // MARK: - FilePatch

    struct Patches {
        private typealias Fixture = FileModelPatchFixture

        @Test func headerAndHunksAreSplitAtEachAtAtLine() {
            let patch = FilePatch(Fixture.text(Fixture.header + Fixture.firstHunk + Fixture.secondHunk))
            #expect(patch.header == Fixture.header)
            #expect(patch.hunks == [Fixture.firstHunk, Fixture.secondHunk])
            #expect(patch.isEmpty == false)
        }

        @Test(arguments: [
            (0, FileModelPatchFixture.firstHunk),
            (1, FileModelPatchFixture.secondHunk),
        ])
        func patchForAHunkIsTheHeaderPlusOnlyThatHunk(index: Int, hunk: [String]) {
            let patch = FilePatch(Fixture.text(Fixture.header + Fixture.firstHunk + Fixture.secondHunk))
            #expect(patch.patch(forHunk: index) == Fixture.text(Fixture.header + hunk),
                    "git apply needs the file header, the one hunk and a final newline")
        }

        @Test(arguments: FileModelPatchFixture.singleHunkDiffs)
        func singleHunkDiffRoundTrips(lines: [String]) {
            let diff = Fixture.text(lines)
            #expect(FilePatch(diff).patch(forHunk: 0) == diff,
                    "A one-hunk diff's patch is the diff itself, byte for byte")
        }

        @Test func diffWithoutAFinalNewlineGainsOne() {
            let diff = (Fixture.header + Fixture.firstHunk).joined(separator: "\n")
            let patch = FilePatch(diff)
            #expect(patch.hunks == [Fixture.firstHunk])
            #expect(patch.patch(forHunk: 0) == diff + "\n")
        }

        @Test func diffStartingWithAHunkHasNoHeader() {
            let patch = FilePatch(Fixture.text(Fixture.firstHunk))
            #expect(patch.header.isEmpty)
            #expect(patch.hunks == [Fixture.firstHunk])
            #expect(patch.patch(forHunk: 0) == Fixture.text(Fixture.firstHunk))
        }

        @Test(arguments: FileModelPatchFixture.diffsWithoutHunks)
        func diffWithoutHunksIsEmpty(diff: String) {
            #expect(FilePatch(diff).isEmpty, "Without an @@ line there's no hunk to stage or revert")
        }

        @Test func binaryDiffKeepsItsLinesAsTheHeader() {
            let lines = [
                "diff --git a/icon.png b/icon.png",
                "index 3333333..4444444 100644",
                "Binary files a/icon.png and b/icon.png differ",
            ]
            #expect(FilePatch(Fixture.text(lines)).header == lines)
        }

        @Test(.tags(.fileModelEdgeCase))
        func emptyDiffHasNoLinesAtAll() {
            let patch = FilePatch("")
            #expect(patch.header.isEmpty, "The single empty line after splitting \"\" is dropped")
            #expect(patch.hunks.isEmpty)
        }

        @Test(.tags(.fileModelEdgeCase))
        func onlyOneTrailingEmptyLineIsDropped() {
            let patch = FilePatch("@@ -1 +1 @@\n-a\n+b\n\n")
            #expect(patch.hunks == [["@@ -1 +1 @@", "-a", "+b", ""]],
                    "A blank last line of the hunk survives; only the newline ending the text is dropped")
        }

        @Test func everyAtAtLineStartsANewHunk() {
            let lines = ["@@ -1 +1 @@", "-a", "+b", "@@ -5 +5 @@", "-c", "+d", "@@ -9 +9 @@", " e"]
            let patch = FilePatch(Fixture.text(Fixture.header + lines))
            #expect(patch.hunks.count == 3)
            #expect(patch.hunks.map { $0.first } == ["@@ -1 +1 @@", "@@ -5 +5 @@", "@@ -9 +9 @@"])
        }

        @Test func patchesFromTheSameTextAreEqual() {
            let diff = Fixture.text(Fixture.header + Fixture.firstHunk)
            #expect(FilePatch(diff) == FilePatch(diff))
            #expect(FilePatch(diff) != FilePatch(Fixture.text(Fixture.header + Fixture.secondHunk)))
        }

        @Test(arguments: [
            (.stage, ["--cached"]),
            (.unstage, ["--cached", "-R"]),
            (.revert, ["-R"]),
        ] as [(FilePatch.Action, [String])])
        func actionsMapToGitApplyFlags(action: FilePatch.Action, flags: [String]) {
            #expect(action.applyArgs == flags)
        }

        @Test(arguments: [(.stage, "stage"), (.unstage, "unstage"), (.revert, "revert")] as [(FilePatch.Action, String)])
        func actionsRoundTripThroughTheirRawValue(action: FilePatch.Action, rawValue: String) {
            #expect(action.rawValue == rawValue)
            #expect(FilePatch.Action(rawValue: rawValue) == action)
        }

        @Test(.tags(.fileModelEdgeCase), arguments: ["", "Stage", "commit", "apply"])
        func unknownActionNamesAreNil(rawValue: String) {
            #expect(FilePatch.Action(rawValue: rawValue) == nil)
        }
    }

    // MARK: - FileNode

    @MainActor
    struct Nodes {
        private let scratch: FileModelScratch

        init() throws {
            scratch = try FileModelScratch()
        }

        @Test func newNodeIsNotLoaded() {
            let node = FileNode(url: scratch.url, isDirectory: true)
            #expect(node.isLoaded == false)
            #expect(node.children == nil)
            #expect(node.isDirectory)
        }

        @Test(arguments: [
            ("/srv/repo/notes.md", "notes.md"),
            ("/srv/repo/Sources/", "Sources"),
            ("/srv/repo/a b/ü é.txt", "ü é.txt"),
            ("/srv/repo/.env", ".env"),
        ])
        func nameIsTheLastPathComponent(path: String, name: String) {
            let node = FileNode(url: URL(fileURLWithPath: path), isDirectory: path.hasSuffix("/"))
            #expect(node.name == name)
        }

        @Test(.tags(.fileModelFileSystem))
        func fileNodesNeverLoadChildren() throws {
            let file = try scratch.file("plain.txt", "text")
            let node = FileNode(url: file, isDirectory: false)
            node.loadChildren()
            node.reloadLoaded()
            #expect(node.isLoaded == false)
            #expect(node.children == nil)
        }

        @Test(.tags(.fileModelFileSystem))
        func foldersComeFirstThenNamesInFinderOrder() throws {
            for name in ["b.txt", "file10.txt", "A.txt", "file2.txt"] { try scratch.file(name) }
            for name in ["zeta", "Alpha"] { try scratch.folder(name) }

            let root = loadedRoot()
            let children = try #require(root.children)
            #expect(children.map { $0.name } == ["Alpha", "zeta", "A.txt", "b.txt", "file2.txt", "file10.txt"],
                    "Folders first, then case-insensitive, numeric-aware order like Finder")
            #expect(children.map { $0.isDirectory } == [true, true, false, false, false, false])
        }

        @Test(.tags(.fileModelFileSystem))
        func gitAndFinderLitterAreHiddenButDotfilesShow() throws {
            try scratch.folder(".git/objects")
            try scratch.file(".DS_Store")
            try scratch.file(".env", "KEY=1")
            try scratch.folder(".github")
            try scratch.file("readme.md")

            let root = loadedRoot()
            #expect(Set(names(root)) == [".github", ".env", "readme.md"])
            #expect(root.children?.first?.name == ".github", "The only folder listed comes first")
        }

        @Test(.tags(.fileModelFileSystem, .fileModelEdgeCase))
        func gitFileOfAWorktreeIsHiddenToo() throws {
            try scratch.file(".git", "gitdir: /srv/repo/.git/worktrees/feature")
            try scratch.file("main.swift")
            #expect(names(loadedRoot()) == ["main.swift"])
        }

        @Test func ignoredNamesAreGitAndDSStoreOnly() {
            #expect(FileNode.ignored == [".git", ".DS_Store"])
        }

        @Test(.tags(.fileModelFileSystem))
        func emptyFolderLoadsWithNoChildren() throws {
            let root = loadedRoot()
            #expect(root.isLoaded)
            #expect(root.children?.isEmpty == true)
        }

        @Test(.tags(.fileModelFileSystem, .fileModelEdgeCase), arguments: ["missing", "plain.txt"])
        func unreadableFolderLoadsWithNoChildren(name: String) throws {
            try scratch.file("plain.txt", "not a folder")
            let node = FileNode(url: scratch.url.appending(path: name, directoryHint: .isDirectory), isDirectory: true)
            node.loadChildren()
            #expect(node.isLoaded, "A folder that can't be listed still counts as loaded")
            #expect(node.children?.isEmpty == true)
        }

        @Test(.tags(.fileModelFileSystem))
        func reloadingKeepsTheNodesOfUnchangedEntries() throws {
            try scratch.file("a.txt")
            try scratch.folder("sub")
            let root = loadedRoot()
            let file = try child(root, "a.txt")
            let folder = try child(root, "sub")

            try scratch.file("b.txt")
            root.loadChildren()

            #expect(names(root) == ["sub", "a.txt", "b.txt"])
            #expect(try child(root, "a.txt") === file, "Reused by URL so the outline keeps its state")
            #expect(try child(root, "sub") === folder)
        }

        @Test(.tags(.fileModelFileSystem))
        func deletedEntriesDisappearOnReload() throws {
            try scratch.file("a.txt")
            try scratch.file("b.txt")
            let root = loadedRoot()
            try #require(names(root) == ["a.txt", "b.txt"])

            try scratch.remove("b.txt")
            root.loadChildren()
            #expect(names(root) == ["a.txt"], "A removed file's node is dropped, not kept from the last load")
        }

        @Test(.tags(.fileModelFileSystem, .fileModelEdgeCase))
        func fileReplacedByAFolderGetsANewNode() throws {
            try scratch.file("thing")
            let root = loadedRoot()
            let old = try child(root, "thing")
            try #require(old.isDirectory == false)

            try scratch.remove("thing")
            try scratch.folder("thing")
            root.loadChildren()

            let new = try child(root, "thing")
            #expect(new !== old, "A node isn't reused once the entry changed kind")
            #expect(new.isDirectory)
        }

        @Test(.tags(.fileModelFileSystem))
        func reloadLoadedDoesNothingBeforeTheFirstLoad() throws {
            try scratch.file("a.txt")
            let root = FileNode(url: scratch.url, isDirectory: true)
            root.reloadLoaded()
            #expect(root.isLoaded == false)
        }

        @Test(.tags(.fileModelFileSystem))
        func reloadLoadedRelistsEveryLoadedFolderOnly() throws {
            try scratch.file("sub/one.txt")
            try scratch.file("other/x.txt")
            let root = loadedRoot()
            let sub = try child(root, "sub")
            let other = try child(root, "other")
            sub.loadChildren()

            try scratch.file("sub/two.txt")
            try scratch.file("top.txt")
            root.reloadLoaded()

            #expect(names(root) == ["other", "sub", "top.txt"])
            #expect(try child(root, "sub") === sub)
            #expect(names(sub) == ["one.txt", "two.txt"], "A loaded subfolder is re-listed too")
            #expect(other.isLoaded == false, "A folder never expanded stays unloaded")
        }

        // Helpers

        private func loadedRoot() -> FileNode {
            let root = FileNode(url: scratch.url, isDirectory: true)
            root.loadChildren()
            return root
        }

        private func names(_ node: FileNode) -> [String] {
            (node.children ?? []).map { $0.name }
        }

        private func child(_ node: FileNode, _ name: String,
                           sourceLocation: SourceLocation = #_sourceLocation) throws -> FileNode {
            try #require(node.children?.first { $0.name == name }, "\(name) should be listed",
                         sourceLocation: sourceLocation)
        }
    }

    // MARK: - FileWatcher

    @MainActor
    struct Watching {
        private let scratch: FileModelScratch

        init() throws {
            scratch = try FileModelScratch()
        }

        @Test(.tags(.fileModelFileSystem), .timeLimit(.minutes(1)))
        func writingInsideTheFolderCallsOnChange() async throws {
            let calls = FileModelCallCounter()
            // FSEvents reports resolved paths, so watch /private/var/…, not /var/….
            let watcher = FileWatcher(path: scratch.url.realPath, latency: 0.05) { calls.count += 1 }
            defer { watcher.stop() }

            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var writes = 0
            while calls.count == 0, ContinuousClock.now < deadline {
                try scratch.file("note-\(writes).txt", "change \(writes)")
                writes += 1
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(calls.count > 0, "A file written under the watched folder should be reported within 10s")
        }

        @Test(.tags(.fileModelFileSystem))
        func stoppedWatcherReportsNothing() async throws {
            let calls = FileModelCallCounter()
            let watcher = FileWatcher(path: scratch.url.realPath, latency: 0.05) { calls.count += 1 }
            watcher.stop()
            watcher.stop()   // a second stop is a no-op

            try scratch.file("after-stop.txt", "x")
            try await Task.sleep(for: .milliseconds(500))
            #expect(calls.count == 0, "A stopped stream delivers nothing")
        }

        @Test(.tags(.fileModelFileSystem))
        func releasedWatcherReportsNothing() async throws {
            let calls = FileModelCallCounter()
            _ = FileWatcher(path: scratch.url.realPath, latency: 0.05) { calls.count += 1 }

            try scratch.file("after-release.txt", "x")
            try await Task.sleep(for: .milliseconds(500))
            #expect(calls.count == 0, "Nobody holds the watcher, so its stream is gone")
        }
    }

    // MARK: - FileTreeController.unique

    @MainActor
    struct UniqueNames {
        private let scratch: FileModelScratch

        init() throws {
            scratch = try FileModelScratch()
        }

        @Test(arguments: ["untitled.txt", "untitled folder", "Read Me.md", "archive.tar.gz", ".gitignore"])
        func freeNameIsUsedAsIs(name: String) {
            let url = FileTreeController.unique(name, in: scratch.url)
            #expect(url.lastPathComponent == name)
            #expect(url.deletingLastPathComponent().path == scratch.url.path)
        }

        @Test(.tags(.fileModelFileSystem), arguments: [
            (0, "untitled.txt"), (1, "untitled 2.txt"), (2, "untitled 3.txt"), (3, "untitled 4.txt"),
        ])
        func takenNamesCountUpFromTwo(taken: Int, expected: String) throws {
            for name in ["untitled.txt", "untitled 2.txt", "untitled 3.txt"].prefix(taken) { try scratch.file(name) }
            #expect(FileTreeController.unique("untitled.txt", in: scratch.url).lastPathComponent == expected,
                    "Finder-style numbering: the second copy of a name is \"2\", never \"1\"")
        }

        @Test(.tags(.fileModelFileSystem), arguments: [
            (0, "report copy.pdf"), (1, "report copy 2.pdf"), (2, "report copy 3.pdf"),
        ])
        func copiesCountUpFromCopy(taken: Int, expected: String) throws {
            try scratch.file("report.pdf")
            for name in ["report copy.pdf", "report copy 2.pdf"].prefix(taken) { try scratch.file(name) }
            #expect(FileTreeController.unique("report.pdf", in: scratch.url, copy: true).lastPathComponent == expected)
        }

        @Test func copyNeverTakesTheOriginalName() {
            let url = FileTreeController.unique("report.pdf", in: scratch.url, copy: true)
            #expect(url.lastPathComponent == "report copy.pdf", "Even when the original name is free")
        }

        @Test(.tags(.fileModelFileSystem), arguments: [(false, "untitled folder 2"), (true, "untitled folder copy")])
        func nameWithoutAnExtensionGetsTheSuffixAtTheEnd(copy: Bool, expected: String) throws {
            try scratch.folder("untitled folder")
            #expect(FileTreeController.unique("untitled folder", in: scratch.url, copy: copy).lastPathComponent == expected)
        }

        @Test(.tags(.fileModelFileSystem))
        func firstGapIsUsed() throws {
            try scratch.file("untitled.txt")
            try scratch.file("untitled 3.txt")
            #expect(FileTreeController.unique("untitled.txt", in: scratch.url).lastPathComponent == "untitled 2.txt")
        }

        @Test(.tags(.fileModelFileSystem))
        func folderTakesAFileNameToo() throws {
            try scratch.folder("notes.txt")
            #expect(FileTreeController.unique("notes.txt", in: scratch.url).lastPathComponent == "notes 2.txt")
        }

        @Test(.tags(.fileModelFileSystem))
        func accentsAndSpacesAreKept() throws {
            try scratch.file("Résumé final.docx")
            #expect(FileTreeController.unique("Résumé final.docx", in: scratch.url).lastPathComponent == "Résumé final 2.docx")
        }

        @Test(.tags(.fileModelFileSystem, .fileModelEdgeCase), arguments: [
            (false, "archive.tar 2.gz"), (true, "archive.tar copy.gz"),
        ])
        func onlyTheLastExtensionStaysAtTheEnd(copy: Bool, expected: String) throws {
            try scratch.file("archive.tar.gz")
            #expect(FileTreeController.unique("archive.tar.gz", in: scratch.url, copy: copy).lastPathComponent == expected)
        }

        @Test(.tags(.fileModelFileSystem, .fileModelEdgeCase), arguments: [
            (false, ".gitignore 2"), (true, ".gitignore copy"),
        ])
        func dotfileHasNoExtension(copy: Bool, expected: String) throws {
            try scratch.file(".gitignore")
            #expect(FileTreeController.unique(".gitignore", in: scratch.url, copy: copy).lastPathComponent == expected,
                    "A leading dot doesn't start an extension")
        }

        @Test(.tags(.fileModelFileSystem))
        func nothingIsCreated() throws {
            let url = FileTreeController.unique("untitled.txt", in: scratch.url)
            #expect(FileManager.default.fileExists(atPath: url.path) == false)
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).isEmpty)
        }

        @Test(.tags(.fileModelEdgeCase))
        func missingFolderGivesTheNameAsIs() {
            let folder = scratch.url.appending(path: "missing", directoryHint: .isDirectory)
            let url = FileTreeController.unique("untitled.txt", in: folder, copy: false)
            #expect(url.lastPathComponent == "untitled.txt")
            #expect(url.deletingLastPathComponent().lastPathComponent == "missing")
        }
    }
}

// MARK: - Helpers

/// A unique folder under the temporary directory, removed when the suite
/// instance that owns it (one per test) goes away.
fileprivate final class FileModelScratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(component: "SandshellFileModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `contents` to `relative`, making any folders on the way.
    @discardableResult
    func file(_ relative: String, _ contents: String = "") throws -> URL {
        let file = url.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let folder = url.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// An absolute symlink at `relative` pointing at `destination`.
    func link(_ relative: String, to destination: URL) throws -> URL {
        let link = url.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        return link
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(at: url.appending(path: relative, directoryHint: .notDirectory))
    }
}

/// Counts `FileWatcher` callbacks (delivered on the main queue).
@MainActor
fileprivate final class FileModelCallCounter {
    var count = 0
}

/// One file's diff, in pieces, for the `FilePatch` tests.
fileprivate enum FileModelPatchFixture {
    static let header = [
        "diff --git a/notes.txt b/notes.txt",
        "index 1111111..2222222 100644",
        "--- a/notes.txt",
        "+++ b/notes.txt",
    ]

    static let firstHunk = ["@@ -1,3 +1,3 @@", " one", "-two", "+TWO", " three"]

    static let secondHunk = [
        "@@ -10,2 +10,3 @@ func tail()", " ten", "+ten and a half", " eleven", "\\ No newline at end of file",
    ]

    /// Diffs with one hunk whose lines are odd in some way; each must survive
    /// splitting and rejoining untouched.
    static let singleHunkDiffs: [[String]] = [
        header + firstHunk,
        header + ["@@ -1 +1 @@", "-echo off\r", "+echo on\r"],
        header + ["@@ -1 +1 @@", "-old", "\\ No newline at end of file", "+new", "\\ No newline at end of file"],
        header + ["@@ -1,3 +1,3 @@", " a", "", "-b", "+B"],
        header + ["@@ -1,2 +1,2 @@", "-b", "+B", ""],
        header + ["@@ -1,2 +1,2 @@", " @@ not a hunk", "-x", "+y"],
        ["diff --git a/ü é.txt b/ü é.txt", "--- a/ü é.txt", "+++ b/ü é.txt", "@@ -1 +1 @@", "-ä", "+✓"],
    ]

    /// Diffs git prints without any hunk.
    static let diffsWithoutHunks = [
        "",
        "diff --git a/icon.png b/icon.png\nindex 3333333..4444444 100644\nBinary files a/icon.png and b/icon.png differ\n",
        "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n",
    ]

    /// Lines joined the way git prints them: newline-terminated.
    static func text(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }
}
