import AppKit
import GhosttyTerminal
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
    /// Session ids in the sidebar's row order (after any search filter).
    var sidebarSessionIDs: [String]
    /// A container is being built/rebuilt; `activity` is its progress line.
    var isBuilding: Bool
    var activity: String?
    /// The sidebar's empty-state text when shown ("No sessions yet", or the
    /// build progress line), else nil.
    var emptyState: String?
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
    /// Background tasks (subagents, background commands, Monitors) running.
    var backgroundRunning: Int = 0
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
    /// The workspace window made key most recently.
    private weak var lastActiveController: MainWindowController?

    /// The workspace window the menus act on: the key window's — itself, or the
    /// one its Settings, Search or Background Tasks window or sheet belongs
    /// to — else the main window's, else the one last made key, else the
    /// primary one.
    @MainActor private var activeController: MainWindowController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let match = windows.first(where: { $0.owns(window) }) { return match }
        }
        if let last = lastActiveController, windows.contains(where: { $0 === last }) { return last }
        if let mainRoot = primaryRoot?.standardizedFileURL.path,
           let main = windows.first(where: { $0.root.standardizedFileURL.path == mainRoot }) {
            return main
        }
        return windows.first
    }

    /// True once the app is quitting, so the cascade of `windowWillClose` events
    /// doesn't overwrite the persisted open-window set with an empty list.
    private var isTerminating = false

    /// Persist the currently-open roots (with multiplicity) and each window's
    /// instance index so launch can restore every window as itself. Call on any
    /// change to `windows` (skipped during quit, where the set captured in
    /// `applicationShouldTerminate` is the one to keep).
    @MainActor private func persistOpenWindows() {
        guard !isTerminating else { return }
        saveOpenWindows()
    }

    @MainActor private func saveOpenWindows() {
        OpenWindows.replace(with: windows.map { .init(root: $0.root, instanceIndex: $0.instanceIndex) })
    }

    /// Set once launch has restored its windows. Files and folders opened with
    /// the app before then (AppKit hands them over before
    /// `applicationDidFinishLaunching`) wait in `openedAtLaunch`.
    private var finishedLaunching = false
    private var openedAtLaunch: [URL] = []

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
    @MainActor private func applyDevIconWashIfDebug() {
#if DEBUG
        let base = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage
        guard let base else { return }
        // AppKit calls the handler on whatever thread draws the image, so keep it
        // off the main actor: a main-actor closure would trap there in Swift 6.
        let tinted = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { @Sendable rect in
            base.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            // .sourceAtop paints only over the icon's opaque pixels, so transparent
            // corners stay clear — a wash over the artwork, not a red square.
            NSColor.systemRed.withAlphaComponent(0.45).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        NSApp.applicationIconImage = tinted
#endif
    }

    /// Launched as the host of the unit tests: no windows, sandboxes or
    /// restored state — the tests exercise the code, not the app.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isHostingTests { return }
        // Patch PATH first so `sbx`/`docker`/`brew` resolve when launched from
        // Finder/Spotlight, and so libghostty's spawned subprocess inherits it.
        PathFixer.patchProcessPath()
        SystemSleep.start()
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
        AutomatedRun.startAnsweringAlerts()
        // Debug builds get a red wash over the Dock/app icon so a dev build is
        // instantly distinguishable from an installed release (which stays blue).
        applyDevIconWashIfDebug()
        // Apply the one global light/dark/system setting app-wide before any
        // windows exist, and start following the system.
        AppAppearance.shared.start()
        MainMenu.install(appName: "Sandshell")
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        KitStore.seedOfficialDefaultsIfNeeded()
        KitStore.seedSandshellKitsIfNeeded()
        Log.info(.app, "Sandshell launched (sbx: \(PathFixer.sbxPath()))")

        #if DEBUG
        SelfTest.prepare()
        #endif
        // Restore every window that was open at last quit; otherwise open the
        // chosen default root folder (falling back to ~/Sandshell).
        let restore = OpenWindows.windows
        Log.info(.app, "launch: \(restore.count) window(s) to restore, \(RootFolderStore.all.count) known root(s)")
        let fallback = RootFolderStore.launchFolder()
        primaryRoot = restore.first?.root ?? fallback
        if !restore.isEmpty {
            // Each with the index it had, so it gets its own frame and layout back.
            for window in restore { createWindow(root: window.root, instanceIndex: window.instanceIndex) }
        } else if RootFolderStore.all.isEmpty {
            showWelcome()   // first launch: no folder has had a sandbox yet
        } else if let fallback {
            openWorkspace(fallback)
        }
        // What the app was opened with (a file dropped on the Dock icon) goes
        // to the windows now back, rather than opening ahead of them.
        finishedLaunching = true
        if !openedAtLaunch.isEmpty {
            let urls = openedAtLaunch
            openedAtLaunch = []
            application(NSApp, open: urls)
        }
        // Nothing opened (the launch folder is gone, or its workspace couldn't
        // be set up): choose one, rather than an app with only a menu bar.
        // (Scripted runs never put up a window, or take focus, on their own.)
        if windows.isEmpty, welcomeWindow == nil, setupWindow == nil, !AutomatedRun.isActive { openWorkspaceBrowser(nil) }

        #if DEBUG
        if SelfTest.requested != nil {
            // Scripted checks run offscreen without taking focus, then quit.
            if let window = windows.first { Task { await SelfTest.run(window) } }
            return
        }
        if UITestHeadless.enabled {
            // The AppleScript suite drives this instance over Apple Events and
            // AX actions while the user keeps working: no activation, no
            // visible windows, no permission prompts.
            UITestHeadless.start()
            return
        }
        #endif
        NSApp.activate()
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
            // The window running the session (another window on its folder only
            // says it's open elsewhere), else the first window that has it.
            let window = self.windows.first { $0.isRunning(id) }
                ?? self.windows.first { $0.workspaceController?.session(id: id) != nil }
            window?.selectSession(id)
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

    #if DEBUG
    /// The UI-test bridge's commands (see `UITestHeadless`): the 'Shll' Apple
    /// Events' operations, opening a `sandshell://` URL, and `ax …` (`UITestAX`).
    @MainActor func uiTestCommand(_ command: String) -> String {
        if command.hasPrefix("ax ") { return UITestAX.handle(command) }
        if command.hasPrefix("open "), let url = URL(string: String(command.dropFirst(5))) {
            openFromURL(url)
        } else if command == "news" {
            activeController?.newSession()
        } else if command != "stat" {
            return #"{"error": "unknown command"}"#
        }
        return scriptStatusJSON()
    }
    #endif

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
            case "ro": if let v = item.value { roMounts.append(URL(filePath: v, directoryHint: .checkFileSystem)) }
            case "rw": if let v = item.value { rwMounts.append(URL(filePath: v, directoryHint: .checkFileSystem)) }
            default: break
            }
        }
        guard let path = workspacePath else { return }
        let workspaceURL = URL(filePath: path, directoryHint: .checkFileSystem)
        let key = RootFolderStore.standardize(workspaceURL.path)

        // Assign a random icon + color to workspaces opened for the first time via CLI.
        if !RootFolderStore.all.contains(where: { $0.path == key }) {
            let color = RootProfile.colors.randomElement() ?? RootProfile.defaultColor
            let icon  = RootProfile.symbols.randomElement() ?? "folder.fill"
            RootFolderStore.upsert(RootProfile(
                path: key, icon: icon, colorHex: color,
                sidebarHex: RootProfile.sidebarTone(forIcon: color)))
            RootFolderStore.adoptDefault(key)
        }

        // Merge CLI-specified mounts (ro/rw) into the workspace policy, replacing
        // any existing entry for the same path so re-invocations with changed
        // flags take effect.
        func withExtras(_ policy: MountPolicy) -> MountPolicy {
            guard !roMounts.isEmpty || !rwMounts.isEmpty else { return policy }
            let extras = roMounts.map { MountSpec(path: $0, readonly: true) }
                       + rwMounts.map { MountSpec(path: $0, readonly: false) }
            let extraPaths = Set(extras.map { $0.path.standardizedFileURL.path })
            var policy = policy
            policy.selections = policy.selections
                .filter { !extraPaths.contains($0.path.standardizedFileURL.path) } + extras
            return policy
        }
        // An open window holds the config in memory (its next save would put
        // the old mounts back): it takes them itself, for every window on the
        // folder (they share it), and offers the rebuild they need — once.
        let open = windows.compactMap(\.workspaceController)
            .filter { $0.rootURL.standardizedFileURL.path == workspaceURL.standardizedFileURL.path }
        if let controller = open.first {
            controller.adoptPolicy(withExtras(controller.policy))
        } else {
            let (loaded, unreadable) = WorkspaceConfig.loadReportingProblems(root: workspaceURL, home: URL.homeDirectory)
            // An unreadable config.json was kept aside: the window says so, and
            // offers the mounts (defaults + these) before it makes a sandbox.
            WorkspaceStore.report(unreadable, root: workspaceURL)
            var config = loaded
            config.policy = withExtras(config.policy)
            if unreadable == nil { config.configured = true }   // skip the mount-config setup wizard
            do {
                try config.save(root: workspaceURL)
            } catch {
                Log.error(.app, "couldn't save the config for \(workspaceURL.path): \(error)")
                Alerts.inform("Couldn’t set up “\(workspaceURL.lastPathComponent)”", error.localizedDescription)
                return
            }
        }

        openWorkspace(workspaceURL)
    }

    /// App menu ▸ Check for Updates… — compares against the Homebrew cask.
    @MainActor @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdatesMenu()
    }

    /// Help ▸ Check sbx Daemon Health… — open a Sandshell native terminal that
    /// compares the CLI binary against the *running* daemon (they diverge when the
    /// long-lived daemon keeps running an older build), prints a match/differ
    /// table, and offers the exact fix/update/debug commands for this install
    /// (stable vs nightly). Drops into a login shell so it stays interactive.
    @MainActor @objc func checkDaemonHealth(_ sender: Any?) {
        // One window at a time. Asking again runs the check again (the open
        // one ran once, then became a shell): a fresh window where it was.
        let previousFrame = daemonHealthTerminal?.window?.frame
        if let open = daemonHealthTerminal {
            daemonHealthTerminal = nil
            open.close()
        }
        let home = URL.homeDirectory.path
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
        wc.onClose = { [weak self, weak wc] in
            if self?.daemonHealthTerminal === wc { self?.daemonHealthTerminal = nil }
        }
        if let previousFrame { wc.window?.setFrame(previousFrame, display: false) }
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
            NSApp.activate()
            return existing
        }
        return createWindow(root: root)
    }

    /// Always create a new window for `root` (used by restore + Duplicate Window),
    /// allowing more than one window per folder. `instanceIndex` is the index
    /// the window had when the app quit (restore); `restoresLayout: false`
    /// opens one fresh pane rather than a saved layout (Duplicate Window).
    @MainActor @discardableResult
    func createWindow(root: URL, instanceIndex requested: Int? = nil,
                      restoresLayout: Bool = true) -> MainWindowController? {
        do {
            // An unreadable state.json is kept aside and a fresh one saved:
            // the window's store would read that one, so pass the news on.
            let (_, unreadable) = try WorkspaceBootstrap.openReportingProblems(root: root)
            WorkspaceStore.report(unreadable, root: root)
        } catch {
            Log.error(.app, "workspace bootstrap failed: \(error)")
            Alerts.inform("Couldn’t open “\(root.lastPathComponent)”", error.localizedDescription)
            return nil
        }
        RecentRoots.record(root)
        RootFolderStore.touch(root.path)
        let key = root.standardizedFileURL.path
        // Distinct autosave names per window on the same root: the index it had
        // at quit, else one no open window on it holds (one freed by a closed
        // window is reused).
        let instanceIndex = MainWindowController.instanceIndex(
            requested: requested,
            used: windows.filter { $0.root.standardizedFileURL.path == key }.map(\.instanceIndex))
        let controller = MainWindowController(root: root, instanceIndex: instanceIndex,
                                              restoresLayout: restoresLayout)
        controller.onOpenWorkspace = { [weak self] r in self?.openWorkspace(r) }
        controller.onBecomeKey = { [weak self, weak controller] in self?.lastActiveController = controller }
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
        // (Scripted runs never take focus from the person using the Mac.)
        guard !AutomatedRun.isActive else { return controller }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return controller
    }

    /// ⌘⇧N / File ▸ Duplicate Window — open another window on the active window's
    /// root (same folders + per-root settings, but its own fresh terminals).
    @MainActor @objc func duplicateWindow(_ sender: Any?) {
        guard let root = activeController?.root else { return }
        // One fresh pane: a saved layout's sessions run in the other window.
        createWindow(root: root, restoresLayout: false)
    }

    /// ⌘O / File ▸ Open… — open the recent workspaces browser.
    @MainActor @objc func openWorkspaceBrowser(_ sender: Any?) {
        if let open = openWindow, isUp(open) { return open.present() }
        let wc = OpenWindowController(
            onOpen: { [weak self] url in self?.openWorkspace(url) },
            onOpenNew: { [weak self] in self?.openFolder(nil) })
        openWindow = wc
        wc.present()
    }
    private var openWindow: OpenWindowController?

    /// Whether `controller`'s window is up, on screen or minimized. Another
    /// Open or setup window comes forward instead of a new one: replacing the
    /// controller kept here would leave the old window's buttons dead.
    @MainActor private func isUp(_ controller: NSWindowController?) -> Bool {
        guard let window = controller?.window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    /// ⌘⌥N / File ▸ Open Folder… — the setup wizard (folder, look, mounts, kits).
    @MainActor @objc func openFolder(_ sender: Any?) {
        if let setup = setupWindow, isUp(setup) { return setup.present() }
        let wc = SetupWindowController(welcome: false, onCreate: { [weak self] url, profile, policy, kits in
            self?.createWorkspace(url, profile: profile, policy: policy, kits: kits, makeDefault: false)
        })
        setupWindow = wc
        wc.present()
    }
    /// The Open Folder wizard's window (the Welcome has its own, `welcomeWindow`:
    /// a folder made from the Welcome becomes the default, one from the wizard doesn't).
    private var setupWindow: SetupWindowController?

    /// File ▸ Welcome to Sandshell… — re-run the first-launch setup on demand.
    @MainActor @objc func runFirstLaunchSetup(_ sender: Any?) { showWelcome() }

    /// First-launch Welcome (Default = today's ~/Sandshell; Advanced = wizard).
    @MainActor private func showWelcome() {
        if let welcome = welcomeWindow, isUp(welcome) { return welcome.present() }
        let wc = SetupWindowController(
            welcome: true,
            onCreate: { [weak self] url, profile, policy, kits in
                self?.createWorkspace(url, profile: profile, policy: policy, kits: kits, makeDefault: true)
            },
            onDefault: { [weak self] in self?.createWorkspaceDefault() })
        welcomeWindow = wc
        wc.present()
    }
    private var welcomeWindow: SetupWindowController?

    /// Create a workspace from the wizard: persist its look + mounts + kits so the
    /// window opens already-configured (no first-run prompt), then open it.
    @MainActor private func createWorkspace(_ url: URL, profile: RootProfile,
                                            policy: MountPolicy, kits: [String], makeDefault: Bool) {
        RootFolderStore.upsert(profile)
        if makeDefault {
            RootFolderStore.defaultPath = RootFolderStore.standardize(url.path)
        } else {
            RootFolderStore.adoptDefault(url.path)
        }
        let (loaded, unreadable) = WorkspaceConfig.loadReportingProblems(root: url, home: URL.homeDirectory)
        // An unreadable config.json was kept aside: the window says so (its
        // other settings are defaults now).
        WorkspaceStore.report(unreadable, root: url)
        var config = loaded
        config.policy = policy
        // Sandshell's own kits go in their own field (what's unchecked stays off).
        config.kits = kits.filter { !KitStore.isSandshellKit($0) }
        config.sandshellKits = kits.filter(KitStore.isSandshellKit)
        config.configured = true   // wizard collected mounts → skip first-run sheet
        do {
            try config.save(root: url)
        } catch {
            Log.error(.app, "couldn't save the config for \(url.path): \(error)")
            Alerts.inform("Couldn’t set up “\(url.lastPathComponent)”", error.localizedDescription)
            return
        }
        openWorkspace(url)
    }

    /// "Default" on the Welcome screen — today's behavior: open ~/Sandshell with
    /// defaults (its first-run mount sheet still appears).
    @MainActor private func createWorkspaceDefault() {
        let root = WorkspaceBootstrap.defaultRoot
        RootFolderStore.upsert(RootProfile.makeDefault(path: root.path))
        RootFolderStore.adoptDefault(root.path)
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
                // Only for a focused terminal, which takes every key itself; anywhere
                // else (text, lists, sheets, alerts) the menu bar's own key
                // equivalents apply, and ⌘D in a Save sheet is Desktop again.
                guard NSApp.modalWindow == nil, let key = NSApp.keyWindow, key.attachedSheet == nil,
                      key.firstResponder is AppTerminalView else { return false }
                if cmd {
                    // The app's own commands, in any window's terminal (a host
                    // terminal, Daemon Health and kit logs too).
                    switch chars {
                    case "q": NSApp.terminate(nil); return true
                    case ",": app.openSettings(nil); return true
                    case "n" where opt: app.openFolder(nil); return true
                    case "n" where ctrl: app.newChat(nil); return true
                    case "n" where shift: app.duplicateWindow(nil); return true
                    case "n": app.newSession(nil); return true
                    case "W" where !opt, "w" where shift && !opt: app.closeWindow(nil); return true
                    default: break
                    }
                }
                // The rest act on a workspace window's panes and sessions.
                guard key.windowController is MainWindowController else { return false }
                if cmd {
                    // Shift turns "[" / "]" into "{" / "}" in charactersIgnoringModifiers,
                    // so match both forms for ⌘⇧[ / ⌘⇧].
                    switch chars {
                    case "D": app.splitDown(nil); return true
                    case "d" where shift: app.splitDown(nil); return true
                    case "d": app.splitRight(nil); return true
                    // A `where` binds only to the pattern before it, so the ⌥ forms
                    // test it explicitly (⌘[ / ⌘] without ⌥ switch sessions below).
                    case "∑": app.closePane(nil); return true
                    case "w" where opt: app.closePane(nil); return true
                    case let c where opt && ["[", "{", "“", "”"].contains(c): app.focusPreviousPane(nil); return true
                    case let c where opt && ["]", "}", "‘", "’"].contains(c): app.focusNextPane(nil); return true
                    case "=" where ctrl: app.equalizePanes(nil); return true
                    case "∫": app.showBackgroundTasks(nil); return true
                    case "b" where opt: app.showBackgroundTasks(nil); return true
                    case "O": app.openQuickly(nil); return true
                    case "o" where shift: app.openQuickly(nil); return true
                    // ⇧⌘F (⌘F stays Find).
                    case "F": app.showSearch(nil); return true
                    case "f" where shift: app.showSearch(nil); return true
                    case "s" where ctrl: app.toggleSessionSidebar(nil); return true
                    case "t" where ctrl: app.toggleChatTerminal(nil); return true
                    case ".": app.stopSession(nil); return true
                    case "r" where !shift && !opt && !ctrl: app.restartSession(nil); return true
                    case "[", "{": app.selectPreviousSession(nil); return true
                    case "]", "}": app.selectNextSession(nil); return true
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

    /// ⌘, — open the Settings window (for the front folder; with no window
    /// open, the most recent folder's).
    @MainActor @objc func openSettings(_ sender: Any?) {
        if let controller = activeController ?? windows.first { return controller.showSettings() }
        showMainWindow(nil)
        activeController?.showSettings()
    }

    /// New Claude chat seeded with text/files in the front workspace (Services,
    /// Shortcuts). With no window up, the most recent folder's opens for it —
    /// unless the Welcome or a folder chooser comes forward instead
    /// (`reopenWorkspaceWindow`), which no chat goes behind.
    @MainActor func newChat(draft: String, urls: [URL], send: Bool) {
        NSApp.activate()
        guard let target = activeController ?? windows.first ?? reopenWorkspaceWindow() else { return }
        target.newChat(draft: draft, urls: urls, send: send)
    }

    /// Services ▸ New Sandshell Chat: selected text arrives quoted (type your
    /// question below it); selected files become attachments.
    @MainActor @objc func newChatFromService(_ pboard: NSPasteboard, userData: String?,
                                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var draft = ""
        if urls.isEmpty, let text = pboard.string(forType: .string), !text.isEmpty {
            draft = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        }
        newChat(draft: draft, urls: urls, send: false)
    }

    // MARK: Panes (View menu)

    @MainActor @objc func splitRight(_ sender: Any?) { activeController?.splitRight() }
    @MainActor @objc func splitDown(_ sender: Any?) { activeController?.splitDown() }
    @MainActor @objc func closePane(_ sender: Any?) { activeController?.closePane() }
    @MainActor @objc func focusNextPane(_ sender: Any?) { activeController?.focusNextPane() }
    @MainActor @objc func focusPreviousPane(_ sender: Any?) { activeController?.focusPreviousPane() }
    @MainActor @objc func equalizePanes(_ sender: Any?) { activeController?.equalizePanes() }

    /// ⌥⌘B — every session's background tasks in the active window.
    @MainActor @objc func showBackgroundTasks(_ sender: Any?) { activeController?.showBackgroundTasks() }

    /// ⇧⌥⌘0 — the window's Files sidebar (tree + editor) for the active session's folder.
    @MainActor @objc func toggleFiles(_ sender: Any?) {
        activeController?.toggleFiles()
    }

    /// ⇧⌘O — fuzzy file finder over the session folder (the Files surface
    /// holding focus answers first via the responder chain; this is the fallback).
    @MainActor @objc func openQuickly(_ sender: Any?) {
        activeController?.openQuickly()
    }

    /// ⌃⌘N — new native Claude chat (ACP) in the current folder; the File menu's
    /// New Codex/Gemini Chat items name their agent in `representedObject`.
    @MainActor @objc func newChat(_ sender: Any?) {
        let raw = (sender as? NSMenuItem)?.representedObject as? String
        sessionCommandTarget()?.newChat(agent: raw.map(AgentKind.init(rawValue:)) ?? .claude)
    }

    /// The workspace window a new session or chat goes to. Asked from a window
    /// of no workspace (a host terminal, Daemon Health, a kit log), that's the
    /// one last used, which may be behind: it comes forward so the new
    /// session is seen.
    @MainActor private func sessionCommandTarget() -> MainWindowController? {
        guard let target = activeController else { return nil }
        if let key = NSApp.keyWindow, !target.owns(key) {
            target.showWindow(nil)
            target.window?.makeKeyAndOrderFront(nil)
        }
        return target
    }

    /// ⇧⌘F — the Search window (sessions + past conversations). From an open
    /// Search window, just refocus it (it belongs to its own workspace).
    @MainActor @objc func showSearch(_ sender: Any?) {
        if let search = NSApp.keyWindow?.windowController as? SearchWindowController {
            search.show()
            return
        }
        activeController?.showSearch()
    }

    /// ⌘N — new session in the current project with the same agent.
    @MainActor @objc func newSession(_ sender: Any?) {
        sessionCommandTarget()?.newSession()
    }

    /// ⌃⌘S — show or hide the sidebar.
    @MainActor @objc func toggleSessionSidebar(_ sender: Any?) {
        activeController?.toggleSidebar()
    }

    // MARK: Session menu (the focused pane's session, like the toolbar)

    @MainActor @objc func toggleSessionDetails(_ sender: Any?) { SessionDetails.toggle() }
    @MainActor @objc func focusSessionFilter(_ sender: Any?) { activeController?.sidebarController?.focusFilter() }
    @MainActor @objc func reopenClosedSession(_ sender: Any?) { activeController?.reopenClosedSession() }
    @MainActor @objc func renameSession(_ sender: Any?) { activeController?.sidebarController?.beginRenameSelected() }
    @MainActor @objc func stopSession(_ sender: Any?) { activeController?.paneTree?.stopClicked() }
    @MainActor @objc func restartSession(_ sender: Any?) { activeController?.paneTree?.headerRestartClicked() }
    @MainActor @objc func revealSessionFolder(_ sender: Any?) { activeController?.paneTree?.revealInFinderClicked() }
    @MainActor @objc func toggleChatTerminal(_ sender: Any?) { activeController?.paneTree?.toggleChatClicked() }
    @MainActor @objc func openHostTerminal(_ sender: Any?) { activeController?.sidebarController?.openHostTerminal() }

    // MARK: Help menu

    @MainActor @objc func showSandshellLog(_ sender: Any?) { activeController?.sidebarController?.openSandshellLog() }
    @MainActor @objc func showDaemonLog(_ sender: Any?) { activeController?.sidebarController?.openDaemonLog() }
    @MainActor @objc func showStatusDebug(_ sender: Any?) { activeController?.sidebarController?.openStatusDebugWindow() }
    @MainActor @objc func showReleaseNotes(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/xmas/homebrew-xmas/releases")!)
    }
    @MainActor @objc func showKeyboardShortcuts(_ sender: Any?) { ShortcutsWindowController.shared.show() }

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

    /// Bring a workspace window back (Window ▸ Sandshell, and dock reopen): with
    /// none open, the Welcome, Open Folder or Open window while one is up (no
    /// folder is set up behind it), else the most recent folder's.
    @MainActor @objc func showMainWindow(_ sender: Any?) {
        if let controller = activeController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            reopenWorkspaceWindow()
        }
        NSApp.activate()
    }

    /// With no workspace window open: an open Welcome, Open Folder or Open
    /// window comes forward (nil — no folder is set up behind it); with none
    /// of those, no folder known shows the Welcome (nil), else the most
    /// recent folder's window opens.
    @MainActor @discardableResult
    private func reopenWorkspaceWindow() -> MainWindowController? {
        if let welcome = welcomeWindow, isUp(welcome) {
            welcome.present()
        } else if let setup = setupWindow, isUp(setup) {
            setup.present()
        } else if let open = openWindow, isUp(open) {
            open.present()
        } else if RootFolderStore.all.isEmpty {
            showWelcome()   // no folder has had a sandbox yet
        } else if let recent = RootFolderStore.byRecency().first {
            return openWorkspace(URL(filePath: recent.path, directoryHint: .checkFileSystem))
        } else {
            openWorkspaceBrowser(nil)   // the folders it knows are gone
        }
        return nil
    }

    /// Handle files/folders passed via `open -a Sandshell /path …` or drag-onto-dock.
    /// Directories open/focus workspaces; regular files are inserted into the
    /// active terminal as sandbox-readable paths.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Opened with the app at launch: wait for PATH and the restored windows.
        guard finishedLaunching else { openedAtLaunch += urls; return }
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
        // A window with no session to take them (an empty pane, one still
        // starting) beeps; only with no window open does their folder open as
        // a workspace to take them.
        if let controller = activeController {
            if !controller.insertExternalItems(files) { NSSound.beep() }
        } else if let parent = files.first?.deletingLastPathComponent() {
            openWorkspace(parent)?.insertExternalItems(files)
        }
    }

    /// Sessions' processes in the sandboxes outlive the app unless reaped.
    func applicationWillTerminate(_ notification: Notification) {
        for window in windows { window.prepareForQuit() }
        ACPSparePool.shared.drain()
        SbxClient.waitForReaps(timeout: 2)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Snapshot the open windows for restore-on-launch, then freeze persistence so
    /// the windows closing during termination don't clear the saved set.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsaved file edits get their say first.
        for controller in windows where !controller.confirmUnsavedFiles() { return .terminateCancel }
        saveOpenWindows()
        isTerminating = true
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopen a workspace window if none is currently on screen (e.g. all were
        // closed while a host terminal stayed open) — or bring the Welcome or
        // Open window forward while one stands in for it.
        if !windows.contains(where: { $0.window?.isVisible == true }) {
            showMainWindow(nil)
        }
        return true
    }
}

// MARK: - Menu validation

extension AppDelegate: NSMenuItemValidation {
    /// Workspace commands need a workspace window; toggles say what they'll do.
    @MainActor func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let controller = activeController
        switch item.action {
        case #selector(toggleFiles(_:)):
            item.title = controller?.isFilesShown == true ? "Hide Files" : "Show Files"
            return controller != nil
        case #selector(toggleSessionDetails(_:)):
            item.title = SessionDetails.isShown ? "Hide Session Details" : "Show Session Details"
            return true
        case #selector(toggleSessionSidebar(_:)):
            item.title = controller?.isSidebarCollapsed == true ? "Show Sidebar" : "Hide Sidebar"
            return controller != nil
        case #selector(closeSessionOrWindow(_:)):
            if let key = NSApp.keyWindow, !windows.contains(where: { $0.window === key }) {
                item.title = "Close"
                return true
            }
            item.title = controller?.closesSession == true ? "Close Session" : "Close Window"
            return NSApp.keyWindow != nil
        case #selector(reopenClosedSession(_:)):
            return controller?.canReopenClosedSession ?? false
        case #selector(renameSession(_:)):
            return controller?.closesSession ?? false
        case #selector(stopSession(_:)):
            return controller?.paneTree?.canPerformSessionAction(#selector(TerminalStackController.stopClicked)) ?? false
        case #selector(restartSession(_:)):
            return controller?.paneTree?.canPerformSessionAction(#selector(TerminalStackController.headerRestartClicked)) ?? false
        case #selector(revealSessionFolder(_:)):
            return controller?.paneTree?.canPerformSessionAction(#selector(TerminalStackController.revealInFinderClicked)) ?? false
        case #selector(toggleChatTerminal(_:)):
            item.title = controller?.paneTree?.chatToggleTitle ?? "Show as Chat"
            return controller?.paneTree?.canPerformSessionAction(#selector(TerminalStackController.toggleChatClicked)) ?? false
        case #selector(newSession(_:)), #selector(newChat(_:)), #selector(duplicateWindow(_:)), #selector(openQuickly(_:)),
             #selector(showSearch(_:)), #selector(splitRight(_:)), #selector(splitDown(_:)),
             #selector(closePane(_:)), #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)),
             #selector(equalizePanes(_:)), #selector(selectNextSession(_:)), #selector(selectPreviousSession(_:)),
             #selector(showBackgroundTasks(_:)), #selector(openHostTerminal(_:)), #selector(showSandshellLog(_:)),
             #selector(showDaemonLog(_:)), #selector(showStatusDebug(_:)), #selector(closeWindow(_:)),
             #selector(focusSessionFilter(_:)):
            return controller != nil || (item.action == #selector(showSearch(_:)) && NSApp.keyWindow?.windowController is SearchWindowController)
        default:
            return true
        }
    }
}

