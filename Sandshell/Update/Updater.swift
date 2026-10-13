import AppKit
import CryptoKit
import Foundation
import Network

/// In-app updater. Reads the docker.com-shared Google Drive "releases" folder
/// (domain-restricted, so it authenticates the user via Google OAuth with the
/// read-only Drive scope), finds the newest `Sandshell-<version>.dmg`, and — if
/// it's newer than the running build — offers to download it, swap the app
/// bundle in place, and relaunch.
///
/// SETUP (one-time): create a Google **OAuth client ID of type "Desktop app"**
/// in the GCP project (consent screen → Internal, scope
/// `…/auth/drive.readonly`) and fill in `clientID`/`clientSecret` below. Desktop
/// clients support the loopback redirect this uses without registering ports.
@MainActor
final class Updater {
    static let shared = Updater()

    // MARK: Configuration
    /// The docker.com-shared releases folder (holds `Sandshell-<version>.dmg`).
    private let driveFolderID = "1TDO_iVfaobA3tYiF8JM_1NA_DBpEANjl"
    /// TODO: set these from the Desktop OAuth client created in GCP.
    private let clientID = "REPLACE_WITH_OAUTH_CLIENT_ID.apps.googleusercontent.com"
    /// "Desktop app" clients have a client secret that is not actually secret
    /// (it's shipped in the binary); the loopback+PKCE flow still requires it.
    private let clientSecret = "REPLACE_WITH_OAUTH_CLIENT_SECRET"
    private let scope = "https://www.googleapis.com/auth/drive.readonly"

    private var configured: Bool { !clientID.hasPrefix("REPLACE_WITH") }
    private var checking = false

    private init() {}

    /// Running app version (CFBundleShortVersionString), e.g. "0.1.0".
    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: - Entry points

    /// Silent check on launch: only runs if the user has already authorized
    /// (never pops a browser unprompted).
    func checkInBackground() {
        guard configured, Keychain.read(Self.refreshKey) != nil else { return }
        check(userInitiated: false)
    }

    /// Menu "Check for Updates…": may trigger the Google sign-in flow.
    func checkForUpdatesMenu() {
        guard configured else {
            inform("Updates aren’t configured",
                   "This build has no Google OAuth client configured, so it can’t reach the "
                   + "releases folder. See Updater.swift setup notes.")
            return
        }
        check(userInitiated: true)
    }

