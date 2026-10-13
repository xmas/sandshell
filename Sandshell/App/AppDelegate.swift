import AppKit
import SwiftUI

struct AppScriptStatus: Encodable {
    var windowCount: Int
    var activeRoot: String?
    var windows: [WindowScriptStatus]
}

struct WindowScriptStatus: Encodable {
    var root: String
    var title: String
    var isKey: Bool
    var selection: String?
    var sessions: [SessionScriptStatus]
}

struct SessionScriptStatus: Encodable {
    var id: String
    var name: String
    var agent: String
    var workdir: String
    var status: String
    var isLive: Bool
    var isUnread: Bool
    var workSeconds: TimeInterval
    var transcriptID: String?
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let testEventClass: AEEventClass = 0x53686C6C  // 'Shll'
    private static let statusEventID: AEEventID = 0x73746174     // 'stat'
    private static let newSessionEventID: AEEventID = 0x6E657773 // 'news'

    /// All open workspace windows. A root may appear more than once (Duplicate
    /// Window), so this is an identity list rather than a path-keyed map.
    private var windows: [MainWindowController] = []
    /// The folder the very first window opened, used as the Window ▸ Sandshell
    /// fallback target when no window is currently key.
    private var primaryRoot: URL?

    /// The controller for the key/main window, or the primary one as a fallback.
    @MainActor private var activeController: MainWindowController? {
        if let key = NSApp.keyWindow,
           let match = windows.first(where: { $0.window === key }) {
            return match
        }
        if let mainRoot = primaryRoot?.standardizedFileURL.path,
           let main = windows.first(where: { $0.root.standardizedFileURL.path == mainRoot }) {
            return main
        }
        return windows.first
    }

    /// True once the app is quitting, so the cascade of `windowWillClose` events
    /// doesn't overwrite the persisted open-window set with an empty list.
    private var isTerminating = false

    /// Persist the currently-open roots (with multiplicity) so launch can restore
    /// every window. Call on any change to `windows` (skipped during quit, where
    /// the set captured in `applicationShouldTerminate` is the one to keep).
    @MainActor private func persistOpenWindows() {
        guard !isTerminating else { return }
        OpenWindows.replace(with: windows.map { $0.root })
    }

