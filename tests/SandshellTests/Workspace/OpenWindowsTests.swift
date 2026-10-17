import Foundation
import Testing
@testable import Sandshell

// Tests for `OpenWindows` (Workspace/WorkspaceState.swift): the windows saved
// at quit come back at launch on their folders, each with the instance index it
// had, so a window that took a closed window's place keeps its own frame, split
// and pane layout rather than the next index's.
//
// Each test keeps the list in a throwaway defaults suite of its own (bound
// through `OpenWindows.$suiteName`), never the app's, and its folders in a
// fresh temporary directory. The suite is named by an absolute path, so its
// plist lands in that directory rather than ~/Library/Preferences.

/// A temporary directory holding one test's defaults suite and folders, removed with it.
fileprivate final class OpenWindowsScratch {
    let base: URL
    let suiteName: String

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandshellOpenWindowsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suiteName = base.appendingPathComponent("windows").path
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    /// A folder in the scratch directory, created unless `exists` is false.
    func folder(_ name: String, exists: Bool = true) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        if exists { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url.standardizedFileURL
    }

    /// The suite's own defaults, to set what an older build or a launch argument left.
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    /// Run `body` with `OpenWindows` keeping its list in this test's suite.
    func run<R>(_ body: () throws -> R) rethrows -> R {
        try OpenWindows.$suiteName.withValue(suiteName, operation: body)
    }
}

/// The paths of `windows`' roots, for comparing what was restored.
fileprivate func paths(_ windows: [OpenWindows.Window]) -> [String] {
    windows.map(\.root.standardizedFileURL.path)
}

struct OpenWindowsTests {
    private let scratch: OpenWindowsScratch

    init() throws {
        scratch = try OpenWindowsScratch()
    }

    @Test func eachWindowComesBackWithItsIndex() throws {
        let folder = try scratch.folder("project")
        let other = try scratch.folder("other")
        scratch.run {
            OpenWindows.replace(with: [
                .init(root: folder, instanceIndex: 0),
                .init(root: other, instanceIndex: 0),
                .init(root: folder, instanceIndex: 2),
            ])
            let restored = OpenWindows.windows
            #expect(paths(restored) == [folder.path, other.path, folder.path])
            #expect(restored.map(\.instanceIndex) == [0, 0, 2])
        }
    }

    @Test func aWindowAfterAClosedOneKeepsItsIndexAcrossRelaunch() throws {
        let folder = try scratch.folder("project")
        scratch.run {
            // W0, W1 and W2 open on one folder; W1 closes; the app quits.
            var open: [Int] = []
            for _ in 0..<3 { open.append(MainWindowController.instanceIndex(requested: nil, used: open)) }
            open.remove(at: 1)
            OpenWindows.replace(with: open.map { .init(root: folder, instanceIndex: $0) })

            // Relaunch: each restored window asks for the index it had.
            var restored: [Int] = []
            for window in OpenWindows.windows {
                restored.append(MainWindowController.instanceIndex(requested: window.instanceIndex, used: restored))
            }
            #expect(restored == [0, 2], "W2 must come back as itself, not as the closed W1")
        }
    }

    @Test func aMissingFolderDropsOutWithoutShiftingTheOthersIndexes() throws {
        let folder = try scratch.folder("project")
        let gone = try scratch.folder("gone", exists: false)
        scratch.run {
            OpenWindows.replace(with: [
                .init(root: gone, instanceIndex: 0),
                .init(root: folder, instanceIndex: 1),
            ])
            let restored = OpenWindows.windows
            #expect(paths(restored) == [folder.path])
            #expect(restored.map(\.instanceIndex) == [1])
        }
    }

    @Test func rootsSavedByAnOlderBuildComeBackWithoutIndexes() throws {
        let folder = try scratch.folder("project")
        scratch.defaults.set([folder.path, folder.path], forKey: "openWindowRoots")
        scratch.run {
            let restored = OpenWindows.windows
            #expect(paths(restored) == [folder.path, folder.path])
            #expect(restored.allSatisfy { $0.instanceIndex == nil })
        }
    }

    @Test func rootsSetAnotherWayDontTakeTheSavedIndexes() throws {
        let folder = try scratch.folder("project")
        let fixture = try scratch.folder("fixture")
        scratch.run {
            OpenWindows.replace(with: [.init(root: folder, instanceIndex: 3)])
        }
        // A self-test's `-openWindowRoots` argument names other roots.
        scratch.defaults.set([fixture.path], forKey: "openWindowRoots")
        scratch.run {
            let restored = OpenWindows.windows
            #expect(paths(restored) == [fixture.path])
            #expect(restored.first?.instanceIndex == nil)
        }
    }

    @Test func noWindowsOpenSavesAnEmptyList() throws {
        let folder = try scratch.folder("project")
        scratch.run {
            OpenWindows.replace(with: [.init(root: folder, instanceIndex: 0)])
            OpenWindows.replace(with: [])
            #expect(OpenWindows.windows.isEmpty)
        }
    }
}