    private func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        Log.info(.app, "checking for updates (current \(currentVersion), userInitiated=\(userInitiated))")
        Task {
            defer { checking = false }
            do {
                let token = try await accessToken(interactive: userInitiated)
                guard let release = try await latestRelease(token: token) else {
                    if userInitiated { inform("No releases found", "The releases folder has no Sandshell DMGs.") }
                    return
                }
                if Self.isNewer(release.version, than: currentVersion) {
                    offer(release, token: token)
                } else if userInitiated {
                    inform("You’re up to date", "Sandshell \(currentVersion) is the latest version.")
                }
            } catch is CancellationError {
                // user cancelled sign-in — stay quiet
            } catch {
                Log.error(.app, "update check failed: \(error.localizedDescription)")
                if userInitiated { inform("Update check failed", error.localizedDescription) }
            }
        }
    }

    // MARK: - Release discovery

    private struct Release { let version: String; let fileID: String; let name: String }

    /// List the releases folder and return the highest-versioned DMG.
    private func latestRelease(token: String) async throws -> Release? {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "q", value: "'\(driveFolderID)' in parents and trashed=false and mimeType='application/x-apple-diskimage'"),
            .init(name: "fields", value: "files(id,name)"),
            .init(name: "pageSize", value: "100"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "includeItemsFromAllDrives", value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        struct List: Decodable { struct F: Decodable { let id: String; let name: String }; let files: [F] }
        let list = try JSONDecoder().decode(List.self, from: data)
        return list.files
            .compactMap { f -> Release? in
                guard let v = Self.version(fromDMGName: f.name) else { return nil }
                return Release(version: v, fileID: f.id, name: f.name)
            }
            .max { Self.isNewer($1.version, than: $0.version) }
    }

    /// Parse "Sandshell-1.2.3.dmg" → "1.2.3".
    static func version(fromDMGName name: String) -> String? {
        guard name.lowercased().hasSuffix(".dmg") else { return nil }
        let stem = String(name.dropLast(4))
        guard let dash = stem.firstIndex(of: "-") else { return nil }
        let v = String(stem[stem.index(after: dash)...])
        return v.allSatisfy { $0.isNumber || $0 == "." } && !v.isEmpty ? v : nil
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

    // MARK: - Offer + install

    private func offer(_ release: Release, token: String) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "Sandshell \(release.version) is available (you have \(currentVersion)). "
            + "Download and install it now? Sandshell will relaunch."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let dmg = try await download(fileID: release.fileID, token: token, name: release.name)
                try installAndRelaunch(dmgURL: dmg)
            } catch {
                Log.error(.app, "update install failed: \(error.localizedDescription)")
                inform("Update failed", error.localizedDescription)
            }
        }
    }

    /// Download the DMG via the authenticated media endpoint.
    private func download(fileID: String, token: String, name: String) async throws -> URL {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media&supportsAllDrives=true")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        try Self.check(resp, nil)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Mount the DMG, copy the new app out, then hand off to a detached script
    /// that waits for us to quit, swaps the bundle in place, and relaunches.
    private func installAndRelaunch(dmgURL: URL) throws {
        Log.info(.app, "installing update from \(dmgURL.lastPathComponent) and relaunching")
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandshell-mnt-\(UUID().uuidString)")
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
        let newApp = mount.appendingPathComponent(appName)
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandshell-new-\(UUID().uuidString).app")
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
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandshell-swap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path, staged.path, dest.path]
        try task.run()
        NSApp.terminate(nil)
    }

    // MARK: - OAuth (PKCE, loopback redirect)

    private static let refreshKey = "google-oauth-refresh-token"
    private var cachedAccess: (token: String, expiry: Date)?

    /// A valid access token: from cache, refreshed, or (interactive only) via a
    /// fresh browser sign-in.
    private func accessToken(interactive: Bool) async throws -> String {
        if let c = cachedAccess, c.expiry > Date().addingTimeInterval(60) { return c.token }
        if let refresh = Keychain.read(Self.refreshKey) {
            if let token = try? await exchangeRefresh(refresh) { return token }
        }
        guard interactive else { throw Err("Not signed in.") }
        return try await signIn()
    }

    private func exchangeRefresh(_ refresh: String) async throws -> String {
        let token = try await tokenRequest([
            "client_id": clientID, "client_secret": clientSecret,
            "refresh_token": refresh, "grant_type": "refresh_token",
        ])
        cache(token); return token.accessToken
    }

    private func signIn() async throws -> String {
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let (port, codeTask) = try await startLoopback()
        let redirect = "http://127.0.0.1:\(port)"

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(auth.url!)

        let code = try await codeTask.value
        let token = try await tokenRequest([
            "client_id": clientID, "client_secret": clientSecret,
            "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        if let refresh = token.refreshToken { Keychain.set(Self.refreshKey, refresh) }
        cache(token)
        return token.accessToken
    }

    private struct TokenResponse: Decodable {
        let accessToken: String; let expiresIn: Int?; let refreshToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token"
        }
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func cache(_ t: TokenResponse) {
        cachedAccess = (t.accessToken, Date().addingTimeInterval(TimeInterval(t.expiresIn ?? 3000)))
    }

    /// Start a one-shot loopback HTTP listener; returns the bound port and a task
    /// that resolves with the OAuth `code` once the browser redirects back.
    private func startLoopback() async throws -> (UInt16, Task<String, Error>) {
        let listener = try NWListener(using: .tcp, on: .any)
        let box = CodeBox()
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let code = Self.parseCode(fromRequestLine: request)
                let body = code != nil
                    ? "Signed in. You can return to Sandshell."
                    : "Sign-in failed. You can close this window."
                let http = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: http.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                box.resolve(code)
                listener.cancel()
            }
        }
        listener.start(queue: .main)
        // Wait for the OS-assigned port.
        for _ in 0..<50 {
            if let p = listener.port?.rawValue, p != 0 {
                return (p, Task { try await box.wait() })
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        listener.cancel()
        throw Err("Could not start the sign-in listener.")
    }

    /// Extract `code` from the HTTP request line "GET /?code=…&… HTTP/1.1".
    private nonisolated static func parseCode(fromRequestLine request: String) -> String? {
        guard let line = request.split(separator: "\r\n").first,
              let pathPart = line.split(separator: " ").dropFirst().first,
              let q = pathPart.split(separator: "?").dropFirst().first else { return nil }
        for pair in q.split(separator: "&") where pair.hasPrefix("code=") {
            return String(pair.dropFirst(5)).removingPercentEncoding
        }
        return nil
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

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launchPath); p.arguments = args
        try p.run(); p.waitUntilExit(); return p.terminationStatus
    }

    private func inform(_ title: String, _ body: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = body
        a.addButton(withTitle: "OK"); a.runModal()
    }

    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return base64url(Data(bytes))
    }
    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

/// Thread-safe one-shot holder bridging the listener callback to async/await.
private final class CodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var code: String??
    private var cont: CheckedContinuation<String, Error>?

    func resolve(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        if let cont {
            self.cont = nil
            if let value { cont.resume(returning: value) }
            else { cont.resume(throwing: CancellationError()) }
        } else {
            code = .some(value)
        }
    }
    func wait() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            lock.lock(); defer { lock.unlock() }
            if let resolved = code {
                if let v = resolved { c.resume(returning: v) } else { c.resume(throwing: CancellationError()) }
            } else {
                cont = c
            }
        }
    }
}

/// Minimal Keychain wrapper for the OAuth refresh token.
private enum Keychain {
    private static let service = "com.xmas.sandshell.oauth"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
