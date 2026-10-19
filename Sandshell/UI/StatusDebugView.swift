import SwiftUI
import System

// MARK: - Root view

struct StatusDebugView: View {
    @ObservedObject var controller: WorkspaceController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                workspaceHeader
                containerSection
                KitStartupSection(kitStartup: controller.kitStartup,
                                  openLog: { [controller] in controller.openKitLog(for: $0) })
                sessionSection
            }
            .padding(18)
        }
        .background(.windowBackground)
    }

    // MARK: Sections

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("WORKSPACE")
                .font(.role(.code))
                .foregroundStyle(.secondary)
            Text(FilePath(controller.rootURL)?.string ?? "")
                .font(.role(.code))
                .textSelection(.enabled)
        }
    }

    private var containerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DebugSectionHeader(title: "Containers", count: controller.containerPhases.count)
            if controller.containerPhases.isEmpty {
                DebugEmptyLabel(text: "none created")
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    containerTableHeader
                    Divider()
                    ForEach(controller.containerPhases.keys
                        .sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { agent in
                        if let phase = controller.containerPhases[agent] {
                            ContainerPhaseRow(
                                agent: agent,
                                phase: phase,
                                containerName: controller.containerName(for: agent),
                                sandbox: controller.containers[agent])
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
            }
        }
    }

    private var containerTableHeader: some View {
        HStack(spacing: 0) {
            Text("Agent").frame(width: 70, alignment: .leading)
            Text("Phase").frame(width: 100, alignment: .leading)
            Text("Container").frame(width: 160, alignment: .leading)
            Text("sbx status").frame(width: 80, alignment: .leading)
        }
        .font(.role(.code))
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DebugSectionHeader(title: "Sessions", count: controller.runtimes.count)
            if controller.runtimes.isEmpty {
                DebugEmptyLabel(text: "none")
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    sessionTableHeader
                    Divider()
                    ForEach(controller.orderedSessions) { session in
                        SessionRuntimeRow(
                            session: session,
                            rt: controller.runtime(session.id))
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
            }
        }
    }

    private var sessionTableHeader: some View {
        HStack(spacing: 0) {
            Text("Session").frame(width: 150, alignment: .leading)
            Text("Live").frame(width: 36, alignment: .center)
            Text("Unrd").frame(width: 36, alignment: .center)
            Text("Status").frame(width: 70, alignment: .leading)
            Text("Work ◷").frame(width: 60, alignment: .trailing)
            Spacer()
            Text("Last active").frame(width: 84, alignment: .trailing)
        }
        .font(.role(.code))
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }
}

// MARK: - Shared pieces

private struct DebugSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.role(.code, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("(\(count))")
                .font(.role(.code))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct DebugEmptyLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.role(.code))
            .foregroundStyle(.tertiary)
            .padding(.leading, 4)
    }
}

// MARK: - Kit startup section

private struct KitStartupSection: View {
    let kitStartup: [AgentKind: KitStartupStatus]
    let openLog: @MainActor (AgentKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DebugSectionHeader(title: "Kit startup", count: kitStartup.count)
            if kitStartup.isEmpty {
                DebugEmptyLabel(text: "not read yet")
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        Text("Agent").frame(width: 70, alignment: .leading)
                        Text("Kit").frame(width: 130, alignment: .leading)
                        Text("Outcome").frame(width: 130, alignment: .leading)
                        Text("Detail").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.role(.code))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    Divider()
                    ForEach(kitStartup.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { agent in
                        if let status = kitStartup[agent] {
                            KitStartupRows(agent: agent, status: status, openLog: { openLog(agent) })
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
            }
        }
    }
}

/// One agent's dispatcher line plus a line per configured kit (or the fetch error).
private struct KitStartupRows: View {
    let agent: AgentKind
    let status: KitStartupStatus
    let openLog: @MainActor () -> Void

