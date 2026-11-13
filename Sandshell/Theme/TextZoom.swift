import AppKit

/// View ▸ Make Text Bigger / Smaller / Actual Size (⌘+ ⌘− ⌘0), as Mail, Notes
/// and Safari do: the text you read and write grows — the Files editor and
/// Markdown preview, terminals — while the window's chrome (sidebar, toolbar,
/// strips) stays the size macOS draws it. One size, kept across launches.
/// Chats have their own, `ChatTextZoom`: these keys size it while you're in a chat.
@MainActor
enum TextZoom {
    /// The sizes ⌘+ and ⌘− step through (1 is Actual Size).
    nonisolated static let steps: [CGFloat] = [0.75, 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2, 2.5]
    static let key = "textZoom"
    /// Posted when `scale` changes; content re-renders at the new size.
    static let didChange = Notification.Name("SandshellTextZoomDidChange")

    /// (Hosted tests keep to their own: they'd read the person's text size.)
    static var defaults = AppDelegate.isHostingTests
        ? (UserDefaults(suiteName: "SandshellTextZoomTests") ?? .standard) : .standard

    /// The current size, one of `steps`.
    static var scale: CGFloat {
        get { nearestStep(CGFloat(defaults.double(forKey: key))) }
        set {
            let step = nearestStep(newValue)
            guard step != scale else { return }
            ChatTextZoom.keepCurrentSize()
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

/// View ▸ Make Chat Text Bigger / Smaller / Chat Actual Size (⌥⌘+ ⌥⌘− ⌥⌘0,
/// or ⌘+ ⌘− ⌘0 while you're in a chat): chat transcripts and composers, apart
/// from `TextZoom`, so a chat can go big for a screen share. Until it's first set
/// it's `TextZoom`'s size, which it keeps when that one next changes, so
/// nothing jumps for anyone who'd already zoomed.
@MainActor
enum ChatTextZoom {
    static let key = "chatTextZoom"

    /// Whether `responder` is in a chat: its composer, or a transcript (a
    /// session's, or a subagent's window).
    static func isInChat(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is ChatSessionView || current is ChatWebTranscript { return true }
            view = current.superview
        }
        return false
    }

    /// Posted when `scale` changes; chats re-render at the new size.
    static let didChange = Notification.Name("SandshellChatTextZoomDidChange")
    /// What `rendering(at:)` is drawing at.
    private static var renderingScale: CGFloat?

    private static var saved: CGFloat? {
        let value = TextZoom.defaults.double(forKey: key)
        return value > 0 ? TextZoom.nearestStep(CGFloat(value)) : nil
    }

    /// The current size, one of `TextZoom.steps`.
    static var scale: CGFloat {
        get { renderingScale ?? saved ?? TextZoom.scale }
        set {
            let step = TextZoom.nearestStep(newValue)
            guard step != scale else { return }
            TextZoom.defaults.set(Double(step), forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var canZoomIn: Bool { scale < TextZoom.steps.last! }
    static var canZoomOut: Bool { scale > TextZoom.steps.first! }
    static var isActualSize: Bool { scale == 1 }

    static func zoomIn() { if let next = TextZoom.steps.first(where: { $0 > scale }) { scale = next } }
    static func zoomOut() { if let next = TextZoom.steps.last(where: { $0 < scale }) { scale = next } }
    static func actualSize() { scale = 1 }

    /// `size` at the current zoom.
    static func scaled(_ size: CGFloat) -> CGFloat { (size * scale * 2).rounded() / 2 }

    /// `TextZoom` is about to change: stay at the size chats are at.
    fileprivate static func keepCurrentSize() {
        if saved == nil { TextZoom.defaults.set(Double(TextZoom.scale), forKey: key) }
    }

    /// Render with the chat's fonts at another size (Files' Markdown preview
    /// goes by `TextZoom`).
    static func rendering<T>(at scale: CGFloat, _ body: () -> T) -> T {
        let outer = renderingScale
        renderingScale = scale
        defer { renderingScale = outer }
        return body()
    }
}

/// The chat's typefaces (Settings ▸ Editor): the agent's replies, and what you
/// write. A change re-renders open chats, as a size change does.
@MainActor
enum ChatFonts {
    static let system = "System"
    static let newYork = "New York"
    static let replyKey = "chatReplyFont"
    static let messageKey = "chatMessageFont"

    static var reply: String {
        // The UI's face, like everything else (New York is a choice in Settings).
        get { TextZoom.defaults.string(forKey: replyKey) ?? system }
        set { set(newValue, forKey: replyKey) }
    }

    static var message: String {
        get { TextZoom.defaults.string(forKey: messageKey) ?? system }
        set { set(newValue, forKey: messageKey) }
    }

    private static func set(_ family: String, forKey key: String) {
        TextZoom.defaults.set(family, forKey: key)
        NotificationCenter.default.post(name: ChatTextZoom.didChange, object: nil)
    }

    /// System, New York, then what's installed.
    static var families: [String] {
        [system, newYork] + NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") && $0 != newYork }
    }

    /// `role` in `family`, at the chat's text size.
    static func font(_ family: String, _ role: TypeRole = .body) -> NSFont {
        let size = ChatTextZoom.scaled(role.pointSize)
        let standard = NSFont.systemFont(ofSize: size, weight: role.weight)
        switch family {
        case system: return standard
        case newYork:
            return standard.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? standard
        default:
            let traits: NSFontTraitMask = role.weight >= .semibold ? .boldFontMask : []
            return NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: size) ?? standard
        }
    }
}

extension NSFont {
    /// A type role in content (chat, composer): grows with View ▸ Make Chat Text Bigger.
    @MainActor static func content(_ role: TypeRole) -> NSFont { content(role, weight: role.weight) }

    @MainActor static func content(_ role: TypeRole, weight: NSFont.Weight) -> NSFont {
        let size = ChatTextZoom.scaled(role.pointSize)
        return role == .code ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }
}
