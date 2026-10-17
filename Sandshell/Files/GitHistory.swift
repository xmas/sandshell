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
        // -z: paths as they are (no quoting of accents or spaces); merges
        // against their first parent (git shows nothing for them otherwise).
        let common = ["-C", repo] + args.prefix(1) + ["--no-color", "--no-renames", "--no-ext-diff", "--diff-merges=first-parent", "-z"]
            + args.dropFirst()
        let numstat = GitStatus.git(common + ["--numstat"]) ?? ""
        let names = GitStatus.git(common + ["--name-status"]) ?? ""
        var kinds: [String: GitStatus.Change] = [:]
        // name-status -z: STATUS NUL PATH NUL …
        let nameFields = names.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 1 < nameFields.count {
            let status = nameFields[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !status.isEmpty else { i += 1; continue }
            kinds[nameFields[i + 1]] = status.hasPrefix("A") ? .added : status.hasPrefix("D") ? .deleted : .modified
            i += 2
        }
        // numstat -z: ADDED TAB REMOVED TAB PATH NUL …
        var files: [ScopedFile] = names.isEmpty && numstat.isEmpty ? [] : numstat.split(separator: "\0").compactMap { record in
            let f = record.trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3 else { return nil }
            return ScopedFile(path: repo + "/" + f[2], change: kinds[f[2]] ?? .modified,
                              added: Int(f[0]), removed: Int(f[1]))
        }
        if case .commit = scope {} else {
            let known = Set(files.map(\.path))
            for path in untracked where !known.contains(path) {
                let lines = (try? String(contentsOfFile: path, encoding: .utf8)).map(lineCount)
                files.append(ScopedFile(path: path, change: .untracked, added: lines, removed: 0))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Lines as git counts them: one per "\n", plus an unterminated last one —
    /// an empty file has none. (Bytes, not Characters: "\r\n" is one Character.)
    nonisolated static func lineCount(_ text: String) -> Int {
        let newlines = text.utf8.count(where: { $0 == UInt8(ascii: "\n") })
        return newlines + (text.isEmpty || text.utf8.last == UInt8(ascii: "\n") ? 0 : 1)
    }

    /// One file's diff in a commit, or since the base (working tree included).
    nonisolated static func diff(repo: String, scope: ChangeScope, path: String) -> String {
        let flags = ["--no-color", "--no-renames", "--no-ext-diff", "--diff-merges=first-parent"]
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
