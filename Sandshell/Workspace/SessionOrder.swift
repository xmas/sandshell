import Foundation

/// The order the sidebar lists sessions in: groups of a session and its forks,
/// newest activity first.
///
/// - A fork sits right under the session it was forked from. Nesting is one
///   level deep: a fork of a fork joins the same group (under the group's top
///   session), placed right after the fork it came from — a group reads as
///   its forks' family tree, depth-first, at one indent.
/// - Forks of one session sort oldest-first (by `forkedAt`, else `createdAt`).
/// - A group sorts by the newest activity among all its members.
/// - A fork whose source is gone lists as a session of its own (its own forks
///   still nest under it).
enum SessionOrder {
    struct Entry: Equatable, Sendable {
        let id: UUID
        /// The group's top session when this is a fork listed under it; nil
        /// for a top-level row.
        let nestedUnder: UUID?

        var isNestedFork: Bool { nestedUnder != nil }
    }

    /// `sessions` in display order. `lastActivity` is a session's sort time.
    /// `rank` (lower first) puts whole groups ahead of others before activity
    /// does — a group takes its best member's rank (e.g. needs-you 0, working 1,
    /// the rest 2). Without it, activity alone orders the groups.
    static func arrange(_ sessions: [Session],
                        lastActivity: (Session) -> Date,
                        rank: ((Session) -> Int)? = nil) -> [Entry] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let index = Dictionary(sessions.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

        // A fork's source, when it's listed and following sources up ends at
        // a top-level session (a corrupt loop lists its members on their own).
        func source(of s: Session) -> UUID? {
            guard let parent = s.forkedFrom, byID[parent] != nil else { return nil }
            var seen: Set<UUID> = [s.id]
            var current: UUID? = parent
            while let id = current {
                guard seen.insert(id).inserted else { return nil }
                current = byID[id]?.forkedFrom.flatMap { byID[$0] != nil ? $0 : nil }
            }
            return parent
        }

        var forks: [UUID: [Session]] = [:]
        var tops: [Session] = []
        for s in sessions {
            if let parent = source(of: s) { forks[parent, default: []].append(s) } else { tops.append(s) }
        }
        func forkedTime(_ s: Session) -> Date { s.forkedAt ?? s.createdAt }
        for key in forks.keys {
            forks[key]?.sort {
                forkedTime($0) != forkedTime($1) ? forkedTime($0) < forkedTime($1) : index[$0.id]! < index[$1.id]!
            }
        }
        func family(_ s: Session) -> [Session] {
            [s] + (forks[s.id] ?? []).flatMap(family)
        }

        struct Group { let top: Session; let members: [Session]; let newest: Date; let rank: Int; let index: Int }
        let groups = tops.map { top in
            let members = family(top)
            return Group(top: top, members: members,
                         newest: members.map(lastActivity).max() ?? .distantPast,
                         rank: rank.map { r in members.map(r).min() ?? 0 } ?? 0,
                         index: index[top.id] ?? 0)
        }.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.newest != $1.newest { return $0.newest > $1.newest }
            return $0.index < $1.index
        }
        return groups.flatMap { group in
            group.members.map { Entry(id: $0.id, nestedUnder: $0.id == group.top.id ? nil : group.top.id) }
        }
    }
}
