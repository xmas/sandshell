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

        if let loginPath = loginShellPath(), !loginPath.isEmpty {
            dirs.append(contentsOf: loginPath.split(separator: ":").map(String.init))
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
        // Source-form kits (Sandshell's own, a folder or git ref) build in sbx's
        // builder sandbox, not the Mac's Docker engine: Docker Desktop's default
        // builder can't export the OCI image a v3 kit is. Inherited by every sbx
        // call, terminals' included; a value the user set stays.
        setenv("SBX_KIT_BUILDER", "sandbox", 0)
        Log.info(.app, "PATH patched (\(merged.count) dirs)")
    }

    /// Marks where the probe's own output starts: the rc files an interactive
    /// shell sources may print banners or prompts to stdout before it.
    static let envMarker = "__SANDSHELL_ENV__"

    /// What the login shell runs: a marker line, then PATH on its own line.
    static var envProbeScript: String {
        "printf '\\n%s\\n%s\\n' \(envMarker) \"$PATH\""
    }

    /// Ask the user's login shell for its PATH (interactive login shell so
    /// `.zprofile`/`.zshrc` Homebrew shellenv lines are sourced).
    private static func loginShellPath() -> String? {
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

    /// PATH from `envProbeScript`'s output: the line after its marker,
    /// whatever an rc file printed around it. Nil without the marker (the
    /// probe never ran: an rc file exited or exec'd something else).
    static func parseEnvProbe(_ raw: String) -> String? {
        guard let marker = raw.range(of: "\n\(envMarker)\n", options: .backwards) else { return nil }
        let lines = raw[marker.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
        return lines.first.map(String.init) ?? ""
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
