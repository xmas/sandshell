import Foundation
import Testing
@testable import Sandshell

/// The sidebar's row logic (Sandshell/UI/SidebarOutlineController.swift): what
/// stays picked across a reload, which session the detail shows for a
/// selection, where a file drop lands, and when subagent changes redraw it.
struct SidebarOutlineControllerTests {}

/// Three sessions; A has two subagents, B a workflow:
/// 0 A, 1 a1, 2 a2, 3 B, 4 B's workflow, 5 C.
enum SidebarFixture {
    typealias Row = SidebarListController.Row

    enum Name: String, CaseIterable, Sendable {
        case a, b, c
        var id: UUID {
            switch self {
            case .a: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
            case .b: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
            case .c: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
            }
        }
    }

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func subagent(_ id: String, of session: Name, state: SubagentInfo.State = .running,
                         lastWrite: Date = epoch) -> SubagentInfo {
        SubagentInfo(id: id, sessionID: session.id, title: "Explore \(id)", agentType: "Explore",
                     transcript: URL(filePath: "/nonexistent/session/subagents/agent-\(id).jsonl"),
                     startedAt: epoch, lastWrite: lastWrite, state: state)
    }

    static func workflow(_ id: String, tokens: Int = 0) -> WorkflowRun {
        WorkflowRun(id: id, dir: URL(filePath: "/nonexistent/session/subagents/workflows/\(id)"), name: "Review",
                    summary: nil, phases: [],
                    agents: [.init(id: "w1", label: "Reviewer", phase: nil, model: nil, tokens: tokens,
                                   startedAt: epoch, lastWrite: epoch, state: .running)],
                    startedAt: epoch, lastWrite: epoch)
    }

    static let rows: [Row] = [
        .session(Name.a.id), .subagent(subagent("a1", of: .a)), .subagent(subagent("a2", of: .a)),
        .session(Name.b.id), .workflow(Name.b.id, workflow("wf_1")),
        .session(Name.c.id),
    ]
}

// MARK: - Row

extension SidebarOutlineControllerTests {
    struct RowIdentity {
        typealias Row = SidebarListController.Row

        @Test func eachRowBelongsToItsSession() {
            #expect(SidebarFixture.rows.map(\.sessionID) == [.a, .a, .a, .b, .b, .c].map(\SidebarFixture.Name.id))
        }

        @Test func aSubagentKeepsItsIdentityWhateverItShows() {
            let running = SidebarFixture.subagent("a1", of: .a)
            let finished = SidebarFixture.subagent("a1", of: .a, state: .done,
                                                   lastWrite: SidebarFixture.epoch.addingTimeInterval(60))
            #expect(Row.subagent(running) != Row.subagent(finished))
            #expect(Row.subagent(running).id == Row.subagent(finished).id)
        }

        @Test func aWorkflowKeepsItsIdentityWhateverItShows() {
            let session = SidebarFixture.Name.b.id
            let before = Row.workflow(session, SidebarFixture.workflow("wf_1"))
            let after = Row.workflow(session, SidebarFixture.workflow("wf_1", tokens: 5_000))
            #expect(before != after)
            #expect(before.id == after.id)
        }

        @Test func sameSubagentIDUnderAnotherSessionIsAnotherRow() {
            let mine = Row.subagent(SidebarFixture.subagent("x", of: .a))
            let theirs = Row.subagent(SidebarFixture.subagent("x", of: .b))
            #expect(mine.id != theirs.id)
        }
    }
}

// MARK: - rowsToSelect(keeping:shown:in:)

extension SidebarOutlineControllerTests {
    struct RestoringTheSelection {
        typealias Row = SidebarListController.Row
        typealias Name = SidebarFixture.Name

        private func select(_ picked: [Row], shown: Name?, in rows: [Row] = SidebarFixture.rows) -> IndexSet {
            SidebarListController.rowsToSelect(keeping: Set(picked.map(\.id)), shown: shown?.id, in: rows)
        }

