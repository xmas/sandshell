import Foundation
import Testing
@testable import Sandshell

/// `SessionOrder.arrange`: the sidebar's order — groups of a session and its
/// forks, by the newest activity in each.
struct SessionOrderTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A session made an hour before t0.
    private static func session(_ name: String) -> Session {
        Session(folderID: UUID(), agent: .claude, name: name, order: 0, workdir: "/w",
                createdAt: t0.addingTimeInterval(-3600))
    }

    private static func fork(_ name: String, of source: Session, at seconds: TimeInterval) -> Session {
        Session.fork(of: source, name: name, order: 0, workdir: "/w", at: t0.addingTimeInterval(seconds))
    }

    /// Arrange `sessions` with each one's activity from `activity` (seconds
    /// after t0, by name; missing: t0), as names — a nested fork as
    /// "fork < its group's top".
    private static func arrange(_ sessions: [Session], activity: [String: TimeInterval],
                                rank: ((Session) -> Int)? = nil) -> [String] {
        let names = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let entries = SessionOrder.arrange(sessions, lastActivity: { t0.addingTimeInterval(activity[$0.name] ?? 0) },
                                           rank: rank)
        return entries.map { entry in
            let name = names[entry.id] ?? "?"
            return entry.nestedUnder.map { "\(name) < \(names[$0] ?? "?")" } ?? name
        }
    }

    @Test func withoutForksItsNewestActivityFirst() {
        let (a, b, c) = (Self.session("a"), Self.session("b"), Self.session("c"))
        #expect(Self.arrange([a, b, c], activity: ["a": 10, "b": 30, "c": 20]) == ["b", "c", "a"])
    }

    @Test func aForkListsUnderItsSource() {
        let a = Self.session("a"), b = Self.session("b")
        let f = Self.fork("f", of: a, at: 5)
        #expect(Self.arrange([f, b, a], activity: ["a": 10, "b": 30, "f": 5]) == ["b", "a", "f < a"])
    }

    @Test func aGroupSortsByItsNewestMember() {
        let a = Self.session("a"), b = Self.session("b")
        let f = Self.fork("f", of: a, at: 5)
        // The fork was active last: its whole group comes first, source on top.
        #expect(Self.arrange([a, b, f], activity: ["a": 10, "b": 30, "f": 40]) == ["a", "f < a", "b"])
    }

    @Test func forksOfOneSessionListOldestFirst() {
        let a = Self.session("a")
        let newer = Self.fork("newer", of: a, at: 200)
        let older = Self.fork("older", of: a, at: 100)
        #expect(Self.arrange([a, newer, older], activity: ["newer": 500, "older": 50])
                == ["a", "older < a", "newer < a"],
                "By when they were forked, not by activity")
    }

    @Test func aForkWithoutAForkTimeSortsByWhenItWasMade() {
        let a = Self.session("a")
        var early = Session(folderID: a.folderID, agent: .claude, name: "early", order: 0, workdir: "/w",
                            createdAt: Self.t0.addingTimeInterval(10))
        early.forkedFrom = a.id
        let late = Self.fork("late", of: a, at: 20)
        #expect(Self.arrange([a, late, early], activity: [:]) == ["a", "early < a", "late < a"])
    }

    /// One level of nesting: a fork of a fork joins its group, right after the
    /// fork it came from.
    @Test func aForkOfAForkNestsInTheSameGroupAfterItsSource() {
        let a = Self.session("a")
        let f1 = Self.fork("f1", of: a, at: 10)
        let f2 = Self.fork("f2", of: a, at: 20)
        let f1x = Self.fork("f1x", of: f1, at: 30)
        #expect(Self.arrange([a, f2, f1x, f1], activity: [:]) == ["a", "f1 < a", "f1x < a", "f2 < a"])
    }

    @Test func aForkWhoseSourceIsGoneListsOnItsOwn() {
        let gone = Self.session("gone")
        let b = Self.session("b")
        let orphan = Self.fork("orphan", of: gone, at: 0)
        let orphansFork = Self.fork("orphansFork", of: orphan, at: 1)
        let order = Self.arrange([b, orphan, orphansFork], activity: ["b": 10, "orphan": 20])
        #expect(order == ["orphan", "orphansFork < orphan", "b"])
    }

    @Test(.tags(.edgeCase))
    func aLoopOfForksListsEachOnceOnItsOwn() {
        var a = Self.session("a"), b = Self.session("b")
        a.forkedFrom = b.id
        b.forkedFrom = a.id
        var selfFork = Self.session("self")
        selfFork.forkedFrom = selfFork.id
        let order = Self.arrange([a, b, selfFork], activity: ["a": 30, "b": 20, "self": 10])
        #expect(order == ["a", "b", "self"])
    }

    @Test(.tags(.edgeCase))
    func equalActivityKeepsTheGivenOrder() {
        let (a, b, c) = (Self.session("a"), Self.session("b"), Self.session("c"))
        #expect(Self.arrange([b, c, a], activity: [:]) == ["b", "c", "a"])
    }

    /// The hook for status priority: a group takes its best member's rank.
    @Test func aRankPutsWholeGroupsFirst() {
        let a = Self.session("a"), b = Self.session("b"), c = Self.session("c")
        let f = Self.fork("f", of: c, at: 0)
        let needsYou: Set = [f.id]
        let order = Self.arrange([a, b, c, f], activity: ["a": 30, "b": 20, "c": 10, "f": 0],
                                 rank: { needsYou.contains($0.id) ? 0 : 2 })
        #expect(order == ["c", "f < c", "a", "b"])
    }

    @Test func everyEntryKnowsWhetherItIsANestedFork() {
        let a = Self.session("a")
        let f = Self.fork("f", of: a, at: 0)
        let entries = SessionOrder.arrange([a, f], lastActivity: { _ in Self.t0 })
        #expect(entries == [SessionOrder.Entry(id: a.id, nestedUnder: nil), SessionOrder.Entry(id: f.id, nestedUnder: a.id)])
        #expect(entries.map(\.isNestedFork) == [false, true])
    }
}
