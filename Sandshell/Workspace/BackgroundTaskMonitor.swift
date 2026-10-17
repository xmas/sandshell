import AppKit

/// Follows every running Claude session's transcript (terminal and chat alike —
/// sandboxed Claude writes to the mounted host `~/.claude`) for background
/// tasks, publishes them on `WorkspaceController.backgroundTasks`, and calls
/// back when one finishes: a notification unless the user is looking at it.
/// One per window, owned by its `SessionSurfaces`.
@MainActor
final class BackgroundTaskMonitor {
    private let controller: WorkspaceController
    /// The session's agent process is running (its tasks can still be).
    private let isAlive: (UUID) -> Bool
    /// The session is on screen in an active window (skip the notification).
    private let isVisible: (UUID) -> Bool

    private struct Watch {
        var url: URL?
        var offset: UInt64 = 0
        var parser = BackgroundTaskParser()
        /// When Sandshell started this session's agent: tasks from before it
        /// belong to an earlier process.
        let since: Date
        var caughtUp = false
        var lastProgressRead = Date.distantPast
    }
    private var watches: [UUID: Watch] = [:]
    private var task: Task<Void, Never>?

    init(controller: WorkspaceController, isAlive: @escaping (UUID) -> Bool,
         isVisible: @escaping (UUID) -> Bool) {
        self.controller = controller
        self.isAlive = isAlive
        self.isVisible = isVisible
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Stops at the first await that ends after `stop()`: the window (and what
    /// `isAlive`/`isVisible` ask) may be gone by then.
    private func tick() async {
        let home = controller.home
        for session in controller.orderedSessions where session.agent == .claude {
            let id = session.id
            guard isAlive(id) else {
                // The agent's process is gone, and its background tasks with it.
                if var watch = watches.removeValue(forKey: id) {
                    watch.parser.endAll()
                    controller.setBackgroundTasks(id, watch.parser.tasks)
                }
                continue
            }
            var watch = watches[id] ?? Watch(since: .now.addingTimeInterval(-5))
            if watch.url == nil, let tid = session.transcriptID {
                watch.url = TranscriptReader.transcriptURL(agent: .claude, workdir: session.conversationWorkdir,
                                                           home: home, id: tid)
            }
            guard let url = watch.url else { watches[id] = watch; continue }

            let offset = watch.offset
            let read = await Task.detached(priority: .utility) { ClaudeTranscriptTail.readLines(url, from: offset) }.value
            guard !Task.isCancelled else { return }
            if let (text, newOffset) = read {
                watch.offset = newOffset
                watch.parser.consume(text)
                if !watch.caughtUp {
                    watch.parser.markOrphans(launchedBefore: watch.since)
                } else {
                    for finished in watch.parser.justFinished where !isVisible(id) {
                        NotificationManager.shared.sendBackgroundTaskDone(
                            sessionID: id, sessionName: session.name, task: finished)
                        controller.markBackgroundTaskSeenLater(id)
                    }
                }
            }
            watch.caughtUp = true

            // A running subagent's latest step, from its own transcript.
            if Date.now.timeIntervalSince(watch.lastProgressRead) >= 2 {
                watch.lastProgressRead = .now
                let agents = watch.parser.tasks.filter { $0.isRunning && $0.kind == .agent }.map(\.id)
                if !agents.isEmpty {
                    let steps = await Task.detached(priority: .utility) {
                        agents.compactMap { aid in
                            SubagentProgress.latestStep(in: SubagentProgress.transcriptURL(
                                sessionTranscript: url, agentID: aid)).map { (aid, $0) }
                        }
                    }.value
                    guard !Task.isCancelled else { return }
                    for (aid, step) in steps { watch.parser.setActivity(step, for: aid) }
                }
            }
            watches[id] = watch
            controller.setBackgroundTasks(id, watch.parser.tasks)
        }
    }
}
