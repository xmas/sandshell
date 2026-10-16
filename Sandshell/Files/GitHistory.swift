import Foundation

/// One commit, for Files' Commits list.
struct GitCommit: Sendable, Hashable {
    var sha: String
    var short: String
    var subject: String
    var author: String
    var date: Date
}

/// Which changes Files lists and diffs: the working tree against HEAD (git
/// status's view, with stage/revert), everything since the branch's base, or
/// one commit.
enum ChangeScope: Sendable, Hashable {
    case uncommitted
    case all(base: String)
    case commit(GitCommit)

    var title: String {
        switch self {
        case .uncommitted: "Uncommitted changes"
        case .all: "All changes"
        case .commit(let c): c.subject
        }
    }
}

/// A file in a scope, with its line counts (nil for binary files).
struct ScopedFile: Sendable, Equatable {
    var path: String          // absolute
    var change: GitStatus.Change
    var added: Int?
    var removed: Int?
}

/// The branch's commits and per-scope files/diffs, from the host's git.
/// Everything here blocks: call it off the main thread.
enum GitHistory {
    /// Where this branch left the default branch (merge-base with origin/HEAD,
    /// origin/main, main or master), and the commits since, newest first. On
    /// the default branch with nothing unpushed there's no base: the commits
    /// are the most recent `recent` instead.
    nonisolated static func commits(repo: String, recent: Int = 20, limit: Int = 100) -> (base: String?, commits: [GitCommit]) {
        let head = GitStatus.git(["-C", repo, "rev-parse", "HEAD"])?.trimmed
        var base: String?
        for ref in defaultBranchCandidates(repo: repo) {
            if let mb = GitStatus.git(["-C", repo, "merge-base", "HEAD", ref])?.trimmed, !mb.isEmpty {
                base = mb
                break
            }
        }
        if let b = base, b == head { base = nil }
        let range = base.map { ["\($0)..HEAD", "-n", "\(limit)"] } ?? ["-n", "\(recent)"]
        let format = "--format=%H%x1f%h%x1f%s%x1f%an%x1f%at"
        let out = GitStatus.git(["-C", repo, "log", "--no-color", format] + range) ?? ""
        let commits = out.split(separator: "\n").compactMap { line -> GitCommit? in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, let t = TimeInterval(f[4]) else { return nil }
            return GitCommit(sha: f[0], short: f[1], subject: f[2], author: f[3], date: Date(timeIntervalSince1970: t))
        }
        return (base, commits)
    }

    private nonisolated static func defaultBranchCandidates(repo: String) -> [String] {
        var refs: [String] = []
        if let origin = GitStatus.git(["-C", repo, "rev-parse", "--abbrev-ref", "origin/HEAD"])?.trimmed,
           !origin.isEmpty, origin != "origin/HEAD" { refs.append(origin) }
        for ref in ["origin/main", "origin/master", "main", "master"] where !refs.contains(ref) {
            if GitStatus.git(["-C", repo, "rev-parse", "--verify", "--quiet", ref]) != nil { refs.append(ref) }
        }
        return refs
    }

    /// The files a scope touches, with +/- counts, sorted by path.
    /// `untracked`: the working tree's untracked files (from git status),
    /// which the uncommitted and all-changes scopes include.
    nonisolated static func files(repo: String, scope: ChangeScope, untracked: [String] = []) -> [ScopedFile] {
        let args: [String]
        switch scope {
        case .uncommitted: args = ["diff", "HEAD"]
        case .all(let base): args = ["diff", base]
        case .commit(let c): args = ["show", "--format=", c.sha]
        }
        let common = ["-C", repo] + args.prefix(1) + ["--no-color", "--no-renames", "--no-ext-diff"] + args.dropFirst()
        let numstat = GitStatus.git(common + ["--numstat"]) ?? ""
        let names = GitStatus.git(common + ["--name-status"]) ?? ""
        var kinds: [String: GitStatus.Change] = [:]
        for line in names.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard f.count == 2 else { continue }
            kinds[f[1]] = f[0].hasPrefix("A") ? .added : f[0].hasPrefix("D") ? .deleted : .modified
        }
        var files: [ScopedFile] = numstat.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3 else { return nil }
            return ScopedFile(path: repo + "/" + f[2], change: kinds[f[2]] ?? .modified,
                              added: Int(f[0]), removed: Int(f[1]))
        }
        if case .commit = scope {} else {
            let known = Set(files.map(\.path))
            for path in untracked where !known.contains(path) {
                let lines = (try? String(contentsOfFile: path, encoding: .utf8))
                    .map { $0.split(separator: "\n", omittingEmptySubsequences: false).count }
                files.append(ScopedFile(path: path, change: .untracked, added: lines, removed: 0))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// One file's diff in a commit, or since the base (working tree included).
    nonisolated static func diff(repo: String, scope: ChangeScope, path: String) -> String {
        let flags = ["--no-color", "--no-renames", "--no-ext-diff"]
        switch scope {
        case .uncommitted: return GitStatus.git(["-C", repo, "diff"] + flags + ["HEAD", "--", path]) ?? ""
        case .all(let base): return GitStatus.git(["-C", repo, "diff"] + flags + [base, "--", path]) ?? ""
        case .commit(let c): return GitStatus.git(["-C", repo, "show"] + flags + ["--format=", c.sha, "--", path]) ?? ""
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
