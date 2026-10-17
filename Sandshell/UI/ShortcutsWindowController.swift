import AppKit
import SwiftUI

/// Help ▸ Keyboard Shortcuts (⇧⌘/): every menu command that has a shortcut,
/// read from the menu bar itself (so it can't go stale), grouped by menu and
/// filterable.
@MainActor
final class ShortcutsWindowController: NSWindowController {
    static let shared = ShortcutsWindowController()

    struct Shortcut: Identifiable, Hashable {
        let menu: String
        let title: String
        let keys: String
        var id: String { menu + "|" + title + "|" + keys }
    }

    private init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        window.title = "Keyboard Shortcuts"
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.setFrameAutosaveName("KeyboardShortcuts")
        super.init(window: window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.contentViewController = NSHostingController(rootView: ShortcutsView(shortcuts: Self.collect()))
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The menu bar's shortcuts, menu by menu (submenus as "Edit ▸ Find").
    static func collect(_ menu: NSMenu? = NSApp.mainMenu) -> [Shortcut] {
        var found: [Shortcut] = []
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {
                if let sub = item.submenu {
                    walk(sub, path: path.isEmpty ? (sub.title.isEmpty ? "App" : sub.title) : "\(path) ▸ \(item.title)")
                } else if !item.keyEquivalent.isEmpty {
                    found.append(Shortcut(menu: path, title: item.title, keys: keys(for: item)))
                }
            }
        }
        if let menu { walk(menu, path: "") }
        return found
    }

    static func keys(for item: NSMenuItem) -> String {
        let flags = item.keyEquivalentModifierMask
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        switch item.keyEquivalent {
        case "\r": s += "↩"
        case "\t": s += "⇥"
        case " ": s += "Space"
        case "\u{1b}": s += "⎋"
        case "\u{8}", "\u{7f}": s += "⌫"
        default: s += item.keyEquivalent.uppercased()
        }
        return s
    }
}

private struct ShortcutsView: View {
    let shortcuts: [ShortcutsWindowController.Shortcut]
    @State private var filter = ""

    private var shown: [ShortcutsWindowController.Shortcut] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return shortcuts }
        return shortcuts.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.menu.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).padding(10)
            List {
                ForEach(Array(Dictionary(grouping: shown, by: \.menu).sorted { a, b in
                    order(a.key) < order(b.key)
                }), id: \.key) { menu, items in
                    Section(menu) {
                        ForEach(items) { s in
                            HStack {
                                Text(s.title)
                                Spacer()
                                Text(s.keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }

    /// Menu bar order.
    private func order(_ menu: String) -> Int {
        shortcuts.firstIndex { $0.menu == menu } ?? .max
    }
}
