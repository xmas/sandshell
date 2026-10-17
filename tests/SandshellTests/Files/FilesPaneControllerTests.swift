import Foundation
import Testing
@testable import Sandshell

/// Tests for `FilesPaneController.adoptTabs(from:into:defaults:)`: the Files
/// inspector's remembered tabs moving from the folder key it used to use to its
/// own per-window key. Each test uses its own defaults suite, never `.standard`.
@MainActor
struct FilesPaneControllerTests {
    private let suite = "SandshellFilesPaneTests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let folderKey = FilesPaneController.folderTabsKey(URL(fileURLWithPath: "/srv/repo"))
    private let inspectorKey = "filesTabs:inspector:/srv/repo"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    @Test func folderKeyIsTheStandardizedPath() {
        #expect(FilesPaneController.folderTabsKey(URL(fileURLWithPath: "/srv/repo/sub/../")) == "filesTabs:/srv/repo")
    }

    @Test func inspectorStartsFromTheFolderListOnce() {
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/srv/repo/a.txt", "/srv/other/b.txt"], forKey: folderKey)
        FilesPaneController.adoptTabs(from: folderKey, into: inspectorKey, defaults: defaults)
        #expect(defaults.stringArray(forKey: inspectorKey) == ["/srv/repo/a.txt", "/srv/other/b.txt"])
        #expect(defaults.stringArray(forKey: folderKey) == ["/srv/repo/a.txt", "/srv/other/b.txt"],
                "Copied, not moved: a split Files pane on the folder may use it")
    }

    @Test func inspectorsOwnListIsNeverReplaced() {
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/srv/repo/mine.txt"], forKey: inspectorKey)
        defaults.set(["/srv/repo/pane.txt"], forKey: folderKey)
        FilesPaneController.adoptTabs(from: folderKey, into: inspectorKey, defaults: defaults)
        #expect(defaults.stringArray(forKey: inspectorKey) == ["/srv/repo/mine.txt"])
    }

    @Test func emptyOwnListCountsAsItsOwn() {
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([String](), forKey: inspectorKey)   // every tab closed
        defaults.set(["/srv/repo/pane.txt"], forKey: folderKey)
        FilesPaneController.adoptTabs(from: folderKey, into: inspectorKey, defaults: defaults)
        #expect(defaults.stringArray(forKey: inspectorKey) == [])
    }

    @Test func nothingToAdoptStillMarksItDone() {
        defer { defaults.removePersistentDomain(forName: suite) }
        FilesPaneController.adoptTabs(from: folderKey, into: inspectorKey, defaults: defaults)
        #expect(defaults.stringArray(forKey: inspectorKey) == [])
        // A split pane saving under the folder later doesn't leak into the inspector.
        defaults.set(["/srv/repo/pane.txt"], forKey: folderKey)
        FilesPaneController.adoptTabs(from: folderKey, into: inspectorKey, defaults: defaults)
        #expect(defaults.stringArray(forKey: inspectorKey) == [])
    }
}
