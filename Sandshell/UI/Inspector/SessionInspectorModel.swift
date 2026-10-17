import AppKit
import Combine
import Observation

/// Whether chats show their Session Details beside them (View ▸ Show
/// Session Details, ⌥⌘I) — one setting for every chat, remembered.
@MainActor
enum SessionDetails {
    static let didToggle = Notification.Name("SandshellSessionDetailsToggled")
    private static let key = "sessionDetailsShown"
    static var isShown: Bool { UserDefaults.standard.bool(forKey: key) }
    static func toggle() {
        UserDefaults.standard.set(!isShown, forKey: key)
        NotificationCenter.default.post(name: didToggle, object: nil)
    }
}

/// Where a session runs and what it works on: the sandbox, the folder, git
/// (branch, worktree, ahead/behind), and how the folder reaches the sandbox.
struct SessionEnvironment: Equatable, Sendable {
    var sandbox: String
    var sandboxState: String
    var system: String?
    var resources: String?
    var folderName: String
    var folderParent: String
    var folderPath: String
    var access: String
    var accessSymbol: String
    var branch: String?
    /// The worktree's name when the folder is a linked git worktree.
    var worktree: String?
    /// The main checkout a worktree belongs to.
    var mainCheckout: String?
    var ahead: Int?
    var behind: Int?
    var upstream: String?
    var changedFiles: Int?
    var kits: [String] = []
}

/// The session inspector's live state: what the chat, the workspace and the
/// sandbox know about one session, kept current from their publishers.
@MainActor
@Observable
final class SessionInspectorModel {
    let sessionID: UUID
    private(set) var context: ContextUsage?
    private(set) var contextNote: String?
    /// The chat's own usage (used / window), for when the breakdown isn't there.
    private(set) var usage: (used: Int, size: Int)?
    private(set) var mcpServers: [ChatSession.MCPServer]?
    private(set) var hasExtras = false
    private(set) var tasks: [BackgroundTask] = []
    private(set) var workflows: [WorkflowRun] = []
    private(set) var subagents: [SubagentInfo] = []
    private(set) var environment: SessionEnvironment?
    private(set) var isWorking = false
    private(set) var refreshingContext = false
    /// Ticks while something runs, so elapsed times move.
    private(set) var now = Date.now

    @ObservationIgnored weak var chat: ChatSession?
    @ObservationIgnored private weak var workspace: WorkspaceController?
    @ObservationIgnored private var bag: Set<AnyCancellable> = []
    @ObservationIgnored var stopTask: ((BackgroundTask) async -> Bool)?
    @ObservationIgnored var openTask: ((BackgroundTask) -> Void)?
    @ObservationIgnored var openWorkflow: ((WorkflowRun) -> Void)?
    @ObservationIgnored var openSubagent: ((SubagentInfo) -> Void)?
    @ObservationIgnored var showMCP: (() -> Void)?
    @ObservationIgnored var openMCPSettings: (() -> Void)?

    init(sessionID: UUID, chat: ChatSession, workspace: WorkspaceController) {
        self.sessionID = sessionID
        self.chat = chat
        self.workspace = workspace
        chat.$contextUsage.sink { [weak self] in self?.context = $0 }.store(in: &bag)
        chat.$contextUsageUnavailable.sink { [weak self] in self?.contextNote = $0 }.store(in: &bag)
        chat.$mcpServers.sink { [weak self] in self?.mcpServers = $0 }.store(in: &bag)
        chat.$hasExtras.sink { [weak self] in self?.hasExtras = $0 }.store(in: &bag)
        chat.$usage.sink { [weak self] u in self?.usage = u.map { ($0.used, $0.size) } }.store(in: &bag)
        chat.$phase.removeDuplicates().sink { [weak self] phase in
            guard let self else { return }
            let wasWorking = self.isWorking
            self.isWorking = phase == .running
            // A turn ended: the window changed.
            if wasWorking, phase == .ready { Task { await self.refreshContext() } }
        }.store(in: &bag)
        workspace.$backgroundTasks.sink { [weak self] all in self?.tasks = all[sessionID] ?? [] }.store(in: &bag)
        workspace.$workflows.sink { [weak self] all in self?.workflows = all[sessionID] ?? [] }.store(in: &bag)
        workspace.$subagents.sink { [weak self] all in self?.subagents = all[sessionID] ?? [] }.store(in: &bag)
        workspace.$clockTick.sink { [weak self] tick in
            guard let self, self.tasks.contains(where: \.isRunning) || self.workflows.contains(where: { !$0.agentsSettled }) else { return }
            self.now = tick
        }.store(in: &bag)
        workspace.$containerPhases.dropFirst().sink { [weak self] _ in self?.loadEnvironment() }.store(in: &bag)
    }

