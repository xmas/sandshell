import Foundation
import Testing
@testable import Sandshell

/// What Settings ▸ Kits says about the last kit startup (`KitStartupStatus`'s
/// `headline` and `tally`, Sandshell/UI/KitConfigView.swift).
struct KitStartupSummaryTests {
    private static let finished = KitStartupReport(startedAt: nil, kits: [], isComplete: true)
    private static let running = KitStartupReport(startedAt: nil, kits: [], isComplete: false)

    private func status(_ outcomes: [KitStartupOutcome], report: KitStartupReport? = finished) -> KitStartupStatus {
        let entries = outcomes.enumerated().map { i, outcome in
            KitStartupEntry(ref: "docker.io/sbx/kit\(i)", name: "kit\(i)", outcome: outcome, detail: [])
        }
        return KitStartupStatus(containerName: "sandbox", report: report, fetchError: nil,
                                fetchedAt: .now, entries: entries)
    }

    @Test func talliesKitsByOutcome() {
        let summary = status([.ok, .noSteps, .warning, .failed(exitCode: 2), .skipped, .skipped])
        #expect(summary.tally == "2 ok · 1 warning · 1 failed · 2 skipped")
    }

    @Test("Warnings agree in number", arguments: [(1, "1 warning"), (2, "2 warnings")])
    func warningsAgreeInNumber(count: Int, tally: String) {
        #expect(status(Array(repeating: .warning, count: count)).tally == tally)
    }

    @Test func namesTheKitsStillInstallingAsAList() {
        let summary = status([.running, .running, .running, .ok], report: Self.running)
        #expect(summary.headline == "Still installing: \(["kit0", "kit1", "kit2"].formatted())")
        #expect(status([.ok], report: Self.running).headline == "Kits still installing…")
    }

    @Test("A finished startup counts the kits that had problems", arguments: [
        ([], "No kits applied"),
        ([.ok, .noSteps], "All kits started"),
        ([.ok, .warning], "1 kit had a problem"),
        ([.warning, .skipped], "2 kits had problems"),
    ] as [([KitStartupOutcome], String)])
    func finishedHeadline(outcomes: [KitStartupOutcome], headline: String) {
        #expect(status(outcomes).headline == headline)
    }
}
