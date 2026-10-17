import Foundation
import Testing
@testable import Sandshell

/// A workflow run laid out the way Claude Code writes one, in a fresh temp dir.
private struct WorkflowFixture {
    let root: URL
    let transcript: URL
    let runDir: URL

    init(runID: String = "wf_abc-123", script: String?, journal: [String], agents: [String: [String]]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wf-tests-\(UUID().uuidString)")
        transcript = root.appendingPathComponent("session.jsonl")
        runDir = root.appendingPathComponent("session/subagents/workflows/\(runID)")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try Data().write(to: transcript)
        if let script {
            let scripts = root.appendingPathComponent("session/workflows/scripts")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try script.write(to: scripts.appendingPathComponent("my-flow-\(runID).js"), atomically: true, encoding: .utf8)
        }
        try (journal.joined(separator: "\n") + "\n").write(to: runDir.appendingPathComponent("journal.jsonl"), atomically: true, encoding: .utf8)
        for (id, lines) in agents {
            try (lines.joined(separator: "\n") + "\n").write(to: runDir.appendingPathComponent("agent-\(id).jsonl"), atomically: true, encoding: .utf8)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func assistant(model: String, input: Int, cacheRead: Int = 0, output: Int = 0, at: String) -> String {
        #"{"type":"assistant","timestamp":"\#(at)","message":{"model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output)},"content":[]}}"#
    }
    static func user(at: String) -> String { #"{"type":"user","timestamp":"\#(at)","message":{"role":"user","content":"go"}}"# }
}

struct WorkflowScannerTests {
    private let script = """
    export const meta = {
      name: 'review-changes',
      description: "Review the diff, then verify — each finding",
      whenToUse: 'phases: [not this]',
      phases: [
        { title: 'Review', detail: 'one reviewer per area' },
        { title: "Verify", detail: 'it\\'s adversarial' },
      ],
    }
    phase('Review')
    """

    @Test func readsNamePhasesAndAgents() throws {
        let fixture = try WorkflowFixture(script: script, journal: [
            #"{"type":"launched"}"#,
            #"{"type":"started","agentId":"a1","label":"review:ui","phase":"Review"}"#,
            #"{"type":"started","agentId":"a2","label":"review:core","phase":"Review"}"#,
            #"{"type":"result","agentId":"a1","result":"ok"}"#,
            #"{"type":"started","agentId":"a3","label":"verify:1","phase":"Verify"}"#,
            #"{"type":"result","agentId":"a3","result":null}"#,
        ], agents: [
            "a1": [WorkflowFixture.user(at: "2026-10-17T07:00:00.000Z"),
                   WorkflowFixture.assistant(model: "claude-opus-5-5", input: 100, cacheRead: 900, output: 50, at: "2026-10-17T07:02:00.000Z")],
            "a2": [WorkflowFixture.user(at: "2026-10-17T07:00:05.000Z")],
            "a3": [WorkflowFixture.user(at: "2026-10-17T07:03:00.000Z")],
        ])
        defer { fixture.remove() }

        let runs = WorkflowScanner.scan(transcript: fixture.transcript)
        let run = try #require(runs.first, "the run is found")
        #expect(runs.count == 1)
        #expect(run.id == "wf_abc-123")
        #expect(run.name == "review-changes")
        #expect(run.summary == "Review the diff, then verify — each finding")
        #expect(run.phases.map(\.title) == ["Review", "Verify"])
        #expect(run.phases.last?.detail == "it's adversarial", "escaped quotes are unescaped")
        #expect(run.agents.map(\.label) == ["review:ui", "review:core", "verify:1"], "agents in the order they started")
        #expect(run.agents.map(\.state) == [.done, .running, .failed], "a null result is a failure")
        #expect(run.agents[0].model == "claude-opus-5-5")
        #expect(run.agents[0].tokens == 1050, "context = input + cache + output of the last reply")
        #expect(run.agents[0].duration() == 120)
        #expect(run.progress(of: run.phases[0]) == (done: 1, total: 2))
        #expect(run.agentsSettled == false)
        #expect(run.totalTokens == 1050)
        #expect(run.transcript(of: run.agents[1]).lastPathComponent == "agent-a2.jsonl")
    }

    @Test func withoutAScriptTheRunIdNamesItAndAgentsNameThePhases() throws {
        let fixture = try WorkflowFixture(script: nil, journal: [
            #"{"type":"started","agentId":"x","label":"only","phase":"Solo"}"#,
            #"{"type":"result","agentId":"x","result":{"k":1}}"#,
        ], agents: ["x": [WorkflowFixture.user(at: "2026-10-17T07:00:00.000Z")]])
        defer { fixture.remove() }

        let run = try #require(WorkflowScanner.scan(transcript: fixture.transcript).first)
        #expect(run.name == "wf_abc-123")
        #expect(run.summary == nil)
        #expect(run.phases.map(\.title) == ["Solo"])
        #expect(run.agentsSettled)
    }

    @Test(.tags(.edgeCase)) func noWorkflowsFolderMeansNoRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wf-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WorkflowScanner.scan(transcript: dir.appendingPathComponent("s.jsonl")).isEmpty)
    }

    @Test(arguments: [
        ("export const meta = { name: 'a', description: 'b', phases: [] }", "a", "b", 0),
        (#"export const meta = {"name":"x","phases":[{"title":"P1"},{"title":"P2","detail":"d"}]}"#, "x", nil, 2),
        ("const nothing = 1", nil, nil, 0),
    ] as [(String, String?, String?, Int)])
    func parsesMetaLiterals(script: String, name: String?, description: String?, phases: Int) {
        let meta = WorkflowScanner.parseMeta(script)
        #expect(meta.name == name)
        #expect(meta.description == description)
        #expect(meta.phases.count == phases)
    }

    @Test func aPhaseTitleIsNotTheWorkflowName() {
        let meta = WorkflowScanner.parseMeta("export const meta = { phases: [{ title: 'T', name: 'inner' }], name: 'outer' }")
        #expect(meta.name == "outer", "name inside a phase object doesn't count")
    }
}
