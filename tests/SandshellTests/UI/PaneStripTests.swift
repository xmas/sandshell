import AppKit
import Testing
@testable import Sandshell

/// The pane strip's condensing rule (`PaneStripCondensing`), by the strip's
/// own width: under 560 the sandbox's label goes, under 480 the folder's,
/// under 410 sandbox, folder and branch fold into ⋯.
struct PaneStripCondensingTests {
    typealias Rule = PaneStripCondensing

    @Test("Each width spells out what the rule says", arguments: [
        (1100, Rule(sandboxLabel: true, folderLabel: true, folded: false)),
        (600, Rule(sandboxLabel: true, folderLabel: true, folded: false)),
        (560, Rule(sandboxLabel: true, folderLabel: true, folded: false)),
        (559, Rule(sandboxLabel: false, folderLabel: true, folded: false)),
        (481, Rule(sandboxLabel: false, folderLabel: true, folded: false)),
        (480, Rule(sandboxLabel: false, folderLabel: true, folded: false)),
        (479, Rule(sandboxLabel: false, folderLabel: false, folded: false)),
        (411, Rule(sandboxLabel: false, folderLabel: false, folded: false)),
        (410, Rule(sandboxLabel: false, folderLabel: false, folded: false)),
        (409, Rule(sandboxLabel: false, folderLabel: false, folded: true)),
        (380, Rule(sandboxLabel: false, folderLabel: false, folded: true)),
    ] as [(CGFloat, Rule)])
    func condensing(width: CGFloat, expected: Rule) {
        #expect(Rule(width: width) == expected)
    }

    @Test(.tags(.edgeCase), arguments: [0, -20] as [CGFloat])
    func noWidthFoldsEverything(width: CGFloat) {
        #expect(Rule(width: width) == Rule(sandboxLabel: false, folderLabel: false, folded: true))
    }

    @Test("Narrowing only ever takes away", arguments: [700, 559, 479, 409] as [CGFloat])
    func narrowerNeverShowsMore(width: CGFloat) {
        let wider = Rule(width: width), narrower = Rule(width: width - 1)
        #expect(!narrower.sandboxLabel || wider.sandboxLabel)
        #expect(!narrower.folderLabel || wider.folderLabel)
        #expect(!wider.folded || narrower.folded)
    }
}

/// When the crumbs the rule shows still don't fit, the least specific gives
/// way first, each down to its minimum (`PaneStripView.crumbWidths`).
@MainActor
struct CrumbWidthsTests {
    // sandbox, folder, branch, name — lowest priority first.
    private let natural: [CGFloat] = [120, 100, 90, 150]
    private let minimum: [CGFloat] = [26, 26, 48, 72]

    @Test func roomEnoughKeepsEveryNaturalWidth() {
        #expect(PaneStripView.crumbWidths(natural: natural, minimum: minimum, room: 460) == natural)
        #expect(PaneStripView.crumbWidths(natural: natural, minimum: minimum, room: 1000) == natural)
    }

    @Test("The sandbox gives way first, then the folder, the branch, the name", arguments: [
        (400, [60, 100, 90, 150]),
        (300, [26, 34, 90, 150]),
        (250, [26, 26, 48, 150]),
        (200, [26, 26, 48, 100]),
        (172, [26, 26, 48, 72]),
    ] as [(CGFloat, [CGFloat])])
    func givesWayInOrder(room: CGFloat, expected: [CGFloat]) {
        #expect(PaneStripView.crumbWidths(natural: natural, minimum: minimum, room: room) == expected)
    }

    @Test(.tags(.edgeCase)) func neverBelowTheMinimumsEvenWithNoRoom() {
        #expect(PaneStripView.crumbWidths(natural: natural, minimum: minimum, room: 0) == minimum)
    }
}

/// The view switch shows the view a session is in now, and only for agents
/// that can chat (ACP) running in their own sandbox.
struct PaneViewModeTests {
    private func session(_ agent: AgentKind, chat: Bool, in containerAgent: AgentKind? = nil) -> Session {
        Session(folderID: UUID(), agent: agent, name: "s", order: 0, workdir: "/workspace",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), containerAgent: containerAgent, isChat: chat)
    }

    @Test("A chat shows Chat, a terminal Terminal", arguments: [AgentKind.claude, .codex, .gemini])
    func current(agent: AgentKind) {
        #expect(PaneViewMode.current(for: session(agent, chat: true)) == .chat)
        #expect(PaneViewMode.current(for: session(agent, chat: false)) == .terminal)
    }

    @Test func anAgentThatCantChatHasNoSwitch() {
        #expect(PaneViewMode.current(for: session(.shell, chat: false)) == nil)
    }

    @Test func aTerminalOnlySessionHasNoSwitch() {
        #expect(PaneViewMode.current(for: session(.claude, chat: false, in: .codex)) == nil)
    }
}

