import AppKit
import Foundation
import Testing
@testable import Sandshell

/// Tests for `Files/FileEditorController.swift`: an `OpenFile`'s view of the
/// disk (the version it last read or saved, writes, moves) and the editor's
/// tabs following moves and trashing, and what Print prints.
///
/// Not covered: saving through the editor (`save(_:)` asks with an alert when
/// the disk changed) and the print operation itself.
struct FileEditorControllerTests {

    // MARK: - OpenFile and the disk

    @MainActor
    struct OpenFiles {
        private let scratch: EditorScratch

        init() throws {
            scratch = try EditorScratch()
        }

        @Test(.tags(.fileSystem))
        func aFreshlyOpenedFileMatchesTheDisk() throws {
            let file = OpenFile(url: try scratch.file("a.txt", "one\n"))
            #expect(file.diskChange == nil)
            #expect(file.modified != nil)
        }

        /// A tab for a file that doesn't exist yet has nothing on disk to
        /// differ from, so saving it doesn't ask.
        @Test(.tags(.fileSystem, .edgeCase))
        func aFileThatNeverExistedHasNoChangeOnDisk() {
            let file = OpenFile(url: scratch.url.appending(path: "never.txt"))
            #expect(file.modified == nil)
            #expect(file.diskChange == nil)
        }

        @Test(.tags(.fileSystem))
        func anotherWriterMakesItRewritten() throws {
            let url = try scratch.file("a.txt", "one\n")
            let file = OpenFile(url: url)
            try scratch.rewrite(url, "agent's\n")
            #expect(file.diskChange == .rewritten)
        }

        enum Removal: CaseIterable { case deleted, movedAway }

        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.32"), arguments: Removal.allCases)
        func aFileNoLongerThereIsGone(removal: Removal) throws {
            let url = try scratch.file("notes.md", "# Notes\n")
            let file = OpenFile(url: url)
            file.text += "more\n"
            switch removal {
            case .deleted: try FileManager.default.removeItem(at: url)
            case .movedAway: try FileManager.default.moveItem(at: url, to: scratch.url.appending(path: "renamed.md"))
            }
            #expect(file.diskChange == .gone, "Saving must ask before writing it back at the old path")
        }

        /// The cached date from before a write must not stand in for the
        /// write's own date.
        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.21"))
        func modificationDateIsReadFreshNotFromTheURLsCache() throws {
            let url = try scratch.file("a.txt", "one\n", modified: EditorScratch.longAgo)
            #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == EditorScratch.longAgo)
            try "two\n".write(to: url, atomically: true, encoding: .utf8)
            let onDisk = try #require(OpenFile.modificationDate(of: url))
            #expect(onDisk > EditorScratch.longAgo)
        }

        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.21"))
        func writeMakesTheWrittenVersionTheSavedOne() throws {
            let url = try scratch.file("a.txt", "one\n", modified: EditorScratch.longAgo)
            let file = OpenFile(url: url)
            file.text = "one\ntwo\n"
            try file.write()
            #expect(file.isDirty == false)
            #expect(file.modified != EditorScratch.longAgo, "The date recorded must be the write's, not the one from before it")
            #expect(file.diskChange == nil, "A refresh right after saving mustn't see a change on disk")
            #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
        }

        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.22"))
        func aMovedFileStillComparesWithTheVersionItWasOpenedFrom() throws {
            let url = try scratch.file("a.txt", "one\n")
            let file = OpenFile(url: url)
            file.text = "mine\n"
            try scratch.rewrite(url, "agent's\n")
            let moved = scratch.url.appending(path: "b.txt")
            try FileManager.default.moveItem(at: url, to: moved)
            file.move(to: moved)
            #expect(file.url == moved)
            #expect(file.text == "mine\n")
            #expect(file.isDirty)
            #expect(file.diskChange == .rewritten, "Saving must still ask before replacing the agent's version")
        }

        /// A rename keeps the file's modification date: nothing changed.
        @Test(.tags(.fileSystem))
        func aRenameAloneIsNoChangeOnDisk() throws {
            let url = try scratch.file("a.txt", "one\n")
            let file = OpenFile(url: url)
            let moved = scratch.url.appending(path: "b.txt")
            try FileManager.default.moveItem(at: url, to: moved)
            file.move(to: moved)
            #expect(file.diskChange == nil)
        }
    }

    // MARK: - The editor's tabs

