import Foundation

/// Ports sbx-ui's `sync_user_mcp_servers` and `sync_claude_credentials_from_keychain`
/// (projects.rs). Must be called before each session launch so claude inside the
/// container sees the same MCP servers and OAuth tokens as the host claude.
enum ClaudeConfigSync {
    // MARK: - MCP server sync

    /// Additively copy `mcpServers` from the host `~/.claude.json` into the
    /// bind-mounted `~/.claude/.claude.json` that claude inside the container reads
    /// (`$CLAUDE_CONFIG_DIR` = `~/.claude`). Existing sandbox entries are left alone
    /// (honours in-sandbox OAuth state). Native-install fields that confuse the
    /// container's claude are stripped on every sync.
    static func syncMCPServers(home: URL) {
        let hostSrc    = home.appendingPathComponent(".claude.json")
        let bindTarget = home.appendingPathComponent(".claude/.claude.json")

        // Seed the bind target from the host file on first launch.
        if !FileManager.default.fileExists(atPath: bindTarget.path),
           let hostData = try? Data(contentsOf: hostSrc),
           var hostObj = (try? JSONSerialization.jsonObject(with: hostData)) as? [String: Any] {
            strip(nativeKeys: &hostObj)
            write(json: hostObj, to: bindTarget)
        }

        var bindObj: [String: Any] = readJSON(at: bindTarget) ?? [:]
        let hostObj:  [String: Any] = readJSON(at: hostSrc)  ?? [:]

        var dirty = strip(nativeKeys: &bindObj)

        // Remove any stdio/command-based servers or host-local URL servers that
        // were previously synced in by mistake — they can't run inside the container.
        if var bindMCPs = bindObj["mcpServers"] as? [String: Any] {
            let before = bindMCPs.count
            bindMCPs = bindMCPs.filter { _, entry in
                guard let e = entry as? [String: Any],
                      let urlStr = e["url"] as? String else { return false }
                return !isHostLocalURL(urlStr)
            }
            if bindMCPs.count != before { bindObj["mcpServers"] = bindMCPs; dirty = true }
        }

        // Additive MCP merge: add REMOTE (URL-based) servers from the host that
        // aren't in the sandbox yet. Skip stdio/command-based servers — those
        // need to run on the host and are exposed to the container via the sbx
        // gateway (--static-mcp), not by spawning them inside the container.
        let hostMCPs = hostObj["mcpServers"] as? [String: Any] ?? [:]
        if !hostMCPs.isEmpty {
            var bindMCPs = bindObj["mcpServers"] as? [String: Any] ?? [:]
            for (name, entry) in hostMCPs where bindMCPs[name] == nil {
                guard let e = entry as? [String: Any],
                      let urlStr = e["url"] as? String,
                      !isHostLocalURL(urlStr) else { continue }
                bindMCPs[name] = entry
                dirty = true
            }
            bindObj["mcpServers"] = bindMCPs
        }

        if dirty { write(json: bindObj, to: bindTarget) }
    }

    // MARK: - Credentials sync

    /// Bridge the macOS keychain `Claude Code-credentials` entry into the
    /// bind-mounted `~/.claude/.credentials.json`. Merge strategy per entry:
    /// whichever side has the later `expiresAt` wins, so tokens refreshed on
    /// either side propagate without clobbering the fresher one.
    /// Also clears stale `mcp-needs-auth-cache.json` entries for servers we
    /// just provided tokens for (removes the "needs authentication" badge).
    static func syncCredentialsFromKeychain(home: URL) {
        guard let blob = keychainCredentials() else { return }
        guard let keychainObj = (try? JSONSerialization.jsonObject(with: Data(blob.utf8))) as? [String: Any]
        else { return }

        let dest = home.appendingPathComponent(".claude/.credentials.json")
        var fileObj: [String: Any] = readJSON(at: dest) ?? [:]

        // claudeAiOauth — single object, take later expiry.
        if let keyOAuth = keychainObj["claudeAiOauth"] {
            let keyExp  = expiresAt(keyOAuth)
            let fileExp = (fileObj["claudeAiOauth"]).flatMap { expiresAt($0) }
            let take: Bool
            switch (keyExp, fileExp) {
            case let (.some(k), .some(f)): take = k >= f
            case (.some, .none):           take = true
            case (.none, _):               take = fileObj["claudeAiOauth"] == nil
            }
            if take { fileObj["claudeAiOauth"] = keyOAuth }
        }

        // mcpOAuth — per-server, same expiry rule.
        if let keyMCP = keychainObj["mcpOAuth"] as? [String: Any] {
            var fileMCP = fileObj["mcpOAuth"] as? [String: Any] ?? [:]
            for (name, keyEntry) in keyMCP {
                let keyExp  = expiresAt(keyEntry)
                let fileExp = fileMCP[name].flatMap { expiresAt($0) }
                let take: Bool
                switch (keyExp, fileExp) {
                case let (.some(k), .some(f)): take = k >= f
                case (.some, .none):           take = true
                case (.none, _):               take = fileMCP[name] == nil
                }
                if take { fileMCP[name] = keyEntry }
            }
            fileObj["mcpOAuth"] = fileMCP
        }

        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        write(json: fileObj, to: dest)
        // Match host permissions (0600).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)

        // Clear stale "needs-auth" cache entries for servers we just provided tokens
        // for — removes the warning badge in claude's MCP picker.
        clearNeedsAuthCache(home: home, fileObj: fileObj)
    }

    // MARK: - Private helpers

    private static let nativeInstallKeys = [
        "installMethod", "nativeInstallPath", "autoUpdaterStatus",
        "autoUpdatesProtectedForNative", "autoUpdates", "installLocation",
    ]

    @discardableResult
    private static func strip(nativeKeys obj: inout [String: Any]) -> Bool {
        var changed = false
        for k in nativeInstallKeys where obj.removeValue(forKey: k) != nil { changed = true }
        return changed
    }

    private static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func write(json obj: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func expiresAt(_ v: Any) -> Int64? {
        (v as? [String: Any])?["expiresAt"] as? Int64
    }

    private static func keychainCredentials() -> String? {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials",
                          "-a", user, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Returns true for URLs that are only reachable on the host (loopback or
    /// docker host bridge). These must not be synced into the container config —
    /// the sbx gateway is already exposed via `mcp-gateway.docker.internal` by
    /// `--static-mcp`, so host-local gateway entries are both broken and redundant.
    private static func isHostLocalURL(_ urlStr: String) -> Bool {
        guard let host = URL(string: urlStr)?.host else { return false }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "host.docker.internal"
    }

    private static func clearNeedsAuthCache(home: URL, fileObj: [String: Any]) {
        let cachePath = home.appendingPathComponent(".claude/mcp-needs-auth-cache.json")
        guard FileManager.default.fileExists(atPath: cachePath.path),
              var cache = readJSON(at: cachePath) else { return }
        let mcpKeys = (fileObj["mcpOAuth"] as? [String: Any]).map { Array($0.keys) } ?? []
        let authedNames = Set(mcpKeys.map { $0.split(separator: "|").first.map(String.init) ?? $0 })
        let toRemove = cache.keys.filter { name in
            guard let entry = cache[name] as? [String: Any] else { return false }
            return entry["id"] == nil && authedNames.contains(name)
        }
        guard !toRemove.isEmpty else { return }
        for k in toRemove { cache.removeValue(forKey: k) }
        write(json: cache, to: cachePath)
    }
}