        @Test func aPickedSessionIsFoundWhereverItMoved() {
            // B was row 1 of [A, B]; A's new subagents push it down.
            #expect(select([.session(Name.b.id)], shown: .b) == [3])
        }

        @Test func aPickedSubagentStaysPickedNotTheRowNowAtItsIndex() {
            // a2 was row 1 before a1 started above it.
            let picked = Row.subagent(SidebarFixture.subagent("a2", of: .a))
            #expect(select([picked], shown: .a) == [2])
        }

        @Test func aPickedSubagentIsFoundAfterItsStateChanges() {
            let wasRunning = Row.subagent(SidebarFixture.subagent("a1", of: .a))
            var rows = SidebarFixture.rows
            rows[1] = .subagent(SidebarFixture.subagent("a1", of: .a, state: .done,
                                                        lastWrite: SidebarFixture.epoch.addingTimeInterval(90)))
            #expect(select([wasRunning], shown: .a, in: rows) == [1])
        }

        @Test func aMultipleSelectionIsKept() {
            #expect(select([.session(Name.b.id), .session(Name.c.id)], shown: .c) == [3, 5])
        }

        @Test func whatIsGoneDropsOutOfAMultipleSelection() {
            let gone = Row.session(UUID())
            #expect(select([gone, .session(Name.a.id), .session(Name.c.id)], shown: .a) == [0, 5])
        }

        @Test(.tags(.edgeCase))
        func whenThePickedRowsAreGoneTheShownSessionIsPicked() {
            let gone = Row.subagent(SidebarFixture.subagent("gone", of: .a))
            #expect(select([gone], shown: .a) == [0])
        }

        @Test(.tags(.edgeCase))
        func thePickedRowsMustIncludeTheShownSession() {
            #expect(select([.session(Name.b.id)], shown: .c) == [5], "else the list and the detail disagree")
        }

        @Test func nothingPickedPicksTheShownSession() {
            #expect(select([], shown: .b) == [3])
        }

        @Test(.tags(.edgeCase))
        func noShownSessionPicksNothing() {
            #expect(select([.session(Name.b.id)], shown: nil).isEmpty)
        }

        @Test(.tags(.edgeCase))
        func aShownSessionTheFilterHidesPicksNothing() {
            let rows = SidebarFixture.rows.filter { $0.sessionID != Name.b.id }
            #expect(select([.session(Name.b.id)], shown: .b, in: rows).isEmpty)
        }
    }
}

// MARK: - shownSession(picked:last:shown:extending:in:)

extension SidebarOutlineControllerTests {
    struct ShownSession {
        struct Case: Sendable, CustomTestStringConvertible {
            let testDescription: String
            let picked: [Int]
            let last: Int
            let shown: SidebarFixture.Name?
            let extending: Bool
            let expected: SidebarFixture.Name?
        }

        @Test(arguments: [
            Case(testDescription: "a click on a session row", picked: [3], last: 3, shown: .a, extending: false, expected: .b),
            Case(testDescription: "a subagent row shows its session", picked: [1], last: 1, shown: .b, extending: false, expected: .a),
            Case(testDescription: "a workflow row shows its session", picked: [4], last: 4, shown: .a, extending: false, expected: .b),
            Case(testDescription: "⌘-click follows the last row picked", picked: [0, 5], last: 5, shown: .a, extending: false, expected: .c),
            Case(testDescription: "⌘-click on a subagent row shows its session", picked: [2, 3, 5], last: 2, shown: .c,
                 extending: false, expected: .a),
            Case(testDescription: "⇧-extension over subagent rows keeps the shown session", picked: [0, 1, 2, 3, 4, 5], last: 0,
                 shown: .c, extending: true, expected: .c),
            Case(testDescription: "⇧-extension within a session's subagents keeps it", picked: [1, 2], last: 2, shown: .a,
                 extending: true, expected: .a),
            Case(testDescription: "⇧-extension that leaves the shown session follows the last row", picked: [3, 4, 5], last: 5,
                 shown: .a, extending: true, expected: .c),
            Case(testDescription: "nothing picked", picked: [], last: -1, shown: .a, extending: false, expected: nil),
        ])
        func detailFollows(_ testCase: Case) {
            let shown = SidebarListController.shownSession(picked: IndexSet(testCase.picked), last: testCase.last,
                                                           shown: testCase.shown?.id, extending: testCase.extending,
                                                           in: SidebarFixture.rows)
            #expect(shown == testCase.expected?.id)
        }
    }
}

