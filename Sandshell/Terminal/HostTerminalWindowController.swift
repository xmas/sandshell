import AppKit
import Combine
import GhosttyTerminal

/// A standalone window hosting a libghostty terminal that runs the **Mac host**
/// login shell (not `sbx exec`) in the workspace root — the "Terminal" footer
/// button. One per workspace root; re-opening focuses the existing window.
@MainActor
final class HostTerminalWindowController: NSWindowController, NSWindowDelegate {
    private let term: TerminalController
    private let scriptURL: URL
    private let theme: ThemeController
    private var themeObserver: AnyCancellable?
    private var cursorObserver: AnyCancellable?
    /// Called when the window closes so the owner can drop its reference.
    var onClose: (() -> Void)?

    /// Host login shell in the workspace root — the footer "Terminal" button.
    convenience init(root: URL, theme: ThemeController) {
        let path = root.path(percentEncoded: false)
        let body = """
        #!/bin/bash
        cd \(SbxCommand.shellQuote(path)) 2>/dev/null || true
        exec "${SHELL:-/bin/zsh}" -l
        """
        self.init(title: "Terminal — \(root.lastPathComponent)",
                  scriptBody: body, workingDirectory: path, theme: theme)
    }

    /// Run an arbitrary bash `scriptBody` in a native libghostty window. Used both
    /// for the host login shell and for debug helpers (e.g. the daemon-health
    /// check) that want a real terminal rather than external Terminal.app.
    init(title: String, scriptBody: String, workingDirectory: String, theme: ThemeController) {
        self.theme = theme
        Log.info(.app, "opening host terminal: \(title)")

        self.scriptURL = Self.writeScript(scriptBody)

        let config = Self.configuration(scriptURL: scriptURL, prefs: theme.prefs)
        self.term = TerminalController(configuration: config, theme: Self.currentTheme(theme))
        term.setColorScheme(theme.terminalIsDark ? .dark : .light)

        let v = LinkOpeningTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        v.onOpenURL = TerminalSession.openURL
        v.controller = term
        v.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: workingDirectory)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isRestorable = false
        window.contentView = v
        window.center()
        super.init(window: window)
        window.delegate = self
        v.delegate = self

        themeObserver = theme.$colors.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.term.setTheme(Self.currentTheme(self.theme))
            self.term.setColorScheme(self.theme.terminalIsDark ? .dark : .light)
        }

        // Cursor style/blink are config-time; re-apply to this live terminal.
        cursorObserver = theme.$prefs
            .map { [$0.terminalCursorStyle, $0.terminalCursorBlink] as [AnyHashable] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.term.setTerminalConfiguration(
                    Self.configuration(scriptURL: self.scriptURL, prefs: self.theme.prefs))
            }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func focus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The full ghostty configuration, shared by init and live cursor-pref updates.
    private static func configuration(scriptURL: URL, prefs: ThemePreferences) -> TerminalConfiguration {
        TerminalConfiguration { c in
            c.withCustom("command", scriptURL.path(percentEncoded: false))
            // Match the in-app terminals (font, cursor, the ⌘ shortcuts our menu owns).
            TerminalSession.applyBase(prefs, to: &c)
        }
    }

    private static func currentTheme(_ theme: ThemeController) -> TerminalTheme {
        let (light, dark) = theme.terminalPalettes()
        return TerminalTheme(light: light.ghosttyConfiguration(), dark: dark.ghosttyConfiguration())
    }

    private static func writeScript(_ body: String) -> URL {
        let url = URL.temporaryDirectory.appending(path: "sandshell-host-\(UUID().uuidString).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    func windowWillClose(_ notification: Notification) {
        try? FileManager.default.removeItem(at: scriptURL)
        onClose?()
    }
}

extension HostTerminalWindowController: TerminalSurfaceCloseDelegate {
    /// When the host shell exits, close the window.
    func terminalDidClose(processAlive: Bool) {
        window?.performClose(nil)
    }
}

extension HostTerminalWindowController: TerminalSurfaceOpenURLDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        TerminalSession.openURL(url)
    }
}

extension HostTerminalWindowController: TerminalSurfaceHoverLinkDelegate {
    func terminalDidUpdateHoverLink(_ url: String?) {
        (window?.contentView as? LinkOpeningTerminalView)?.updateHoveredLink(url)
    }
}
