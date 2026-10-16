import AppKit

extension NSMenuItem {
    /// A menu item in one call: its action and target, an SF Symbol (or an
    /// image), the object it acts on, a key equivalent, and a submenu.
    convenience init(_ title: String, action: Selector? = nil, target: AnyObject? = nil,
                     symbol: String? = nil, image: NSImage? = nil, object: Any? = nil,
                     key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                     submenu: [NSMenuItem]? = nil) {
        self.init(title: title, action: action, keyEquivalent: key)
        self.target = target
        self.image = image ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        representedObject = object
        if !key.isEmpty { keyEquivalentModifierMask = modifiers }
        if let submenu {
            let menu = NSMenu()
            menu.items = submenu
            self.submenu = menu
        }
    }

    /// A menu item that runs `handler` (the item keeps it alive).
    convenience init(_ title: String, handler: @escaping () -> Void) {
        let box = ClosureMenuItem(handler)
        self.init(title, action: #selector(ClosureMenuItem.run), target: box, object: box)
    }
}

extension RootProfile {
    /// A recent-folder item: its icon, its path as the tooltip, its URL as the object.
    @MainActor func menuItem(action: Selector, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(name, action: action, target: target, image: menuImage(), object: url)
        item.toolTip = path
        return item
    }
}

/// The target of a closure-based menu item.
final class ClosureMenuItem: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
