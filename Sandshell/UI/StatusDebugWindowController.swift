import AppKit
import SwiftUI

// MARK: - Window controller

@MainActor
final class StatusDebugWindowController: NSWindowController {
    init(controller: WorkspaceController) {
        let view = StatusDebugView(controller: controller)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sandbox Status  ·  ⌥ ladybug"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 600, height: 540))
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
}

// MARK: - Root view

private struct StatusDebugView: View {
    @ObservedObject var controller: WorkspaceController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                workspaceHeader
                containerSection
                kitSection
                sessionSection
            }
            .padding(18)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Sections

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("WORKSPACE")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(controller.rootURL.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var containerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Containers", count: controller.containerPhases.count)
            if controller.containerPhases.isEmpty {
                emptyLabel("none created")
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
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
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
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }

    private var kitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Kit startup", count: controller.kitStartup.count)
            if controller.kitStartup.isEmpty {
                emptyLabel("not read yet")
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        Text("Agent").frame(width: 70, alignment: .leading)
                        Text("Kit").frame(width: 130, alignment: .leading)
                        Text("Outcome").frame(width: 130, alignment: .leading)
                        Text("Detail").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    Divider()
                    ForEach(controller.kitStartup.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { agent in
                        if let status = controller.kitStartup[agent] {
                            if let err = status.fetchError {
                                HStack(spacing: 0) {
                                    Text(agent.rawValue).frame(width: 70, alignment: .leading)
                                    Text("log unavailable: \(err)").foregroundStyle(.tertiary).lineLimit(1)
                                }
                                .font(.system(.caption, design: .monospaced)).padding(.vertical, 2)
                            } else {
                                HStack(spacing: 0) {
                                    Text(agent.rawValue).frame(width: 70, alignment: .leading)
                                    Text("dispatcher").foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                                    Text(status.isComplete ? "complete" : (status.report?.isAborted == true ? "ABORTED" : "in progress"))
                                        .foregroundStyle(status.report?.isAborted == true ? .red : .secondary)
                                        .frame(width: 130, alignment: .leading)
                                    Button("Show Log") { controller.openKitLog(for: agent) }
                                        .controlSize(.mini)
                                }
                                .font(.system(.caption, design: .monospaced)).padding(.vertical, 2)
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
                                    .font(.system(.caption, design: .monospaced)).padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Sessions", count: controller.runtimes.count)
            if controller.runtimes.isEmpty {
                emptyLabel("none")
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    sessionTableHeader
                    Divider()
                    ForEach(controller.orderedSessions, id: \.id) { session in
                        SessionRuntimeRow(
                            session: session,
                            rt: controller.runtime(session.id))
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
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
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            Text("(\(count))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.leading, 4)
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
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 2)
    }
}

// MARK: - Session runtime row
// Re-renders every second because StatusDebugView observes WorkspaceController
// whose clockTick @Published fires — no separate timer needed here.

private struct SessionRuntimeRow: View {
    let session: Session
    let rt: SessionRuntime?

    var body: some View {
        HStack(spacing: 0) {
            Text(session.name.isEmpty ? "—" : session.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 150, alignment: .leading)

            statusDot(rt?.isLive == true, activeColor: .green)
                .frame(width: 36)

            statusDot(rt?.isUnread == true, activeColor: .accentColor)
                .frame(width: 36)

            Text(rt?.status == .working ? "working" : "ready")
                .foregroundStyle(rt?.status == .working ? Color(nsColor: .sessionWorking) : Color.secondary)
                .frame(width: 70, alignment: .leading)

            Text(rt.map { formatWork($0) } ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)

            Spacer()

            Text(rt?.lastActivityAt.map { relativeTime($0) } ?? "—")
                .foregroundStyle(.tertiary)
                .frame(width: 84, alignment: .trailing)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 2)
    }

    private func statusDot(_ active: Bool, activeColor: Color) -> some View {
        Circle()
            .fill(active ? activeColor : Color.clear)
            .overlay {
                Circle()
                    .strokeBorder(
                        active ? Color.clear : Color.secondary.opacity(0.35),
                        lineWidth: 1)
            }
            .frame(width: 7, height: 7)
    }

    private func formatWork(_ rt: SessionRuntime) -> String {
        let s = Int(ceil(rt.liveWorkSeconds()))
        guard s >= 1 else { return "—" }
        let m = s / 60; let sec = s % 60
        return m > 0 ? "\(m)m\(sec)s" : "\(sec)s"
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
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
        case .running:              return .green
        case .creating, .rebuilding: return .yellow
        case .stopped:              return Color(NSColor.secondaryLabelColor)
        case .absent:               return Color(NSColor.tertiaryLabelColor)
        case .failed:               return .red
        }
    }
}
