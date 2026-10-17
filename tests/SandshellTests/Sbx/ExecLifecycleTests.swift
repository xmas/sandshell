import Foundation
import Testing
@testable import Sandshell

/// A terminal's exit is also read off its `sbx exec` over the sbx socket:
/// `SbxClient.ExecLifecycleState` decodes an exec's inspection (what it runs,
/// when sbx says), and `SbxClient.launchExec` picks the terminal's own exec
/// out of the ones that started beside it — other sessions' agents, a chat's
/// warm spare, reaps, the kit-startup log read.
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

    // MARK: - Claiming the launch's exec

    struct ClaimingTheLaunchsExec {
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

        /// An exec as `inspectExecLifecycle` would see it: `nil` command = sbx
        /// doesn't say; `inspected: false` = the inspection failed (it's gone).
        struct Exec: Sendable {
            let id: String
            let command: [String]?
            var inspected = true

            func candidate() throws -> (id: String, state: State?) {
                guard inspected else { return (id, nil) }
                var object: [String: Any] = ["ID": id, "Running": true, "Pid": 1]
                if let command {
                    object["ProcessConfig"] = ["entrypoint": command[0], "arguments": Array(command.dropFirst())]
                }
                return (id, try JSONDecoder().decode(State.self, from: JSONSerialization.data(withJSONObject: object)))
            }
        }

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
                 execs: [Exec(id: "a", command: nil, inspected: false), Exec(id: "b", command: own)],
                 claims: "b"),
            Case(testDescription: "its own alone",
                 execs: [Exec(id: "a", command: own)],
                 claims: "a"),
            Case(testDescription: "a lone exec, when sbx doesn't say what execs run",
                 execs: [Exec(id: "a", command: nil)],
                 claims: "a"),
        ])
        func claimsTheLaunchsOwnExec(_ c: Case) throws {
            let candidates = try c.execs.map { try $0.candidate() }
            #expect(SbxClient.launchExec(among: candidates, tag: Self.tag) == c.claims)
        }

        @Test(arguments: [
            Case(testDescription: "nothing new yet", execs: [], claims: nil),
            Case(testDescription: "only the kit-startup log read (its own isn't up yet)",
                 execs: [Exec(id: "a", command: logRead)], claims: nil),
            Case(testDescription: "only another session's agent",
                 execs: [Exec(id: "a", command: otherSession)], claims: nil),
            Case(testDescription: "only the session's earlier launch",
                 execs: [Exec(id: "a", command: earlierLaunch)], claims: nil),
            Case(testDescription: "a reap whose script names the launch's tag",
                 execs: [Exec(id: "a", command: reap)], claims: nil),
            Case(testDescription: "several, when sbx doesn't say what execs run",
                 execs: [Exec(id: "a", command: nil), Exec(id: "b", command: nil)], claims: nil),
            Case(testDescription: "a lone exec that couldn't be inspected",
                 execs: [Exec(id: "a", command: nil, inspected: false)], claims: nil),
        ])
        func neverClaimsAnotherExec(_ c: Case) throws {
            let candidates = try c.execs.map { try $0.candidate() }
            #expect(SbxClient.launchExec(among: candidates, tag: Self.tag) == c.claims)
        }
    }
}
