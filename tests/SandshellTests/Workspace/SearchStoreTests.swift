import Foundation
import Testing
@testable import Sandshell

/// `SearchStore.rank` (Workspace/SearchStore.swift): how the Search window
/// matches what was typed against open sessions' titles and folders.
struct SearchStoreTests {
    private func session(_ name: String, workdir: String = "/work/project") -> Session {
        Session(folderID: UUID(), agent: .claude, name: name, order: 0, workdir: workdir)
    }

    private func rank(_ sessions: [Session], _ query: String) -> [SearchResult] {
        SearchStore.rank(sessions: sessions, activity: [:], records: [], matches: [:], query: query)
    }

    @Test(arguments: [
        ("Fix the login bug", "LOGIN"),
        ("FIX THE LOGIN", "fix"),
        ("Résumé draft", "resume"),
        ("Résumé draft", "RÉSUMÉ"),
        ("resume draft", "résumé"),
    ])
    func titlesMatchIgnoringCaseAndAccents(title: String, query: String) throws {
        let result = try #require(rank([session(title)], query).first)
        #expect(result.tier == .title)
    }

    @Test(arguments: [("/work/Café", "cafe"), ("/Code/MyIOSApp", "ios")])
    func foldersMatchIgnoringCaseAndAccents(folder: String, query: String) throws {
        let result = try #require(rank([session("Untitled", workdir: folder)], query).first)
        #expect(result.tier == .folder, "The title doesn't match, so the folder does")
    }

    @Test func titleMatchOutranksAFolderMatch() {
        let inFolder = session("Untitled", workdir: "/work/login")
        let inTitle = session("Login page")
        #expect(rank([inFolder, inTitle], "login").map(\.title) == ["Login page", "Untitled"])
    }

    @Test func sessionsThatDontMatchAreLeftOut() {
        #expect(rank([session("Fix the login bug")], "résumé").isEmpty)
    }

    @Test func anEmptyQueryListsEverySessionUnranked() {
        let results = rank([session("One"), session("Two")], "  ")
        #expect(results.map(\.title) == ["One", "Two"], "Sidebar order")
        #expect(results.allSatisfy { $0.tier == nil })
    }
}
