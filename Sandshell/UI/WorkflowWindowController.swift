import AppKit
import Combine
import SwiftUI

/// A workflow run in its own window, like the Claude app's: how long it's
/// been going, its agents and tokens, its phases with progress, and every
/// agent's model, tokens and time — following it while it runs. Click an
/// agent to read its conversation. One window per run.
@MainActor
final class WorkflowWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: WorkflowWindowController] = [:]

    static func show(_ run: WorkflowRun, sessionID: UUID, workspace: WorkspaceController,
                     stop: (() async -> Bool)?) {
        let controller = open[run.id] ?? WorkflowWindowController(run, sessionID: sessionID, workspace: workspace, stop: stop)
        open[run.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(_ run: WorkflowRun, sessionID: UUID, workspace: WorkspaceController, stop: (() async -> Bool)?) {
        let model = WorkflowWindowModel(run: run, sessionID: sessionID, workspace: workspace, stop: stop)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = run.name
        window.subtitle = "Workflow"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.setFrameAutosaveName("WorkflowWindow")
        window.contentViewController = NSHostingController(rootView: WorkflowRunView(model: model))
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("WorkflowWindow") { window.center() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.open = Self.open.filter { $0.value !== self }
    }
}

/// The run as it stands, kept current from the workspace's poll.
@MainActor
@Observable
final class WorkflowWindowModel {
    private(set) var run: WorkflowRun
    private(set) var task: BackgroundTask?
    private(set) var now = Date.now
    let sessionID: UUID
    @ObservationIgnored private weak var workspace: WorkspaceController?
    @ObservationIgnored let stop: (() async -> Bool)?
    @ObservationIgnored private var bag: Set<AnyCancellable> = []

    init(run: WorkflowRun, sessionID: UUID, workspace: WorkspaceController, stop: (() async -> Bool)?) {
        self.run = run
        self.sessionID = sessionID
        self.workspace = workspace
        self.stop = stop
        workspace.$workflows.sink { [weak self] all in
            guard let self, let latest = all[sessionID]?.first(where: { $0.id == run.id }), latest != self.run else { return }
            self.run = latest
        }.store(in: &bag)
        workspace.$backgroundTasks.sink { [weak self] all in
            self?.task = all[sessionID]?.first { $0.runID == run.id }
        }.store(in: &bag)
        workspace.clockTick.sink { [weak self] tick in
            guard let self, self.isRunning else { return }
            self.now = tick
        }.store(in: &bag)
    }

    /// Running until the background task says it's over (or, without one,
    /// while an agent is still answering).
    var isRunning: Bool { task.map(\.isRunning) ?? !run.agentsSettled }

    var elapsed: TimeInterval {
        guard let start = task?.startedAt ?? run.startedAt else { return 0 }
        let end = isRunning ? now : (task?.finishedAt ?? run.lastWrite ?? now)
        return end.timeIntervalSince(start)
    }

    func openAgent(_ agent: WorkflowRun.Agent) {
        guard let workspace else { return }
        let info = SubagentInfo(id: agent.id, sessionID: sessionID, title: agent.label, agentType: agent.phase,
                                transcript: run.transcript(of: agent), startedAt: agent.startedAt ?? .now,
                                lastWrite: agent.lastWrite ?? .now, state: SubagentInfo.State(agent.state))
        SubagentWindowController.show(info, workspace: workspace)
    }
}

struct WorkflowRunView: View {
    let model: WorkflowWindowModel
    @State private var collapsed: Set<String> = []

    var body: some View {
        let run = model.run
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(run)
                if let summary = run.summary {
                    Text(summary).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Phases").font(.headline)
                ForEach(run.phases) { phase in phaseSection(phase, in: run) }
            }
            .padding(18)
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private func header(_ run: WorkflowRun) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.name).font(.title2.weight(.semibold))
                HStack(spacing: 12) {
                    Label(Format.compactWorkTime(model.elapsed) ?? "—", systemImage: model.isRunning ? "clock" : "checkmark.circle")
                    Label("\(run.agents.count) agents", systemImage: "person.2")
                    Label("\(Format.tokens(run.totalTokens)) tokens", systemImage: "text.word.spacing")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            if model.isRunning, let stop = model.stop {
                Button("Stop Workflow", systemImage: "stop") { Task { _ = await stop() } }
                    .controlSize(.regular)
            }
        }
    }

    private func phaseSection(_ phase: WorkflowRun.Phase, in run: WorkflowRun) -> some View {
        let agents = run.agents(in: phase)
        let progress = run.progress(of: phase)
        let isOpen = !collapsed.contains(phase.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    if isOpen { collapsed.insert(phase.id) } else { collapsed.remove(phase.id) }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.title).font(.body.weight(.medium))
                        if let detail = phase.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text("\(progress.done)/\(progress.total)").foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(phase.title), \(progress.done) of \(progress.total) done")
            Pips(agents: agents)
            if isOpen, !agents.isEmpty {
                agentTable(agents)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private func agentTable(_ agents: [WorkflowRun.Agent]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Agent"); Text("Model"); Text("Tokens").gridColumnAlignment(.trailing); Text("Time").gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(agents) { agent in
                GridRow {
                    Button {
                        model.openAgent(agent)
                    } label: {
                        HStack(spacing: 6) {
                            stateMark(agent.state)
                            Text(agent.label).lineLimit(1)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(agent.label)’s conversation")
                    Text(Self.modelName(agent.model)).foregroundStyle(.secondary).lineLimit(1)
                    Text(agent.tokens > 0 ? Format.tokens(agent.tokens) : "—").monospacedDigit()
                    Text(Format.compactWorkTime(agent.duration(at: model.now)) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private func stateMark(_ state: WorkflowRun.Agent.State) -> some View {
        switch state {
        case .running: ProgressView().controlSize(.mini).frame(width: 14)
        case .done: Image(systemName: "checkmark").foregroundStyle(.secondary).frame(width: 14).accessibilityLabel("done")
        case .failed: Image(systemName: "xmark").foregroundStyle(.red).frame(width: 14).accessibilityLabel("failed")
        }
    }

    /// "claude-opus-5-5" → "Opus 5.5".
    static func modelName(_ id: String?) -> String {
        guard let id else { return "—" }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }
}

/// One square per agent: filled when done, accent while running, red if failed.
private struct Pips: View {
    let agents: [WorkflowRun.Agent]

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(9), spacing: 3), count: 24)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
            ForEach(agents) { agent in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(agent.state))
                    .frame(width: 9, height: 9)
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ state: WorkflowRun.Agent.State) -> Color {
        switch state {
        case .done: Color.secondary.opacity(0.45)
        case .running: Color.accentColor
        case .failed: Color.red
        }
    }
}
