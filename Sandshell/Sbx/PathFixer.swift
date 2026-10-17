import Foundation

/// GUI apps launched from Finder/Spotlight inherit a minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so `sbx`, `docker`, and `brew` aren't
/// found. At launch we probe the user's login-shell PATH once and patch the
/// process environment so every subprocess we (and libghostty) spawn inherits
/// it. Mirrors `lib.rs::fix_macos_path` + `sbx.rs::sbx_path_from_login_shell`.
enum PathFixer {
    /// Homebrew + common user bin dirs to guarantee on PATH as a fallback.
    private static let extraDirs = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ]

    /// Run once at startup. Idempotent.
    static func patchProcessPath() {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var dirs: [String] = []

        // Ask the login shell for both PATH and key env vars used by our tools.
        if let (loginPath, extras) = loginShellEnv() {
            if !loginPath.isEmpty {
                dirs.append(contentsOf: loginPath.split(separator: ":").map(String.init))
            }
            for (key, value) in extras where ProcessInfo.processInfo.environment[key] == nil {
                setenv(key, value, 0)   // 0 = don't overwrite if already set
            }
        }
        dirs.append(contentsOf: current.split(separator: ":").map(String.init))

        // Prepend known dirs that may be missing from a sparse login PATH.
        for dir in extraDirs.reversed() where FileManager.default.fileExists(atPath: dir) {
            dirs.insert(dir, at: 0)
        }

        // De-dupe while preserving order.
        var seen = Set<String>()
        let merged = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
        setenv("PATH", merged.joined(separator: ":"), 1)
        unsetenv("MCP_GATEWAY_URL")
        Log.info(.app, "PATH patched (\(merged.count) dirs)")
    }

    /// Extra env vars to import from the login shell alongside PATH.
    static let extraEnvVars = ["SBX_MCP_URL"]

    /// Marks where the probe's own output starts: the rc files an interactive
    /// shell sources may print banners or prompts to stdout before it.
    static let envMarker = "__SANDSHELL_ENV__"

    /// What the login shell runs: a marker line, then PATH and each extra var
    /// on its own line (one `printf`, which repeats its format per argument).
    static var envProbeScript: String {
        let varList = extraEnvVars.map { "\"$\($0)\"" }.joined(separator: " ")
        return "printf '\\n%s\\n' \(envMarker); printf '%s\\n' \"$PATH\" \(varList)"
    }

    /// Ask the user's login shell for PATH and selected extra env vars (interactive
    /// login shell so `.zprofile`/`.zshrc` Homebrew shellenv lines are sourced).
    /// Returns `(path, [key: value])` where `path` is the PATH string and the dict
    /// contains any non-empty values for `extraEnvVars`.
    private static func loginShellEnv() -> (String, [String: String])? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(filePath: shell)
        // `-ilc` for zsh/bash; `-lc` for /bin/sh.
        let flag = (shell.hasSuffix("/sh") || shell == "sh") ? "-lc" : "-ilc"
        proc.arguments = [flag, envProbeScript]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseEnvProbe(raw)
    }

    /// PATH and the non-empty `extraEnvVars` from `envProbeScript`'s output:
    /// the lines after its marker, whatever an rc file printed around them.
    /// Nil without the marker (the probe never ran: an rc file exited or
    /// exec'd something else), so nothing is imported.
    static func parseEnvProbe(_ raw: String) -> (String, [String: String])? {
        guard let marker = raw.range(of: "\n\(envMarker)\n", options: .backwards) else { return nil }
        let lines = raw[marker.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
        let path = lines.first.map(String.init) ?? ""
        var extras: [String: String] = [:]
        for (i, key) in extraEnvVars.enumerated() where i + 1 < lines.count && !lines[i + 1].isEmpty {
            extras[key] = String(lines[i + 1])
        }
        return (path, extras)
    }

    /// Absolute path to the `sbx` binary, resolved against the patched PATH.
    /// Mirrors `sbx.rs::sbx_path` candidate probing.
    static func sbxPath() -> String {
        if let found = which("sbx") { return found }
        let home = URL.homeDirectory
        let candidates = [
            "/opt/homebrew/bin/sbx",
            "/usr/local/bin/sbx",
            home.appending(path: ".docker/sbx/bin/sbx").path(percentEncoded: false),
            home.appending(path: ".local/bin/sbx").path(percentEncoded: false),
            home.appending(path: "bin/sbx").path(percentEncoded: false),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "sbx"
    }

    /// Search `name` in the current (patched) PATH without spawning a subprocess.
    /// Safe to call from any context including SwiftUI view bodies.
    static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let full = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }
}
