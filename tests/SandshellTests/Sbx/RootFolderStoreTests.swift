import Foundation
import Testing
@testable import Sandshell

// Tests for `RootFolderStore`'s launch folder (Sbx/RootFolderStore.swift):
// which folder becomes the launch default as folders are opened, that turning
// it off sticks, and what launch opens when the chosen folder is gone.
//
// Each test keeps the registry in a throwaway defaults suite of its own (bound
// through `RootFolderStore.$suiteName`), never the app's, and its folders, in
// a fresh temporary directory. The suite is named by an absolute path, so its
// plist lands in that directory rather than ~/Library/Preferences.

/// A temporary directory holding one test's defaults suite and folders, removed with it.
fileprivate final class RootFolderStoreScratch {
    let base: URL
    let suiteName: String

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandshellRootFolderStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suiteName = base.appendingPathComponent("registry").path
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    /// The standardized path of a folder in the scratch directory, created
    /// unless `exists` is false (a folder that's gone).
    func folder(_ name: String, exists: Bool = true) throws -> String {
        let url = base.appendingPathComponent(name, isDirectory: true)
        if exists { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return RootFolderStore.standardize(url.path)
    }

    /// Run `body` with `RootFolderStore` keeping its registry in this test's suite.
    func run<R>(_ body: () throws -> R) rethrows -> R {
        try RootFolderStore.$suiteName.withValue(suiteName, operation: body)
    }
}

/// The ways a folder gets opened or registered after the launch folder was chosen.
enum RootFolderLaterOpen: String, CaseIterable {
    /// Duplicate Window on the chosen folder (`createWindow` touches it again).
    case sameFolderAgain
    /// Any other folder's window opening.
    case anotherFolder
    /// Another folder's first sandbox being created.
    case anotherFoldersFirstSandbox
    /// Another folder set up in the Open Folder wizard or from `sandshell://open`.
    case anotherFolderSetUp

    func perform(chosen: String, other: String) {
        switch self {
        case .sameFolderAgain: RootFolderStore.touch(chosen)
        case .anotherFolder: RootFolderStore.touch(other)
        case .anotherFoldersFirstSandbox: RootFolderStore.ensureRegistered(other)
        case .anotherFolderSetUp: RootFolderStore.adoptDefault(other)
        }
    }
}

struct RootFolderStoreLaunchDefaultTests {
    private let scratch: RootFolderStoreScratch

    init() throws {
        scratch = try RootFolderStoreScratch()
    }

    @Test func theFirstFolderOpenedBecomesTheLaunchDefault() throws {
        let first = try scratch.folder("first")
        let second = try scratch.folder("second")
        scratch.run {
            #expect(RootFolderStore.defaultPath == nil, "a fresh registry has no launch folder")
            RootFolderStore.touch(first)
            RootFolderStore.touch(second)
            #expect(RootFolderStore.defaultPath == first)
        }
    }

    @Test("A chosen launch folder stays when other folders open", arguments: RootFolderLaterOpen.allCases)
    func chosenLaunchFolderStays(later: RootFolderLaterOpen) throws {
        let chosen = try scratch.folder("chosen")
        let other = try scratch.folder("other")
        scratch.run {
            RootFolderStore.touch(other)
            RootFolderStore.defaultPath = chosen
            later.perform(chosen: chosen, other: other)
            #expect(RootFolderStore.defaultPath == chosen)
        }
    }

    @Test("Turning the launch folder off stays off when folders open later", arguments: RootFolderLaterOpen.allCases)
    func turningTheLaunchFolderOffSticks(later: RootFolderLaterOpen) throws {
        let chosen = try scratch.folder("chosen")
        let other = try scratch.folder("other")
        scratch.run {
            RootFolderStore.touch(chosen)
            #expect(RootFolderStore.defaultPath == chosen)
            RootFolderStore.defaultPath = nil   // General ▸ "Open this folder at launch" unchecked
            later.perform(chosen: chosen, other: other)
            #expect(RootFolderStore.defaultPath == nil)
        }
    }

    @Test func turningTheLaunchFolderBackOnChoosesTheFolder() throws {
        let folder = try scratch.folder("folder")
        scratch.run {
            RootFolderStore.touch(folder)
            RootFolderStore.defaultPath = nil
            RootFolderStore.defaultPath = folder
            #expect(RootFolderStore.defaultPath == folder)
        }
    }
}

struct RootFolderStoreLaunchFolderTests {
    private let scratch: RootFolderStoreScratch

    init() throws {
        scratch = try RootFolderStoreScratch()
    }

    /// Stands in for ~/Sandshell: launch makes it when it's missing.
    private func fallback() throws -> URL {
        URL(fileURLWithPath: try scratch.folder("Sandshell", exists: false))
    }

    @Test func withNoLaunchFolderChosenLaunchOpensTheFallback() throws {
        let fallback = try fallback()
        scratch.run {
            #expect(RootFolderStore.launchFolder(fallback: fallback) == fallback)
        }
    }

    @Test func withTheLaunchFolderTurnedOffLaunchOpensTheFallback() throws {
        let fallback = try fallback()
        let folder = try scratch.folder("folder")
        scratch.run {
            RootFolderStore.touch(folder)
            RootFolderStore.defaultPath = nil
            #expect(RootFolderStore.launchFolder(fallback: fallback) == fallback)
        }
    }

    @Test func aChosenFolderThatExistsIsOpened() throws {
        let fallback = try fallback()
        let chosen = try scratch.folder("chosen")
        scratch.run {
            RootFolderStore.defaultPath = chosen
            #expect(RootFolderStore.launchFolder(fallback: fallback)?.path == chosen)
        }
    }

    @Test("A chosen folder that's gone isn't recreated as a new workspace", .tags(.edgeCase))
    func aChosenFolderThatIsGoneIsNotOpened() throws {
        let fallback = try fallback()
        let gone = try scratch.folder("unplugged", exists: false)
        scratch.run {
            RootFolderStore.defaultPath = gone
            #expect(RootFolderStore.launchFolder(fallback: fallback) == nil)
        }
        #expect(FileManager.default.fileExists(atPath: gone) == false)
    }

    @Test("A chosen fallback folder that's gone is still opened (launch makes it)", .tags(.edgeCase))
    func aChosenFallbackThatIsGoneIsStillOpened() throws {
        let fallback = try fallback()
        scratch.run {
            RootFolderStore.defaultPath = fallback.path
            #expect(RootFolderStore.launchFolder(fallback: fallback)?.path == fallback.path)
        }
    }
}

struct RootFolderStoreStandardizeTests {
    @Test("A folder has one registry key however its path is spelled", arguments: [
        ("/srv/ws", "/srv/ws"),
        ("/srv/ws/", "/srv/ws"),
        ("/srv/ws//", "/srv/ws"),
        ("/srv/x/../ws/", "/srv/ws"),
        ("/srv/./ws", "/srv/ws"),
        ("/srv/My Folder/", "/srv/My Folder"),
        ("/", "/"),
    ])
    func oneKeyPerFolder(path: String, key: String) {
        #expect(RootFolderStore.standardize(path) == key)
    }
}
