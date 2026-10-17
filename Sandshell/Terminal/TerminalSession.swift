import AppKit
import Combine
import GhosttyTerminal
import UniformTypeIdentifiers

/// Adds the host-side affordance for Ghostty-recognized terminal links.
/// Normal clicks still go to the PTY; command-click opens the hovered link.
@MainActor
final class LinkOpeningTerminalView: AppTerminalView {
    var onOpenURL: (@MainActor (String) -> Void)?

    private var hoveredLink: String?
    private var pushedLinkCursor = false

    func updateHoveredLink(_ url: String?) {
        hoveredLink = url
        if url != nil {
            guard !pushedLinkCursor else { return }
            NSCursor.pointingHand.push()
            pushedLinkCursor = true
        } else {
            popLinkCursorIfNeeded()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), hoveredLink != nil {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let hoveredLink {
            onOpenURL?(hoveredLink)
            return
        }
        super.mouseUp(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        updateHoveredLink(nil)
        super.mouseExited(with: event)
    }

    private func popLinkCursorIfNeeded() {
        guard pushedLinkCursor else { return }
        NSCursor.pop()
        pushedLinkCursor = false
    }

    // MARK: - Right-click file-path actions
    //
    // Ghostty only hover-detects scheme-qualified URLs / OSC-8 links, so a bare
    // path printed by a tool (e.g. "…in place: /Users/x/a.csv.") is never a
    // ⌘-click link. Instead: select the path (double-click / drag) and right-click
    // — if the selection resolves to an existing file, we add Finder/open actions.
    // The context menu is only offered by the superclass when a selection sits
    // under the click, so this never hijacks the empty-terminal menu.
    override func selectionContextMenu() -> NSMenu {
        let base = super.selectionContextMenu()
        guard let text = readSelectedText(),
              let url = fileURL(fromSelection: text) else { return base }

        let menu = NSMenu()
        for (title, action) in [
            ("Reveal in Finder", #selector(revealInFinder(_:))),
            ("Open", #selector(openInDefaultApp(_:))),
            ("Open With…", #selector(openWithChooser(_:))),
        ] {
            menu.addItem(NSMenuItem(title, action: action, target: self, object: url))
        }
        menu.addItem(.separator())
        // Re-parent the superclass items (Copy, …) onto our menu.
        for item in base.items { base.removeItem(item); menu.addItem(item) }
        return menu
    }

    /// Read the current selection without clobbering the user's clipboard:
    /// snapshot the general pasteboard, use ghostty's copy, then restore.
    private func readSelectedText() -> String? {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount
        let saved = pb.snapshotItems()
        let text = copySelectedTextToPasteboard() ? pb.string(forType: .string) : nil
        pb.restore(saved)
        PasteboardURLWatcher.shared.ignoreRestore(since: changeCount)
        return text
    }

    /// Resolve a selection to an existing file URL, or nil. Handles trailing
    /// sentence punctuation ("…/a.csv." → "/a.csv"), surrounding quotes/brackets,
    /// and `~` expansion. Only absolute or home-relative paths (no cwd context).
    private func fileURL(fromSelection raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = s.firstIndex(where: \.isNewline) { s = String(s[..<nl]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>()[]{} "))
        while let last = s.last, ".,:;".contains(last) { s.removeLast() }
        guard !s.isEmpty else { return nil }

        let home = NSHomeDirectory()
        let path: String
        if s == "~" { path = home }
        else if s.hasPrefix("~/") { path = home + "/" + String(s.dropFirst(2)) }
        else if s.hasPrefix("/") { path = s }
        else { return nil }

        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path, directoryHint: .checkFileSystem)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openInDefaultApp(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openWithChooser(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose an application to open “\(url.lastPathComponent)”"
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Keeps the cursor stack balanced if it goes while a link is hovered.
    isolated deinit {
        if pushedLinkCursor { NSCursor.pop() }
    }
}

/// Owns one libghostty terminal running a session's agent via `sbx exec` in its
/// container. Builds a dedicated `TerminalController` (its own ghostty app)
/// configured to launch a temp script, and vends the `AppTerminalView` to host
/// in the window. One instance per live session.
@MainActor
final class TerminalSession {
    let sessionID: UUID
    let view: AppTerminalView

    private let controller: TerminalController
    private let scriptURL: URL
    private let containerName: String
    /// The env tags this launch's processes in the sandbox carry.
    let tag: SbxCommand.ProcessTag
    private let theme: ThemeController
    private var themeObserver: AnyCancellable?
    private var cursorObserver: AnyCancellable?
    /// Called when the agent/PTY process exits and the surface wants to close.
    var onProcessExit: (() -> Void)?

    init(sessionID: UUID,
         containerName: String,
         agent: AgentKind,
         workdir: String,
         mcpURL: URL?,
         theme: ThemeController,
         resumeID: String? = nil,
         claude: SbxCommand.ClaudeOptions? = nil) {
        self.sessionID = sessionID
        self.theme = theme
        self.containerName = containerName
        let tag = SbxCommand.ProcessTag(session: sessionID)
        self.tag = tag

        let home = NSHomeDirectory()
        let sbxPath = PathFixer.sbxPath()
        let body = SbxCommand.sessionScript(
            containerName: containerName, workdir: workdir, agent: agent,
            sbxPath: sbxPath, home: home, mcpURL: mcpURL, resumeID: resumeID, claude: claude, tag: tag)

        let scriptURL = Self.writeScript(body)
        self.scriptURL = scriptURL

        // One controller (= one ghostty app) per terminal. The launched command
        // is set via the app-level `command` config pointing at our script. Color
        // is kept *out* of the base config and supplied as a TerminalTheme, so the
        // palette can be swapped live (see observeTheme()).
        let config = Self.configuration(scriptURL: scriptURL, prefs: theme.prefs)
        self.controller = TerminalController(configuration: config, theme: Self.currentTheme(theme))
        controller.setColorScheme(theme.terminalIsDark ? .dark : .light)

        let v = LinkOpeningTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        v.onOpenURL = Self.openURL
        v.controller = controller
        v.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: workdir)
        self.view = v

        observeTheme()
        observeCursorPrefs()
        v.delegate = self   // receive terminalDidClose when the process exits
    }

    /// The full per-terminal ghostty configuration. Kept in one place so a live
    /// prefs change (cursor style/blink) can re-apply it via `setTerminalConfiguration`.
    private static func configuration(scriptURL: URL, prefs: ThemePreferences) -> TerminalConfiguration {
        TerminalConfiguration { c in
            c.withCustom("command", scriptURL.path(percentEncoded: false))
            Self.applyBase(prefs, to: &c)
            // Exit immediately when the agent process ends so we can detect it
            // (terminalDidClose) and present our own restart prompt, rather than
            // ghostty's "Press any key to close the terminal" dead-end.
            c.withCustom("wait-after-command", "false")
        }
    }

    /// Ghostty's default keybinds that land on our menu's ⌘ shortcuts. A
    /// focused terminal runs its bindings before the menu sees the key, and
    /// most of these are Ghostty app commands (open config, quit, new window,
    /// close window, undo, full screen, inspector…) that this embedding drops,
    /// so the key did nothing; ⌘C is Edit ▸ Copy's, which copies the
    /// selection. Unbound, the menu gets the key (when no menu item takes it,
    /// the terminal still does).
    ///
    /// Left to Ghostty: ⌘V, ⌘A and ⌘0 (paste, select all, font size, done in
    /// the terminal); ⌘E, ⌘G, ⇧⌘G and ⌘J, whose text-find menu items have
    /// nothing to do in a terminal; and the pane commands ⌘D, ⇧⌘D, ⌥⌘W and
    /// ⌃⌘=, which AppDelegate's shortcut monitor routes in a workspace window
    /// and which, from a terminal on this Mac, would reach into the workspace
    /// window behind it. `ReleasedMenuKeysTests` asks the bundled Ghostty
    /// about every menu shortcut.
    ///
    /// Written as Ghostty's defaults are, with the character: "super+," and
    /// "super+shift+[" unbind them; the key names "super+comma" and
    /// "super+shift+left_bracket" are other keys and unbind nothing.
    nonisolated static let releasedMenuKeys = [
        "super+,", "super+shift+,", "super+q", "super+n",
        "super+w", "super+shift+w", "super+shift+t",
        "super+z", "super+shift+z", "super+c",
        "super+f", "super+shift+f",
        "super+alt+i", "super+ctrl+f",
        "super+[", "super+]", "super+shift+[", "super+shift+]",
    ]

    /// Font, cursor and the released menu shortcuts: what every Sandshell
    /// terminal shares (sessions and `HostTerminalWindowController`'s).
    static func applyBase(_ prefs: ThemePreferences, to c: inout TerminalConfiguration.Builder) {
        c.withFontFamily("SF Mono")
        c.withFontSize(13)
        c.withFontThicken(true)
        applyCursor(prefs, to: &c)
        for key in releasedMenuKeys { c.withCustom("keybind", "\(key)=unbind") }
    }

    /// Apply the workspace's cursor preferences to a config builder. `theme`
    /// leaves the engine/theme default in place; otherwise we set shape/blink.
    /// (Cursor settings are config-time, so they take effect for newly-opened
    /// terminals.)
    private static func applyCursor(_ prefs: ThemePreferences, to c: inout TerminalConfiguration.Builder) {
        switch prefs.terminalCursorStyle {
        case .theme: break
        case .block: c.withCursorStyle(.block)
        case .bar: c.withCursorStyle(.bar)
        case .underline: c.withCursorStyle(.underline)
        }
        switch prefs.terminalCursorBlink {
        case .theme: break
        case .on: c.withCursorStyleBlink(true)
        case .off: c.withCursorStyleBlink(false)
        }
    }

    /// Build the ghostty light/dark theme from this window's current terminal palette.
    private static func currentTheme(_ theme: ThemeController) -> TerminalTheme {
        let (light, dark) = theme.terminalPalettes()
        return TerminalTheme(light: light.ghosttyConfiguration(), dark: dark.ghosttyConfiguration())
    }

    /// Re-theme this live terminal when the user changes the terminal theme or the
    /// effective appearance flips (light↔dark).
    private func observeTheme() {
        themeObserver = theme.$colors.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.controller.setTheme(Self.currentTheme(self.theme))
            self.controller.setColorScheme(self.theme.terminalIsDark ? .dark : .light)
        }
    }

    /// Cursor style/blink are config-time in ghostty, so push a fresh configuration
    /// to this live terminal when they change instead of waiting for a new one.
    private func observeCursorPrefs() {
        cursorObserver = theme.$prefs
            .map { [$0.terminalCursorStyle, $0.terminalCursorBlink] as [AnyHashable] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.controller.setTerminalConfiguration(
                    Self.configuration(scriptURL: self.scriptURL, prefs: self.theme.prefs))
            }
    }

    private static func writeScript(_ body: String) -> URL {
        let url = URL.temporaryDirectory.appending(path: "sandshell-\(UUID().uuidString).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    /// Remove the launch script and kill this launch's processes in the
    /// sandbox (they outlive the host-side `sbx exec` when the PTY closes).
    func cleanup() {
        try? FileManager.default.removeItem(at: scriptURL)
        SbxClient.reapSessionProcesses(container: containerName, match: tag.pairs[1])
    }
}

extension TerminalSession: TerminalSurfaceCloseDelegate {
    func terminalDidClose(processAlive: Bool) {
        onProcessExit?()
    }
}

extension TerminalSession: TerminalSurfaceOpenURLDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        TerminalSession.openURL(url)
    }

    /// Open a URL or bare file path from a terminal link activation.
    static func openURL(_ url: String) {
        // Scheme-qualified URLs (http/https/mailto/file/…)
        if let u = URL(string: url), let scheme = u.scheme?.lowercased() {
            if ["http", "https", "mailto", "file"].contains(scheme) {
                NSWorkspace.shared.open(u)
                return
            }
        }
        // Bare file path: /absolute or ~/home-relative
        guard url.hasPrefix("/") || url.hasPrefix("~/") else { return }
        let path = url.hasPrefix("~/") ? NSHomeDirectory() + "/" + String(url.dropFirst(2)) : url
        NSWorkspace.shared.open(URL(filePath: path, directoryHint: .checkFileSystem))
    }
}

extension TerminalSession: TerminalSurfaceHoverLinkDelegate {
    func terminalDidUpdateHoverLink(_ url: String?) {
        (view as? LinkOpeningTerminalView)?.updateHoveredLink(url)
    }
}