    // MARK: Context

    func refreshContext() async {
        guard let chat, !refreshingContext else { return }
        refreshingContext = true
        await chat.refreshContextUsage()
        refreshingContext = false
    }

    func compact() { chat?.compact() }
    var canCompact: Bool { chat?.phase == .ready }

    // MARK: Tasks

    /// Running first (newest first), then the finished ones.
    var runningTasks: [BackgroundTask] { tasks.filter(\.isRunning).sorted { $0.startedAt > $1.startedAt } }
    var finishedTasks: [BackgroundTask] { tasks.filter { !$0.isRunning }.sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) } }

    func workflow(for task: BackgroundTask) -> WorkflowRun? {
        guard let run = task.runID else { return nil }
        return workflows.first { $0.id == run }
    }

    // MARK: Connectors

    func refreshMCP() async { try? await chat?.refreshMCP() }

    // MARK: Environment

    func loadEnvironment() {
        guard let workspace, let session = workspace.session(id: sessionID) else { return }
        let kind = session.containerAgentKind
        let folder = URL(fileURLWithPath: session.workdir)
        let access = workspace.sandboxAccess(for: folder, agent: kind)
        let sandbox = workspace.containerName(for: kind)
        let phase = workspace.containerPhases[kind]?.displayLabel ?? "not created"
        let kits = workspace.kits(for: kind, from: workspace.resolvedKits()).map { ($0 as NSString).lastPathComponent }
        Task {
            let git = await Task.detached(priority: .utility) { GitFacts.load(folder) }.value
            let parent = folder.deletingLastPathComponent().path.tildeAbbreviated
            environment = SessionEnvironment(
                sandbox: sandbox, sandboxState: phase,
                system: access.system.flatMap { s in s.shortDistribution ?? s.distribution ?? "Linux \(s.kernel)" },
                resources: access.system.flatMap { s in
                    let parts = [s.cpus.map { "\($0) CPU\($0 == 1 ? "" : "s")" }, s.memory].compactMap { $0 }
                    return parts.isEmpty ? nil : parts.joined(separator: " · ")
                },
                folderName: folder.lastPathComponent, folderParent: parent, folderPath: folder.path,
                access: access.summary, accessSymbol: access.symbol,
                branch: git.branch, worktree: git.worktree, mainCheckout: git.mainCheckout,
                ahead: git.ahead, behind: git.behind, upstream: git.upstream, changedFiles: git.changed,
                kits: kits)
        }
    }
}

/// Git facts about a folder: branch, worktree, ahead/behind its upstream.
struct GitFacts: Sendable {
    var branch: String?
    var worktree: String?
    var mainCheckout: String?
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    var changed: Int?

    nonisolated static func load(_ folder: URL) -> GitFacts {
        func git(_ args: [String]) -> String? {
            GitStatus.git(["-C", folder.path] + args)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var facts = GitFacts()
        guard let gitDir = git(["rev-parse", "--absolute-git-dir"]), !gitDir.isEmpty else { return facts }
        facts.branch = git(["symbolic-ref", "--short", "-q", "HEAD"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? git(["rev-parse", "--short", "HEAD"]).map { "detached at \($0)" }
        // A linked worktree's git dir is <main>/.git/worktrees/<name>.
        if let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"]),
           URL(fileURLWithPath: common).standardizedFileURL != URL(fileURLWithPath: gitDir).standardizedFileURL {
            facts.worktree = URL(fileURLWithPath: gitDir).lastPathComponent
            facts.mainCheckout = URL(fileURLWithPath: common).deletingLastPathComponent().path.tildeAbbreviated
        }
        if let upstream = git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]), !upstream.isEmpty,
           !upstream.contains("fatal"),
           let counts = git(["rev-list", "--left-right", "--count", "\(upstream)...HEAD"]) {
            let parts = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if parts.count == 2 { facts.upstream = upstream; facts.behind = parts[0]; facts.ahead = parts[1] }
        }
        facts.changed = git(["status", "--porcelain", "-z"]).map { $0.split(separator: "\0").count }
        return facts
    }
}
