import AppKit
import Foundation

/// In-app updater. Sandshell ships through the Homebrew tap `xmas/xmas`
/// (public repo xmas/homebrew-xmas): the cask `Casks/sandshell.rb` is the
/// source of truth for the latest version, and its DMGs are GitHub release
/// assets on that repo (tag `sandshell-v<version>`).
///
/// The check reads the raw cask rather than the GitHub releases API: the cask
/// is exactly what `brew upgrade` will install (so we never announce a version
/// brew can't see yet), the tap repo also hosts other apps' releases (so
/// "latest release" isn't necessarily ours), and raw.githubusercontent.com has
/// no API rate limit or auth. The cask's `url` also gives the DMG location for
/// the non-Homebrew fallback.
///
/// If the running app was installed by Homebrew, "update" runs
/// `brew update && brew upgrade --cask xmas/xmas/sandshell` in Terminal after
/// Sandshell quits (so Homebrew's records stay in sync). Otherwise it downloads
/// the DMG, swaps the bundle in place, and relaunches.
@MainActor
final class Updater {
    static let shared = Updater()

    // MARK: Configuration
    static let caskToken = "xmas/xmas/sandshell"
    static let caskURL = URL(string: "https://raw.githubusercontent.com/xmas/homebrew-xmas/main/Casks/sandshell.rb")!
    static let upgradeCommand = "brew update && brew upgrade --cask \(caskToken)"

    private var checking = false

    private init() {}

    /// Running app version (CFBundleShortVersionString), e.g. "0.1.0".
    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: - Entry points

    /// Silent check on launch: only speaks up when an update exists.
    func checkInBackground() {
        check(userInitiated: false)
    }

    /// Menu "Check for Updates…".
    func checkForUpdatesMenu() {
        check(userInitiated: true)
    }

