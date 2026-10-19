import SwiftUI

/// A miniature of the window (sidebar and detail) in light or dark, for the appearance editor.
struct AppearancePreview: View {
    let dark: Bool
    let icon: String
    let iconColor: String
    let sidebar: String
    let detail: Color
    let name: String

    var body: some View {
        let sb = Color(NSColor.hex(sidebar))
        VStack(alignment: .leading, spacing: 4) {
            Text(dark ? "Dark" : "Light").font(.role(.meta)).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                // Sidebar column
                VStack(alignment: .leading, spacing: 0) {
                    // Traffic light dots
                    HStack(spacing: 4) {
                        ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.3)).frame(width: 6, height: 6) }
                    }
                    .padding(.top, 8).padding(.leading, 8).padding(.bottom, 2)

                    // Badge + folder name
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(NSColor.hex(iconColor)))
                            .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Image(systemName: icon)
                                    .font(.mark(10, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        Text(name)
                            .font(.mark(9, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)

                    // Faux session row
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(NSColor.hex(iconColor)))
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                            .frame(width: 13, height: 13)
                        VStack(alignment: .leading, spacing: 2) {
                            RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.7)).frame(width: 32, height: 4)
                            RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.4)).frame(width: 22, height: 3)
                        }
                    }
                    .padding(.leading, 8).padding(.bottom, 4)

                    Spacer()

                    // Bottom toolbar strip — slightly darker via black overlay
                    HStack(spacing: 0) {
                        ForEach(0..<4) { _ in
                            Image(systemName: "circle").font(.mark(7))

                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 20)
                    .background { sb.overlay(Color.black.opacity(0.15)) }
                }
                .frame(width: 90)
                .background(sb)

                // Detail column
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 130)
            .clipShape(.rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary) }
        }
        // A picture of the window: one element, not its parts.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dark ? "Dark appearance preview" : "Light appearance preview")
    }
}
