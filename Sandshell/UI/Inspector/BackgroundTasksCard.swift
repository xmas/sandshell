import SwiftUI

/// The session's background work: workflows, subagents, commands, monitors.
/// Running ones with their time and Stop; the finished ones folded away.
struct BackgroundTasksCard: View {
    let model: SessionInspectorModel
    @State private var showFinished = false

    var body: some View {
        let running = model.runningTasks, finished = model.finishedTasks
        VStack(alignment: .leading, spacing: 6) {
            if running.isEmpty && finished.isEmpty {
                Text("Nothing running in the background.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(running) { task in row(task) }
            if !finished.isEmpty {
                DisclosureGroup(isExpanded: $showFinished) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(finished) { task in row(task) }
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary).frame(width: 18)
                            .accessibilityHidden(true)
                        Text("\(finished.count) finished")
                    }
                }
            }
        }
        .font(.callout)
    }

    private func row(_ task: BackgroundTask) -> some View {
        HStack(spacing: 9) {
            Button {
                open(task)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: Self.symbol(task))
                        .foregroundStyle(task.isRunning ? Color.primary : Color.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title).lineLimit(1).truncationMode(.tail)
                        if let line = detailLine(task) {
                            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(Format.compactWorkTime(task.duration(at: model.now)) ?? "")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(task.detail ?? task.title)
            if task.isRunning {
                Button("Stop \(task.title)", systemImage: "stop") {
                    Task { _ = await model.stopTask?(task) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Stop")
            } else {
                Image(systemName: task.state == .failed ? "xmark.circle" : task.state == .stopped ? "stop.circle" : "checkmark")
                    .foregroundStyle(task.state == .failed ? Color.red : Color.secondary)
                    .accessibilityLabel(task.state.rawValue)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// A workflow's phase progress ("Verify 12/40"), else the task's latest activity.
    private func detailLine(_ task: BackgroundTask) -> String? {
        if let run = model.workflow(for: task) {
            let current = run.phases.last { run.progress(of: $0).total > 0 } ?? run.phases.first
            guard let current else { return "\(run.agents.count) agents" }
            let p = run.progress(of: current)
            return "\(current.title) \(p.done)/\(p.total) · \(run.agents.count) agents · \(Format.tokens(run.totalTokens))"
        }
        return task.activity ?? (task.isRunning ? nil : task.summary)
    }

    private func open(_ task: BackgroundTask) {
        if let run = model.workflow(for: task) {
            model.openWorkflow?(run)
        } else if task.kind == .agent, let info = model.subagents.first(where: { $0.id == task.id }) {
            model.openSubagent?(info)
        } else {
            model.openTask?(task)
        }
    }

    static func symbol(_ task: BackgroundTask) -> String {
        switch task.kind {
        case .workflow: "point.3.connected.trianglepath.dotted"
        case .agent: "person.2"
        case .shell: "apple.terminal"
        case .monitor: "waveform.path.ecg"
        }
    }
}