    // This app is fully programmatic — no MainMenu.xib / storyboard. The default
    // NSApplicationDelegate.main() just calls NSApplicationMain, which relies on a
    // nib to instantiate and install the delegate; with no nib the delegate is
    // never set and `applicationDidFinishLaunching` never fires. So we build the
    // app explicitly and install the delegate ourselves. `app.run()` never returns,
    // so the local `delegate` stays retained (NSApplication.delegate is weak).
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// In DEBUG, wash the app/Dock icon red so a locally-built dev instance is
    /// obvious beside an installed (blue) release build. A no-op in release.
    private func applyDevIconWashIfDebug() {
#if DEBUG
        let base = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage
        guard let base else { return }
        let size = NSSize(width: 512, height: 512)
        let rect = NSRect(origin: .zero, size: size)
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        base.draw(in: rect, from: NSRect(origin: .zero, size: base.size),
                  operation: .copy, fraction: 1.0)
        // .sourceAtop paints only over the icon's opaque pixels, so transparent
        // corners stay clear — a wash over the artwork, not a red square.
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSColor.systemRed.withAlphaComponent(0.45).set()
        NSBezierPath(rect: rect).fill()
        tinted.unlockFocus()
        NSApp.applicationIconImage = tinted
#endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Patch PATH first so `sbx`/`docker`/`brew` resolve when launched from
        // Finder/Spotlight, and so libghostty's spawned subprocess inherits it.
        PathFixer.patchProcessPath()
        // Handle `sandshell://open?workspace=…&ro=…&rw=…` URLs from the CLI.
        // Must be registered before any queued events fire (right after launch).
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: 0x4755524C,  // kInternetEventClass ('GURL')
            andEventID:   0x4755524C)   // kAEGetURL ('GURL')
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleScriptStatus(_:withReplyEvent:)),
            forEventClass: Self.testEventClass,
            andEventID: Self.statusEventID)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleScriptNewSession(_:withReplyEvent:)),
            forEventClass: Self.testEventClass,
            andEventID: Self.newSessionEventID)

        NSApp.setActivationPolicy(.regular)
        // Debug builds get a red wash over the Dock/app icon so a dev build is
        // instantly distinguishable from an installed release (which stays blue).
        applyDevIconWashIfDebug()
        // Apply the one global light/dark/system setting app-wide before any
        // windows exist, and start following the system.
        AppAppearance.shared.start()
        MainMenu.install(appName: "Sandshell")
        KitStore.seedOfficialDefaultsIfNeeded()
        Log.info(.app, "Sandshell launched (sbx: \(PathFixer.sbxPath()))")

        // Restore every window that was open at last quit; otherwise open the
        // chosen default root folder (falling back to ~/Sandshell).
        let restore = OpenWindows.all
        Log.info(.app, "launch: \(restore.count) window(s) to restore, \(RootFolderStore.all.count) known root(s)")
        let fallback = RootFolderStore.defaultPath.map { URL(fileURLWithPath: $0) }
            ?? WorkspaceBootstrap.defaultRoot
        primaryRoot = restore.first ?? fallback
        if !restore.isEmpty {
            for root in restore { createWindow(root: root) }
        } else if RootFolderStore.all.isEmpty {
            showWelcome()   // first launch: no folder has had a sandbox yet
        } else {
            openWorkspace(fallback)
        }

        NSApp.activate(ignoringOtherApps: true)
        installShortcutMonitor()
        Updater.shared.checkInBackground()

        // Only watch the pasteboard for OSC-52-copied URLs while Sandshell is
        // the active app, so a copy made in another app never triggers it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in PasteboardURLWatcher.shared.start() } }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in PasteboardURLWatcher.shared.stop() } }
        if NSApp.isActive { PasteboardURLWatcher.shared.start() }

        // Ask for notification permission and wire up the tap → select-session handler.
        NotificationManager.shared.requestPermission()
        NotificationManager.shared.onSessionTap = { [weak self] id in
            guard let self else { return }
            for window in self.windows {
                if window.selectSession(id) { break }
            }
        }
    }

    /// Receive `sandshell://open?…` Apple Events sent by the CLI.
    /// NSAppleEventManager delivers on the main thread, so @MainActor is correct.
    @MainActor @objc private func handleGetURL(_ event: NSAppleEventDescriptor,
                                               withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: 0x2D2D2D2D)?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "sandshell" else { return }
        openFromURL(url)
    }

    @MainActor @objc private func handleScriptStatus(_ event: NSAppleEventDescriptor,
                                                     withReplyEvent reply: NSAppleEventDescriptor) {
        reply.setParam(NSAppleEventDescriptor(string: scriptStatusJSON()), forKeyword: 0x2D2D2D2D)
    }

    @MainActor @objc private func handleScriptNewSession(_ event: NSAppleEventDescriptor,
                                                         withReplyEvent reply: NSAppleEventDescriptor) {
        activeController?.newSession()
        reply.setParam(NSAppleEventDescriptor(string: scriptStatusJSON()), forKeyword: 0x2D2D2D2D)
    }

    @MainActor private func scriptStatusJSON() -> String {
        let status = AppScriptStatus(
            windowCount: windows.count,
            activeRoot: activeController?.root.path,
            windows: windows.map { $0.scriptingStatus() })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(status),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Decode `sandshell://open?workspace=…&ro=…&rw=…`, configure the workspace
    /// (random look for new folders, extra mounts merged in, setup wizard skipped),
    /// then open or focus its window.
    @MainActor private func openFromURL(_ url: URL) {
        guard url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return }

        var workspacePath: String?
        var roMounts: [URL] = []
        var rwMounts: [URL] = []
        for item in queryItems {
            switch item.name {
            case "workspace": workspacePath = item.value
            case "ro": if let v = item.value { roMounts.append(URL(fileURLWithPath: v)) }
            case "rw": if let v = item.value { rwMounts.append(URL(fileURLWithPath: v)) }
            default: break
            }
        }
        guard let path = workspacePath else { return }
        let workspaceURL = URL(fileURLWithPath: path)
        let key = RootFolderStore.standardize(workspaceURL.path)

        // Assign a random icon + color to workspaces opened for the first time via CLI.
        if !RootFolderStore.all.contains(where: { $0.path == key }) {
            let color = RootProfile.colors.randomElement() ?? RootProfile.defaultColor
            let icon  = RootProfile.symbols.randomElement() ?? "folder.fill"
            RootFolderStore.upsert(RootProfile(
                path: key, icon: icon, colorHex: color,
                sidebarHex: RootProfile.sidebarTone(forIcon: color)))
            if RootFolderStore.defaultPath == nil { RootFolderStore.defaultPath = key }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        var config = WorkspaceConfig.loadOrDefault(root: workspaceURL, home: home)

        // Merge CLI-specified mounts (ro/rw) into the workspace policy, replacing
        // any existing entry for the same path so re-invocations with changed
        // flags take effect.
        if !roMounts.isEmpty || !rwMounts.isEmpty {
            let extras = roMounts.map { MountSpec(path: $0, readonly: true) }
                       + rwMounts.map { MountSpec(path: $0, readonly: false) }
            let extraPaths = Set(extras.map { $0.path.standardizedFileURL.path })
            var selections = config.policy.selections
                .filter { !extraPaths.contains($0.path.standardizedFileURL.path) }
            selections.append(contentsOf: extras)
            config.policy.selections = selections
        }
        config.configured = true   // skip the mount-config setup wizard
        try? config.save(root: workspaceURL)

        openWorkspace(workspaceURL)
    }

    /// App menu ▸ Check for Updates… — may trigger Google sign-in.
    @MainActor @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdatesMenu()
    }

    /// Help ▸ Check sbx Daemon Health… — open a Sandshell native terminal that
    /// compares the CLI binary against the *running* daemon (they diverge when the
    /// long-lived daemon keeps running an older build), prints a match/differ
    /// table, and offers the exact fix/update/debug commands for this install
    /// (stable vs nightly). Drops into a login shell so it stays interactive.
    @MainActor @objc func checkDaemonHealth(_ sender: Any?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let body = """
        #!/bin/bash
        SEP="============================================================"

        # --- gather -----------------------------------------------------------
        SBX_BIN="$(command -v sbx)"
        TARGET="$(readlink "$SBX_BIN" 2>/dev/null || echo "$SBX_BIN")"
        CLI_LINE="$(sbx version 2>/dev/null)"
        CLI_VER="$(echo "$CLI_LINE" | awk '{print $3}')"
        CLI_REV="$(echo "$CLI_LINE" | awk '{print $4}')"

        SOCK="$(sbx daemon status 2>/dev/null | awk -F': ' '/Socket:/{print $2}')"
        [ -z "$SOCK" ] && SOCK="$HOME/Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/sandboxd.sock"
        LOG="$(sbx daemon status 2>/dev/null | awk -F': ' '/Logs:/{print $2}')"
        [ -z "$LOG" ] && LOG="$HOME/Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/daemon.log"

        HEALTH="$(curl -s --max-time 3 --unix-socket "$SOCK" http://localhost/daemon/health)"
        D_VER="$(echo "$HEALTH" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version",""))' 2>/dev/null)"
        D_REV="$(echo "$HEALTH" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("revision",""))' 2>/dev/null)"
        D_API="$(echo "$HEALTH" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("api_version",""))' 2>/dev/null)"

        case "$TARGET" in
          *sbx@nightly*)   CHANNEL="nightly"; CASK="docker/tap/sbx@nightly";;
          *Caskroom/sbx/*) CHANNEL="stable";  CASK="docker/tap/sbx";;
          *)               CHANNEL="unknown"; CASK="";;
        esac

        # --- comparison table -------------------------------------------------
        if [ -z "$D_VER" ]; then
          VMATCH="daemon not running?"; RMATCH="-"; SYNCED="no"
        elif [ "$CLI_REV" = "$D_REV" ]; then
          VMATCH="match"; RMATCH="match"; SYNCED="yes"
        else
          [ "$CLI_VER" = "$D_VER" ] && VMATCH="match" || VMATCH="DIFFER"
          RMATCH="DIFFER"; SYNCED="no"
        fi

        clear
        echo "$SEP"
        echo "  sbx — CLI vs running daemon"
        echo "$SEP"
        {
          echo "field|CLI (sbx binary)|running daemon|"
          echo "version|${CLI_VER:-?}|${D_VER:-<none>}|$VMATCH"
          echo "revision|${CLI_REV:-?}|${D_REV:-<none>}|$RMATCH"
          echo "api_version|-|${D_API:-<none>}|"
        } | column -t -s '|'
        echo
        echo "install channel : $CHANNEL"
        echo "sbx binary      : $SBX_BIN"
        echo "      -> $TARGET"
        echo "daemon socket   : $SOCK"
        echo "daemon log      : $LOG"
        echo

        # --- recommendation ---------------------------------------------------
        echo "$SEP"
        if [ "$SYNCED" = "yes" ]; then
          echo "  OK — CLI and running daemon are the same build. Nothing to do."
        else
          echo "  The running daemon is a DIFFERENT build than your CLI."
          echo
          echo "  1) Make the daemon run your current CLI (most common fix):"
          echo "         sbx daemon stop && sbx daemon start -d"
          echo
          if [ -n "$CASK" ]; then
            echo "  2) Update sbx itself ($CHANNEL), then restart the daemon:"
            echo "         brew update && brew upgrade --cask $CASK"
            echo "         sbx daemon stop && sbx daemon start -d"
          else
            echo "  2) Update sbx however you installed it, then restart the daemon:"
            echo "         sbx daemon stop && sbx daemon start -d"
          fi
        fi
        echo
        echo "$SEP"
        echo "  Daemon controls"
        echo "         sbx daemon status            # running? + socket/log paths"
        echo "         sbx daemon stop              # stop"
        echo "         sbx daemon start -d          # start detached"
        echo
        echo "  Debug logging"
        echo "         sbx daemon log-level set all debug   # raise live (no restart)"
        echo "         sbx daemon log-level set all info    # back to normal"
        echo "         sbx daemon stop && sbx -D daemon start -d   # restart with debug on"
        echo
        echo "  Read / share the log"
        echo "         tail -f '$LOG'        # follow live"
        echo "         open -R '$LOG'        # reveal in Finder to attach/send"
        echo
        echo "  More:  sbx diagnose"
        echo "$SEP"
        echo
        exec "${SHELL:-/bin/zsh}" -l
        """
        let theme = activeController?.theme ?? ThemeController(prefs: ThemeDefaults.prefs)
        let wc = HostTerminalWindowController(
            title: "sbx Daemon Health", scriptBody: body, workingDirectory: home, theme: theme)
        wc.onClose = { [weak self] in self?.daemonHealthTerminal = nil }
        daemonHealthTerminal = wc
        wc.focus()
    }
    private var daemonHealthTerminal: HostTerminalWindowController?

    /// Focus the window already showing `root`, or create one for it. Records the
    /// root in the recent list so it shows up in the sidebar-header / Open menu.
    @MainActor @discardableResult
    func openWorkspace(_ root: URL) -> MainWindowController? {
        let key = root.standardizedFileURL.path
        if let existing = windows.first(where: { $0.root.standardizedFileURL.path == key }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        return createWindow(root: root)
    }

    /// Always create a new window for `root` (used by restore + Duplicate Window),
    /// allowing more than one window per folder.
    @MainActor @discardableResult
    func createWindow(root: URL) -> MainWindowController? {
        do {
            try WorkspaceBootstrap.openOrCreate(root: root)
        } catch {
            Log.error(.app, "workspace bootstrap failed: \(error)")
            return nil
        }
        RecentRoots.record(root)
        RootFolderStore.touch(root.path)
        let key = root.standardizedFileURL.path
        // Distinct autosave name per duplicate on the same root.
        let instanceIndex = windows.filter { $0.root.standardizedFileURL.path == key }.count
        let controller = MainWindowController(root: root, instanceIndex: instanceIndex)
        controller.onOpenWorkspace = { [weak self] r in self?.openWorkspace(r) }
        // Drop the window from the registry once it closes.
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
            self.persistOpenWindows()
            Log.info(.app, "closed window for \(controller.root.path) (\(self.windows.count) open)")
        }
        windows.append(controller)
        persistOpenWindows()
        Log.info(.app, "opened window for \(root.path) (\(windows.count) open)")
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    /// ⌘⇧N / File ▸ Duplicate Window — open another window on the active window's
    /// root (same folders + per-root settings, but its own fresh terminals).
    @MainActor @objc func duplicateWindow(_ sender: Any?) {
        guard let root = activeController?.root else { return }
        createWindow(root: root)
    }

    /// ⌘O / File ▸ Open… — open the recent workspaces browser.
    @MainActor @objc func openWorkspaceBrowser(_ sender: Any?) {
        let wc = OpenWindowController(
            onOpen: { [weak self] url in self?.openWorkspace(url) },
            onOpenNew: { [weak self] in self?.openFolder(nil) })
        openWindow = wc
        wc.present()
    }
    private var openWindow: OpenWindowController?

    /// ⌘⌥N / File ▸ Open Folder… — the setup wizard (folder, look, mounts, kits).
    @MainActor @objc func openFolder(_ sender: Any?) {
        let wc = SetupWindowController(welcome: false, onCreate: { [weak self] url, profile, policy, kits in
            self?.createWorkspace(url, profile: profile, policy: policy, kits: kits, makeDefault: false)
        })
        setupWindow = wc
        wc.present()
    }
    private var setupWindow: SetupWindowController?

    /// File ▸ Welcome to Sandshell… — re-run the first-launch setup on demand.
    @MainActor @objc func runFirstLaunchSetup(_ sender: Any?) { showWelcome() }

    /// First-launch Welcome (Default = today's ~/Sandshell; Advanced = wizard).
    @MainActor private func showWelcome() {
        let wc = SetupWindowController(
            welcome: true,
            onCreate: { [weak self] url, profile, policy, kits in
                self?.createWorkspace(url, profile: profile, policy: policy, kits: kits, makeDefault: true)
            },
            onDefault: { [weak self] in self?.createWorkspaceDefault() })
        setupWindow = wc
        wc.present()
    }

    /// Create a workspace from the wizard: persist its look + mounts + kits so the
    /// window opens already-configured (no first-run prompt), then open it.
    @MainActor private func createWorkspace(_ url: URL, profile: RootProfile,
                                            policy: MountPolicy, kits: [String], makeDefault: Bool) {
        RootFolderStore.upsert(profile)
        if makeDefault || RootFolderStore.defaultPath == nil {
            RootFolderStore.defaultPath = RootFolderStore.standardize(url.path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var config = WorkspaceConfig.loadOrDefault(root: url, home: home)
        config.policy = policy
        config.kits = kits
        config.configured = true   // wizard collected mounts → skip first-run sheet
        try? config.save(root: url)
        openWorkspace(url)
    }

    /// "Default" on the Welcome screen — today's behavior: open ~/Sandshell with
    /// defaults (its first-run mount sheet still appears).
    @MainActor private func createWorkspaceDefault() {
        let root = WorkspaceBootstrap.defaultRoot
        RootFolderStore.upsert(RootProfile.makeDefault(path: root.path))
        if RootFolderStore.defaultPath == nil { RootFolderStore.defaultPath = RootFolderStore.standardize(root.path) }
        openWorkspace(root)
    }

    /// A focused libghostty terminal swallows ⌘-shortcuts before the main menu,
    /// so catch the app's own shortcuts in a local key monitor (runs ahead of
    /// view dispatch) and route them. Returning nil consumes the event.
    private func installShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let chars = event.charactersIgnoringModifiers else { return event }
            let cmd = event.modifierFlags.contains(.command)
            let opt = event.modifierFlags.contains(.option)
            let ctrl = event.modifierFlags.contains(.control)
            let shift = event.modifierFlags.contains(.shift)
            guard cmd || opt || ctrl else { return event }
            // Monitors fire on the main thread; only Sendable values cross in.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let app = NSApp.delegate as? AppDelegate else { return false }
                if cmd {
                    // Shift turns "[" / "]" into "{" / "}" in charactersIgnoringModifiers,
                    // so match both forms for ⌘⇧[ / ⌘⇧].
                    switch chars {
                    case "q": NSApp.terminate(nil); return true
                    case ",": app.openSettings(nil); return true
                    case "n" where opt: app.openFolder(nil); return true
                    case "n" where shift: app.duplicateWindow(nil); return true
                    case "n": app.newSession(nil); return true
                    case "[", "{": app.selectPreviousSession(nil); return true
                    case "]", "}": app.selectNextSession(nil); return true
                    default: break
                    }
                } else if ctrl {   // ⌃1 hides the sidebar (terminal only), ⌃2 shows it
                    switch chars {
                    case "1": app.hideSidebar(nil); return true
                    case "2": app.showSidebar(nil); return true
                    default: break
                    }
                }
                return false
            }
            return handled ? nil : event
        }
    }
    private var shortcutMonitor: Any?

    /// Close the entire key window — all of its tabs (⇧⌘W). ⌘W (performClose:)
    /// closes only the current tab, or the window when it's the only tab.
    @MainActor @objc func closeWindow(_ sender: Any?) {
        guard let key = NSApp.keyWindow else { return }
        if let group = key.tabGroup, group.windows.count > 1 {
            for window in group.windows { window.performClose(sender) }
        } else {
            key.performClose(sender)
        }
    }

    /// ⌘, — open the Settings window.
    @MainActor @objc func openSettings(_ sender: Any?) {
        activeController?.showSettings()
    }

    /// ⌘N — new session in the current project with the same agent.
    @MainActor @objc func newSession(_ sender: Any?) {
        activeController?.newSession()
    }

    /// ⌥1 — hide the sidebar (terminal only).
    @MainActor @objc func hideSidebar(_ sender: Any?) {
        activeController?.setSidebarCollapsed(true)
    }

    /// ⌥2 — show the sidebar.
    @MainActor @objc func showSidebar(_ sender: Any?) {
        activeController?.setSidebarCollapsed(false)
    }

    /// ⌘⇧] — select the next session.
    @MainActor @objc func selectNextSession(_ sender: Any?) {
        activeController?.cycleSession(1)
    }

    /// ⌘⇧[ — select the previous session.
    @MainActor @objc func selectPreviousSession(_ sender: Any?) {
        activeController?.cycleSession(-1)
    }

    /// ⌘W — close the key auxiliary window (e.g. Settings) first; otherwise close
    /// the selected session, or the window if none is selected.
    @MainActor @objc func closeSessionOrWindow(_ sender: Any?) {
        if let key = NSApp.keyWindow,
           !windows.contains(where: { $0.window === key }) {
            key.performClose(sender)
            return
        }
        activeController?.closeSessionOrWindow()
    }

    /// "Apply to All" (per-root Appearance/Terminal inspector): push `prefs` to
    /// every open window and make it the default that new roots inherit.
    @MainActor func applyThemeToAllWindows(_ prefs: ThemePreferences) {
        ThemeDefaults.prefs = prefs
        for controller in windows { controller.applyTheme(prefs) }
    }

    /// Bring a workspace window back (Window ▸ Sandshell, and dock reopen).
    @MainActor @objc func showMainWindow(_ sender: Any?) {
        if let controller = activeController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } else if let root = primaryRoot {
            openWorkspace(root)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Handle files/folders passed via `open -a Sandshell /path …` or drag-onto-dock.
    /// Directories open/focus workspaces; regular files are inserted into the
    /// active terminal as sandbox-readable paths.
    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                openWorkspace(url)
            } else {
                files.append(url)
            }
        }
        guard !files.isEmpty else { return }
        if activeController?.insertExternalItems(files) == true { return }
        if let parent = files.first?.deletingLastPathComponent() {
            openWorkspace(parent)?.insertExternalItems(files)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Snapshot the open windows for restore-on-launch, then freeze persistence so
    /// the windows closing during termination don't clear the saved set.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        OpenWindows.replace(with: windows.map { $0.root })
        isTerminating = true
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopen a workspace window if none is currently on screen (e.g. all were
        // closed while the Settings window stayed open).
        if !windows.contains(where: { $0.window?.isVisible == true }) {
            showMainWindow(nil)
        }
        return true
    }
}
