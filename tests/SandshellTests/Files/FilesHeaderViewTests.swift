import Foundation
import Testing
@testable import Sandshell

/// The Files sidebar header's branch line: "main · 6 changed".
@MainActor
struct FilesHeaderViewTests {
    private func status(branch: String?, changed: Int, repo: String? = "/srv/repo") -> GitStatus {
        var status = GitStatus()
        status.repoRoot = repo
        status.branch = branch
        status.changes = Dictionary(uniqueKeysWithValues: (0..<changed).map { ("/srv/repo/f\($0)", GitStatus.Change.modified) })
        return status
    }

    @Test(arguments: [
        ("main", 6, "main · 6 changed"),
        ("main", 1, "main · 1 changed"),
        ("feature/x", 0, "feature/x · clean"),
    ])
    func branchAndChangedCount(branch: String, changed: Int, expected: String) {
        #expect(FilesHeaderView.branchLine(status(branch: branch, changed: changed)) == expected)
    }

    @Test func detachedHead() {
        #expect(FilesHeaderView.branchLine(status(branch: nil, changed: 2)) == "detached · 2 changed")
    }

    @Test func nothingOutsideARepo() {
        #expect(FilesHeaderView.branchLine(.empty) == "")
    }
}
