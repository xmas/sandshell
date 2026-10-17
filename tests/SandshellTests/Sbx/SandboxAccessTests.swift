import Foundation
import Testing
@testable import Sandshell

/// A folder and a symlink to it, in a fresh temp dir: the same folder by two paths.
private struct LinkedFolder {
    let root: URL
    let real: URL
    let link: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-access-\(UUID().uuidString)")
        real = root.appendingPathComponent("real")
        link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct SandboxAccessPathTests {
    @Test func aPathAMountHoldsAsIsStaysAsIs() throws {
        let f = try LinkedFolder()
        defer { f.remove() }
        let mounts = [SandboxAccess.Mount(path: f.link.path, readOnly: false)]
        #expect(SandboxAccess.sandboxPath(for: f.link.appendingPathComponent("sub").path, mounts: mounts)
                == f.link.appendingPathComponent("sub").path)
    }

    @Test func theResolvedPathGoesThroughTheMountThatHoldsIt() throws {
        let f = try LinkedFolder()
        defer { f.remove() }
        // Mounted by its link; the session saved the folder by its real path.
        let mounts = [SandboxAccess.Mount(path: f.link.path, readOnly: false)]
        #expect(SandboxAccess.sandboxPath(for: f.real.realPath, mounts: mounts) == f.link.path)
        #expect(SandboxAccess.sandboxPath(for: f.real.appendingPathComponent("sub").realPath, mounts: mounts)
                == f.link.appendingPathComponent("sub").path)
    }

    @Test func theDeepestMountWins() throws {
        let f = try LinkedFolder()
        defer { f.remove() }
        let mounts = [SandboxAccess.Mount(path: f.root.path, readOnly: true),
                      SandboxAccess.Mount(path: f.link.path, readOnly: false)]
        #expect(SandboxAccess.sandboxPath(for: f.real.appendingPathComponent("sub").realPath, mounts: mounts)
                == f.link.appendingPathComponent("sub").path)
    }

    @Test(.tags(.edgeCase)) func aPathNoMountHoldsComesBackUnchanged() throws {
        let f = try LinkedFolder()
        defer { f.remove() }
        let mounts = [SandboxAccess.Mount(path: f.link.appendingPathComponent("sub").path, readOnly: false)]
        #expect(SandboxAccess.sandboxPath(for: "/nowhere/at/all", mounts: mounts) == "/nowhere/at/all")
        #expect(SandboxAccess.sandboxPath(for: f.root.path, mounts: []) == f.root.path)
    }

    @Test func accessFindsTheMountForAFolderSavedByItsRealPath() throws {
        let f = try LinkedFolder()
        defer { f.remove() }
        let access = SandboxAccess(folder: URL(fileURLWithPath: f.real.realPath), sandbox: "s",
                                   mounts: [.init(path: f.link.path, readOnly: true)], created: true)
        #expect(access.mode == .readOnly, "shared, not 'not shared'")
        #expect(access.mount?.path == f.link.path)
    }
}
