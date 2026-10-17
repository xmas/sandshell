import Foundation
import Testing
@testable import Sandshell

/// Git facts Session Details shows: branch, worktree, ahead/behind, changes,
/// and a clone sandbox's remote — read from real repos in temp folders.
@Suite(.tags(.fileSystem))
struct GitFactsTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitfacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func git(_ dir: URL, _ args: String...) {
        _ = GitStatus.git(["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args)
    }

    private func repo(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        git(dir, "init", "-q", "-b", "main")
        try "hello\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(dir, "add", "-A")
        git(dir, "commit", "-qm", "first")
        return dir
    }

    @Test func aPlainRepo() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try repo("plain")
        try "changed\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let facts = GitFacts.load(dir)
        #expect(facts.branch == "main")
        #expect(facts.worktree == nil)
        #expect(facts.changed == 1)
        #expect(facts.upstream == nil, "no upstream, so no ahead/behind")
    }

    @Test func aLinkedWorktree() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let main = try repo("main")
        let linked = root.appendingPathComponent("feature-wt")
        git(main, "worktree", "add", "-q", "-b", "feature", linked.path)
        let facts = GitFacts.load(linked)
        #expect(facts.branch == "feature")
        #expect(facts.worktree == "feature-wt")
        #expect(facts.mainCheckout?.hasSuffix("/main") == true, "the checkout it belongs to (\(facts.mainCheckout ?? "nil"))")
    }

    @Test func aheadAndBehindItsUpstream() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = try repo("upstream")
        let clone = root.appendingPathComponent("clone")
        _ = GitStatus.git(["clone", "-q", upstream.path, clone.path])
        try "two\n".write(to: clone.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        git(clone, "add", "-A")
        git(clone, "commit", "-qm", "local")
        let facts = GitFacts.load(clone)
        #expect(facts.upstream == "origin/main")
        #expect(facts.ahead == 1)
        #expect(facts.behind == 0)
    }

    @Test func aCloneSandboxRemote() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try repo("host")
        // What sbx --clone sets up: a sandbox-<name> remote; its branch one commit ahead.
        let agent = root.appendingPathComponent("agent")
        _ = GitStatus.git(["clone", "-q", dir.path, agent.path])
        git(agent, "commit", "-q", "--allow-empty", "-m", "from the agent")
        git(dir, "remote", "add", "sandbox-box", agent.path)
        git(dir, "fetch", "-q", "sandbox-box")
        let facts = GitFacts.load(dir, sandbox: "box")
        #expect(facts.sandboxRemote == "sandbox-box")
        #expect(facts.sandboxAhead == 1)
        #expect(GitFacts.load(dir, sandbox: "other").sandboxRemote == nil, "another sandbox's name doesn't match")
    }

    @Test(.tags(.edgeCase)) func notARepo() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let facts = GitFacts.load(root)
        #expect(facts.branch == nil)
        #expect(facts.changed == nil)
    }
}
