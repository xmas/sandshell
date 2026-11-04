import Foundation
import Testing
@testable import Sandshell

/// Which subagent and workflow rows hide themselves (`SubagentSummary.hides`):
/// only the really done ones.
struct FinishedRowsHideTests {
    @Test(arguments: [(SubagentInfo.State.done, true), (.running, false), (.failed, false), (.stopped, false)])
    func aSubagentHidesOnceItsTurnEnded(state: SubagentInfo.State, hides: Bool) {
        #expect(SubagentSummary.hides(SidebarFixture.subagent("a1", of: .a, state: state)) == hides)
    }

    func run(_ states: [WorkflowRun.Agent.State]) -> WorkflowRun {
        let base = SidebarFixture.workflow("wf_1")
        return WorkflowRun(id: base.id, dir: base.dir, name: base.name, summary: nil, phases: [],
                           agents: states.enumerated().map { i, state in
                               .init(id: "w\(i)", label: "Agent \(i)", phase: nil, model: nil, tokens: 0,
                                     startedAt: SidebarFixture.epoch, lastWrite: SidebarFixture.epoch, state: state) },
                           startedAt: SidebarFixture.epoch, lastWrite: SidebarFixture.epoch)
    }

    @Test func aWorkflowHidesOnceEveryAgentIsDone() {
        #expect(SubagentSummary.hides(run([.done, .done]), tasks: []))
        #expect(!SubagentSummary.hides(run([.done, .running]), tasks: []), "one still running")
        #expect(!SubagentSummary.hides(run([.done, .failed]), tasks: []), "one failed: it stays")
        #expect(!SubagentSummary.hides(run([]), tasks: []), "no agents yet")
    }
}
