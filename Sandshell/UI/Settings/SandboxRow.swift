import SwiftUI

struct SandboxRow: View {
    let sb: Sandbox
    @ObservedObject var controller: WorkspaceController
    @Binding var expanded: Bool
    let requestDelete: () -> Void

    private var busy: Bool { controller.sandboxBusy.contains(sb.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                SandboxDetailView(sb: sb, controller: controller, requestDelete: requestDelete)
                    .padding(.top, 6)
            }
        }
    }

    /// The always-visible row, a button that expands it. The chevron rotates
    /// (not crossfades) on toggle.
    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Circle().fill(sb.isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .frame(width: 7, height: 7)
                Text(sb.name)
                Text(sb.agent).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                else { Text(sb.status).font(.caption).foregroundStyle(.secondary) }
            }
            // The gap the Spacer leaves is part of the button too.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sandbox-row-\(sb.name)")
    }
}
