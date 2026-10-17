import Foundation
import Testing
@testable import Sandshell

/// `KitStartupParser` and `KitStartupOutcome` (Sbx/KitStartup.swift): the
/// sandbox's kit startup log, read into each kit's outcome.
struct KitStartupTests {
    private let log = """
        === dispatcher run 2026-09-17T21:25:15Z ===
        > /etc/durable-startup.d/002-startup-hatch-kit/000-cmd.sh
        [hatch-kit] WARNING: could not obtain hatch-mcp binary.
        ok /etc/durable-startup.d/002-startup-hatch-kit/000-cmd.sh
        > /etc/durable-startup.d/003-startup-beads-kit/000-cmd.sh
        fail /etc/durable-startup.d/003-startup-beads-kit/000-cmd.sh exit=22
        """

    @Test func runStartIsTheMarkersTimestamp() throws {
        let report = try #require(KitStartupParser.parse(log))
        #expect(report.startedAt == Date(timeIntervalSince1970: 1_789_680_315))
    }

    @Test("A run marker whose time can't be read still starts a run", .tags(.edgeCase), arguments: [
        "=== dispatcher run ===",
        "=== dispatcher run yesterday ===",
    ])
    func unreadableTimestampIsNil(marker: String) throws {
        let report = try #require(KitStartupParser.parse(marker + "\n=== dispatcher complete ==="))
        #expect(report.startedAt == nil)
        #expect(report.isComplete)
    }

    @Test func kitsGetTheirStepsOutcomes() throws {
        let report = try #require(KitStartupParser.parse(log))
        #expect(report.kits.map(\.name) == ["hatch-kit", "beads-kit"])
        #expect(report.kits.map(\.outcome) == [.warning, .failed(exitCode: 22)])
        #expect(report.isAborted)
    }

    @Test("Each outcome's label, and whether it's a problem", arguments: [
        (KitStartupOutcome.running, "installing", false),
        (.ok, "ok", false),
        (.warning, "warning", true),
        (.failed(exitCode: 22), "failed (exit 22)", true),
        (.skipped, "skipped", true),
        (.noSteps, "not run", false),
    ])
    func outcomeLabelAndProblem(outcome: KitStartupOutcome, label: String, isProblem: Bool) {
        #expect(outcome.label == label)
        #expect(outcome.isProblem == isProblem)
    }
}
