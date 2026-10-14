#if DEBUG
import AppKit

/// The UI-test bridge's `ax` commands: find and press elements by
/// accessibility identifier or label from inside the app, over AppKit's own
/// accessibility tree. System Events sees no other app's windows while the
/// screen is locked or the display asleep (an overnight run); this does.
///
/// `ax <verb>\t<window title>\t<target>` — the window is the one whose title is
/// `<window title>` (or starts with it plus " — "); its sheets are searched
/// first, innermost first. Verbs:
///   press-id / press-label  press the element → `ok`, `missing` or `refused`
///   exists-id               `yes` / `no`
///   ids                     every identifier, one per line
///   sheets                  how many sheets are open on the window
@MainActor
enum UITestAX {
    static func handle(_ command: String) -> String {
        let parts = command.dropFirst("ax ".count).components(separatedBy: "\t")
        guard parts.count >= 2 else { return "error: expected ax <verb> TAB <window> [TAB <target>]" }
        let verb = parts[0], title = parts[1], target = parts.count > 2 ? parts[2] : ""
        guard let window = NSApp.windows.first(where: {
            $0.sheetParent == nil && ($0.title == title || $0.title.hasPrefix(title + " — "))
        }) else {
            return "error: no window titled \(title) (windows: \(NSApp.windows.map(\.title).filter { !$0.isEmpty }))"
        }
        wakeSwiftUI(window)
        switch verb {
        case "sheets":
            var n = 0, sheet = window.attachedSheet
            while let s = sheet { n += 1; sheet = s.attachedSheet }
            return "\(n)"
        case "dump":
            return elements(in: window).prefix(600).map {
                "\(type(of: $0.object)) id=\($0.identifier ?? "-") label=\($0.label ?? "-")"
            }.joined(separator: "\n")
        case "ids":
            return elements(in: window).compactMap(\.identifier).joined(separator: "\n")
        case "exists-id":
            return find(in: window) { $0.identifier == target } == nil ? "no" : "yes"
        case "press-id", "press-label":
            let match: (Node) -> Bool = verb == "press-id"
                ? { $0.identifier == target }
                : { $0.label == target || $0.title == target }
            guard let element = find(in: window, match) else { return "missing" }
            return element.press() ? "ok" : "refused"
        default:
            return "error: unknown ax verb \(verb)"
        }
    }

    /// SwiftUI builds a hosting view's accessibility tree only once an
    /// assistive client shows up (none does with the screen locked): say one has.
    /// (The legacy attribute API, by selector: only it can say so.)
    private static func wakeSwiftUI(_ window: NSWindow) {
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                          with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        var sheet: NSWindow? = window
        while let w = sheet {
            for v in w.contentView.map({ [$0] + $0.subviews }) ?? [] {
                _ = v.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXChildren")
            }
            sheet = w.attachedSheet
        }
    }

    /// An element of the tree. SwiftUI's nodes answer the NSAccessibility
    /// selectors without being `NSAccessibilityProtocol` to Swift, so they're
    /// reached through Objective-C dispatch.
    @MainActor struct Node {
        let object: AnyObject
        var identifier: String? {
            guard let id = object.accessibilityIdentifier?(), !id.isEmpty else { return nil }
            return id
        }
        var label: String? { object.accessibilityLabel?() ?? nil }
        var title: String? { object.accessibilityTitle?() ?? nil }
        var children: [Any] { (object.accessibilityChildren?() ?? nil) ?? [] }
        func press() -> Bool {
            // An alert's buttons (a confirmation dialog) can turn down AXPress
            // while the sheet animates in; a real click goes through.
            let button = object as? NSButton ?? (object as? NSButtonCell)?.controlView as? NSButton
            if let button, button.isEnabled, button.window != nil {
                button.performClick(nil)
                return true
            }
            return object.accessibilityPerformPress?() ?? false
        }
    }

    private static func find(in window: NSWindow, _ match: (Node) -> Bool) -> Node? {
        elements(in: window).first(where: match)
    }

    /// Every element under the window: its sheets' (innermost first), then its own.
    private static func elements(in window: NSWindow) -> [Node] {
        var roots: [NSWindow] = []
        var sheet = window.attachedSheet
        while let s = sheet { roots.insert(s, at: 0); sheet = s.attachedSheet }
        roots.append(window)
        roots.append(contentsOf: window.childWindows ?? [])
        var out: [Node] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ e: Any, depth: Int) {
            let o = e as AnyObject
            guard depth < 60, out.count < 20_000, seen.insert(ObjectIdentifier(o)).inserted else { return }
            let node = Node(object: o)
            out.append(node)
            for child in node.children { walk(child, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        return out
    }
}
#endif
