import SwiftUI

/// Terminal ▸ the Custom palette's colors, its light and dark versions edited
/// one at a time.
struct CustomPaletteEditor: View {
    @ObservedObject var theme: ThemeController
    @Binding var editingDark: Bool

    /// The custom palette for `dark`: the one saved, else Sandshell's.
    static func palette(in prefs: ThemePreferences, dark: Bool) -> TerminalPalette {
        let fallback = dark ? TerminalThemes.sandshell.dark : TerminalThemes.sandshell.light
        return (dark ? prefs.customTerminalDark : prefs.customTerminalLight) ?? fallback
    }

    var body: some View {
        Picker("Editing", selection: $editingDark) {
            Text("Light").tag(false)
            Text("Dark").tag(true)
        }
        .pickerStyle(.segmented)

        Section("Base") {
            ColorPicker("Background", selection: bind(\.background), supportsOpacity: false)
            ColorPicker("Foreground", selection: bind(\.foreground), supportsOpacity: false)
            ColorPicker("Cursor",     selection: bind(\.cursor),     supportsOpacity: false)
            ColorPicker("Selection",  selection: bind(\.selection),  supportsOpacity: false)
        }
        Section("ANSI Colors") {
            ansiRow(title: "Normal", range: 0..<8)
            ansiRow(title: "Bright", range: 8..<16)
        }
    }

    @ViewBuilder
    private func ansiRow(title: String, range: Range<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                ForEach(range, id: \.self) { i in
                    ColorPicker("ANSI \(i)", selection: bindAnsi(i), supportsOpacity: false)
                        .labelsHidden().help("ANSI \(i)")
                }
            }
        }
    }

    private func currentCustom() -> TerminalPalette { Self.palette(in: theme.prefs, dark: editingDark) }
    private func setCustom(_ pal: TerminalPalette) {
        if editingDark { theme.prefs.customTerminalDark = pal } else { theme.prefs.customTerminalLight = pal }
    }
    private func bind(_ keyPath: WritableKeyPath<TerminalPalette, String>) -> Binding<Color> {
        Binding(
            get: { Color(NSColor.hex(currentCustom()[keyPath: keyPath])) },
            set: { var p = currentCustom(); p[keyPath: keyPath] = NSColor($0).hexString; setCustom(p) }
        )
    }
    private func bindAnsi(_ index: Int) -> Binding<Color> {
        Binding(
            get: { Color(NSColor.hex(currentCustom().ansi[index])) },
            set: { var p = currentCustom(); p.ansi[index] = NSColor($0).hexString; setCustom(p) }
        )
    }
}
