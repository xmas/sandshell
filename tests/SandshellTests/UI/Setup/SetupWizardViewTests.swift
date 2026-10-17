import Foundation
import Testing
@testable import Sandshell

/// `SetupWizardView.plainPath(_:)` (UI/Setup/SetupWizardView.swift): the folder
/// path the wizard shows, checks and registers — without the trailing "/" a
/// directory URL's `path(percentEncoded:)` keeps.
struct SetupWizardViewTests {
    @Test(arguments: [
        ("/Users/x/Sandshell/", "/Users/x/Sandshell"),
        ("/Users/x/My Work/", "/Users/x/My Work"),
        ("/Users/x/notes.txt", "/Users/x/notes.txt"),
    ])
    func aDirectoryLosesItsTrailingSlash(path: String, expected: String) {
        #expect(SetupWizardView.plainPath(URL(filePath: path)) == expected)
    }

    @Test(.tags(.edgeCase))
    func theRootStaysASlash() {
        #expect(SetupWizardView.plainPath(URL(filePath: "/", directoryHint: .isDirectory)) == "/")
    }

    /// `defaultRoot` and the folder panel give directory URLs; their path is
    /// the folder's own, as written (nothing resolved, escaped or decoded).
    @Test(.tags(.fileSystem))
    func aFolderOnDiskKeepsItsPath() throws {
        let folder = URL.temporaryDirectory.appending(path: "setup-wizard-\(UUID().uuidString)/Ünïcode %20 folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let path = folder.path(percentEncoded: false)
        let url = URL(filePath: path, directoryHint: .checkFileSystem)
        #expect(url.hasDirectoryPath)
        #expect(SetupWizardView.plainPath(url) == path)
    }
}
