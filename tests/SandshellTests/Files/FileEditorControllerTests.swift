import AppKit
import Foundation
import Testing
@testable import Sandshell

/// Tests for `Files/FileEditorController.swift`: an `OpenFile`'s view of the
/// disk (the version it last read or saved, writes, moves, files it can't
/// read), the editor's tabs following moves, trashing and its undo (and the
/// banner saying the disk differs), what Print prints, how lines are counted,
/// how diffs are numbered and rendered, and the gutter's change bars
/// (`LineChanges(unifiedDiff:)`).
///
/// Not covered: saving when the disk changed (`save(_:)` asks with an alert)
/// and the print operation itself.
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

        enum Unreadable: CaseIterable { case noPermission, folder }

        /// A file that's there but can't be read isn't an empty editable copy
        /// (a save would write over it): it says why instead.
        @Test(.tags(.fileSystem, .edgeCase), arguments: Unreadable.allCases)
        func aFileThatCantBeReadIsNotText(_ unreadable: Unreadable) throws {
            let url: URL
            switch unreadable {
            case .noPermission:
                url = try scratch.file("secret.txt", "keep out\n")
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            case .folder:
                url = try scratch.folder("docs")
            }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            let file = OpenFile(url: url)
            #expect(file.isText == false)
            #expect(file.readError != nil)
            #expect(file.text.isEmpty)
            #expect(file.isDirty == false)
        }

        /// One that isn't there yet opens empty, to be saved into place.
        @Test(.tags(.fileSystem, .edgeCase))
        func aFileNotThereYetOpensAsEmptyText() {
            let file = OpenFile(url: scratch.url.appending(path: "new.txt"))
            #expect(file.isText)
            #expect(file.readError == nil)
            #expect(file.text.isEmpty)
        }

        @Test(.tags(.fileSystem))
        func aReadableFileHasNoReadError() throws {
            let file = OpenFile(url: try scratch.file("a.txt", "one\r\ntwo\r\n"))
            #expect(file.isText)
            #expect(file.readError == nil)
            #expect(file.text == "one\r\ntwo\r\n", "Line endings are kept as they are on disk")
        }
    }

    // MARK: - Lines, diffs and change bars

    @MainActor
    struct Lines {
        /// The editor's count matches NSString.lineRange (what Go to Line and
        /// the ruler use): CRLF is one break, a lone CR or U+2028 one too, a
        /// form feed or vertical tab none.
        @Test(arguments: [
            ("", 1), ("one", 1), ("one\n", 2), ("one\ntwo", 2), ("one\ntwo\n", 3),
            ("one\r\ntwo\r\nthree", 3), ("one\r\n", 2), ("one\rtwo", 2), ("one\u{2028}two", 2),
            ("one\u{0C}two\u{0B}three", 1), ("\n\n", 3),
        ])
        func lineCountIsWhatTheRulerNumbers(text: String, lines: Int) {
            #expect(FileEditorController.lineCount(of: text) == lines)
            // The same breaks NSString finds, line by line.
            let ns = text as NSString
            var breaks = 0, location = 0
            while location < ns.length {
                var end = 0, contentsEnd = 0
                ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
                if contentsEnd < end { breaks += 1 }
                location = end
            }
            #expect(breaks + 1 == lines)
        }

        @Test func untrackedFileIsAllAddedOneLineEach() {
            #expect(FileEditorController.untrackedDiff("a\nb\n") == "+a\n+b\n+")
            #expect(FileEditorController.untrackedDiff("a\r\nb\r\n") == "+a\n+b\n+", "A CRLF file isn't one long line")
            #expect(FileEditorController.untrackedDiff("") == "+")
        }

        @Test func untrackedFileIsNumberedFromOne() {
            let rendered = FileEditorController.renderDiff(FileEditorController.untrackedDiff("first\r\nsecond\r\n"), untracked: true)
            #expect(rendered.string.contains("    1 +first\n"))
            #expect(rendered.string.contains("    2 +second\n"))
            #expect(rendered.string.contains("    3") == false, "No line after the last newline")
        }

        /// git ends a CRLF file's content lines with "\r\n" (one Character in Swift).
        @Test func crlfDiffIsSplitIntoItsLines() {
            let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-old\r\n+new\r\n same\r\n"
            let rendered = FileEditorController.renderDiff(diff).string
            #expect(rendered.contains("    1 -old\n"))
            #expect(rendered.contains("    1 +new\n"))
            #expect(rendered.contains("    2  same\n"))
            #expect(rendered.contains("+++") == false, "File headers aren't shown")
        }

        /// git splits diff lines only at LF: a form feed or lone CR inside a line is content.
        @Test(.tags(.edgeCase))
        func formFeedInADiffLineIsContent() {
            let diff = "@@ -1 +1,2 @@\n-a\u{0C}b\n+a\u{0C}c\n+d\re\n"
            let numbers = FileEditorController.lineNumbers(diff.components(separatedBy: "\n"))
            let rendered = FileEditorController.renderDiff(diff).string
            #expect(rendered.contains("    1 -a\u{0C}b\n"))
            #expect(rendered.contains("    2 +d\re\n"))
            #expect(numbers.compactMap { $0?.line } == [1, 1, 2])
        }

        @Test func annotateNumbersNewLinesAndRemovedOnesByTheOldFile() {
            let lines = ["diff --git a/x b/x", "index 1..2 100644", "--- a/x", "+++ b/x",
                         "@@ -3,3 +3,3 @@ func", " keep", "-gone", "+came", " tail", ""]
            let annotated = FileEditorController.annotate(lines)
            #expect(annotated.map(\.header) == [true, true, true, true, false, false, false, false, false, true])
            #expect(annotated.map { $0.number?.line } == [nil, nil, nil, nil, nil, 3, 4, 4, 5, nil])
            #expect(annotated.map { $0.number?.old } == [nil, nil, nil, nil, nil, false, true, false, false, nil])
        }

        /// Inside a hunk, "--" and "++" lines are a removed "-" line and an added "+" one.
        @Test(.tags(.edgeCase))
        func headerLookalikesInsideAHunkAreContent() {
            let annotated = FileEditorController.annotate(["@@ -1,2 +1,2 @@", "-- comment", "+++ counter", ""])
            #expect(annotated.map(\.header) == [false, false, false, true])
            #expect(annotated.map { $0.number?.line } == [nil, 1, 1, nil])
        }

        @Test func eachHunkRestartsTheNumbering() {
            let numbers = FileEditorController.lineNumbers(["@@ -1 +1 @@", "-a", "+b", "@@ -40,0 +41 @@", "+z"])
            #expect(numbers.map { $0?.line } == [nil, 1, 1, nil, 41])
        }

        @Test(.tags(.edgeCase))
        func noNewlineMarkerHasNoNumber() {
            let numbers = FileEditorController.lineNumbers(["@@ -1 +1 @@", "-a", "\\ No newline at end of file", "+b"])
            #expect(numbers.map { $0?.line } == [nil, 1, nil, 1])
        }
    }

    // MARK: - LineChanges(unifiedDiff:)

    struct ChangeBars {
        @Test func addedLinesHaveNoOldCount() {
            #expect(LineChanges(unifiedDiff: "@@ -3,0 +4,2 @@\n+a\n+b\n") == LineChanges(added: [4, 5]))
        }

        @Test func countsDefaultToOne() {
            #expect(LineChanges(unifiedDiff: "@@ -10 +12 @@ func f()\n-a\n+b\n") == LineChanges(modified: [12]))
        }

        @Test func aDeletionMarksTheLineBeforeIt() {
            #expect(LineChanges(unifiedDiff: "@@ -7,2 +6,0 @@\n-a\n-b\n") == LineChanges(deletedAfter: [6]))
            #expect(LineChanges(unifiedDiff: "@@ -1 +0,0 @@\n-a\n") == LineChanges(deletedAfter: [0]), "0: before the first line")
        }

        @Test func everyHunkCounts() {
            let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,3 @@\n-a\n+b\n+c\n+d\n@@ -9,0 +11 @@\n+e\n@@ -20 +21,0 @@\n-f\n"
            #expect(LineChanges(unifiedDiff: diff) == LineChanges(added: [11], modified: [1, 2, 3], deletedAfter: [21]))
        }

        /// A content line that looks like a hunk header starts with "+", "-" or " ".
        @Test(.tags(.edgeCase))
        func headerLookalikeContentIsNotAHunk() {
            #expect(LineChanges(unifiedDiff: "@@ -1 +1 @@\n-@@ -5 +5 @@\n+@@ -6,0 +7 @@\n") == LineChanges(modified: [1]))
        }

        @Test(.tags(.edgeCase))
        func noHunksNoChanges() {
            #expect(LineChanges(unifiedDiff: "") == LineChanges())
            #expect(LineChanges(unifiedDiff: "Binary files a/x and b/x differ\n") == LineChanges())
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

        /// A folder's URL from the tree ends in "/" (`contentsOfDirectory`):
        /// the tabs inside it still follow it, and back again on Undo.
        @Test(.tags(.fileSystem, .edgeCase))
        func tabsFollowAFolderWhoseURLEndsInASlash() throws {
            let inside = try scratch.file("docs/a.txt", "one\n")
            editor.open(inside)
            let docs = scratch.url.appending(path: "docs", directoryHint: .isDirectory)
            let notes = scratch.url.appending(path: "notes", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: docs, to: notes)
            editor.fileMoved(from: docs, to: notes)
            #expect(editor.openURLs.map(\.path) == [notes.appending(path: "a.txt").path])

            try FileManager.default.moveItem(at: notes, to: docs)
            editor.fileMoved(from: notes, to: docs)
            #expect(editor.openURLs.map(\.path) == [inside.path])
        }

        /// It says why it couldn't be read, with nothing to edit, save or print.
        @Test(.tags(.fileSystem, .edgeCase))
        func anUnreadableFileShowsWhyInsteadOfAnEmptyEditor() throws {
            let url = try scratch.file("secret.txt", "keep out\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            editor.open(url)
            #expect(editor.currentURL == url)
            #expect(editor.printView == nil)
            #expect(editor.debugEmptyMessage?.contains("secret.txt") == true)

            editor.open(try scratch.file("b.txt", "two\n"))
            #expect(editor.debugEmptyMessage == nil, "A readable file shows in the editor")
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
            #expect(editor.debugBanner == "notes.md was moved or deleted.")
        }

        /// ⌘⌫ then ⌘Z leaves the editor as it was: the closed tabs come back
        /// in their places, modes and selections, the shown one shown again.
        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.32"))
        func undoingTheTrashReopensTheTabsItClosed() throws {
            let guide = try scratch.file("docs/guide.md", "# Guide\n")
            let other = try scratch.file("b.txt", "two\n")
            let current = try scratch.file("docs/a.txt", "one\ntwo\n")
            editor.open(guide)
            editor.setMode(.source)   // not what a fresh tab on it would show
            editor.open(other)
            editor.open(current)
            editor.goToLineForTesting(2)
            let docs = scratch.url.appending(path: "docs")
            let inTrash = try scratch.folder("Trash").appending(path: "docs")
            try FileManager.default.moveItem(at: docs, to: inTrash)
            let reopen = editor.filesTrashed([docs])
            #expect(editor.openURLs.map(\.path) == [other.path])

            try FileManager.default.moveItem(at: inTrash, to: docs)
            reopen()
            #expect(editor.openURLs.map(\.path) == [guide.path, other.path, current.path])
            #expect(editor.currentURL?.path == current.path)
            #expect(editor.debugCaret == 4, "The caret is where it was, on line 2")
            editor.open(guide)
            #expect(editor.debugMode == .source)
        }

        /// What Undo can't put back stays closed; a tab opened again in the
        /// meantime isn't doubled.
        @Test(.tags(.fileSystem, .edgeCase), .bug(id: "xmas-sandshell-e7q.32"))
        func reopeningSkipsFilesNotBackAndTabsAlreadyOpen() throws {
            let gone = try scratch.file("gone.txt", "one\n")
            let back = try scratch.file("back.txt", "two\n")
            editor.open(gone)
            editor.open(back)
            let trash = try scratch.folder("Trash")
            for url in [gone, back] { try FileManager.default.moveItem(at: url, to: trash.appending(path: url.lastPathComponent)) }
            let reopen = editor.filesTrashed([gone, back])
            #expect(editor.openURLs.isEmpty)

            try FileManager.default.moveItem(at: trash.appending(path: "back.txt"), to: back)
            editor.open(back)
            reopen()
            #expect(editor.openURLs.map(\.path) == [back.path])
        }

        enum Return: CaseIterable { case undo, refresh }

        /// The file comes back as the tab opened it (Undo Move to Trash keeps
        /// its date): the "moved or deleted" banner comes down, whether the
        /// undo's reopen or the next FSEvents refresh notices first.
        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.32"), arguments: Return.allCases)
        func theGoneBannerComesDownWhenTheFileIsBack(by way: Return) throws {
            let notes = try scratch.file("notes.md", "# Notes\n")
            editor.open(notes)
            editor.setMode(.source)
            editor.debugType("more ", at: 0)
            let inTrash = try scratch.folder("Trash").appending(path: "notes.md")
            try FileManager.default.moveItem(at: notes, to: inTrash)
            let reopen = editor.filesTrashed([notes])
            #expect(editor.debugBanner == "notes.md was moved or deleted.")

            try FileManager.default.moveItem(at: inTrash, to: notes)
            switch way {
            case .undo: reopen()
            case .refresh: editor.filesChangedOnDisk()
            }
            #expect(editor.debugBanner == nil)
            #expect(editor.debugIsDirty, "The edits are still there to save")
        }

        /// Saving makes the disk this tab's version: no banner left saying
        /// otherwise, even before the refresh that follows the write.
        @Test(.tags(.fileSystem), .bug(id: "xmas-sandshell-e7q.32"))
        func savingTakesTheBannerDown() throws {
            let notes = try scratch.file("notes.md", "# Notes\n")
            editor.open(notes)
            editor.setMode(.source)
            editor.debugType("more ", at: 0)
            let inTrash = try scratch.folder("Trash").appending(path: "notes.md")
            try FileManager.default.moveItem(at: notes, to: inTrash)
            editor.filesTrashed([notes])
            #expect(editor.debugBanner != nil)
            // Back before any refresh, so saving doesn't need to ask.
            try FileManager.default.moveItem(at: inTrash, to: notes)
            editor.saveDocument(nil)
            #expect(editor.debugIsDirty == false)
            #expect(editor.debugBanner == nil)
            #expect(try String(contentsOf: notes, encoding: .utf8) == "more # Notes\n")
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
