import Foundation
import Testing
@testable import Sandshell

/// `OpenFoldersView.filter(_:query:)` (UI/OpenFoldersView.swift): what the Open
/// Workspace browser lists as you type.
struct OpenFoldersViewTests {
    private func root(_ path: String) -> RootProfile {
        RootProfile(path: path, icon: "folder.fill", colorHex: "3b82f6", sidebarHex: "1e293b")
    }

    private var roots: [RootProfile] {
        [root("/Users/x/Code/sandshell"), root("/Users/x/Résumé"), root("/Users/x/projects/notes"),
         root("/Users/x/Code/projects")]
    }

    @Test(arguments: ["", "   "])
    func aBlankQueryListsEveryFolderInOrder(query: String) {
        #expect(OpenFoldersView.filter(roots, query: query) == roots)
    }

    @Test func nameMatchesComeBeforePathMatches() {
        let names = OpenFoldersView.filter(roots, query: "projects").map(\.name)
        #expect(names == ["projects", "notes"], "“projects” by name, then “notes” by its path")
    }

    @Test(arguments: ["resume", "RÉSUMÉ", "Resume"])
    func matchingIgnoresCaseAndDiacritics(query: String) {
        #expect(OpenFoldersView.filter(roots, query: query).map(\.name) == ["Résumé"])
    }

    /// A folder whose name and path both match is listed once, as a name match.
    @Test(.tags(.edgeCase))
    func aFolderMatchingByNameAndPathIsListedOnce() {
        let resume = root("/Users/x/resume-drafts/Résumé")
        let other = root("/Users/x/resume-old/cv")
        #expect(OpenFoldersView.filter([other, resume], query: "resume") == [resume, other])
    }

    @Test func surroundingSpacesAreIgnored() {
        #expect(OpenFoldersView.filter(roots, query: "  sandshell ").map(\.name) == ["sandshell"])
    }

    @Test func noMatchListsNothing() {
        #expect(OpenFoldersView.filter(roots, query: "zebra").isEmpty)
    }
}