    private func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        Log.info(.app, "checking for updates (current \(currentVersion), userInitiated=\(userInitiated))")
        Task {
            defer { checking = false }
            do {
                guard let release = try await latestRelease() else {
                    if userInitiated { inform("No releases found", "Couldn’t read a version from the Homebrew cask.") }
                    return
                }
                if Self.isNewer(release.version, than: currentVersion) {
                    offer(release)
                } else if userInitiated {
                    inform("You’re up to date", "Sandshell \(currentVersion) is the latest version.")
                }
            } catch {
                Log.error(.app, "update check failed: \(error.localizedDescription)")
                if userInitiated { inform("Update check failed", error.localizedDescription) }
            }
        }
    }

    // MARK: - Release discovery

    private struct Release { let version: String; let dmgURL: URL? }

    /// Fetch the tap's cask and read its `version` and (expanded) `url`.
    private func latestRelease() async throws -> Release? {
        var req = URLRequest(url: Self.caskURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return Self.parseCask(String(decoding: data, as: UTF8.self))
            .map { Release(version: $0.version, dmgURL: $0.dmgURL) }
    }

    /// Pull `version "…"` and `url "…"` (with `#{version}` expanded) from a cask.
    static func parseCask(_ text: String) -> (version: String, dmgURL: URL?)? {
        func quoted(_ stanza: String) -> String? {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(stanza + " \"") else { continue }
                let rest = t.dropFirst(stanza.count + 2)
                guard let end = rest.firstIndex(of: "\"") else { continue }
                return String(rest[..<end])
            }
            return nil
        }
        // Only the native app's cask counts: its tags are `sandshell-v…`. (The
        // same token previously shipped the Tauri app at 0.15.x under `v…` tags.)
        guard let v = quoted("version"), !v.isEmpty,
              v.allSatisfy({ $0.isNumber || $0 == "." }),
              let rawURL = quoted("url"), rawURL.contains("/sandshell-v") else { return nil }
        return (v, URL(string: rawURL.replacing("#{version}", with: v)))
    }

    /// Numeric, component-wise semver-ish comparison ("0.10.0" > "0.9.0").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The Caskroom entry if this copy was installed by `brew install --cask`.
    private var homebrewManaged: Bool {
        ["/opt/homebrew/Caskroom/sandshell", "/usr/local/Caskroom/sandshell"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Offer + install

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        let base = "Sandshell \(release.version) is available (you have \(currentVersion))."
        if homebrewManaged {
            alert.informativeText = base + " Sandshell will quit and Terminal will run:\n\n"
                + Self.upgradeCommand + "\n\nthen reopen it."
            alert.addButton(withTitle: "Upgrade with Homebrew")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Copy Command")
            switch alert.runModal() {
            case .alertFirstButtonReturn: upgradeWithHomebrew()
            case .alertThirdButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.upgradeCommand, forType: .string)
            default: break
            }
        } else {
            alert.informativeText = base + " Download and install it now? Sandshell will relaunch.\n\n"
                + "Tip: install with Homebrew (brew install --cask \(Self.caskToken)) "
                + "to get updates through brew upgrade."
            alert.addButton(withTitle: "Update Now")
            alert.addButton(withTitle: "Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let url = release.dmgURL else {
                inform("Update failed", "The cask has no download URL.")
                return
            }
            Task {
                do {
                    let dmg = try await download(url)
                    try installAndRelaunch(dmgURL: dmg)
                } catch {
                    Log.error(.app, "update install failed: \(error.localizedDescription)")
                    inform("Update failed", error.localizedDescription)
                }
            }
        }
    }

    /// Hand off to Terminal: a `.command` script that waits for us to quit,
    /// runs the brew upgrade, and reopens the app. Then quit.
    private func upgradeWithHomebrew() {
        let brew = PathFixer.which("brew") ?? "brew"
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = Bundle.main.bundleURL.path
        let script = """
        #!/bin/bash
        echo "Waiting for Sandshell to quit…"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        "\(brew)" update && "\(brew)" upgrade --cask \(Self.caskToken) && /usr/bin/open "\(app)"
        """
        do {
            let url = URL.temporaryDirectory.appending(path: "sandshell-upgrade-\(UUID().uuidString).command")
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
            Log.info(.app, "handing update to Homebrew: \(Self.upgradeCommand)")
            Task {
                do {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: terminal,
                                                          configuration: NSWorkspace.OpenConfiguration())
                    NSApp.terminate(nil)
                } catch {
                    Log.error(.app, "could not open Terminal for brew upgrade: \(error.localizedDescription)")
                    inform("Couldn’t open Terminal", "Run this yourself:\n\n\(Self.upgradeCommand)")
                }
            }
        } catch {
            inform("Update failed", error.localizedDescription)
        }
    }

    /// Download the DMG (public GitHub release asset).
    private func download(_ url: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        try Self.check(resp, nil)
        let dest = URL.temporaryDirectory.appending(path: url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Mount the DMG, copy the new app out, then hand off to a detached script
    /// that waits for us to quit, swaps the bundle in place, and relaunches.
    private func installAndRelaunch(dmgURL: URL) throws {
        Log.info(.app, "installing update from \(dmgURL.lastPathComponent) and relaunching")
        let mount = URL.temporaryDirectory.appending(path: "sandshell-mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmgURL.path, "-nobrowse", "-noverify",
                                     "-mountpoint", mount.path])
        defer {
            do {
                try run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            } catch {
                Log.error(.app, "failed to detach update disk image: \(error.localizedDescription)")
            }
        }

        guard let appName = (try? FileManager.default.contentsOfDirectory(atPath: mount.path))?
            .first(where: { $0.hasSuffix(".app") }) else {
            throw Err("No .app found in the downloaded disk image.")
        }
        let newApp = mount.appending(path: appName)
        let staged = URL.temporaryDirectory.appending(path: "sandshell-new-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [newApp.path, staged.path])

        let dest = Bundle.main.bundleURL   // e.g. /Applications/Sandshell.app
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        /usr/bin/ditto "$1" "$2.incoming" || exit 1
        /bin/rm -rf "$2"
        /bin/mv "$2.incoming" "$2"
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        /usr/bin/open "$2"
        """
        let scriptURL = URL.temporaryDirectory.appending(path: "sandshell-swap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let task = Process()
        task.executableURL = URL(filePath: "/bin/bash")
        task.arguments = [scriptURL.path, staged.path, dest.path]
        try task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private struct Err: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }

    private static func check(_ resp: URLResponse, _ data: Data?) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw Err("HTTP \(http.statusCode). \(body.prefix(200))")
        }
    }

    /// Run a tool to completion; a non-zero exit throws, so a failed mount or
    /// copy stops the update (and says so) instead of swapping in a broken app.
    private func run(_ launchPath: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(filePath: launchPath); p.arguments = args
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Err("\(URL(filePath: launchPath).lastPathComponent) failed (exit \(p.terminationStatus)).")
        }
    }

    private func inform(_ title: String, _ body: String) {
        Alerts.inform(title, body)
    }
}
