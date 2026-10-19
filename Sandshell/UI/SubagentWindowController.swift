import AppKit

/// A subagent's own conversation, read-only — its prompt, its tool calls, its
/// replies — following along while it works. One window per subagent.
@MainActor
final class SubagentWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: SubagentWindowController] = [:]

    private var info: SubagentInfo
    private weak var workspace: WorkspaceController?
    private let transcript = ChatTranscriptView()
    private let status = NSTextField(labelWithString: "")
    private var follow: Task<Void, Never>?
    private var lastModified: Date?

    static func show(_ info: SubagentInfo, workspace: WorkspaceController) {
        let controller = open[info.id] ?? SubagentWindowController(info, workspace: workspace)
        // Kept open while its folder's window closed and opened again: follow the new one.
        controller.workspace = workspace
        open[info.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    static func debugWindow(_ id: String) -> SubagentWindowController? { open[id] }
    var debugTranscriptText: String { transcript.debugText }
    #endif

    private init(_ info: SubagentInfo, workspace: WorkspaceController) {
        self.info = info
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = info.title
        window.subtitle = [info.agentType.map { "\($0) subagent" } ?? "Subagent",
                           workspace.displayName(info.sessionID)].compactMap { $0 }.joined(separator: " · ")
        window.isReleasedWhenClosed = false
        // The first opens where one was last left; more cascade from the
        // frontmost (only one open window can hold the frame's name).
        let others = Self.open.values.compactMap(\.window)
        let front = others.filter(\.isVisible).min { $0.orderedIndex < $1.orderedIndex } ?? others.first
        if front == nil { window.setFrameAutosaveName("SubagentWindow") }
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        window.delegate = self

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let root = NSView()
        for v in [transcript, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: root.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        window.contentView = root
        if let front {
            window.setFrame(front.frame, display: false)
            _ = window.cascadeTopLeft(from: window.cascadeTopLeft(from: .zero))
        } else if !window.setFrameUsingName("SubagentWindow") {
            window.center()
        }
        load()
        // Follow it while it works (and pick up its state from the sidebar's poll).
        follow = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                await self.refreshState()
                self.load()
            }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Its state from the sidebar's poll (a workflow's agent: from its run's);
    /// once off those lists (its session closed, newer ones pushed it off, its
    /// folder's window went away), from what they're made of: a workflow
    /// agent's run journal, a background subagent's task, else its transcript.
    private func refreshState() async {
        if let latest = workspace?.subagents[info.sessionID]?.first(where: { $0.id == info.id }) {
            info = latest
            return
        }
        if let agent = workspace?.workflows[info.sessionID]?.lazy.flatMap(\.agents).first(where: { $0.id == info.id }) {
            info.lastWrite = agent.lastWrite ?? info.lastWrite
            info.state = SubagentInfo.State(agent.state)
            return
        }
        let url = info.transcript, id = info.id
        let lastWrite = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? info.lastWrite
        var state: SubagentInfo.State
        if let run = info.workflowRunDir {
            // The journal's done / failed is final. (Its lastWrite came from
            // the run as a line's timestamp, not the file's: no use comparing.)
            guard info.isRunning else { return }
            guard let agent = await Task.detached(priority: .utility, operation: {
                WorkflowScanner.state(ofAgent: id, inRun: run)
            }).value else { return }
            state = SubagentInfo.State(agent)
        } else if let task = workspace?.backgroundTasks(info.sessionID).first(where: { $0.kind == .agent && $0.id == id }) {
            state = SubagentInfo.State(task.state)
        } else {
            // A subagent's lastWrite is its file's: settled and not written
            // since (not resumed), it stays as it is.
            guard info.isRunning || lastWrite != info.lastWrite else { return }
            let since = workspace?.runtime(info.sessionID)?.workingSince
            state = await Task.detached(priority: .utility) {
                SubagentScanner.state(url, lastWrite: lastWrite, parentWorkingSince: since)
            }.value
        }
        // Its session closed: its agent, and the subagent with it, was stopped.
        if state == .running, let workspace, workspace.session(id: info.sessionID) == nil { state = .stopped }
        info.lastWrite = lastWrite
        info.state = state
    }

    private func load() {
        let url = info.transcript
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        updateStatus()
        guard modified != lastModified else { return }
        lastModified = modified
        Task { [weak self] in
            let items = await Task.detached(priority: .utility) { SubagentScanner.items(url) }.value
            self?.transcript.update(items)
        }
    }

    private func updateStatus() {
        switch info.state {
        case .running: status.stringValue = "Working… (read-only)"
        case .done: status.stringValue = "Finished \(Format.ago(info.lastWrite))"
        case .failed: status.stringValue = "Failed"
        case .stopped: status.stringValue = "Stopped"
        }
    }

    func windowWillClose(_ notification: Notification) {
        follow?.cancel()
        Self.open[info.id] = nil
    }
}
