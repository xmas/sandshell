import Foundation
import Testing
@testable import Sandshell

/// `KitDrift.extra(notIn:root:)` (Sbx/KitDrift.swift): Adopt in one window
/// mustn't add again what another window on the folder already adopted
/// (xmas-sandshell-e7q.49).
struct KitDriftAdoptTests {
    private let root = URL(fileURLWithPath: "/ws", isDirectory: true)

    private func drift(extra: [String]) -> KitDrift {
        KitDrift(containerName: "ws", extra: extra, missing: [])
    }

    @Test func extrasNotConfiguredYetAreAllKeptInOrder() {
        let extra = ["docker.io/kits/b:1", "kits/a:2", "./local-kit"]
        #expect(drift(extra: extra).extra(notIn: [], root: root) == extra)
        #expect(drift(extra: extra).extra(notIn: ["kits/other:1"], root: root) == extra)
    }

    @Test func extrasAlreadyConfiguredAreDropped() {
        let adopted = drift(extra: ["kits/a:1", "kits/b:1"]).extra(notIn: ["kits/base:1", "kits/a:1"], root: root)
        #expect(adopted == ["kits/b:1"])
    }

    @Test func everyExtraConfiguredLeavesNothingToAdopt() {
        let extra = ["kits/a:1", "kits/b:1"]
        #expect(drift(extra: extra).extra(notIn: extra, root: root).isEmpty)
    }

    /// The config may spell a kit the way it was typed, sbx the way it resolved it.
    @Test(.tags(.edgeCase), arguments: [
        ("docker.io/kits/a", "kits/a:latest"),
        ("kits/a:latest", "index.docker.io/kits/a"),
        ("./local-kit", "/ws/local-kit"),
        ("/ws/local-kit/", "./local-kit"),
    ])
    func anotherSpellingOfAConfiguredKitCountsAsConfigured(extra: String, configured: String) {
        #expect(drift(extra: [extra]).extra(notIn: [configured], root: root).isEmpty)
    }
}
