import AppKit
import SwiftUI

/// The Open Workspace browser (⌘O, "See More…" in the recents menus): every
/// folder Sandshell has ever opened, each with its colored icon, sortable by
/// last-opened or name, filtered as you type. ↑/↓ move the selection (the
/// top match by default), Return opens it, Esc closes; rows highlight on hover.
struct OpenFoldersView: View {
    let onOpen: (URL) -> Void
    let onOpenNew: () -> Void
    let onClose: () -> Void

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recent", name = "Name"
        var id: String { rawValue }
    }

    @State private var sort: Sort = .recent
    @State private var query = ""
    @State private var roots: [RootProfile] = RootFolderStore.byRecency()
    /// Keyboard selection — the row Return opens. Follows the top match as
    /// the filter changes; ↑/↓ move it.
    @State private var selectedID: RootProfile.ID?
    @State private var hoveredID: RootProfile.ID?
    @FocusState private var searchFocused: Bool

    private var filtered: [RootProfile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return roots }
        // Name matches first, then path matches — both case-insensitive.
        let byName = roots.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let byPath = roots.filter { !$0.name.localizedCaseInsensitiveContains(q) && $0.path.localizedCaseInsensitiveContains(q) }
        return byName + byPath
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .onChange(of: sort) { _, _ in reload() }
        .onChange(of: query) { _, _ in selectedID = filtered.first?.id }
        .onAppear { reload(); searchFocused = true }
        .onExitCommand { onClose() }
    }

    private var selected: RootProfile? {
        filtered.first { $0.id == selectedID } ?? filtered.first
    }

    /// Move the keyboard selection by `delta` rows, clamped to the list.
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !filtered.isEmpty else { return .ignored }
        let current = filtered.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), filtered.count - 1)
        selectedID = filtered[next].id
        return .handled
    }

    private func openSelected() {
        if let root = selected { onOpen(root.url) }
    }

    // MARK: Header: title, search, sort

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Open Workspace").font(.title3.bold())
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .accessibilityIdentifier("open-workspace-sort")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type to search folders", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { openSelected() }
                    .onKeyPress(.upArrow) { moveSelection(-1) }
                    .onKeyPress(.downArrow) { moveSelection(1) }
                    .accessibilityIdentifier("open-workspace-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
        }
        .padding(16)
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        if filtered.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: roots.isEmpty ? "folder.badge.questionmark" : "magnifyingglass")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                Text(roots.isEmpty ? "No workspaces yet" : "No folders match “\(query)”")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { root in
                            Button { onOpen(root.url) } label: { row(root) }
                                .buttonStyle(.plain)
                                .id(root.id)
                                .onHover { inside in
                                    if inside { hoveredID = root.id } else if hoveredID == root.id { hoveredID = nil }
                                }
                                .accessibilityIdentifier("open-workspace-row")
                                .accessibilityAddTraits(root.id == selected?.id ? .isSelected : [])
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .onChange(of: selectedID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) } }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func row(_ root: RootProfile) -> some View {
        let isSelected = root.id == selected?.id
        let isHovered = root.id == hoveredID
        return HStack(spacing: 12) {
            RootIconMark(profile: root, side: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(root.name).font(.callout).fontWeight(.medium).lineLimit(1)
                Text(root.path.tildeAbbreviated).font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let opened = root.lastOpened {
                Text(Format.relative(opened))
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color(nsColor: .tertiaryLabelColor))
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor
                      : isHovered ? Color(nsColor: .quaternaryLabelColor).opacity(0.5)
                      : Color.clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 2))
        .contentShape(Rectangle())
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("\(roots.count) folder\(roots.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button(action: onOpenNew) { Text("Open New…") }
                .help("Choose a folder. A folder you’ve opened before opens directly; a new one runs the setup wizard.")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func reload() {
        roots = sort == .recent ? RootFolderStore.byRecency() : RootFolderStore.byName()
        if !filtered.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id }
    }

}

/// A root folder's colored icon mark (rounded square in its brand color with
/// the white SF symbol) — the same identity the sidebar header shows.
struct RootIconMark: View {
    let profile: RootProfile
    var side: CGFloat = 24

    var body: some View {
        BadgeMark(color: .hex(profile.colorHex), content: .symbol(profile.icon), side: side)
    }
}

extension RootProfile {
    /// Menu-sized rendering of the colored icon mark (for NSMenuItem images).
    @MainActor
    func menuImage(side: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.28, yRadius: side * 0.28)
            NSColor.hex(colorHex).setFill()
            path.fill()
            let config = NSImage.SymbolConfiguration(pointSize: side * 0.55, weight: .semibold)
            if let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let tinted = symbol.tinted(.white)
                let size = tinted.size
                let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

private extension NSImage {
    /// A copy filled with `color` (for drawing a template symbol in a fixed tint).
    func tinted(_ color: NSColor) -> NSImage {
        let copy = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        copy.isTemplate = false
        return copy
    }
}

/// Window controller for the Open Workspaces dialog.
final class OpenWindowController: NSWindowController {
    init(onOpen: @escaping (URL) -> Void, onOpenNew: @escaping () -> Void) {
        let window = NSWindow()
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = "Open Workspace"
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.minSize = NSSize(width: 420, height: 320)
        super.init(window: window)

        let view = OpenFoldersView(
            onOpen: { [weak self] url in
                onOpen(url)
                self?.close()
            },
            onOpenNew: { [weak self] in onOpenNew(); self?.close() },
            onClose: { [weak self] in self?.close() })
        // Setting the content view controller resizes the window to the SwiftUI
        // view's fitting size (which for a ScrollView is tiny, so the window
        // collapsed to minSize). Don't let SwiftUI drive the window size; set
        // ours afterwards, then let a remembered user resize win over it.
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 520, height: 620))
        window.center()
        window.setFrameAutosaveName("OpenWorkspaceBrowser")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
