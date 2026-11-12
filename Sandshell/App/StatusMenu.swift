import AppKit

/// What the menu bar status shows: the sessions that need you, are working
/// or finished while you were elsewhere, across every open window.
struct StatusMenuModel: Equatable {
    struct Entry: Equatable {
        let id: UUID
        let workspace: String
        let name: String
        let status: SessionRowStatus
    }

    var entries: [Entry]

    /// The states worth a line in the menu.
    static func lists(_ state: SessionRowStatus.State) -> Bool {
        [.needsYou, .working, .finishedUnread].contains(state)
    }

    init(entries: [Entry]) {
        // Whatever needs you first, then what's working, then what finished.
        let order: [SessionRowStatus.State] = [.needsYou, .working, .finishedUnread]
        self.entries = entries.filter { Self.lists($0.status.state) }
            .enumerated()
            .sorted { a, b in
                let ra = order.firstIndex(of: a.element.status.state) ?? 9
                let rb = order.firstIndex(of: b.element.status.state) ?? 9
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    var needsYou: Int { entries.count { $0.status.state == .needsYou } }
    var working: Int { entries.count { $0.status.state == .working } }
    var finished: Int { entries.count { $0.status.state == .finishedUnread } }

    /// The menu bar symbol: what's most pressing.
    var symbol: String {
        if needsYou > 0 { return "exclamationmark.bubble.fill" }
        if working > 0 { return "shippingbox.fill" }
        return "shippingbox"
    }

    /// Beside the symbol: how many need you, else how many work (nothing when idle).
    var title: String {
        if needsYou > 0 { return "\(needsYou)" }
        if working > 0 { return "\(working)" }
        return ""
    }

    /// The menu's first line.
    var headline: String {
        var parts: [String] = []
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if working > 0 { parts.append("\(working) working") }
        if finished > 0 { parts.append("\(finished) finished") }
        return parts.isEmpty ? "No agents working" : parts.joined(separator: " · ")
    }

    /// A session's line: "Name — Working · 3/6" (the workspace when there's
    /// more than one).
    func line(_ entry: Entry, showWorkspace: Bool) -> String {
        let status = [entry.status.word, entry.status.detail].compactMap { $0 }.joined(separator: " · ")
        let name = showWorkspace ? "\(entry.workspace) › \(entry.name)" : entry.name
        return "\(name) — \(status)"
    }
}

/// Sandshell in the menu bar: what's working and what needs you, in every
/// window, a session a click away; whether the Mac's kept awake.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    static let shared = StatusMenuController()
    static let key = "showsMenuBarStatus"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            shared.refresh()
        }
    }

    private var item: NSStatusItem?
    private var timer: Timer?
    private var shown: StatusMenuModel?
    private var windows: () -> [MainWindowController] = { [] }
    private var onSelect: (UUID) -> Void = { _ in }

    func start(windows: @escaping () -> [MainWindowController], onSelect: @escaping (UUID) -> Void) {
        self.windows = windows
        self.onSelect = onSelect
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { StatusMenuController.shared.refresh() }
        }
        refresh()
    }

    /// Every open window's sessions, each once (two windows can share a folder).
    func model() -> StatusMenuModel {
        var seen = Set<UUID>()
        var entries: [StatusMenuModel.Entry] = []
        for window in windows() {
            guard let controller = window.workspaceController else { continue }
            for session in controller.orderedSessions where seen.insert(session.id).inserted {
                entries.append(.init(id: session.id, workspace: window.root.lastPathComponent,
                                     name: controller.displayName(of: session),
                                     status: .of(controller.runtime(session.id), agent: session.agent)))
            }
        }
        return StatusMenuModel(entries: entries)
    }

    func refresh() {
        guard Self.isEnabled else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shown = nil
            return
        }
        let now = model()
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            item.button?.imagePosition = .imageLeading
            self.item = item
        } else if now == shown {
            return
        }
        shown = now
        guard let button = item?.button else { return }
        button.image = NSImage(systemSymbolName: now.symbol, accessibilityDescription: "Sandshell")
        button.image?.isTemplate = true
        button.title = now.title
        button.toolTip = "Sandshell — \(now.headline)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let model = model()
        menu.removeAllItems()
        let headline = NSMenuItem(title: model.headline, action: nil, keyEquivalent: "")
        headline.isEnabled = false
        menu.addItem(headline)
        let workspaces = Set(model.entries.map(\.workspace))
        for entry in model.entries {
            let item = NSMenuItem(model.line(entry, showWorkspace: workspaces.count > 1)) { [weak self] in
                NSApp.activate()
                self?.onSelect(entry.id)
            }
            item.image = NSImage(systemSymbolName: Self.symbol(entry.status.state), accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let awake = NSMenuItem("Keep Mac Awake While Agents Work") { KeepAwake.isEnabled.toggle() }
        awake.state = KeepAwake.isEnabled ? .on : .off
        menu.addItem(awake)
        if let reason = KeepAwake.shared.reason {
            let why = NSMenuItem(title: "Kept awake: \(reason)", action: nil, keyEquivalent: "")
            why.isEnabled = false
            menu.addItem(why)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem("Open Sandshell") {
            NSApp.activate()
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        })
        menu.addItem(NSMenuItem("Hide This From the Menu Bar") { StatusMenuController.isEnabled = false })
    }

    private static func symbol(_ state: SessionRowStatus.State) -> String {
        switch state {
        case .needsYou: "exclamationmark.circle.fill"
        case .working: "circle.dotted"
        default: "checkmark.circle"
        }
    }
}
