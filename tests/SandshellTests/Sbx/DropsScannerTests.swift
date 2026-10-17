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

    /// A dropped file the agent then changed: an APFS clone of a file
    /// outside the drops folder, written over at its start (not replaced), so
    /// it owns a block of its own.
    @discardableResult
    func changedDrop(_ relative: String, _ text: String) throws -> URL {
        let original = base.appending(path: "originals/\(relative)", directoryHint: .notDirectory)
        let drop = dropDir.appending(path: relative, directoryHint: .notDirectory)
        for url in [original, drop] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(String(repeating: "-", count: 8192).utf8).write(to: original)
        try #require(clonefile(original.path(percentEncoded: false), drop.path(percentEncoded: false), 0) == 0,
                     "The temporary directory should be on APFS")
        let handle = try FileHandle(forWritingTo: drop)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(text.utf8))
        return drop
    }
}

/// `DropsScanner` (Sbx/DropsScanner.swift): which dropped files the agent
/// changed (APFS private bytes), and copying them out with their folders.
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
}
