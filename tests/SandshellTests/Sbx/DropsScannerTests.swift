import Darwin
import Foundation
import Testing
@testable import Sandshell

/// A temporary folder holding one test's `.sbx/drops`, removed with it. It's
/// spelled /var/folders/…, which the enumerator resolves to
/// /private/var/folders/… — like a workspace under /tmp or behind a symlink.
fileprivate final class DropsScratch {
    let base: URL
    let dropDir: URL
    let stagingDir: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "SandshellDropsScannerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        dropDir = base.appending(path: ".sbx/drops", directoryHint: .isDirectory)
        stagingDir = base.appending(path: ".sbx/drops-changed-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    /// A dropped file left alone: an APFS clone of a file outside the drops
    /// folder, sharing all its blocks.
    @discardableResult
    func untouchedDrop(_ relative: String) throws -> URL {
        let original = base.appending(path: "originals/\(relative)", directoryHint: .notDirectory)
        let drop = dropDir.appending(path: relative, directoryHint: .notDirectory)
        for url in [original, drop] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(String(repeating: "-", count: 8192).utf8).write(to: original)
        try #require(clonefile(original.path(percentEncoded: false), drop.path(percentEncoded: false), 0) == 0,
                     "The temporary directory should be on APFS")
        return drop
    }

    /// A dropped file the agent then changed: written over at its start (not
    /// replaced), so it owns a block of its own.
    @discardableResult
    func changedDrop(_ relative: String, _ text: String) throws -> URL {
        let drop = try untouchedDrop(relative)
        let handle = try FileHandle(forWritingTo: drop)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(text.utf8))
        return drop
    }

    /// A file the agent made in the drops folder: all its blocks are its own.
    func newFile(_ relative: String, _ text: String) throws {
        let url = dropDir.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A dropped file FileManager couldn't clone (from an external disk, a
    /// network share, another APFS volume): a full copy, which owns all its
    /// blocks and keeps the original's modification date, a day old here.
    @discardableResult
    func fullCopyDrop(_ relative: String) throws -> URL {
        let original = base.appending(path: "originals/\(relative)", directoryHint: .notDirectory)
        let drop = dropDir.appending(path: relative, directoryHint: .notDirectory)
        for url in [original, drop] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(String(repeating: "-", count: 8192).utf8).write(to: original)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-86_400)],
                                              ofItemAtPath: original.path(percentEncoded: false))
        // COPYFILE_ALL without COPYFILE_CLONE: what FileManager falls back to.
        try #require(copyfile(original.path(percentEncoded: false), drop.path(percentEncoded: false),
                              nil, copyfile_flags_t(COPYFILE_ALL)) == 0)
        return drop
    }

    /// Record a drop in `.provenance` as the drop handler does
    /// (`TerminalStackController.recordProvenance`), keyed by the top-level name.
    func recordDrop(_ name: String, at date: Date) throws {
        let url = dropDir.appending(path: ".provenance", directoryHint: .notDirectory)
        var entries = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: [String: String]] ?? [:]
        entries[name] = ["source": "/Volumes/Elsewhere/\(name)", "droppedAt": ISO8601DateFormatter().string(from: date)]
        try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}

/// Appends text to a file in place, as an agent's edit would.
fileprivate func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

/// `DropsScanner` (Sbx/DropsScanner.swift): which dropped files the agent
/// changed (APFS private bytes for clones, dates for full copies), and copying
/// them out with their folders.
struct DropsScannerTests {
    private let scratch: DropsScratch

    init() throws {
        scratch = try DropsScratch()
    }

    @Test("Changed files are found with their path inside the drops folder", .tags(.fileSystem))
    func changedFilesHaveTheirRelativePath() throws {
        try scratch.changedDrop("My Folder/notes.md", "changed")
        try scratch.changedDrop("top level.txt", "changed too")

        let changed = DropsScanner.scan(dropDir: scratch.dropDir)

        #expect(Set(changed.map(\.relativePath)) == ["My Folder/notes.md", "top level.txt"])
        #expect(changed.allSatisfy { $0.privateBytes > 0 })
    }

    @Test("Untouched clones aren't changed; edited clones and new files are", .tags(.fileSystem))
    func onlyFilesWithBlocksOfTheirOwnAreChanged() throws {
        try scratch.untouchedDrop("same/untouched.txt")
        try scratch.changedDrop("same/edited.txt", "changed")
        try scratch.newFile("same/new.txt", "made by the agent")

        let changed = DropsScanner.scan(dropDir: scratch.dropDir)

        #expect(Set(changed.map(\.relativePath)) == ["same/edited.txt", "same/new.txt"])
    }

