import SwiftUI

/// The background tasks of one session (the title-strip popover) or of every
/// session in a window (Window ▸ Background Tasks): what's running and for how
/// long, its latest step, and how finished ones ended.
struct BackgroundTasksView: View {
    @ObservedObject var controller: WorkspaceController
    /// The sessions to list; one for the popover, all for the window panel.
    let sessionIDs: () -> [UUID]
    /// Read the tail of a background command's output (inside its sandbox).
    var loadOutput: ((UUID, BackgroundTask) async -> String?)?
    /// Window panel: show that session.
    var onSelectSession: ((UUID) -> Void)?
    /// Stop a running task (chats only: the agent stops it); nil where it can't.
    var stopTask: ((UUID, BackgroundTask) async -> Bool)?
    var canStop: ((UUID, BackgroundTask) -> Bool)?

    /// Each listed session with tasks, its tasks already split for the list
    /// (once per session here, so the sections' bodies only lay them out).
    private var groups: [(session: Session, tasks: BackgroundTaskList)] {
        sessionIDs().compactMap { id in
            guard let s = controller.session(id: id) else { return nil }
            let tasks = controller.backgroundTasks(id)
            return tasks.isEmpty ? nil : (s, BackgroundTaskList(tasks))
        }
    }

    var body: some View {
        let groups = groups
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                ContentUnavailableView("No Background Tasks", systemImage: "square.stack.3d.up",
                                       description: Text("When Claude starts a subagent, a background command or a Monitor, it shows up here, and you're notified when it finishes."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.session.id) { group in
                            BackgroundTaskSection(session: group.session, tasks: group.tasks,
                                                  titled: onSelectSession != nil, loadOutput: loadOutput,
                                                  onSelectSession: onSelectSession,
                                                  stopTask: stopTask, canStop: canStop)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .accessibilityIdentifier("background-tasks")
    }
}

/// A session's tasks as the list shows them: the running ones newest first,
/// then the latest `finishedLimit` that finished (orphans — never seen
/// finishing — left out).
struct BackgroundTaskList: Equatable {
    static let finishedLimit = 25
    let running: [BackgroundTask]
    let finished: [BackgroundTask]

    init(_ tasks: [BackgroundTask]) {
        running = tasks.filter(\.isRunning).sorted { $0.startedAt > $1.startedAt }
        finished = Array(tasks.filter { !$0.isRunning && !$0.orphaned }
            .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
            .prefix(Self.finishedLimit))
    }
}

/// One session's tasks, split by `BackgroundTaskList`.
private struct BackgroundTaskSection: View {
    let session: Session
    let tasks: BackgroundTaskList
    /// The window panel names each session (a click shows it).
    let titled: Bool
    let loadOutput: ((UUID, BackgroundTask) async -> String?)?
    let onSelectSession: ((UUID) -> Void)?
    let stopTask: ((UUID, BackgroundTask) async -> Bool)?
    let canStop: ((UUID, BackgroundTask) -> Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if titled {
                Button { onSelectSession?(session.id) } label: {
                    HStack(spacing: 6) {
                        Text(session.name).font(.headline).lineLimit(1)
                        Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Show this session")
            }
            if !tasks.running.isEmpty {
                header("Running", tasks.running.count)
                ForEach(tasks.running) { task in
                    BackgroundTaskRow(task: task, sessionID: session.id, loadOutput: loadOutput,
                                      stop: stopAction(for: task))
                }
            }
            if !tasks.finished.isEmpty {
                header("Finished", tasks.finished.count)
                ForEach(tasks.finished) { BackgroundTaskRow(task: $0, sessionID: session.id, loadOutput: loadOutput) }
            }
        }
    }

    private func header(_ title: String, _ count: Int) -> some View {
        Text("\(title.uppercased()) · \(count)")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    /// The row's Stop, where this task can be stopped.
    private func stopAction(for task: BackgroundTask) -> (() async -> Bool)? {
        guard canStop?(session.id, task) == true, let stopTask else { return nil }
        let id = session.id
        return { await stopTask(id, task) }
    }
}

private struct BackgroundTaskRow: View {
    let task: BackgroundTask
    let sessionID: UUID
    let loadOutput: ((UUID, BackgroundTask) async -> String?)?
    var stop: (() async -> Bool)?
    @State private var stopping = false
    @State private var stopFailed = false
    @State private var output: String?
    @State private var showOutput = false
    @State private var loading = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kindSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .accessibilityLabel(kindName)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.title).lineLimit(2)
                    Spacer(minLength: 8)
                    if task.isRunning, stop != nil {
                        if stopping { ProgressView().controlSize(.mini) }
                        Button("Stop", action: stopTask)
                            .controlSize(.small)
                            .disabled(stopping)
                            .help("Stop this task (the agent is told it was stopped)")
                            .accessibilityIdentifier("background-task-stop")
                    }
                    BackgroundTaskStateBadge(task: task)
                }
                if let detail = task.detail, detail != task.title {
                    Text(detail).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let line = task.isRunning ? task.activity : (task.summary ?? task.activity) {
                    Text(line).font(.callout)
                        .foregroundStyle(task.state == .failed ? Color.red : Color.secondary)
                        .lineLimit(3).textSelection(.enabled)
                }
                if stopFailed {
                    Text("Couldn’t stop it — it may have just finished.").font(.caption).foregroundStyle(.red)
                }
                if task.kind == .monitor, task.events > 0 {
                    Text("^[\(task.events) event](inflect: true)").font(.caption).foregroundStyle(.tertiary)
                }
                if task.kind == .shell, task.outputPath != nil, loadOutput != nil {
                    BackgroundTaskOutput(output: output, loading: loading,
                                         isExpanded: $showOutput, onOpen: refreshOutput)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if task.detail != nil { Button("Copy Command", action: copyCommand) }
            if showOutput { Button("Reload Output", action: refreshOutput) }
        }
    }

    private var kindSymbol: String {
        switch task.kind {
        case .agent: "person.2"
        case .shell: "terminal"
        case .monitor: "waveform.path.ecg"
        case .workflow: "point.3.connected.trianglepath.dotted"
        }
    }

    /// What VoiceOver says for the kind symbol.
    private var kindName: String {
        switch task.kind {
        case .agent: "Subagent"
        case .shell: "Background command"
        case .monitor: "Monitor"
        case .workflow: "Workflow"
        }
    }

    private func stopTask() {
        guard let stop else { return }
        stopping = true
        Task {
            stopFailed = !(await stop())
            stopping = false
        }
    }

    private func copyCommand() {
        guard let detail = task.detail else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail, forType: .string)
    }

    private func refreshOutput() {
        guard let loadOutput else { return }
        loading = output == nil
        Task {
            let text = await loadOutput(sessionID, task)
            output = text
            loading = false
        }
    }
}

/// How long a task has run (ticking while it runs) and how it ended.
private struct BackgroundTaskStateBadge: View {
    let task: BackgroundTask

