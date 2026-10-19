import SwiftUI

/// A folder's look in Settings ▸ General: the app's appearance, icon, colors and theme.
struct AppearanceEditor: View {
    let folderName: String
    @Binding var icon: String
    @Binding var colorHex: String
    @Binding var sidebarHex: String
    @ObservedObject var theme: ThemeController
    @ObservedObject private var appearance = AppAppearance.shared
    @State private var showAllSymbols = false

    private let symCols = Array(repeating: GridItem(.fixed(40), spacing: 8), count: 8)
    private var quickSymbols: [String] {
        RootProfile.symbols.contains(icon) ? RootProfile.symbols : [icon] + RootProfile.symbols
    }

    /// Each theme's bright, once (themes can share one).
    private static let iconColorItems: [SearchableColorPicker.Entry] = {
        var seen = Set<String>()
        return SidebarTheme.all.compactMap { t in
            seen.insert(t.bright).inserted ? SearchableColorPicker.Entry(hex: t.bright, name: t.name) : nil
        }
    }()
    private static let sidebarItems = SidebarTheme.all.map { SearchableColorPicker.Entry(hex: $0.deep, name: $0.name) }

    var body: some View {
        // The theme these colors are, if any: the one the browser highlights.
        let selectedThemeID = SidebarTheme.all.first { $0.bright == colorHex && $0.deep == sidebarHex }?.id
        VStack(alignment: .leading, spacing: 18) {
            // Global appearance toggle
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance — applies to all of Sandshell")
                    .font(.role(.meta)).foregroundStyle(.secondary)
                Picker("Appearance", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }

            // Side-by-side light + dark previews
            HStack(spacing: 12) {
                AppearancePreview(dark: false, icon: icon, iconColor: colorHex, sidebar: sidebarHex,
                                  detail: detailColor(dark: false), name: folderName)
                AppearancePreview(dark: true, icon: icon, iconColor: colorHex, sidebar: sidebarHex,
                                  detail: detailColor(dark: true), name: folderName)
            }

            // Icon symbol picker
            LabeledField("Icon") {
                LazyVGrid(columns: symCols, spacing: 8) {
                    ForEach(quickSymbols.prefix(16), id: \.self) { s in
                        IconSwatch(symbol: s, isSelected: icon == s, tint: colorHex) { icon = s }
                    }
                }
            } trailing: {
                Button("See more…") { showAllSymbols = true }.font(.role(.meta))
            }

            // Searchable color dropdowns
            HStack(alignment: .top, spacing: 10) {
                ColorDropdownBox("Icon Color") {
                    SearchableColorPicker(label: "Icon Color", items: Self.iconColorItems, selected: $colorHex)
                }
                ColorDropdownBox("Sidebar") {
                    SearchableColorPicker(label: "Sidebar", items: Self.sidebarItems, selected: $sidebarHex)
                }
                ColorDropdownBox("Main") {
                    SearchableColorPicker(label: "Main", items: Self.iconColorItems,
                                          selected: $theme.prefs.mainColorHex)
                } trailing: {
                    Toggle("Match terminal", isOn: $theme.prefs.mainMatchTerminal)
                        .toggleStyle(.checkbox).font(.role(.meta))
                }
            }

            Text(theme.prefs.mainMatchTerminal
                 ? "The detail background follows the terminal theme; only the top bar uses the Main color."
                 : "Main always renders light in Light mode and dark in Dark mode.")
                .font(.role(.meta)).foregroundStyle(.tertiary)

            // Theme browser — fixedSize forces the grid to report its full height
            // to the Form row so it doesn't overflow the window footer.
            VStack(alignment: .leading, spacing: 8) {
                Text("Themes").font(.role(.meta)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(SidebarTheme.all) { t in
                        ThemeBrowserCard(t: t, isSelected: selectedThemeID == t.id) { applyTheme(t) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(2)
            }
        }
        .sheet(isPresented: $showAllSymbols) { SymbolPickerView(selection: $icon) }
    }

    // MARK: Helpers

    /// Take a theme's icon and sidebar colors, and its bright as the Main color.
    private func applyTheme(_ t: SidebarTheme) {
        colorHex = t.bright
        sidebarHex = t.deep
        theme.prefs.mainColorHex = t.bright
    }

    private func mainTint(dark: Bool) -> Color {
        Color(NSColor.hex(RootProfile.mainTone(forIcon: theme.prefs.mainColorHex, dark: dark)))
    }
    private func detailColor(dark: Bool) -> Color {
        if theme.prefs.mainMatchTerminal {
            let pal = theme.terminalPalettes()
            return Color((dark ? pal.dark : pal.light).bgColor)
        }
        return mainTint(dark: dark)
    }
}

/// A captioned block in the appearance editor, with an optional control at the
/// caption's trailing end.
private struct LabeledField<Content: View, Trailing: View>: View {
    let title: String
    let content: Content
    let trailing: Trailing

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.role(.meta)).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            content
        }
    }
}

/// One of the appearance editor's color dropdowns: a caption (and optional
/// trailing control) over the dropdown in a tinted box.
private struct ColorDropdownBox<Content: View, Trailing: View>: View {
    let label: String
    let content: Content
    let trailing: Trailing

    init(_ label: String, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(.role(.meta)).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            content
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.quinary, in: .rect(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
    }
}

extension ColorDropdownBox where Trailing == EmptyView {
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.init(label, content: content) { EmptyView() }
    }
}
