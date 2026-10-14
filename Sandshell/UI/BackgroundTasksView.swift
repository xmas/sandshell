import AppKit
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

    private var groups: [(session: Session, tasks: [BackgroundTask])] {
        sessionIDs().compactMap { id in
            guard let s = controller.session(id: id) else { return nil }
            let tasks = controller.backgroundTasks(id)
            return tasks.isEmpty ? nil : (s, tasks)
        }
    }

    var body: some View {
        let groups = groups
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("No background tasks").font(.headline)
                    Text("When Claude starts a subagent, a background command or a Monitor, it shows up here, and you're notified when it finishes.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.session.id) { group in
                            section(group.session, group.tasks, titled: onSelectSession != nil)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .accessibilityIdentifier("background-tasks")
    }

    @ViewBuilder
    private func section(_ session: Session, _ tasks: [BackgroundTask], titled: Bool) -> some View {
        let running = tasks.filter(\.isRunning).sorted { $0.startedAt > $1.startedAt }
        let finished = Array(tasks.filter { !$0.isRunning && !$0.orphaned }
            .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }.prefix(25))
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
            if !running.isEmpty {
                header("Running", running.count)
                ForEach(running) { BackgroundTaskRow(task: $0, sessionID: session.id, loadOutput: loadOutput) }
            }
            if !finished.isEmpty {
                header("Finished", finished.count)
                ForEach(finished) { BackgroundTaskRow(task: $0, sessionID: session.id, loadOutput: loadOutput) }
            }
        }
    }

    private func header(_ title: String, _ count: Int) -> some View {
        Text("\(title.uppercased()) · \(count)")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

private struct BackgroundTaskRow: View {
    let task: BackgroundTask
    let sessionID: UUID
    let loadOutput: ((UUID, BackgroundTask) async -> String?)?
    @State private var output: String?
    @State private var showOutput = false
    @State private var loading = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kindSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.title).fontWeight(.medium).lineLimit(2)
                    Spacer(minLength: 8)
                    stateBadge
                }
                if let detail = task.detail, detail != task.title {
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let line = task.isRunning ? task.activity : (task.summary ?? task.activity) {
                    Text(line).font(.callout)
                        .foregroundStyle(task.state == .failed ? Color.red : Color.secondary)
                        .lineLimit(3).textSelection(.enabled)
                }
                if task.kind == .monitor, task.events > 0 {
                    Text("\(task.events) event\(task.events == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary)
                }
                if task.kind == .shell, task.outputPath != nil, loadOutput != nil {
                    DisclosureGroup(isExpanded: $showOutput) {
                        Group {
                            if loading { ProgressView().controlSize(.small) }
                            else {
                                Text(output ?? "No output yet.")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(6)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    } label: {
                        Text("Output").font(.caption)
                    }
                    .onChange(of: showOutput) { _, open in if open { refreshOutput() } }
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let detail = task.detail {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
            }
            if showOutput { Button("Reload Output", action: refreshOutput) }
        }
    }

    private var kindSymbol: String {
        switch task.kind {
        case .agent: return "person.2"
        case .shell: return "terminal"
        case .monitor: return "waveform.path.ecg"
        }
    }

    @ViewBuilder private var stateBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let time = Text(formatWorkTime(task.duration(at: context.date))).monospacedDigit()
            switch task.state {
            case .running:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    time
                }
                .foregroundStyle(Color(nsColor: .hex("16a34a")))
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
        .font(.caption)
        .labelStyle(.titleAndIcon)
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

/// Window ▸ Background Tasks: every session's background work in this window.
@MainActor
final class BackgroundTasksWindowController: NSWindowController {
    init(controller: WorkspaceController, title: String,
         loadOutput: @escaping (UUID, BackgroundTask) async -> String?,
         onSelectSession: @escaping (UUID) -> Void) {
        let view = BackgroundTasksView(
            controller: controller,
            sessionIDs: { [weak controller] in controller?.orderedSessions.map(\.id) ?? [] },
            loadOutput: loadOutput,
            onSelectSession: onSelectSession)
        let hosting = NSHostingController(rootView: view.frame(minWidth: 380, minHeight: 260))
        let window = NSPanel(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel]
        window.title = "Background Tasks — \(title)"
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.setContentSize(NSSize(width: 460, height: 420))
        window.setFrameAutosaveName("BackgroundTasksPanel")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
