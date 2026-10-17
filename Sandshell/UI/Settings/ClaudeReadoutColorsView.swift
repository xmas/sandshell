import SwiftUI

/// The readout colour pickers — lives in Settings ▸ Terminal. Unset roles follow
/// the terminal palette; a set one shows an undo arrow back to the theme.
struct ClaudeReadoutColorsView: View {
    var theme: ThemeColors?
    @ObservedObject private var appearance = ClaudeStatsAppearance.shared

    var body: some View {
        ForEach(ClaudeStatsColorRole.allCases) { role in
            HStack(spacing: 8) {
                ColorPicker(role.title, selection: $appearance[color: role, fallback: fallback(role)],
                            supportsOpacity: false)
                if appearance.isOverridden(role) {
                    Button("Back to Theme Colour", systemImage: "arrow.uturn.backward.circle") {
                        appearance.set(role, nil)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Back to the theme colour")
                }
            }
        }
        if !appearance.overrides.isEmpty {
            Button("Reset All to Theme") { appearance.resetAll() }
        }
    }

    private func fallback(_ role: ClaudeStatsColorRole) -> NSColor {
        ClaudeStatsView.themeFallback(role, theme)
    }
}