/// What VoiceOver hears for the branch crumb: the branch, then the lines
/// changed, with "line" agreeing with the count.
@MainActor
struct BranchCrumbLabelTests {
    @Test(arguments: [
        (1, 0, "main, 1 line added, 0 removed"),
        (5, 2, "main, 5 lines added, 2 removed"),
        (0, 3, "main, 0 lines added, 3 removed"),
    ] as [(Int, Int, String)])
    func lineCounts(added: Int, removed: Int, expected: String) {
        #expect(PaneStripView.branchAccessibilityLabel("main", added: added, removed: removed) == expected)
    }

    @Test func noChangesReadsJustTheBranch() {
        #expect(PaneStripView.branchAccessibilityLabel("main", added: 0, removed: 0) == "main")
    }
}

/// Pane layouts an earlier build saved, with Files leaves (Files was a pane
/// then): restored without them, splits left with one child collapsed, the
/// survivors keeping their shares.
struct SavedPaneLayoutTests {
    private let a = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!

    private func decode(_ json: String) throws -> SavedPaneLayout {
        try JSONDecoder().decode(SavedPaneLayout.self, from: Data(json.utf8))
    }

    @Test func aSessionBesideFilesBecomesTheSessionAlone() throws {
        let saved = try decode(#"""
            {"axis":"horizontal","fractions":[0.6,0.4],"children":[
              {"session":"\#(a.uuidString)"},
              {"files":{"session":"\#(a.uuidString)","folder":"/srv/project"}}]}
            """#)
        #expect(saved.withoutFiles() == SavedPaneLayout(session: a))
    }

    @Test func survivorsKeepTheirShares() throws {
        let saved = try decode(#"""
            {"axis":"horizontal","fractions":[0.3,0.3,0.4],"children":[
              {"session":"\#(a.uuidString)"},
              {"files":{"folder":"/srv/project"}},
              {"axis":"vertical","fractions":[0.5,0.5],"children":[{"files":{"folder":"/srv"}},{"session":"\#(b.uuidString)"}]}]}
            """#)
        let cleaned = try #require(saved.withoutFiles())
        #expect(cleaned.axis == .horizontal)
        #expect(cleaned.children == [SavedPaneLayout(session: a), SavedPaneLayout(session: b)])
        let shares = try #require(cleaned.fractions)
        #expect(shares.count == 2)
        #expect(abs(shares[0] - 0.3 / 0.7) < 0.0001)
        #expect(abs(shares[1] - 0.4 / 0.7) < 0.0001)
    }

    @Test func aLayoutOfOnlyFilesLeavesNothing() throws {
        let saved = try decode(#"""
            {"axis":"vertical","children":[{"files":{"folder":"/srv/a"}},{"files":{"folder":"/srv/b"}}]}
            """#)
        #expect(saved.withoutFiles() == nil)
        #expect(try decode(#"{"files":{"folder":"/srv/a"}}"#).withoutFiles() == nil)
    }

    @Test("A layout without Files comes back as it was", arguments: [
        #"{"session":"AAAAAAAA-0000-4000-8000-000000000001"}"#,
        #"{}"#,
        #"{"axis":"vertical","fractions":[0.25,0.75],"children":[{"session":"AAAAAAAA-0000-4000-8000-000000000001"},{}]}"#,
    ])
    func noFilesNoChange(json: String) throws {
        let saved = try decode(json)
        #expect(saved.withoutFiles() == saved)
    }

    @Test(.tags(.edgeCase)) func sharesThatDontMatchTheChildrenAreDropped() throws {
        let saved = try decode(#"""
            {"axis":"horizontal","fractions":[1],"children":[{},{},{"files":{"folder":"/srv"}}]}
            """#)
        let cleaned = try #require(saved.withoutFiles())
        #expect(cleaned.children?.count == 2)
        #expect(cleaned.fractions == nil, "equal shares, as for a fresh split")
    }

    @Test func whatsSavedNowHasNoFilesKey() throws {
        let layout = SavedPaneLayout(axis: .horizontal, children: [SavedPaneLayout(session: a), SavedPaneLayout()],
                                     fractions: [0.5, 0.5])
        let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
        #expect(!json.contains("files"))
        #expect(try decode(json) == layout)
    }
}