    @Test("Export copies each changed file to the same path under the staging folder", .tags(.fileSystem))
    func exportKeepsTheFolders() throws {
        let drop = try scratch.changedDrop("My Folder/sub/notes.md", "changed")

        try DropsScanner.export(DropsScanner.scan(dropDir: scratch.dropDir), from: scratch.dropDir, to: scratch.stagingDir)

        let copied = scratch.stagingDir.appending(path: "My Folder/sub/notes.md", directoryHint: .notDirectory)
        let text = try String(contentsOf: copied, encoding: .utf8)
        #expect(text.hasPrefix("changed"))
        #expect(text == (try String(contentsOf: drop, encoding: .utf8)))
    }

    @Test(.tags(.fileSystem, .edgeCase))
    func missingDropsFolderHasNoChanges() {
        #expect(DropsScanner.scan(dropDir: scratch.base.appending(path: "nowhere", directoryHint: .isDirectory)).isEmpty)
    }

    @Test("A full copy (a drop that couldn't be cloned) is changed only once written to", .tags(.fileSystem))
    func fullCopiesAreJudgedByDate() throws {
        let anHourAgo = Date.now.addingTimeInterval(-3600)
        try scratch.fullCopyDrop("Far Folder/untouched.txt")
        let edited = try scratch.fullCopyDrop("Far Folder/edited.txt")
        try scratch.recordDrop("Far Folder", at: anHourAgo)
        try scratch.fullCopyDrop("loose.txt")
        try scratch.recordDrop("loose.txt", at: anHourAgo)
        try append("changed", to: edited)
        try scratch.newFile("Far Folder/made by the agent.txt", "new")

        let changed = DropsScanner.scan(dropDir: scratch.dropDir)

        #expect(Set(changed.map(\.relativePath)) == ["Far Folder/edited.txt", "Far Folder/made by the agent.txt"])
    }

    @Test("A full copy with no recorded drop counts as changed", .tags(.fileSystem, .edgeCase))
    func unrecordedFullCopyIsChanged() throws {
        try scratch.fullCopyDrop("unrecorded.txt")
        try scratch.recordDrop("something else.txt", at: .now.addingTimeInterval(-3600))

        #expect(DropsScanner.scan(dropDir: scratch.dropDir).map(\.relativePath) == ["unrecorded.txt"])
    }

    @Test("Drop times are read from .provenance; unreadable entries are left out", .tags(.fileSystem))
    func dropTimesComeFromProvenance() throws {
        let dropped = try Date("2026-10-17T09:30:00Z", strategy: .iso8601)
        try scratch.recordDrop("notes.md", at: dropped)
        let url = scratch.dropDir.appending(path: ".provenance", directoryHint: .notDirectory)
        var entries = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        entries["no date"] = ["source": "/somewhere"]
        entries["bad date"] = ["source": "/somewhere", "droppedAt": "yesterday"]
        try JSONSerialization.data(withJSONObject: entries).write(to: url)

        #expect(DropsScanner.dropTimes(in: scratch.dropDir) == ["notes.md": dropped])
    }

    @Test(.tags(.fileSystem, .edgeCase))
    func missingProvenanceHasNoDropTimes() {
        #expect(DropsScanner.dropTimes(in: scratch.dropDir).isEmpty)
    }
}

/// `DropsScanner.isChanged`: clones by their blocks, full copies by date.
struct DropsChangeRuleTests {
    private static let dropped = Date(timeIntervalSinceReferenceDate: 800_000_000)

    struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        let blocks: DropsScanner.Blocks
        let modified: Date?
        let droppedAt: Date?
        let changed: Bool
        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(label: "untouched clone", blocks: .init(privateBytes: 0, mayShare: true),
             modified: dropped.addingTimeInterval(60), droppedAt: dropped, changed: false),
        Case(label: "edited clone, even with an old date", blocks: .init(privateBytes: 4096, mayShare: true),
             modified: dropped.addingTimeInterval(-86_400), droppedAt: dropped, changed: true),
        Case(label: "full copy keeping the original's date", blocks: .init(privateBytes: 8192, mayShare: false),
             modified: dropped.addingTimeInterval(-86_400), droppedAt: dropped, changed: false),
        Case(label: "full copy of a file saved in the drop's second", blocks: .init(privateBytes: 8192, mayShare: false),
             modified: dropped.addingTimeInterval(0.6), droppedAt: dropped, changed: false),
        Case(label: "full copy written after the drop", blocks: .init(privateBytes: 8192, mayShare: false),
             modified: dropped.addingTimeInterval(5), droppedAt: dropped, changed: true),
        Case(label: "file of its own with no recorded drop", blocks: .init(privateBytes: 4096, mayShare: false),
             modified: dropped.addingTimeInterval(-86_400), droppedAt: nil, changed: true),
        Case(label: "file of its own with no date", blocks: .init(privateBytes: 4096, mayShare: false),
             modified: nil, droppedAt: dropped, changed: true),
    ]

    @Test(arguments: cases)
    func changeRule(_ c: Case) {
        #expect(DropsScanner.isChanged(c.blocks, modified: c.modified, droppedAt: c.droppedAt) == c.changed)
    }
}
