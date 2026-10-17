import Foundation
import Testing
@testable import Sandshell

/// The mount editor's model (Sandshell/UI/MountConfigModel.swift): which home
/// folders it suggests, the live mount count against the sbx limit, and dirty
/// tracking — each test with a fake `$HOME` in a fresh temporary folder.
@MainActor
@Suite(.tags(.fileSystem))
struct MountConfigModelTests {
    let home: URL
    let root = URL(filePath: "/srv/workspace")

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "mountconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private func makeFolders(_ names: String...) throws {
        for name in names {
            try FileManager.default.createDirectory(at: home.appending(path: name), withIntermediateDirectories: true)
        }
    }

    private func makeModel(_ selections: [MountSpec] = []) -> MountConfigModel {
        MountConfigModel(home: home, root: root, policy: MountPolicy(selections: selections))
    }

    @Test func suggestsOnlyTheCommonFoldersThatExist() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeFolders("Documents", "Downloads")
        let model = makeModel([MountSpec(path: home.appending(path: "Documents"), readonly: true)])
        #expect(model.suggestions.map(\.url.lastPathComponent) == ["Downloads", "Documents"])
        #expect(model.suggestions.map(\.enabled) == [false, true])
        #expect(model.others.isEmpty, "a selected suggestion isn't listed again under Other folders")
        #expect(!model.isDirty)
    }

    @Test func theDefaultPolicyOpensAsEnabledSuggestionsAndUnchanged() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeFolders("Documents", "Desktop")
        let policy = MountPolicy.makeDefault(home: home)
        let model = MountConfigModel(home: home, root: root, policy: policy)
        #expect(model.suggestions.map(\.enabled) == [true, true])
        #expect(model.others.isEmpty)
        #expect(!model.isDirty)
        #expect(model.policy().selections.map(\.spec) == policy.selections.map(\.spec),
                "the same mounts go to sbx create")
    }

    @Test func countsTheRootAgentMountsEnabledSuggestionsAndOthers() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeFolders("Documents", "Downloads")
        let model = makeModel([MountSpec(path: home.appending(path: "Documents"), readonly: true),
                               MountSpec(path: URL(filePath: "/srv/data"))])
        #expect(model.agentMounts.map(\.path.lastPathComponent) == [".agents", ".claude"],
                "no ~/.codex, so it isn't mounted")
        #expect(model.mountCount == 1 + 2 + 1 + 1)

        model.suggestions[0].enabled = true
        #expect(model.mountCount == 6)
        #expect(model.isDirty)
        model.revert()
        #expect(model.mountCount == 5)
        #expect(!model.isDirty)
    }

    @Test func anExistingCodexFolderIsMounted() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try makeFolders(".codex")
        #expect(makeModel().agentMounts.map(\.path.lastPathComponent) == [".agents", ".claude", ".codex"])
    }

    @Test(.tags(.edgeCase)) func reachesTheSbxMountLimit() {
        defer { try? FileManager.default.removeItem(at: home) }
        // Root + .agents + .claude, plus enough folders to stop one short.
        let others = (0..<(MountPolicy.mountLimit - 4)).map { MountSpec(path: URL(filePath: "/srv/d\($0)")) }
        let model = makeModel(others)
        #expect(model.mountCount == MountPolicy.mountLimit - 1)
        #expect(!model.atLimit)

        model.others.append(MountSpec(path: URL(filePath: "/srv/last")))
        #expect(model.atLimit)
    }

    @Test func flippingAFolderToReadWriteKeepsItAndMarksItChanged() {
        defer { try? FileManager.default.removeItem(at: home) }
        let data = URL(filePath: "/srv/data")
        let model = makeModel([MountSpec(path: data, readonly: true)])

        model.toggleReadonly(model.others[0])
        #expect(model.others.map(\.path) == [data])
        #expect(model.others[0].readonly == false)
        #expect(model.isChanged(other: model.others[0]))
        #expect(model.isDirty)

        model.commitBaseline()
        #expect(!model.isDirty)
        #expect(!model.isChanged(other: model.others[0]))
    }
}