    var body: some View {
        if let err = status.fetchError {
            HStack(spacing: 0) {
                Text(agent.rawValue).frame(width: 70, alignment: .leading)
                Text("log unavailable: \(err)").foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.role(.code)).padding(.vertical, 2)
        } else {
            HStack(spacing: 0) {
                Text(agent.rawValue).frame(width: 70, alignment: .leading)
                Text("dispatcher").foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                Text(status.isComplete ? "complete" : (status.report?.isAborted == true ? "ABORTED" : "in progress"))
                    .foregroundStyle(status.report?.isAborted == true ? .red : .secondary)
                    .frame(width: 130, alignment: .leading)
                Button("Show Log", action: openLog)
                    .controlSize(.mini)
            }
            .font(.role(.code)).padding(.vertical, 2)
            ForEach(status.entries) { entry in
                HStack(alignment: .top, spacing: 0) {
                    Text("").frame(width: 70)
                    Text(entry.name).frame(width: 130, alignment: .leading)
                    Text(entry.outcome.label)
                        .foregroundStyle(entry.outcome.isProblem ? .red : (entry.outcome == .running ? .secondary : .green))
                        .frame(width: 130, alignment: .leading)
                    Text(entry.detail.first ?? "")
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.role(.code)).padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Container phase row

private struct ContainerPhaseRow: View {
    let agent: AgentKind
    let phase: ContainerPhase
    let containerName: String
    let sandbox: Sandbox?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle()
                    .fill(phase.debugDotColor)
                    .frame(width: 7, height: 7)
                Text(agent.rawValue)
            }
            .frame(width: 70, alignment: .leading)

            Text(phase.displayLabel)
                .foregroundStyle(phase.debugDotColor)
                .frame(width: 100, alignment: .leading)

            Text(containerName)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)

            Text(sandbox?.status ?? "—")
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .leading)
        }
        .font(.role(.code))
        .padding(.vertical, 2)
    }
}

// MARK: - Session runtime row
// Its own once-a-second timeline ticks the work time and "Xs ago" (the
// workspace clock doesn't re-render the views observing the controller).

private struct SessionRuntimeRow: View {
    let session: Session
    let rt: SessionRuntime?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 0) {
                Text(session.name.isEmpty ? "—" : session.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 150, alignment: .leading)

                statusDot(rt?.isLive == true, activeColor: .green, label: "Live")
                    .frame(width: 36)

                statusDot(rt?.isUnread == true, activeColor: .accentColor, label: "Unread")
                    .frame(width: 36)

                Text(rt?.status == .working ? "working" : "ready")
                    .foregroundStyle(rt?.status == .working ? Color(nsColor: .sessionWorking) : Color.secondary)
                    .frame(width: 70, alignment: .leading)

                Text(rt.map { formatWork($0, at: context.date) } ?? "—")
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)

                Spacer()

                Text(rt?.lastActivityAt.map { relativeTime($0, at: context.date) } ?? "—")
                    .foregroundStyle(.tertiary)
                    .frame(width: 84, alignment: .trailing)
            }
            .font(.role(.code))
            .padding(.vertical, 2)
        }
    }

    /// A filled dot when on, an outline when off; VoiceOver hears the column and Yes / No.
    private func statusDot(_ active: Bool, activeColor: Color, label: String) -> some View {
        Circle()
            .fill(active ? activeColor : Color.clear)
            .strokeBorder(active ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1)
            .frame(width: 7, height: 7)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(active ? "Yes" : "No")
    }

    private func formatWork(_ rt: SessionRuntime, at now: Date) -> String {
        let s = Int(ceil(rt.liveWorkSeconds(at: now)))
        guard s >= 1 else { return "—" }
        let m = s / 60; let sec = s % 60
        return m > 0 ? "\(m)m\(sec)s" : "\(sec)s"
    }

    private func relativeTime(_ date: Date, at now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 5  { return "now" }
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h ago"
    }
}

// MARK: - Phase color helper

extension ContainerPhase {
    var debugDotColor: Color {
        switch self {
        case .running:               .green
        case .creating, .rebuilding: .yellow
        case .stopped:               .secondary
        case .absent:                Color(nsColor: .tertiaryLabelColor)
        case .failed:                .red
        }
    }
}
