import AppKit
import SwiftUI

// MARK: - FolderLookEditor

/// Reusable folder "look" editor — icon (SF Symbol), color, sidebar background.
/// Used in the General folder manager and the Open Folder / Welcome dialog.
struct FolderLookEditor: View {
    @Binding var icon: String
    @Binding var colorHex: String
    @Binding var sidebarHex: String
    @State private var showAllSymbols = false

    private let cols = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8)
    private var quickSymbols: [String] {
        RootProfile.symbols.contains(icon) ? RootProfile.symbols : [icon] + RootProfile.symbols
    }
    private var ring: Color { Color(nsColor: .controlAccentColor) }

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
                    ForEach(SidebarTheme.all.filter { $0.group == group }) { t in
                        Text(t.name).tag(t.id as String?)
                    }
                }
            }
        }
        .pickerStyle(.menu)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Icon").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("See more…") { showAllSymbols = true }.font(.caption)
            }
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(quickSymbols, id: \.self) { s in
                    IconSwatch(symbol: s, isSelected: icon == s, tint: colorHex) { icon = s }
                }
            }
        }
        .sheet(isPresented: $showAllSymbols) { SymbolPickerView(selection: $icon) }

        VStack(alignment: .leading, spacing: 6) {
            Text("Color").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(RootProfile.colors, id: \.self) { c in
                    ColorSwatch(hex: c, isSelected: colorHex == c, ring: ring) { colorHex = c }
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Sidebar").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(RootProfile.colors, id: \.self) { c in
                    DotSwatch(hex: c, isSelected: sidebarHex == RootProfile.sidebarTone(forIcon: c), ring: ring) {
                        sidebarHex = RootProfile.sidebarTone(forIcon: c)
                    }
                }
            }
        }
    }
}

// MARK: - Shared small swatch helpers

private struct ColorSwatch: View {
    let hex: String; let isSelected: Bool; let ring: Color; let action: () -> Void
    var body: some View {
        Circle().fill(Color(NSColor.hex(hex))).frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(ring, lineWidth: isSelected ? 3 : 0))
            .padding(2).contentShape(Circle()).onTapGesture(perform: action)
    }
}

private struct IconSwatch: View {
    let symbol: String; let isSelected: Bool; let tint: String; let action: () -> Void
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color(NSColor.hex(tint)) : Color.secondary.opacity(0.12)))
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .contentShape(Rectangle()).onTapGesture(perform: action)
    }
}

private struct DotSwatch: View {
    let hex: String; let isSelected: Bool; let ring: Color; let action: () -> Void
    var body: some View {
        Circle().fill(Color(NSColor.hex(hex))).frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(ring, lineWidth: isSelected ? 3 : 0))
            .frame(width: 34, height: 26).contentShape(Rectangle()).onTapGesture(perform: action)
    }
}

// MARK: - SearchableColorPicker

private struct ColorEntry: Hashable {
    let hex: String
    let name: String
}

private struct ColorPickerDropdown: View {
    @Binding var selected: String
    @Binding var isOpen: Bool
    let allItems: [ColorEntry]
    @State private var query = ""

    private var filtered: [ColorEntry] {
        query.isEmpty ? allItems : allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder private func rowView(hex: String, name: String) -> some View {
        Button {
            selected = hex
            isOpen = false
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(NSColor.hex(hex))).frame(width: 14, height: 14)
                Text(name).font(.callout)
                Spacer()
                if hex == selected {
                    Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search…", text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.map { $0.hex }, id: \.self) { hex in
                        rowView(hex: hex, name: allItems.first(where: { $0.hex == hex })?.name ?? "")
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: max(56, min(CGFloat(filtered.count) * 28 + 8, 220)))
        }
        .frame(width: 210)
    }
}

private struct SearchableColorPicker: View {
    let label: String
    let items: [ColorEntry]
    @Binding var selected: String
    @State private var isOpen = false

    private var selectedName: String {
        items.first { $0.hex == selected }?.name ?? selected
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(NSColor.hex(selected))).frame(width: 12, height: 12)
                Text(selectedName).font(.callout).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ColorPickerDropdown(selected: $selected, isOpen: $isOpen, allItems: items)
        }
    }
}

// MARK: - ThemeBrowserCard

private struct ThemeBrowserCard: View {
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
                                    .frame(width: 13, height: 13)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(.white.opacity(0.35), lineWidth: 1))
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
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - GeneralPaneView

