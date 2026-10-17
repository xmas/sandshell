import AppKit
import SwiftUI

/// Help ▸ Keyboard Shortcuts (⌥⌘/): every menu command that has a shortcut,
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

    /// One menu's shortcuts: a section of the list.
    struct MenuGroup: Identifiable, Hashable {
        let menu: String
        let items: [Shortcut]
        var id: String { menu }
    }

    private let host = NSHostingController(rootView: ShortcutsView(groups: []))

    private init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        window.title = "Keyboard Shortcuts"
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        // The list sets only the window's minimum size: the window keeps the
        // size it opens at, or the one it was given.
        host.sizingOptions = [.minSize]
        window.contentViewController = host   // (fits the window to the empty list…)
        window.setContentSize(NSSize(width: 460, height: 560))
        window.center()
        // …so the saved frame comes back, and saving starts, only now.
        window.setFrameUsingName("KeyboardShortcuts")
        window.setFrameAutosaveName("KeyboardShortcuts")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        host.rootView = ShortcutsView(groups: Self.grouped(Self.collect()))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// `shortcuts` by menu, in menu-bar order: each menu where its first
    /// shortcut is (a menu's own items can come before and after a submenu's).
    nonisolated static func grouped(_ shortcuts: [Shortcut]) -> [MenuGroup] {
        let byMenu = Dictionary(grouping: shortcuts, by: \.menu)
        var seen: Set<String> = []
        return shortcuts.map(\.menu).filter { seen.insert($0).inserted }
            .map { MenuGroup(menu: $0, items: byMenu[$0] ?? []) }
    }

    /// The shortcuts whose title or menu matches `query` the way Finder's
    /// search does (case and accents aside), dropping menus left empty; all of
    /// them for an empty query.
    nonisolated static func filter(_ groups: [MenuGroup], by query: String) -> [MenuGroup] {
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter { $0.title.localizedStandardContains(query) || $0.menu.localizedStandardContains(query) }
            return items.isEmpty ? nil : MenuGroup(menu: group.menu, items: items)
        }
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
