import Foundation
import Testing
@testable import Sandshell

// Tests for what keeps several windows on one folder apart: the instance index
// a new window takes (`MainWindowController.freeInstanceIndex`, which picks its
// frame, split and Files autosave names) and the key its pane layout is saved
// under (`PaneTreeController.layoutKey`). Paths are under `/srv`, which doesn't
// exist, so nothing on disk is consulted.

struct WindowInstanceIndexTests {
    @Test("A new window takes the lowest index no open window on its folder holds", arguments: [
        ([], 0),
        ([0], 1),
        ([0, 1], 2),
        ([1], 0),
        ([0, 2], 1),
        ([1, 2], 0),
        ([2, 0, 1], 3),
    ] as [([Int], Int)])
    func freeIndex(used: [Int], expected: Int) {
        #expect(MainWindowController.freeInstanceIndex(used: used) == expected)
    }

    @Test func duplicatingAfterTheFirstWindowClosedKeepsOpenWindowsApart() {
        var open: [Int] = []
        open.append(MainWindowController.freeInstanceIndex(used: open))   // the folder's window
        open.append(MainWindowController.freeInstanceIndex(used: open))   // Duplicate Window
        open.removeFirst()                                                // close the first
        open.append(MainWindowController.freeInstanceIndex(used: open))   // Duplicate again
        #expect(Set(open).count == open.count, "open windows' indexes \(open) collide")
    }
}

struct PaneLayoutKeyTests {
    private let root = URL(fileURLWithPath: "/srv/project")

    @Test func theFirstWindowKeepsTheFolderKey() {
        #expect(PaneTreeController.layoutKey(root: root, instanceIndex: 0) == "paneLayout:/srv/project")
    }

    @Test func eachWindowOnAFolderSavesUnderItsOwnKey() {
        let keys = (0..<4).map { PaneTreeController.layoutKey(root: root, instanceIndex: $0) }
        #expect(Set(keys).count == keys.count)
        #expect(keys[2] == "paneLayout:/srv/project#2")
    }

    @Test func theKeyNamesTheStandardizedFolder() {
        let unstandardized = URL(fileURLWithPath: "/srv/other/../project")
        #expect(PaneTreeController.layoutKey(root: unstandardized, instanceIndex: 1) == "paneLayout:/srv/project#1")
    }
}
