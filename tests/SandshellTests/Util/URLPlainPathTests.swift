import Foundation
import Testing
@testable import Sandshell

/// Tests for `URL.plainPath` (`Util/Format.swift`): the decoded path without
/// a trailing slash, as the soft-deprecated `URL.path` gave it.
struct URLPlainPathTests {

    @Test(arguments: ["/srv/repo/a.txt", "/srv/a b/ü ✓.md", "/srv/100%/x", "/srv/#hash?/y"])
    func fileURLGivesItsPathDecoded(path: String) {
        #expect(URL(filePath: path).plainPath == path)
    }

    /// A folder's URL often ends in "/" (`contentsOfDirectory(at:)`, a folder
    /// that exists given to `URL(fileURLWithPath:)`); its path doesn't.
    @Test func folderURLDropsItsTrailingSlash() {
        let folder = URL(filePath: "/srv/repo/src", directoryHint: .isDirectory)
        #expect(folder.path(percentEncoded: false) == "/srv/repo/src/")
        #expect(folder.plainPath == "/srv/repo/src")
    }

    @Test(.tags(.edgeCase))
    func rootStaysTheRoot() {
        #expect(URL(filePath: "/").plainPath == "/")
    }

    /// The same string the old `path` gave, folder or file, slash or not.
    @Test(arguments: [
        URL(filePath: "/srv/repo/src", directoryHint: .isDirectory),
        URL(filePath: "/srv/repo/a.txt", directoryHint: .notDirectory),
        URL(filePath: "/srv/a b/c d", directoryHint: .isDirectory),
        URL(filePath: "/srv/repo/sub/../a.txt"),
    ])
    func matchesThePathItReplaces(url: URL) {
        #expect(url.plainPath == url.path)
    }
}