// MARK: - dropRow(proposed:between:pointer:in:)

extension SidebarOutlineControllerTests {
    struct DropTarget {
        struct Case: Sendable, CustomTestStringConvertible {
            let testDescription: String
            let proposed: Int
            let between: Bool
            /// The row under the pointer (-1: none).
            let pointer: Int
            let expected: Int
        }

        @Test(arguments: [
            Case(testDescription: "on a session row", proposed: 3, between: false, pointer: 3, expected: 3),
            Case(testDescription: "on a subagent row: its session", proposed: 2, between: false, pointer: 2, expected: 0),
            Case(testDescription: "on a workflow row: its session", proposed: 4, between: false, pointer: 4, expected: 3),
            Case(testDescription: "a session row's lower edge", proposed: 4, between: true, pointer: 3, expected: 3),
            Case(testDescription: "a session row's upper edge", proposed: 3, between: true, pointer: 3, expected: 3),
            Case(testDescription: "the last subagent's lower edge: its session, not the next", proposed: 3, between: true,
                 pointer: 2, expected: 0),
            Case(testDescription: "a workflow row's lower edge: its session, not the next", proposed: 5, between: true,
                 pointer: 4, expected: 3),
            Case(testDescription: "below the last row", proposed: 6, between: true, pointer: -1, expected: 5),
            Case(testDescription: "in a gap no row claims: the row above it", proposed: 3, between: true, pointer: -1, expected: 0),
        ])
        func landsOnTheSessionUnderThePointer(_ testCase: Case) {
            let row = SidebarListController.dropRow(proposed: testCase.proposed, between: testCase.between,
                                                    pointer: testCase.pointer, in: SidebarFixture.rows)
            #expect(row == testCase.expected)
        }

        @Test(.tags(.edgeCase))
        func anEmptyListHasNoRowToDropOn() {
            #expect(SidebarListController.dropRow(proposed: 0, between: true, pointer: -1, in: []) == -1)
        }
    }
}

// MARK: - SubagentInfo.asShown

extension SidebarOutlineControllerTests {
    struct SubagentAsShown {
        @Test(arguments: [
            (SubagentInfo.State.running, true),
            (SubagentInfo.State.done, false),
            (SubagentInfo.State.failed, false),
            (SubagentInfo.State.stopped, false),
        ])
        func aNewWriteChangesTheRowUnlessItsRunning(state: SubagentInfo.State, looksTheSame: Bool) {
            let before = SidebarFixture.subagent("a1", of: .a, state: state)
            let after = SidebarFixture.subagent("a1", of: .a, state: state, lastWrite: SidebarFixture.epoch.addingTimeInterval(3))
            #expect((before.asShown == after.asShown) == looksTheSame)
        }

        @Test func finishingChangesTheRow() {
            let running = SidebarFixture.subagent("a1", of: .a)
            let done = SidebarFixture.subagent("a1", of: .a, state: .done)
            #expect(running.asShown != done.asShown)
        }

        @Test func everythingElseIsKept() {
            let shown = SidebarFixture.subagent("a1", of: .a).asShown
            #expect(shown.id == "a1")
            #expect(shown.title == "Explore a1")
            #expect(shown.state == .running)
            #expect(shown.startedAt == SidebarFixture.epoch)
        }
    }
}
