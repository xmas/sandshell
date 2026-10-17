import SwiftUI

/// One theme in the appearance editor's browser: a mini sidebar + detail and its name.
struct ThemeBrowserCard: View {
    let t: SidebarTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Mini sidebar + detail preview (always light-mode style)
                HStack(spacing: 0) {
                    Color(NSColor.hex(t.deep))
                        .frame(width: 36)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 3) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(NSColor.hex(t.bright)))
                                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                                    .frame(width: 13, height: 13)
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(.white.opacity(0.65)).frame(width: 22, height: 3)
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(.white.opacity(0.35)).frame(width: 15, height: 3)
                            }
                            .padding(5)
                        }
                    Color(NSColor.hex(t.tint)).frame(maxWidth: .infinity)
                }
                .frame(height: 54)

                Divider()

                Text(t.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
            }
            .clipShape(.rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7).strokeBorder(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}
