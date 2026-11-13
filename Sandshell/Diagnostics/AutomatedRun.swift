import AppKit

/// A debug run's own world, so it never competes with the work you're doing
/// in your own Sandshell: Xcode's Run (⌘R, and `RunProject` from a sandbox)
/// passes `-SandshellDebugProfile YES` (DEBUG builds only). Each workspace
/// keeps its state in `.sandshell/debug/` — its own session list, its config
/// seeded from the real one — and its sandboxes are named `<name>-debug`, so
/// a debug run has its own agents. The Debug build's own bundle id
/// (`com.xmas.sandshell.debug`) keeps its settings and saved windows apart,
/// and the scheme's `-SandshellDebugOpen` opens just the checkout.
enum DebugProfile {
    static let isActive: Bool = {
        #if DEBUG
        // Never while hosting the unit tests (the scheme's arguments can reach them).
        let env = ProcessInfo.processInfo.environment
        guard env["XCTestConfigurationFilePath"] == nil, env["XCTestBundlePath"] == nil else { return false }
        return UserDefaults.standard.bool(forKey: "SandshellDebugProfile")
        #else
        return false
        #endif
    }()

    /// What a debug run opens instead of the windows it had (the scheme's
    /// `-SandshellDebugOpen $(SRCROOT)`: a path, or a list of them); nil
    /// outside a debug run or with none given. Its own key, not
    /// `openWindowRoots`: launch arguments reach every defaults suite, the
    /// unit tests' too.
    static var windowsToOpen: [OpenWindows.Window]? {
        guard isActive else { return nil }
        let d = UserDefaults.standard
        let paths = d.stringArray(forKey: "SandshellDebugOpen") ?? d.string(forKey: "SandshellDebugOpen").map { [$0] } ?? []
        let roots = paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        return roots.isEmpty ? nil : roots.map { OpenWindows.Window(root: $0, instanceIndex: nil) }
    }

    /// Added to a debug run's sandbox names.
    static let sandboxSuffix = "-debug"

    /// The folder under `<root>/.sandshell` a debug run keeps its files in.
    static let controlSubfolder = "debug"

    /// A debug run's first look at a workspace: its config starts as a copy of
    /// the real one (mounts, kits, agent), so the debug sandbox matches it.
    static func seedConfig(root: URL, into url: URL) {
        let fm = FileManager.default
        let real = root.appending(path: ".sandshell/config.json")
        guard isActive, !fm.fileExists(atPath: url.path(percentEncoded: false)),
              fm.fileExists(atPath: real.path(percentEncoded: false)) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: real, to: url)
    }
}

/// Launched by a scripted test — the DEBUG self-test (`-SandshellSelfTest`) or
/// the AppleScript suite (`-SandshellUITestHeadless`) — usually while someone
/// is working at the Mac. Nothing may wait on a person: no Keychain or
/// notification prompts, and alerts answer themselves.
enum AutomatedRun {
    static let isActive: Bool = {
        #if DEBUG
        let d = UserDefaults.standard
        return d.string(forKey: "SandshellSelfTest") != nil || d.bool(forKey: "SandshellUITestHeadless")
        #else
        return false
        #endif
    }()

    /// Destructive steps (rebuilding a sandbox) only go ahead unattended for
    /// scratch workspaces, so a test pointed at a real folder can't take down
    /// its sandbox.
    static func isScratch(_ root: URL) -> Bool {
        let path = root.realPath
        return ["/tmp/", "/private/tmp/", "/private/var/folders/"].contains { path.hasPrefix($0) }
    }

    @MainActor private static var timer: Timer?

    /// Press the default button of any alert that appears (app-modal or sheet).
    @MainActor static func startAnsweringAlerts() {
        guard isActive, timer == nil else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { answerAlerts() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common includes the modal-panel mode
        timer = t
    }

    @MainActor private static func answerAlerts() {
        // The UI-test suite answers its own sheet alerts (they stay hidden and
        // never take focus); an app-modal alert would block it, so take those.
        var panels = UserDefaults.standard.bool(forKey: "SandshellUITestHeadless")
            ? [] : NSApp.windows.compactMap(\.attachedSheet)
        if let modal = NSApp.modalWindow { panels.append(modal) }
        for panel in panels where String(describing: type(of: panel)).contains("Alert") {
            guard let button = defaultButton(in: panel.contentView) else { continue }
            Log.info(.app, "automated run: answering alert with “\(button.title)”")
            button.performClick(nil)
        }
    }

    /// The alert's default button: the one Return presses — or, when the
    /// app isn't active (a test copy never is) and AppKit hasn't given it
    /// Return, the rightmost button that isn't Cancel (where alerts put it).
    @MainActor private static func defaultButton(in view: NSView?) -> NSButton? {
        let buttons = allButtons(in: view).filter(\.isEnabled)
        if let b = buttons.first(where: { $0.keyEquivalent == "\r" }) { return b }
        return buttons.filter { $0.keyEquivalent != "\u{1b}" }
            .max { $0.convert($0.bounds, to: nil).maxX < $1.convert($1.bounds, to: nil).maxX }
    }

    @MainActor private static func allButtons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { allButtons(in: $0) }
    }
}
