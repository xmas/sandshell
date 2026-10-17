import Foundation

/// Finds a terminal launch's own `sbx exec` among the sandbox's, poll by poll —
/// the sandbox's other sessions, a chat's warm spare, reaps and the
/// kit-startup log read start execs beside it, and any of them ending must not
/// read as the terminal exiting.
///
/// Its own is the new exec whose command carries the launch's tag
/// (`SANDSHELL_LAUNCH=…` as an argument of its own; a reap's script only names
/// it). When sbx doesn't say what execs run (no ProcessConfig in its exec
/// inspection), a new exec is taken only when it's the lone one, was the lone
/// one at the previous poll too (not a log read or reap that came and went,
/// nor another that showed up before the terminal's own) and still runs —
/// never a guess among several.
struct LaunchExecFinder: Equatable {
    typealias State = SbxClient.ExecLifecycleState

    /// The launch's `SANDSHELL_LAUNCH=…` tag.
    let tag: String
    /// Execs that aren't the launch's: there before it, or seen to run
    /// something else, or to have ended without saying what they ran.
    private(set) var notOurs: Set<String>
    /// Running execs sbx didn't say the command of: inspected once, and again
    /// only when one may be taken.
    private(set) var undescribed: Set<String> = []
    /// The new execs at the previous poll.
    private(set) var previous: Set<String> = []
    /// Whether some exec's inspection said what it runs (sbx reports ProcessConfig).
    private(set) var sawCommands = false

    init(tag: String, baseline: Set<String>) {
        self.tag = tag
        self.notOurs = baseline
    }

    /// The execs that may be the launch's: active, not known to be another's,
    /// and not another terminal's own (`others`).
    func candidates(active: Set<String>, others: Set<String>) -> Set<String> {
        active.subtracting(notOurs).subtracting(others)
    }

    /// Which execs to inspect at this poll: those not looked at yet and, when
    /// sbx doesn't say what execs run, a lone one that may be taken (to see it
    /// still runs).
    func toInspect(active: Set<String>, others: Set<String>) -> [String] {
        let new = candidates(active: active, others: others)
        if mayTakeLone(new) { return Array(new) }
        return new.subtracting(undescribed).sorted()
    }

    /// Folds in this poll's inspections — an exec missing from them is gone,
    /// or the socket failed, and is looked at again next time — and returns
    /// the launch's exec, with its state, once it's found.
    mutating func claim(active: Set<String>, others: Set<String>,
                        inspections: [String: State]) -> (id: String, state: State)? {
        for id in inspections.keys.sorted() {
            guard let state = inspections[id] else { continue }
            if let command = state.command {
                sawCommands = true
                if command.contains(tag) { return (id, state) }
                notOurs.insert(id)
            } else if state.running {
                undescribed.insert(id)
            } else {
                // Ended without saying what it ran: a log read or reap that came
                // and went (the terminal's own exiting is its PTY closing).
                notOurs.insert(id)
                undescribed.remove(id)
            }
        }
        let new = candidates(active: active, others: others)
        defer { previous = new }
        guard mayTakeLone(new), let only = new.first, let state = inspections[only],
              state.running, state.command == nil else { return nil }
        return (only, state)
    }

    /// sbx doesn't say what execs run, and a lone new exec was the lone one
    /// at the previous poll too. (When it does say, only the tagged one is taken.)
    private func mayTakeLone(_ new: Set<String>) -> Bool {
        !sawCommands && new.count == 1 && new == previous
    }
}
