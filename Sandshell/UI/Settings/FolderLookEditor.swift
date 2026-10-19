import SwiftUI

/// Reusable folder "look" editor — icon (SF Symbol), color, sidebar background.
/// Used in the General folder manager and the Open Folder / Welcome dialog.
struct FolderLookEditor: View {
    @Binding var icon: String
    @Binding var colorHex: String
    @Binding var sidebarHex: String
    @State private var showAllSymbols = false

    private let cols = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8)
    /// Each group's themes, in `SidebarTheme.all` order.
    private static let themesByGroup = Dictionary(grouping: SidebarTheme.all, by: \.group)
    private var quickSymbols: [String] {
        RootProfile.symbols.contains(icon) ? RootProfile.symbols : [icon] + RootProfile.symbols
    }

    private var themeBinding: Binding<String?> {
        Binding(
            get: { SidebarTheme.all.first { $0.bright == colorHex && $0.deep == sidebarHex }?.id },
            set: { id in
                guard let id, let t = SidebarTheme.all.first(where: { $0.id == id }) else { return }
                colorHex = t.bright
                sidebarHex = t.deep
            }
        )
    }

    var body: some View {
        Picker("Theme", selection: themeBinding) {
            Text("—").tag(nil as String?)
            ForEach(SidebarTheme.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(Self.themesByGroup[group] ?? []) { t in
                        Text(t.name).tag(t.id as String?)
                    }
                }
            }
        }
        .pickerStyle(.menu)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Icon").font(.role(.meta)).foregroundStyle(.secondary)
                Spacer()
                Button("See more…") { showAllSymbols = true }.font(.role(.meta))
            }
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(quickSymbols, id: \.self) { s in
                    IconSwatch(symbol: s, isSelected: icon == s, tint: colorHex) { icon = s }
                }
            }
        }
        .sheet(isPresented: $showAllSymbols) { SymbolPickerView(selection: $icon) }

        VStack(alignment: .leading, spacing: 6) {
            Text("Color").font(.role(.meta)).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(RootProfile.colors, id: \.self) { c in
                    ColorSwatch(hex: c, isSelected: colorHex == c) { colorHex = c }
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Sidebar").font(.role(.meta)).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(RootProfile.colors, id: \.self) { c in
                    DotSwatch(hex: c, isSelected: sidebarHex == RootProfile.sidebarTone(forIcon: c)) {
                        sidebarHex = RootProfile.sidebarTone(forIcon: c)
                    }
                }
            }
        }
    }
}

private struct ColorSwatch: View {
    let hex: String; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(Color(NSColor.hex(hex)))
                .strokeBorder(.tint, lineWidth: isSelected ? 3 : 0)
                .frame(width: 22, height: 22)
                .padding(2).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SidebarTheme.find(bright: hex)?.name ?? hex)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DotSwatch: View {
    let hex: String; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(Color(NSColor.hex(hex)))
                .strokeBorder(.tint, lineWidth: isSelected ? 3 : 0)
                .frame(width: 24, height: 24)
                .frame(width: 34, height: 26).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SidebarTheme.find(bright: hex)?.name ?? hex)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
