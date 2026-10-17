import SwiftUI

/// Make Default / Apply to All for a window's theme settings.
struct ThemeScopeButtons: View {
    @ObservedObject var theme: ThemeController
    var body: some View {
        Section {
            HStack {
                Button("Make Default") { ThemeDefaults.prefs = theme.prefs }
                    .help("Use these settings as the default for newly-opened folders.")
                Button("Apply to All", action: applyToAllWindows)
                    .help("Apply these settings to every open window and make them the default.")
            }
        } footer: {
            Text("These settings apply to this folder. 'Make Default' sets the default for new "
                 + "folders; 'Apply to All' also updates every open window.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func applyToAllWindows() {
        (NSApp.delegate as? AppDelegate)?.applyThemeToAllWindows(theme.prefs)
    }
}
