import AppKit

/// View ▸ Make Text Bigger / Smaller / Actual Size (⌘+ ⌘− ⌘0), as Mail, Notes
/// and Safari do: the text you read and write grows — chats and their
/// composers, the Files editor and Markdown preview, terminals — while the
/// window's chrome (sidebar, toolbar, strips) stays the size macOS draws it.
/// One size for the app, kept across launches.
@MainActor
enum TextZoom {
    /// The sizes ⌘+ and ⌘− step through (1 is Actual Size).
    nonisolated static let steps: [CGFloat] = [0.75, 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2, 2.5]
    static let key = "textZoom"
    /// Posted when `scale` changes; content re-renders at the new size.
    static let didChange = Notification.Name("SandshellTextZoomDidChange")

    static var defaults = UserDefaults.standard

    /// The current size, one of `steps`.
    static var scale: CGFloat {
        get { nearestStep(CGFloat(defaults.double(forKey: key))) }
        set {
            let step = nearestStep(newValue)
            guard step != scale else { return }
            defaults.set(Double(step), forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var canZoomIn: Bool { scale < steps.last! }
    static var canZoomOut: Bool { scale > steps.first! }
    static var isActualSize: Bool { scale == 1 }

    static func zoomIn() { if let next = steps.first(where: { $0 > scale }) { scale = next } }
    static func zoomOut() { if let next = steps.last(where: { $0 < scale }) { scale = next } }
    static func actualSize() { scale = 1 }

    /// `size` at the current zoom.
    static func scaled(_ size: CGFloat) -> CGFloat { (size * scale * 2).rounded() / 2 }

    /// The step closest to `value`; 1 for nothing saved.
    nonisolated static func nearestStep(_ value: CGFloat) -> CGFloat {
        guard value > 0 else { return 1 }
        return steps.min { abs($0 - value) < abs($1 - value) } ?? 1
    }
}

extension NSFont {
    /// A type role in content (chat, composer): grows with View ▸ Make Text Bigger.
    @MainActor static func content(_ role: TypeRole) -> NSFont { content(role, weight: role.weight) }

    @MainActor static func content(_ role: TypeRole, weight: NSFont.Weight) -> NSFont {
        let size = TextZoom.scaled(role.pointSize)
        return role == .code ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }
}
