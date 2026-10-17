import Foundation
import Testing
@testable import Sandshell

// `WorkspaceController` reads the folder registry (`RootFolderStore`, backed by
// `UserDefaults.standard`) when it's made, and the test host is the real app,
// so only its static helpers are tested here.

/// `WorkspaceController.adjacentSession(to:in:_:)`: Select Next/Previous Session
/// walks the sessions the sidebar lists, in its order (xmas-sandshell-e7q.52).
@MainActor
struct WorkspaceControllerAdjacentSessionTests {
    private let ids = [UUID(), UUID(), UUID()]

    @Test(arguments: [(0, 1, 1), (1, 1, 2), (2, 1, 0), (0, -1, 2), (1, -1, 0), (2, -1, 1)])
    func stepsThroughTheListWrappingAround(from: Int, delta: Int, expected: Int) {
        #expect(WorkspaceController.adjacentSession(to: ids[from], in: ids, delta) == ids[expected])
    }

    @Test(arguments: [(1, 0), (-1, 2)])
    func withNothingSelectedStartsAtTheEndItMovesFrom(delta: Int, expected: Int) {
        #expect(WorkspaceController.adjacentSession(to: nil, in: ids, delta) == ids[expected])
    }

    /// A filter hid the selected session: the cycle starts over among those listed.
    @Test(.tags(.edgeCase), arguments: [(1, 0), (-1, 2)])
    func aSelectionTheListDoesNotShowStartsOver(delta: Int, expected: Int) {
        #expect(WorkspaceController.adjacentSession(to: UUID(), in: ids, delta) == ids[expected])
    }

    @Test(.tags(.edgeCase))
    func anEmptyListHasNoNeighbour() {
        #expect(WorkspaceController.adjacentSession(to: nil, in: [], 1) == nil)
        #expect(WorkspaceController.adjacentSession(to: ids[0], in: [], -1) == nil)
    }

    @Test(.tags(.edgeCase), arguments: [1, -1])
    func aListOfOneStaysPut(delta: Int) {
        #expect(WorkspaceController.adjacentSession(to: ids[0], in: [ids[0]], delta) == ids[0])
    }
}

/// `WorkspaceController.containerName(for:slug:slugAgent:)`: the agent the bare slug
/// was pinned to keeps it when the primary agent changes, so another agent never
/// attaches to its sandbox (xmas-sandshell-e7q.44).
@MainActor
struct WorkspaceControllerContainerNameTests {
    @Test func theSlugAgentHasTheBareSlug() {
        #expect(WorkspaceController.containerName(for: .claude, slug: "proj", slugAgent: .claude) == "proj")
    }

    @Test(arguments: [AgentKind.codex, .shell, AgentKind(rawValue: "my-kit-agent")])
    func everyOtherAgentHasItsOwnName(agent: AgentKind) {
        #expect(WorkspaceController.containerName(for: agent, slug: "proj", slugAgent: .claude)
                == "proj-\(agent.rawValue)")
    }

    @Test func changingThePrimaryAgentKeepsTheNames() {
        var state = WorkspaceState()
        _ = state.pinSlugAgent(.claude)   // the primary was Claude; now it's Codex
        let owner = state.slugAgent ?? .codex
        #expect(WorkspaceController.containerName(for: .claude, slug: "proj", slugAgent: owner) == "proj")
        #expect(WorkspaceController.containerName(for: .codex, slug: "proj", slugAgent: owner) == "proj-codex")
    }
}

/// `ContainerPhase.displayLabel`: the status window's phase column.
struct ContainerPhaseLabelTests {
    @Test(arguments: [
        (ContainerPhase.absent, "absent"),
        (.creating, "creating"),
        (.rebuilding, "rebuilding"),
        (.running, "running"),
        (.stopped, "stopped"),
        (.failed("no space left"), "failed: no space left"),
    ])
    func eachPhaseHasItsLabel(phase: ContainerPhase, label: String) {
        #expect(phase.displayLabel == label)
    }

    @Test(.tags(.edgeCase))
    func aFailureShowsTheFirstSixtyCharactersOfWhy() {
        let why = String(repeating: "a", count: 60) + String(repeating: "b", count: 40)

        #expect(ContainerPhase.failed(why).displayLabel == "failed: " + String(repeating: "a", count: 60))
    }
}
