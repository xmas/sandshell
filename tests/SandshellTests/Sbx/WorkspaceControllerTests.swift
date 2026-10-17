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