    @MainActor
    struct Tabs {
        private let scratch: EditorScratch
        private let editor = FileEditorController()

        init() throws {
            scratch = try EditorScratch()
            editor.loadViewIfNeeded()
        }

        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.22"))
        func tabsFollowAMovedFolderWithTheirEdits() throws {
            let inside = try scratch.file("docs/a.txt", "one\n")
            let outside = try scratch.file("b.txt", "two\n")
            editor.open(outside)
            editor.open(inside)
            editor.debugType("mine ", at: 0)
            try scratch.rewrite(inside, "agent's\n")
            let renamed = scratch.url.appending(path: "notes", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: scratch.url.appending(path: "docs"), to: renamed)
            editor.fileMoved(from: scratch.url.appending(path: "docs"), to: renamed)
            let moved = renamed.appending(path: "a.txt")
            #expect(editor.openURLs.map(\.path) == [outside.path, moved.path])
            #expect(editor.currentURL?.path == moved.path)
            #expect(editor.debugIsDirty)
            #expect(editor.debugEditorText == "mine one\n")
            #expect(editor.debugDiskChange == .rewritten, "Saving must still ask before replacing the agent's version")
        }

        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.32"))
        func trashingClosesCleanTabsAndKeepsOnesWithEdits() throws {
            let clean = try scratch.file("docs/a.txt", "one\n")
            let other = try scratch.file("b.txt", "two\n")
            let edited = try scratch.file("notes.md", "# Notes\n")
            editor.open(clean)
            editor.open(other)
            editor.open(edited)
            editor.setMode(.source)
            editor.debugType("more ", at: 0)
            // Stand-in for the Trash: out of the folder, where the tree's trash() puts them.
            let trash = try scratch.folder("Trash")
            for url in [scratch.url.appending(path: "docs"), edited] {
                try FileManager.default.moveItem(at: url, to: trash.appending(path: url.lastPathComponent))
            }
            editor.filesTrashed([scratch.url.appending(path: "docs"), edited])
            #expect(editor.openURLs.map(\.path) == [other.path, edited.path], "Clean tabs under the trashed folder close")
            #expect(editor.currentURL?.path == edited.path)
            #expect(editor.debugIsDirty, "Unsaved edits stay open")
            #expect(editor.debugDiskChange == .gone, "Saving must ask before putting it back")
        }

        // MARK: Print

        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.19"))
        func printPrintsTheShownPreviewNotTheSourceShownBefore() throws {
            editor.open(try scratch.file("main.swift", "let answer = 42\n"))
            editor.open(try scratch.file("README.md", "# Read Me\n\nHello there.\n"))
            let printed = try #require(editor.printView as? NSTextView)
            #expect(printed.string.contains("Hello there."))
            #expect(printed.string.contains("answer") == false, "The hidden source editor still holds main.swift")
        }

        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.19"))
        func printPrintsTheSourceInSourceMode() throws {
            editor.open(try scratch.file("main.swift", "let answer = 42\n"))
            editor.open(try scratch.file("README.md", "# Read Me\n"))
            editor.setMode(.source)
            let printed = try #require(editor.printView as? NSTextView)
            #expect(printed.string == "# Read Me\n")
        }

        @Test(.tags(.fileSystem, .edgeCase))
        func nothingToPrintWithoutATextFile() throws {
            #expect(editor.printView == nil)
            editor.open(try scratch.file("blob.bin", "\u{0}\u{1}\u{2}"))
            #expect(editor.printView == nil, "A file that isn't text shows in Quick Look")
        }
    }
}

/// A scratch folder under the temporary directory, removed with the suite.
fileprivate final class EditorScratch {
    /// A date no file in the test is otherwise written at (APFS can't store
    /// dates before 1970, so not `.distantPast`).
    static let longAgo = Date(timeIntervalSinceReferenceDate: 0)

    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(component: "SandshellFileEditorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `contents` to `relative` (making folders on the way), dated
    /// `modified` when given.
    func file(_ relative: String, _ contents: String, modified: Date? = nil) throws -> URL {
        let file = url.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }

    func folder(_ relative: String) throws -> URL {
        let folder = url.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Another writer (an agent) replaces the file; dated an hour on, so it
    /// differs from the version read even within the same clock tick.
    func rewrite(_ file: URL, _ contents: String) throws {
        try contents.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(3600)], ofItemAtPath: file.path)
    }
}