    var body: some View {
        // A finished task's time is fixed: only a running one needs the tick.
        TimelineView(.animation(minimumInterval: 1, paused: !task.isRunning)) { context in
            let elapsed = formatWorkTime(task.duration(at: context.date))
            let time = Text(elapsed).monospacedDigit()
            Group {
                switch task.state {
                case .running:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        time
                    }
                    .foregroundStyle(Color(nsColor: .sessionWorking))
                case .completed:
                    Label { time } icon: { Image(systemName: "checkmark.circle.fill") }
                        .foregroundStyle(.secondary)
                case .failed:
                    Label { time } icon: { Image(systemName: "xmark.octagon.fill") }
                        .foregroundStyle(.red)
                case .stopped:
                    Label { time } icon: { Image(systemName: "stop.circle") }
                        .foregroundStyle(.secondary)
                }
            }
            // The state shows as an icon and colour: say it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stateName)
            .accessibilityValue(elapsed)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    private var stateName: String {
        switch task.state {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

/// A background command's output tail, read when it's opened.
private struct BackgroundTaskOutput: View {
    let output: String?
    let loading: Bool
    @Binding var isExpanded: Bool
    let onOpen: @MainActor () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                if loading { ProgressView().controlSize(.small) }
                else {
                    Text(output ?? "No output yet.")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(6)
            .background(.quinary, in: .rect(cornerRadius: 5))
        } label: {
            Text("Output").font(.caption)
        }
        .onChange(of: isExpanded) { _, open in if open { onOpen() } }
    }
}
