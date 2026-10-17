import Foundation
import Testing
@testable import Sandshell

/// A terminal's exit is also read off its `sbx exec` over the sbx socket:
/// `SbxClient.ExecLifecycleState` decodes an exec's inspection (what it runs,
/// when sbx says), and `LaunchExecFinder` picks the terminal's own exec out
/// of the ones that start beside it — other sessions' agents, a chat's warm
/// spare, reaps, the kit-startup log read — poll by poll.
struct ExecLifecycleTests {
    typealias State = SbxClient.ExecLifecycleState

    static func decode(_ json: String) throws -> State {
        try JSONDecoder().decode(State.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    struct Decoding {
        @Test func mobyInspectionGivesWhatTheExecRuns() throws {
            let state = try decode("""
                {"ID": "e1", "Running": true, "Pid": 42, "ExitCode": null,
                 "ProcessConfig": {"entrypoint": "env", "arguments": ["-u", "MCP_GATEWAY_URL", "SANDSHELL_LAUNCH=L",
                                   "bash", "-c", "exec claude"], "privileged": false, "tty": true, "user": "agent"}}
                """)
            #expect(state.id == "e1")
            #expect(state.running)
            #expect(state.pid == 42)
            #expect(state.exitCode == nil)
            #expect(state.command == ["env", "-u", "MCP_GATEWAY_URL", "SANDSHELL_LAUNCH=L", "bash", "-c", "exec claude"])
        }

        @Test(arguments: [
            (#"{"entrypoint": "cat"}"#, ["cat"]),
            (#"{"arguments": ["-c", "true"]}"#, ["-c", "true"]),
            (#"{"entrypoint": "sh", "arguments": []}"#, ["sh"]),
        ] as [(String, [String])])
        func partialProcessConfigGivesWhatItHas(config: String, command: [String]) throws {
            let state = try decode(#"{"ID": "e1", "Running": true, "Pid": 7, "ProcessConfig": \#(config)}"#)
            #expect(state.command == command)
        }

        @Test(.tags(.edgeCase), arguments: [
            #"{"id": "e1", "running": false, "pid": 0, "exit_code": 3}"#,
            #"{"ID": "e1", "Running": false, "Pid": 0, "ExitCode": 3}"#,
            #"{"ID": "e1", "Running": false, "Pid": 0, "ExitCode": 3, "ProcessConfig": null}"#,
            #"{"ID": "e1", "Running": false, "Pid": 0, "ExitCode": 3, "ProcessConfig": {}}"#,
            #"{"ID": "e1", "Running": false, "Pid": 0, "ExitCode": 3, "ProcessConfig": {"arguments": []}}"#,
            #"{"ID": "e1", "Running": false, "Pid": 0, "ExitCode": 3, "ProcessConfig": "sh -c true"}"#,
        ])
        func noCommandWhenSbxDoesNotSayWhatItRuns(json: String) throws {
            let state = try decode(json)
            #expect(state.command == nil)
            #expect(state.running == false, "the lifecycle still decodes")
            #expect(state.exitCode == 3)
        }
    }

    // MARK: - Finding the launch's exec

    struct FindingTheLaunchsExec {
        static let session = UUID()
        static let launch = SbxCommand.ProcessTag(session: session)
        static var tag: String { launch.pairs[1] }

        /// A Claude terminal's `env … bash -c …`, tagged like `launchCommand`'s.
        static func agent(_ tag: SbxCommand.ProcessTag) -> [String] {
            ["env", "-u", "MCP_GATEWAY_URL"] + tag.pairs + ["bash", "-c", "exec claude"]
        }
        static let own = agent(launch)
        /// The same session launched before (a restart), and another session.
        static let earlierLaunch = agent(SbxCommand.ProcessTag(session: session))
        static let otherSession = agent(SbxCommand.ProcessTag(session: UUID()))
        static let logRead = ["cat", "/var/log/sandshell/kit-startup.log"]
        /// A reap of this very launch names its tag inside its script.
        static let reap = ["sh", "-c", SbxCommand.reapScript(match: launch.pairs[1])]

        /// An exec as the socket shows it: `nil` command = sbx doesn't say what
        /// it runs; `inspectable: false` = its inspection fails (gone, or the
        /// socket hiccuped).
        struct Exec: Sendable {
            let id: String
            var command: [String]? = nil
            var running = true
            var inspectable = true

            func state() throws -> State {
                var object: [String: Any] = ["ID": id, "Running": running, "Pid": running ? 1 : 0]
                if !running { object["ExitCode"] = 0 }
                if let command {
                    object["ProcessConfig"] = ["entrypoint": command[0], "arguments": Array(command.dropFirst())]
                }
                return try JSONDecoder().decode(State.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }

        /// Polls a sandbox the way the terminal's watch does: list its execs,
        /// inspect those the finder asks about, fold the inspections in.
        struct Poller {
            var finder: LaunchExecFinder
            /// Every inspection made, in order.
            var inspected: [String] = []

            init(baseline: Set<String> = []) {
                finder = LaunchExecFinder(tag: FindingTheLaunchsExec.tag, baseline: baseline)
            }

            /// The exec claimed at this poll, if any.
            mutating func poll(_ execs: [Exec], others: Set<String> = []) throws -> (id: String, running: Bool)? {
                let active = Set(execs.map(\.id))
                var inspections: [String: State] = [:]
                for id in finder.toInspect(active: active, others: others) {
                    inspected.append(id)
                    guard let exec = execs.first(where: { $0.id == id }), exec.inspectable else { continue }
                    inspections[id] = try exec.state()
                }
                return finder.claim(active: active, others: others, inspections: inspections)
                    .map { ($0.id, $0.state.running) }
            }

            /// Polls `times` times with the same execs; the claims made.
            mutating func poll(_ execs: [Exec], times: Int, others: Set<String> = []) throws -> [String] {
                try (0..<times).compactMap { _ in try poll(execs, others: others)?.id }
            }
        }

        // MARK: When sbx says what execs run

        struct Case: Sendable, CustomTestStringConvertible {
            let testDescription: String
            let execs: [Exec]
            let claims: String?
        }

        @Test(arguments: [
            Case(testDescription: "its own among another session's, a log read and a reap",
                 execs: [Exec(id: "a", command: otherSession), Exec(id: "b", command: logRead),
                         Exec(id: "c", command: reap), Exec(id: "d", command: own)],
                 claims: "d"),
            Case(testDescription: "its own, sorting after the session's earlier launch",
                 execs: [Exec(id: "a", command: earlierLaunch), Exec(id: "z", command: own)],
                 claims: "z"),
            Case(testDescription: "its own beside one that couldn't be inspected",
                 execs: [Exec(id: "a", inspectable: false), Exec(id: "b", command: own)],
                 claims: "b"),
            Case(testDescription: "its own alone",
                 execs: [Exec(id: "a", command: own)],
                 claims: "a"),
        ])
        func takesItsOwnAtOnce(_ c: Case) throws {
            var poller = Poller()
            #expect(try poller.poll(c.execs)?.id == c.claims)
        }

        @Test(arguments: [
            Case(testDescription: "only the kit-startup log read (its own isn't up yet)",
                 execs: [Exec(id: "a", command: logRead)], claims: nil),
            Case(testDescription: "only another session's agent",
                 execs: [Exec(id: "a", command: otherSession)], claims: nil),
            Case(testDescription: "only the session's earlier launch",
                 execs: [Exec(id: "a", command: earlierLaunch)], claims: nil),
            Case(testDescription: "a reap whose script names the launch's tag",
                 execs: [Exec(id: "a", command: reap)], claims: nil),
            Case(testDescription: "an exec that says nothing, beside one that runs something else",
                 execs: [Exec(id: "a", command: logRead), Exec(id: "b")], claims: nil),
        ])
        func neverTakesAnother(_ c: Case) throws {
            var poller = Poller()
            #expect(try poller.poll(c.execs, times: 4).isEmpty)
        }

        @Test func anotherIsInspectedOnce() throws {
            var poller = Poller()
            let others = [Exec(id: "a", command: Self.otherSession), Exec(id: "b", command: Self.logRead)]
            _ = try poller.poll(others, times: 5)
            #expect(poller.inspected == ["a", "b"])
            // Its own, when it shows up, is the only one looked at.
            #expect(try poller.poll(others + [Exec(id: "c", command: Self.own)])?.id == "c")
            #expect(poller.inspected == ["a", "b", "c"])
        }

        @Test func itsOwnThatAlreadyEndedIsTakenAsEnded() throws {
            var poller = Poller()
            let claim = try #require(try poller.poll([Exec(id: "a", command: Self.own, running: false)]))
            #expect(claim.id == "a")
            #expect(claim.running == false, "so the terminal shows it exited")
        }

        @Test func anExecThatCouldNotBeInspectedIsLookedAtAgain() throws {
            var poller = Poller()
            #expect(try poller.poll([Exec(id: "a", command: Self.own, inspectable: false)]) == nil)
            #expect(try poller.poll([Exec(id: "a", command: Self.own)])?.id == "a")
            #expect(poller.inspected == ["a", "a"])
        }

        // MARK: Leaving out what isn't new

        @Test func execsFromBeforeTheLaunchAreNeverLookedAt() throws {
            var poller = Poller(baseline: ["old"])
            #expect(try poller.poll([Exec(id: "old", command: Self.own)], times: 3).isEmpty)
            #expect(try poller.poll([Exec(id: "old")], times: 3).isEmpty)
            #expect(poller.inspected.isEmpty)
        }

        @Test func anotherTerminalsOwnExecIsNeverTaken() throws {
            var poller = Poller()
            #expect(try poller.poll([Exec(id: "theirs")], times: 4, others: ["theirs"]).isEmpty)
            #expect(poller.inspected.isEmpty)
        }

        // MARK: When sbx doesn't say what execs run

        @Test func aLoneExecIsTakenOnlyAtTheSecondPollItsSeenAlone() throws {
            var poller = Poller()
            let mine = Exec(id: "a")
            #expect(try poller.poll([mine]) == nil, "it may be a log read or reap, about to end")
            let claim = try #require(try poller.poll([mine]))
            #expect(claim.id == "a")
            #expect(claim.running)
        }

        @Test func aLoneExecThatEndedIsNeverTaken() throws {
            // A log read seen running, ended by the time it may be taken; the
            // terminal's own comes up after it.
            var poller = Poller()
            #expect(try poller.poll([Exec(id: "cat")]) == nil)
            #expect(try poller.poll([Exec(id: "cat", running: false)]) == nil)
            #expect(try poller.poll([Exec(id: "cat", running: false), Exec(id: "mine")]) == nil)
            #expect(try poller.poll([Exec(id: "cat", running: false), Exec(id: "mine")])?.id == "mine",
                    "the ended one doesn't count as a second candidate")
        }

        @Test func aLoneExecAlreadyEndedWhenFirstInspectedIsNeverTaken() throws {
            var poller = Poller()
            let ended = Exec(id: "cat", running: false)
            #expect(try poller.poll([ended], times: 4).isEmpty)
            #expect(poller.inspected == ["cat"], "and isn't looked at again")
        }

        @Test func anExecThatCameAndWentBeforeItsOwnIsNotTaken() throws {
            // First poll: only a log read (its own isn't registered yet); then
            // the log read is gone and its own is there.
            var poller = Poller()
            #expect(try poller.poll([Exec(id: "cat")]) == nil)
            #expect(try poller.poll([Exec(id: "mine")]) == nil, "not the lone one at the previous poll")
            #expect(try poller.poll([Exec(id: "mine")])?.id == "mine")
        }

        @Test func severalAreNeverGuessedAmong() throws {
            // A chat's agent and the terminal's, in the same sandbox.
            var poller = Poller()
            let execs = [Exec(id: "chat"), Exec(id: "mine")]
            #expect(try poller.poll(execs, times: 10).isEmpty)
            #expect(poller.inspected.sorted() == ["chat", "mine"], "each is inspected once, not every poll")
        }

        @Test func itsOwnIsTakenOnceTheOthersEnd() throws {
            var poller = Poller()
            #expect(try poller.poll([Exec(id: "spare"), Exec(id: "mine")], times: 3).isEmpty)
            #expect(try poller.poll([Exec(id: "mine")]) == nil)
            #expect(try poller.poll([Exec(id: "mine")])?.id == "mine")
        }

        @Test(.tags(.edgeCase)) func aLoneExecThatCouldNotBeInspectedIsNotTaken() throws {
            var poller = Poller()
            let gone = Exec(id: "a", inspectable: false)
            #expect(try poller.poll([gone], times: 4).isEmpty)
        }

        @Test(.tags(.edgeCase)) func aLoneSilentExecIsNotTakenWhenSbxSaysWhatOthersRun() throws {
            // sbx described one exec, so its own carries the tag: one that says
            // nothing is no reason to guess.
            var poller = Poller()
            #expect(try poller.poll([Exec(id: "cat", command: Self.logRead)]) == nil)
            #expect(try poller.poll([Exec(id: "silent")], times: 4).isEmpty)
        }
    }
}