/// Settings ▸ General for **this** workspace only: its folder identity (icon,
/// color, sidebar), whether it opens at launch, primary agent, base image,
/// archive cadence, appearance. Other folders are managed from the Open
/// Workspace browser (⌘O), not here.
struct GeneralPaneView: View {
    @ObservedObject var controller: WorkspaceController
    /// Whether this folder is the one opened at launch when no windows are
    /// restored (the app-global `RootFolderStore.defaultPath`).
    @State private var opensAtLaunch: Bool
    @State private var primaryAgent: AgentKind
    @State private var archiveMinutes: Double
    @State private var imageChannel: ImageChannel
    @State private var customImage: String

    init(controller: WorkspaceController) {
        self.controller = controller
        let current = RootFolderStore.standardize(controller.rootURL.path)
        _opensAtLaunch = State(initialValue: RootFolderStore.defaultPath == current)
        _primaryAgent = State(initialValue: controller.primaryAgent)
        _archiveMinutes = State(initialValue: (controller.archiveInterval / 60).rounded())
        _imageChannel = State(initialValue: controller.imageChannel)
        _customImage = State(initialValue: controller.customImage)
    }

    private var editing: RootProfile { controller.rootProfile }
    private var currentPath: String { RootFolderStore.standardize(controller.rootURL.path) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    BadgeMark(color: .hex(editing.colorHex), content: .symbol(editing.icon), side: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(editing.name).fontWeight(.semibold)
                        Text(controller.rootURL.path).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Toggle("Open this folder at launch", isOn: $opensAtLaunch)
                    .onChange(of: opensAtLaunch) { _, on in
                        if on {
                            RootFolderStore.defaultPath = currentPath
                        } else if RootFolderStore.defaultPath == currentPath {
                            RootFolderStore.defaultPath = nil
                        }
                    }
                    .accessibilityIdentifier("general-open-at-launch")
            } header: {
                Text("This Folder")
            } footer: {
                Text("Used only when Sandshell has no windows to restore at launch. "
                     + "Other folders live in the Open Workspace browser (⌘O).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agents") {
                Picker("Primary Agent", selection: $primaryAgent) {
                    ForEach(controller.availableAgents) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
                .onChange(of: primaryAgent) { _, new in controller.setPrimaryAgent(new) }
            }
            Section {
                Picker("Base Image", selection: $imageChannel) {
                    ForEach(ImageChannel.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: imageChannel) { _, new in controller.setImageChannel(new, customImage: customImage) }
                .accessibilityIdentifier("general-image-channel")
                if imageChannel == .custom {
                    TextField("docker/sandbox-templates:claude-code-docker-0.5.0 or any image", text: $customImage)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { controller.setImageChannel(.custom, customImage: customImage) }
                        // Also commit when Settings closes without Return being pressed.
                        .onDisappear { controller.setImageChannel(imageChannel, customImage: customImage) }
                }
                if let t = controller.workspace.templateImage(for: controller.primaryAgent) {
                    Text("sbx create -t \(t)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if !controller.customAgents.isEmpty {
                    // `-t` would replace a kit agent's own image (see ImageChannel.templateImage).
                    Text("Built-in agents only — \(controller.customAgents.map(\.displayName).joined(separator: ", ")) "
                         + "always run\(controller.customAgents.count == 1 ? "s" : "") the image from \(controller.customAgents.count == 1 ? "its" : "their") kit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(controller.isBuilding ? "Rebuilding…" : "Changes apply when a sandbox is (re)built.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Rebuild Sandboxes Now") { controller.rebuildAll() }
                        .disabled(controller.isBuilding)
                        .accessibilityIdentifier("general-rebuild-now")
                }
            } header: {
                Text("Sandbox Image")
            } footer: {
                Text("Stable is Docker’s released template (updated every few weeks — the Claude Code baked into it goes "
                     + "stale, and new models refuse old versions). Nightly is rebuilt every day from Docker’s main branch with "
                     + "the current Claude Code; less tested. Either way the tag is re-pulled on every rebuild.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Archive") {
                Stepper(value: $archiveMinutes, in: 1...240, step: 1) {
                    Text("Auto-archive every \(Int(archiveMinutes)) min")
                }
                .onChange(of: archiveMinutes) { _, new in controller.setArchiveInterval(new * 60) }
            }
            Section("Appearance — \(editing.name)") {
                AppearanceEditor(folderName: editing.name,
                                 icon: bind(\.icon), colorHex: bind(\.colorHex),
                                 sidebarHex: bind(\.sidebarHex), theme: controller.theme)
            }
            ThemeScopeButtons(theme: controller.theme)
        }
        .formStyle(.grouped)
        .contentMargins(.bottom, 80, for: .scrollContent)
    }

    /// Edit this folder's look; `updateRootProfile` persists to the registry
    /// and republishes so the sidebar re-renders live.
    private func bind(_ keyPath: WritableKeyPath<RootProfile, String>) -> Binding<String> {
        Binding(
            get: { editing[keyPath: keyPath] },
            set: { newValue in controller.updateRootProfile { $0[keyPath: keyPath] = newValue } })
    }
}

// MARK: - AppearanceEditor

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

    private var themeBinding: Binding<String?> {
        Binding(
            get: { SidebarTheme.all.first { $0.bright == colorHex && $0.deep == sidebarHex }?.id },
            set: { id in
                guard let id, let t = SidebarTheme.all.first(where: { $0.id == id }) else { return }
                colorHex = t.bright
                sidebarHex = t.deep
                theme.prefs.mainColorHex = t.bright
            }
        )
    }

    private var iconColorItems: [ColorEntry] {
        var seen = Set<String>()
        return SidebarTheme.all.compactMap { t in
            seen.insert(t.bright).inserted ? ColorEntry(hex: t.bright, name: t.name) : nil
        }
    }
    private var sidebarItems: [ColorEntry] {
        SidebarTheme.all.map { ColorEntry(hex: $0.deep, name: $0.name) }
    }
    private var mainColorBinding: Binding<String> {
        Binding(
            get: { theme.prefs.mainColorHex },
            set: { theme.prefs.mainColorHex = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Global appearance toggle
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance — applies to all of Sandshell")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }

            // Side-by-side light + dark previews
            HStack(spacing: 12) {
                AppearancePreview(dark: false, icon: icon, iconColor: colorHex, sidebar: sidebarHex,
                                  detail: detailColor(dark: false), topBar: mainBar(dark: false), name: folderName)
                AppearancePreview(dark: true, icon: icon, iconColor: colorHex, sidebar: sidebarHex,
                                  detail: detailColor(dark: true), topBar: mainBar(dark: true), name: folderName)
            }

            // Icon symbol picker
            field("Icon", trailing: AnyView(Button("See more…") { showAllSymbols = true }.font(.caption))) {
                LazyVGrid(columns: symCols, spacing: 8) {
                    ForEach(quickSymbols.prefix(16), id: \.self) { s in
                        IconSwatch(symbol: s, isSelected: icon == s, tint: colorHex) { icon = s }
                    }
                }
            }

            // Searchable color dropdowns
            HStack(alignment: .top, spacing: 10) {
                colorDropdown(label: "Icon Color") {
                    SearchableColorPicker(label: "Icon Color", items: iconColorItems, selected: $colorHex)
                }
                colorDropdown(label: "Sidebar") {
                    SearchableColorPicker(label: "Sidebar", items: sidebarItems, selected: $sidebarHex)
                }
                colorDropdown(label: "Main", trailing: AnyView(
                    Toggle("Match terminal", isOn: $theme.prefs.mainMatchTerminal)
                        .toggleStyle(.checkbox).font(.caption2))) {
                    SearchableColorPicker(label: "Main", items: iconColorItems, selected: mainColorBinding)
                }
            }

            Text(theme.prefs.mainMatchTerminal
                 ? "The detail background follows the terminal theme; only the top bar uses the Main color."
                 : "Main always renders light in Light mode and dark in Dark mode.")
                .font(.caption2).foregroundStyle(.tertiary)

            // Theme browser — fixedSize forces the grid to report its full height
            // to the Form row so it doesn't overflow the window footer.
            VStack(alignment: .leading, spacing: 8) {
                Text("Themes").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(SidebarTheme.all) { t in
                        ThemeBrowserCard(t: t, isSelected: themeBinding.wrappedValue == t.id) {
                            colorHex = t.bright
                            sidebarHex = t.deep
                            theme.prefs.mainColorHex = t.bright
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(2)
            }
        }
        .sheet(isPresented: $showAllSymbols) { SymbolPickerView(selection: $icon) }
    }

    // MARK: Helpers

    private func mainTint(dark: Bool) -> Color {
        Color(NSColor.hex(RootProfile.mainTone(forIcon: theme.prefs.mainColorHex, dark: dark)))
    }
    private func mainBar(dark: Bool) -> Color {
        Color(NSColor.hex(RootProfile.mainBarTone(forIcon: theme.prefs.mainColorHex, dark: dark)))
    }
    private func detailColor(dark: Bool) -> Color {
        if theme.prefs.mainMatchTerminal {
            let pal = theme.terminalPalettes()
            return Color((dark ? pal.dark : pal.light).bgColor)
        }
        return mainTint(dark: dark)
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, trailing: AnyView? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }

    @ViewBuilder
    private func colorDropdown<Content: View>(label: String, trailing: AnyView? = nil,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let trailing { trailing }
            }
            content()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - AppearancePreview

private struct AppearancePreview: View {
    let dark: Bool
    let icon: String
    let iconColor: String
    let sidebar: String
    let detail: Color
    let topBar: Color  // kept for API compat; title lives in sidebar column
    let name: String

    var body: some View {
        let sb = NSColor.hex(sidebar)
        VStack(alignment: .leading, spacing: 4) {
            Text(dark ? "Dark" : "Light").font(.caption2).foregroundStyle(.secondary)
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
                            .frame(width: 22, height: 22)
                            .overlay(Image(systemName: icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
                        Text(name)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)

                    // Faux session row
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(NSColor.hex(iconColor)))
                            .frame(width: 13, height: 13)
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(.white.opacity(0.25), lineWidth: 1))
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
                            Image(systemName: "circle").font(.system(size: 7))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 20)
                    .background(Color(sb).overlay(Color.black.opacity(0.15)))
                }
                .frame(width: 90)
                .background(Color(sb))

                // Detail column
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        }
    }
}

// MARK: - TerminalPaneView

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
                    Button("Customize This Palette…") {
                        seedCustomFromCurrent()
                        theme.prefs.terminalThemeName = TerminalThemes.customName
                    }
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
                    .font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary)
            }

            if isCustom {
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
            ThemeScopeButtons(theme: theme)
        }
        .formStyle(.grouped)
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
    }

    private var shownPalette: TerminalPalette {
        if isCustom { return currentCustom() }
        let preset = TerminalThemes.preset(named: theme.prefs.terminalThemeName) ?? TerminalThemes.sandshell
        return editingDark ? preset.dark : preset.light
    }

    @ViewBuilder
    private func ansiRow(title: String, range: Range<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                ForEach(range, id: \.self) { i in
                    ColorPicker("", selection: bindAnsi(i), supportsOpacity: false).labelsHidden().help("ANSI \(i)")
                }
            }
        }
    }

    private func currentCustom() -> TerminalPalette {
        let fallback = editingDark ? TerminalThemes.sandshell.dark : TerminalThemes.sandshell.light
        return (editingDark ? theme.prefs.customTerminalDark : theme.prefs.customTerminalLight) ?? fallback
    }
    private func setCustom(_ pal: TerminalPalette) {
        if editingDark { theme.prefs.customTerminalDark = pal } else { theme.prefs.customTerminalLight = pal }
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

// MARK: - PalettePreview

private struct PalettePreview: View {
    let palette: TerminalPalette
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8).fill(Color(palette.bgColor))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("›").foregroundStyle(Color(palette.fgColor))
                    Text("sandshell").foregroundStyle(Color(palette.dimColor))
                    Text("session").foregroundStyle(Color(palette.greenColor))
                }
                .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 5) {
                    ForEach(0..<16, id: \.self) { i in
                        Circle().fill(Color(NSColor.hex(palette.ansi[i]))).frame(width: 11, height: 11)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }
}

// MARK: - ThemeScopeButtons

struct ThemeScopeButtons: View {
    @ObservedObject var theme: ThemeController
    var body: some View {
        Section {
            HStack {
                Button("Make Default") { ThemeDefaults.prefs = theme.prefs }
                    .help("Use these settings as the default for newly-opened folders.")
                Button("Apply to All") {
                    (NSApp.delegate as? AppDelegate)?.applyThemeToAllWindows(theme.prefs)
                }
                .help("Apply these settings to every open window and make them the default.")
            }
        } footer: {
            Text("These settings apply to this folder. 'Make Default' sets the default for new "
                 + "folders; 'Apply to All' also updates every open window.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - StubPaneView

struct StubPaneView: View {
    let title: String
    let symbol: String
    let note: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(note).foregroundStyle(.secondary)
        }
        .frame(width: InspectorMetrics.paneWidth, height: 320)
    }
}
