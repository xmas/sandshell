import SwiftUI

/// Settings ▸ Terminal: palette, appearance, cursor and the Claude readout's colors.
struct TerminalPaneView: View {
    @ObservedObject var theme: ThemeController
    @State private var editingDark: Bool

    init(theme: ThemeController) {
        self.theme = theme
        _editingDark = State(initialValue: theme.terminalIsDark)
    }

    private var isCustom: Bool { theme.prefs.terminalThemeName == TerminalThemes.customName }

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Palette", selection: $theme.prefs.terminalThemeName) {
                    ForEach(TerminalThemes.presets) { Text($0.name).tag($0.name) }
                    Divider()
                    Text("Custom").tag(TerminalThemes.customName)
                }
                .onChange(of: theme.prefs.terminalThemeName) { old, new in
                    if new == TerminalThemes.customName { seedCustomIfNeeded(from: old) }
                }
                if !isCustom {
                    Button("Customize This Palette…", action: customizePalette)
                }
                Picker("Appearance", selection: $theme.prefs.terminalMode) {
                    ForEach(TerminalAppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: theme.prefs.terminalMode) { _, _ in editingDark = theme.terminalIsDark }
            }

            Section {
                Picker("Style", selection: $theme.prefs.terminalCursorStyle) {
                    ForEach(CursorStyleSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Blink", selection: $theme.prefs.terminalCursorBlink) {
                    ForEach(CursorBlinkSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Cursor")
            } footer: {
                Text("Cursor changes apply to open terminals immediately. Set Blink to Off to stop blinking.")
                    .font(.role(.meta)).foregroundStyle(.secondary)
            }

            Section("Preview") {
                PalettePreview(palette: shownPalette).frame(height: 70)
            }

            Section {
                ClaudeReadoutColorsView(theme: theme.colors)
            } header: {
                Text("Claude Readout")
            } footer: {
                Text("Colors for the context gauge, percent, tokens, cost and model name in the terminal "
                     + "title strip. Unset colors follow the terminal palette. Applies to every window.")
                    .font(.role(.meta)).foregroundStyle(.secondary)
            }

            if isCustom {
                CustomPaletteEditor(theme: theme, editingDark: $editingDark)
            }
            ThemeScopeButtons(theme: theme)
        }
        .formStyle(.grouped)
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
    }

    private var shownPalette: TerminalPalette {
        if isCustom { return CustomPaletteEditor.palette(in: theme.prefs, dark: editingDark) }
        let preset = TerminalThemes.preset(named: theme.prefs.terminalThemeName) ?? TerminalThemes.sandshell
        return editingDark ? preset.dark : preset.light
    }

    /// Seed the custom palettes from the current preset, then switch to Custom.
    private func customizePalette() {
        seedCustomFromCurrent()
        theme.prefs.terminalThemeName = TerminalThemes.customName
    }

    private func seedCustomIfNeeded(from themeName: String) {
        if theme.prefs.customTerminalLight == nil || theme.prefs.customTerminalDark == nil { seedCustom(from: themeName) }
    }
    private func seedCustomFromCurrent() { seedCustom(from: theme.prefs.terminalThemeName) }
    private func seedCustom(from themeName: String) {
        let preset = TerminalThemes.preset(named: themeName) ?? TerminalThemes.sandshell
        if theme.prefs.customTerminalLight == nil { theme.prefs.customTerminalLight = preset.light }
        if theme.prefs.customTerminalDark == nil  { theme.prefs.customTerminalDark  = preset.dark  }
    }
}
