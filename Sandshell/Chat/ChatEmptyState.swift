import SwiftUI

/// One line of what the empty chat says about where the agent works: the
/// folder, its branch, the sandbox, the approval mode.
struct ChatEmptyFact: Equatable, Identifiable {
    enum Status: Equatable { case none, starting, running, stopped }
    let id: String
    let symbol: String
    let title: String
    let detail: String
    var status: Status = .none
    /// A path or a name the agent's tools would type: the code face.
    var code = false

    /// The facts for a chat in `folder` (the Mac's path), as far as they're known:
    /// no branch until git has answered, none outside a repo; no mode until the
    /// agent offers modes.
    static func facts(folder: String, access: SandboxAccess.Mode?, git: GitStatus?,
                      sandbox: String, system: SandboxSystem?, phase: ChatSession.Phase,
                      mode: String?) -> [ChatEmptyFact] {
        var facts: [ChatEmptyFact] = []
        let shared = switch access {
        case .readWrite: "Shared read-write"
        case .readOnly: "Shared read-only"
        case .notShared: "Not shared with the sandbox"
        case nil: "Shared with the sandbox"
        }
        facts.append(ChatEmptyFact(id: "folder", symbol: "folder", title: folder.tildeAbbreviated,
                                   detail: shared, code: true))
        if let git, git.repoRoot != nil {
            let n = git.changes.count
            facts.append(ChatEmptyFact(id: "branch", symbol: "arrow.triangle.branch", title: git.branch ?? "Detached HEAD",
                                       detail: n == 0 ? "No changes" : n == 1 ? "1 file changed" : "\(n) files changed",
                                       code: git.branch != nil))
        }
        let (status, state): (Status, String) = switch phase {
        case .starting: (.starting, "Starting…")
        case .ready, .running: (.running, "Running")
        case .closed: (.stopped, "Stopped")
        }
        let about = status == .running ? [system?.shortDistribution, system?.memory] : []
        facts.append(ChatEmptyFact(id: "sandbox", symbol: "shippingbox", title: sandbox,
                                   detail: ([state] + about.compactMap { $0 }).joined(separator: " · "),
                                   status: status, code: true))
        if let mode {
            facts.append(ChatEmptyFact(id: "mode", symbol: "hand.raised", title: mode,
                                       detail: "Approval mode"))
        }
        return facts
    }
}

/// What the empty chat knows: filled in by its `ChatSessionView` as the chat
/// starts, its sandbox is looked at and git answers.
@MainActor
final class ChatEmptyModel: ObservableObject {
    let agent: String
    let sandbox: String
    /// The chat's folder on this Mac (the sandbox's path until the pane says).
    @Published var folder: String
    @Published var access: SandboxAccess?
    @Published var git: GitStatus?
    @Published var phase: ChatSession.Phase = .starting
    @Published var mode: String?
    /// Getting-started tips: only for your first few chats (decided as the chat opens).
    @Published var showsTips: Bool
    private var gitTask: Task<Void, Never>?

    init(agent: String, sandbox: String, folder: String, showsTips: Bool = true) {
        self.agent = agent
        self.sandbox = sandbox
        self.folder = folder
        self.showsTips = showsTips
    }

    var facts: [ChatEmptyFact] {
        ChatEmptyFact.facts(folder: folder, access: access?.mode, git: git, sandbox: sandbox,
                            system: access?.system, phase: phase, mode: mode)
    }

    /// Re-read the branch and what's changed (each time the empty chat shows).
    func refreshGit() {
        gitTask?.cancel()
        let folder = URL(filePath: folder, directoryHint: .isDirectory)
        gitTask = Task { [weak self] in
            let status = await GitStatus.load(for: folder)
            guard !Task.isCancelled, let self else { return }
            if self.git != status { self.git = status }
        }
    }
}

/// The empty chat's tips are for your first few chats: each chat you send a
/// first message in counts, and after `chats` of them the tips stop showing.
struct ChatTips {
    static let chats = 5
    static let key = "ChatTipsChatsStarted"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var showing: Bool { defaults.integer(forKey: Self.key) < Self.chats }

    /// A chat got its first message.
    func chatStarted() {
        let n = defaults.integer(forKey: Self.key)
        if n < Self.chats { defaults.set(n + 1, forKey: Self.key) }
    }
}

/// An empty chat: the tide line, what to do next, where the agent works and
/// how to get going. What doesn't fit the pane's height goes, tips first.
struct ChatEmptyState: View {
    @ObservedObject var model: ChatEmptyModel
    /// Two columns once the pane is wide enough for them.
    @State private var width: CGFloat = 0

    static let tips: [(key: String, what: String)] = [
        ("/", "commands and skills"),
        ("@", "mention a file"),
        ("⌘V", "paste or drop files"),
        ("⌘D", "split the pane"),
    ]

    var body: some View {
        SeaBackdrop {
            ViewThatFits(in: .vertical) {
                stack(facts: true, tips: true)
                stack(facts: true, tips: false)
                stack(facts: false, tips: false)
            }
            .padding(.horizontal, 24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var columns: Int { width >= 480 ? 2 : 1 }
    private var blockWidth: CGFloat { columns == 2 ? 420 : 280 }

    private func stack(facts: Bool, tips: Bool) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("What should \(model.agent) work on?")
                    .font(.role(.title))
                Text("It works in its sandbox, and sees only what's shared with it.")
                    .font(.role(.meta))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if facts { factGrid }
            if tips && model.showsTips { tipGrid }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Facts

    private var factGrid: some View {
        let rows = stride(from: 0, to: model.facts.count, by: columns).map { Array(model.facts[$0..<min($0 + columns, model.facts.count)]) }
        return Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { r in
                if r > 0 { rule.frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    ForEach(rows[r].indices, id: \.self) { i in
                        if i > 0 { rule.frame(width: 1).gridCellUnsizedAxes(.vertical) }
                        cell(rows[r][i])
                            .gridCellColumns(rows[r].count < columns ? columns * 2 - 1 : 1)
                    }
                }
            }
        }
        .frame(width: blockWidth)
        .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// The hairline between facts.
    private var rule: some View { Color.primary.opacity(0.08) }

    private func cell(_ fact: ChatEmptyFact) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fact.symbol)
                .font(.role(.body))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let color = Self.color(fact.status) {
                        Circle().fill(color).frame(width: 6, height: 6)
                    }
                    Text(fact.title)
                        .font(.role(fact.code ? .code : .body))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(fact.detail)
                    .font(.role(.meta))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(fact.title)
    }

    private static func color(_ status: ChatEmptyFact.Status) -> Color? {
        switch status {
        case .none: nil
        case .starting: .orange
        case .running: .green
        case .stopped: .secondary
        }
    }

    // MARK: Tips

    private var tipGrid: some View {
        let tips = Self.tips
        let rows = stride(from: 0, to: tips.count, by: columns).map { Array(tips[$0..<min($0 + columns, tips.count)]) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Getting started")
                .font(.role(.meta))
                .foregroundStyle(.tertiary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { i in
                            HStack(spacing: 8) {
                                Keycap(rows[r][i].key).frame(width: 34, alignment: .trailing)
                                Text(rows[r][i].what)
                                    .font(.role(.meta))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(width: blockWidth, alignment: .leading)
    }
}

/// A key as printed on the keyboard, for a tip.
private struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.role(.code))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.14)))
    }
}
