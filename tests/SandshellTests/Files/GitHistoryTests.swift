import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Boundaries and odd inputs for Files' history values. File-private and
    /// uniquely named so it can't clash with tags other suites declare.
    @Tag fileprivate static var gitHistoryEdgeCase: Self
}

/// Tests for the value types in `Files/GitHistory.swift`: `ChangeScope`,
/// `GitCommit` and `ScopedFile`.
///
/// Not covered: `GitHistory.commits`, `.files` and `.diff` — each one runs the
/// host's git before doing anything else.
struct GitHistoryTests {

    // MARK: - ChangeScope.title

    struct Titles {
        @Test func uncommittedScopeIsTitledUncommittedChanges() {
            #expect(ChangeScope.uncommitted.title == "Uncommitted changes")
        }

        @Test(arguments: ["0123456789abcdef0123456789abcdef01234567", "origin/main", ""])
        func allChangesTitleDoesNotNameTheBase(base: String) {
            #expect(ChangeScope.all(base: base).title == "All changes")
        }

        @Test(arguments: ["Fix the tree's sort order", "Ünïcode ✓ and “quotes”", "  padded  ", ""])
        func commitScopeIsTitledByItsSubject(subject: String) {
            var commit = GitHistoryFixture.commit
            commit.subject = subject
            #expect(ChangeScope.commit(commit).title == subject,
                    "The subject is shown exactly as git gave it, even when it's empty")
        }
    }

    // MARK: - ChangeScope equality and hashing

    struct Scopes {
        @Test func sameScopesAreEqual() {
            #expect(ChangeScope.uncommitted == .uncommitted)
            #expect(ChangeScope.all(base: "abc") == .all(base: "abc"))
            #expect(ChangeScope.commit(GitHistoryFixture.commit) == .commit(GitHistoryFixture.commit))
        }

        @Test func allChangesScopesDifferByBase() {
            #expect(ChangeScope.all(base: "abc") != .all(base: "def"))
        }

        @Test func differentKindsOfScopeDiffer() {
            #expect(ChangeScope.uncommitted != .all(base: GitHistoryFixture.commit.sha))
            #expect(ChangeScope.all(base: GitHistoryFixture.commit.sha) != .commit(GitHistoryFixture.commit))
            #expect(ChangeScope.uncommitted != .commit(GitHistoryFixture.commit))
        }

        @Test(arguments: GitHistoryFixture.commitVariants)
        func commitScopesDifferWhenAnyFieldDiffers(variant: GitCommit) {
            #expect(ChangeScope.commit(GitHistoryFixture.commit) != .commit(variant))
        }

        @Test func equalScopesHashTogether() {
            let scopes = Set<ChangeScope>([
                .uncommitted, .uncommitted,
                .all(base: "abc"), .all(base: "abc"), .all(base: "def"),
                .commit(GitHistoryFixture.commit), .commit(GitHistoryFixture.commit),
            ])
            #expect(scopes.count == 4, "Duplicates collapse: uncommitted, all(abc), all(def) and the commit")
        }
    }

    // MARK: - GitCommit

    struct Commits {
        @Test func equalCommitsHashTogether() {
            let commits = Set([GitHistoryFixture.commit, GitHistoryFixture.commit])
            #expect(commits.count == 1)
        }

        @Test(arguments: GitHistoryFixture.commitVariants)
        func commitsDifferWhenAnyFieldDiffers(variant: GitCommit) {
            #expect(variant != GitHistoryFixture.commit)
            #expect(Set([GitHistoryFixture.commit, variant]).count == 2)
        }
    }

    // MARK: - ScopedFile

    struct Files {
        @Test func filesWithTheSameValuesAreEqual() {
            let file = ScopedFile(path: "/srv/repo/a.swift", change: .modified, added: 3, removed: 1)
            #expect(file == ScopedFile(path: "/srv/repo/a.swift", change: .modified, added: 3, removed: 1))
        }

        @Test(arguments: [
            ScopedFile(path: "/srv/repo/b.swift", change: .modified, added: 3, removed: 1),
            ScopedFile(path: "/srv/repo/a.swift", change: .added, added: 3, removed: 1),
            ScopedFile(path: "/srv/repo/a.swift", change: .modified, added: 4, removed: 1),
            ScopedFile(path: "/srv/repo/a.swift", change: .modified, added: 3, removed: 0),
        ])
        func filesDifferWhenAnyFieldDiffers(other: ScopedFile) {
            #expect(ScopedFile(path: "/srv/repo/a.swift", change: .modified, added: 3, removed: 1) != other)
        }

        @Test(.tags(.gitHistoryEdgeCase))
        func binaryFileIsNotAnEmptyTextFile() {
            let binary = ScopedFile(path: "/srv/repo/icon.png", change: .added, added: nil, removed: nil)
            let empty = ScopedFile(path: "/srv/repo/icon.png", change: .added, added: 0, removed: 0)
            #expect(binary != empty, "nil counts mean binary, not zero lines")
        }
    }
}

// MARK: - Fixtures

fileprivate enum GitHistoryFixture {
    static let commit = GitCommit(
        sha: "0123456789abcdef0123456789abcdef01234567",
        short: "0123456",
        subject: "Fix the tree's sort order",
        author: "Ada Lovelace",
        date: Date(timeIntervalSince1970: 1_700_000_000)
    )

    /// `commit` with exactly one field changed, one variant per field.
    static let commitVariants: [GitCommit] = {
        var sha = commit
        sha.sha = "fedcba9876543210fedcba9876543210fedcba98"
        var short = commit
        short.short = "0123457"
        var subject = commit
        subject.subject = "Fix the tree's sort order again"
        var author = commit
        author.author = "Grace Hopper"
        var date = commit
        date.date = Date(timeIntervalSince1970: 1_700_000_001)
        return [sha, short, subject, author, date]
    }()
}
