import SwiftUI

/// One folder in the Open Workspace browser: its icon, name, path and when it
/// was last opened. It owns its hover highlight.
struct OpenFoldersRow: View {
    let root: RootProfile
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RootIconMark(profile: root, side: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(root.name).font(.callout).fontWeight(.medium).lineLimit(1)
                    Text(root.path.tildeAbbreviated).font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let opened = root.lastOpened {
                    Text(Format.relative(opened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            // On the accent fill, primary/secondary/tertiary turn white.
            .environment(\.backgroundProminence, isSelected ? .increased : .standard)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor
                          : isHovered ? Color(nsColor: .quaternaryLabelColor).opacity(0.5)
                          : Color.clear)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("open-workspace-row")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
