import AppKit
import GhosttyTerminal

/// A full terminal color palette: background, foreground, cursor, selection and
/// the 16 ANSI colors (0–7 normal, 8–15 bright). All values are `RRGGBB` hex.
/// Drives both the live ghostty surface and the surrounding chrome, so the two
/// always share a background.
struct TerminalPalette: Codable, Equatable {
    var background: String
    var foreground: String
    var cursor: String
    var selection: String
    var ansi: [String]   // exactly 16 entries

    /// A ghostty configuration carrying only this palette's colors (no command/
    /// font/keybinds — those live in the base config).
    func ghosttyConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { b in
            b.withBackground(background)
            b.withForeground(foreground)
            b.withCursorColor(cursor)
            b.withSelectionBackground(selection)
            b.withSelectionForeground(foreground)
            for (i, color) in ansi.prefix(16).enumerated() {
                let ghosttyColor = color.hasPrefix("#") ? color : "#\(color)"
                b.withPalette(i, color: ghosttyColor)
            }
        }
    }

    // Chrome-facing accessors (the detail header/frame paint these).
    var bgColor: NSColor { .hex(background) }
    var fgColor: NSColor { .hex(foreground) }
    /// A muted foreground for secondary labels — blended toward the background so
    /// it reads as "dim" regardless of the theme's bright-black choice.
    var dimColor: NSColor { fgColor.blended(withFraction: 0.5, of: bgColor) ?? fgColor }
    var greenColor: NSColor { .hex(ansi.indices.contains(2) ? ansi[2] : "1a7f4b") }
    var redColor: NSColor { .hex(ansi.indices.contains(1) ? ansi[1] : "c0392b") }
}

/// The user's Ghostty theme, read from Ghostty's config: `theme = X` or
/// `theme = dark:X,light:Y`, with the config's own colors on top.
enum GhosttyTheme {
    /// Nil when Ghostty isn't here (and always under tests: never the real home).
    nonisolated(unsafe) private(set) static var current: (light: TerminalPalette, dark: TerminalPalette)? = read()

    static func reload() { current = read() }

    private static func read() -> (light: TerminalPalette, dark: TerminalPalette)? {
        guard !AppDelegate.isHostingTests else { return nil }
        return load(home: FileManager.default.homeDirectoryForCurrentUser,
                    xdg: ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
                    apps: [URL(filePath: "/Applications/Ghostty.app")])
    }

    struct Settings: Equatable {
        var theme: String?
        var background, foreground, cursor, selection: String?
        var palette: [Int: String] = [:]
        var includes: [String] = []
    }

    /// `#abc`, `abc`, `#aabbcc` or `aabbcc`, as `aabbcc`; nil for anything else.
    static func hex(_ value: String) -> String? {
        var s = value.lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        return s.count == 6 ? s : nil
    }

    static func parse(_ text: String) -> Settings {
        var out = Settings()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "theme": out.theme = value
            case "background": out.background = hex(value) ?? out.background
            case "foreground": out.foreground = hex(value) ?? out.foreground
            case "cursor-color": out.cursor = hex(value) ?? out.cursor
            case "selection-background": out.selection = hex(value) ?? out.selection
            case "config-file": out.includes.append(value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let index = Int(parts[0]), (0..<16).contains(index), let color = hex(parts[1]) {
                    out.palette[index] = color
                }
            default: break
            }
        }
        return out
    }

    /// `base` with `later` on top.
    static func merged(_ base: Settings, _ later: Settings) -> Settings {
        var out = later
        out.theme = later.theme ?? base.theme
        out.background = later.background ?? base.background
        out.foreground = later.foreground ?? base.foreground
        out.cursor = later.cursor ?? base.cursor
        out.selection = later.selection ?? base.selection
        out.palette = base.palette.merging(later.palette) { _, new in new }
        return out
    }

    /// The (light, dark) theme names of a `theme` value.
    static func names(_ value: String) -> (light: String, dark: String) {
        var light: String?, dark: String?, plain: String?
        for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.hasPrefix("light:") { light = String(part.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if part.hasPrefix("dark:") { dark = String(part.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            else { plain = part }
        }
        return (light ?? plain ?? dark ?? "", dark ?? plain ?? light ?? "")
    }

    static func palette(_ s: Settings, base: TerminalPalette) -> TerminalPalette {
        var ansi = base.ansi
        for (index, color) in s.palette where ansi.indices.contains(index) { ansi[index] = color }
        return TerminalPalette(background: s.background ?? base.background, foreground: s.foreground ?? base.foreground,
                               cursor: s.cursor ?? s.foreground ?? base.cursor, selection: s.selection ?? base.selection, ansi: ansi)
    }

    /// `file`'s settings with the `config-file`s it names, later ones on top.
    private static func settings(of file: URL, seen: inout Set<String>) -> Settings? {
        guard seen.count < 32, seen.insert(file.standardizedFileURL.path).inserted,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var out = parse(text)
        for var include in out.includes {
            if include.hasPrefix("?") { include.removeFirst() }
            let target = include.hasPrefix("/") ? URL(filePath: include) : file.deletingLastPathComponent().appending(path: include)
            if let more = settings(of: target, seen: &seen) { out = merged(out, more) }
        }
        return out
    }

    static func load(home: URL, xdg: String?, apps: [URL]) -> (light: TerminalPalette, dark: TerminalPalette)? {
        let fm = FileManager.default
        let configHome = xdg.flatMap { $0.isEmpty ? nil : URL(filePath: $0) } ?? home.appending(path: ".config")
        let folders = [configHome.appending(path: "ghostty"), home.appending(path: "Library/Application Support/com.mitchellh.ghostty")]
        let files = folders.flatMap { [$0.appending(path: "config"), $0.appending(path: "config.ghostty")] }
            .filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
        let app = apps.first { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard app != nil || !files.isEmpty else { return nil }
        var config = Settings()
        var seen: Set<String> = []
        for file in files { if let found = settings(of: file, seen: &seen) { config = merged(config, found) } }
        func side(_ name: String?, base: TerminalPalette) -> TerminalPalette {
            var theme = Settings()
            if let name, !name.isEmpty {
                let places = (name.hasPrefix("/") ? [URL(filePath: name)] : folders.map { $0.appending(path: "themes/\(name)") })
                    + (app.map { [$0.appending(path: "Contents/Resources/ghostty/themes/\(name)")] } ?? [])
                if let found = places.first(where: { fm.fileExists(atPath: $0.path(percentEncoded: false)) }),
                   let text = try? String(contentsOf: found, encoding: .utf8) { theme = parse(text) }
            }
            var overrides = config
            overrides.theme = nil
            return palette(merged(theme, overrides), base: base)
        }
        let picked = config.theme.map(names)
        let base = TerminalThemes.alabasterAfterglow   // Ghostty's own default colors
        return (side(picked?.light, base: base.light), side(picked?.dark, base: base.dark))
    }
}

/// A named built-in terminal theme with a light and dark variant.
struct TerminalThemePreset: Identifiable, Equatable {
    let name: String
    let light: TerminalPalette
    let dark: TerminalPalette
    var id: String { name }
}

enum TerminalThemes {
    /// Sentinel name stored in preferences when the user has hand-edited colors.
    static let customName = "Custom"
    /// Whatever theme Ghostty is set to, when it's installed.
    static let ghosttyName = "Ghostty"

    /// All built-in presets, in display order. The first is the default.
    static let presets: [TerminalThemePreset] = [
        sandshell, alabasterAfterglow, solarized, tokyoNight,
        dracula, nord, gruvbox, catppuccin, oneHalf, github,
    ]

    static func preset(named name: String) -> TerminalThemePreset? {
        if name == ghosttyName, let theme = GhosttyTheme.current {
            return TerminalThemePreset(name: ghosttyName, light: theme.light, dark: theme.dark)
        }
        return presets.first { $0.name == name }
    }

    // MARK: Presets

    /// Sandshell — brand palette tuned to the app chrome.
    static let sandshell = TerminalThemePreset(
        name: "Sandshell",
        light: TerminalPalette(
            background: "f7f8fb", foreground: "1f2430", cursor: "1d63ed", selection: "e7eefe",
            ansi: ["1f2430", "c0392b", "1a7f4b", "b8860b", "1d63ed", "8e44ad", "0e7490", "9098a6",
                   "6b7280", "e05a4b", "2aa866", "d4a017", "4f8bff", "a569bd", "22a3c4", "c8cdd6"]),
        dark: TerminalPalette(
            background: "15171d", foreground: "cdd3dc", cursor: "6ea0ff", selection: "2a3550",
            ansi: ["3b414d", "ff7b72", "46c08a", "e3b341", "6ea0ff", "c896ff", "56d4dd", "cdd3dc",
                   "6b7480", "ff9b94", "6fd6a6", "f0c674", "8fb6ff", "d6b3ff", "7ee0e8", "e6e8ee"]))

    /// Alabaster (light) + Afterglow (dark) — libghostty's defaults.
    static let alabasterAfterglow = TerminalThemePreset(
        name: "Alabaster / Afterglow",
        light: TerminalPalette(
            background: "f7f7f7", foreground: "000000", cursor: "007acc", selection: "c9d0d9",
            ansi: ["000000", "aa3731", "448c27", "cb8800", "325cc0", "7a3e9d", "0083b2", "f7f7f7",
                   "777777", "f03e31", "60cb00", "ffbc5d", "007acc", "e64ce6", "00aacb", "f7f7f7"]),
        dark: TerminalPalette(
            background: "212121", foreground: "d0d0d0", cursor: "d0d0d0", selection: "303030",
            ansi: ["151515", "ac4142", "7e8e50", "e4b567", "6c99bb", "9f4e86", "7dd5cf", "d0d0d0",
                   "505050", "ac4142", "7e8e50", "e4b567", "6c99bb", "9f4e86", "7dd5cf", "f5f5f5"]))

    /// Solarized — Ethan Schoonover's classic light + dark.
    static let solarized = TerminalThemePreset(
        name: "Solarized",
        light: TerminalPalette(
            background: "fdf6e3", foreground: "657b83", cursor: "586e75", selection: "eee8d5",
            ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                   "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]),
        dark: TerminalPalette(
            background: "002b36", foreground: "839496", cursor: "93a1a1", selection: "073642",
            ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                   "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]))

    /// Tokyo Night Day (light) + Tokyo Night (dark).
    static let tokyoNight = TerminalThemePreset(
        name: "Tokyo Night",
        light: TerminalPalette(
            background: "e1e2e7", foreground: "3760bf", cursor: "3760bf", selection: "b7c1e3",
            ansi: ["e9e9ed", "f52a65", "587539", "8c6c3e", "2e7de9", "9854f1", "007197", "6172b0",
                   "a1a6c5", "f52a65", "587539", "8c6c3e", "2e7de9", "9854f1", "007197", "3760bf"]),
        dark: TerminalPalette(
            background: "1a1b26", foreground: "c0caf5", cursor: "c0caf5", selection: "33467c",
            ansi: ["15161e", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
                   "414868", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "c0caf5"]))

    // Dark-only aesthetics use the same palette for both schemes (the terminal
    // theme is intentionally independent of the app's light/dark).
    static let dracula = TerminalThemePreset(
        name: "Dracula", light: draculaPalette, dark: draculaPalette)
    private static let draculaPalette = TerminalPalette(
        background: "282a36", foreground: "f8f8f2", cursor: "f8f8f2", selection: "44475a",
        ansi: ["21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
               "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff"])

    static let nord = TerminalThemePreset(
        name: "Nord", light: nordPalette, dark: nordPalette)
    private static let nordPalette = TerminalPalette(
        background: "2e3440", foreground: "d8dee9", cursor: "d8dee9", selection: "434c5e",
        ansi: ["3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
               "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4"])

    /// Gruvbox Light + Dark.
    static let gruvbox = TerminalThemePreset(
        name: "Gruvbox",
        light: TerminalPalette(
            background: "fbf1c7", foreground: "3c3836", cursor: "3c3836", selection: "ebdbb2",
            ansi: ["fbf1c7", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "7c6f64",
                   "928374", "9d0006", "79740e", "b57614", "076678", "8f3f71", "427b58", "3c3836"]),
        dark: TerminalPalette(
            background: "282828", foreground: "ebdbb2", cursor: "ebdbb2", selection: "504945",
            ansi: ["282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
                   "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"]))

    /// Catppuccin Latte (light) + Mocha (dark).
    static let catppuccin = TerminalThemePreset(
        name: "Catppuccin",
        light: TerminalPalette(
            background: "eff1f5", foreground: "4c4f69", cursor: "dc8a78", selection: "ccced7",
            ansi: ["5c5f77", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "acb0be",
                   "6c6f85", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "bcc0cc"]),
        dark: TerminalPalette(
            background: "1e1e2e", foreground: "cdd6f4", cursor: "f5e0dc", selection: "585b70",
            ansi: ["45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "bac2de",
                   "585b70", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8"]))

    /// Atom One Light + Dark.
    static let oneHalf = TerminalThemePreset(
        name: "One",
        light: TerminalPalette(
            background: "fafafa", foreground: "383a42", cursor: "526fff", selection: "e5e5e6",
            ansi: ["383a42", "e45649", "50a14f", "c18401", "4078f2", "a626a4", "0184bc", "a0a1a7",
                   "4f525e", "e45649", "50a14f", "c18401", "4078f2", "a626a4", "0184bc", "383a42"]),
        dark: TerminalPalette(
            background: "282c34", foreground: "abb2bf", cursor: "528bff", selection: "3e4451",
            ansi: ["282c34", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "abb2bf",
                   "545862", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "c8ccd4"]))

    /// GitHub Light + Dark.
    static let github = TerminalThemePreset(
        name: "GitHub",
        light: TerminalPalette(
            background: "ffffff", foreground: "24292f", cursor: "24292f", selection: "b6e3ff",
            ansi: ["24292f", "cf222e", "116329", "4d2d00", "0969da", "8250df", "1b7c83", "6e7781",
                   "57606a", "a40e26", "1a7f37", "633c01", "218bff", "a475f9", "3192aa", "8c959f"]),
        dark: TerminalPalette(
            background: "0d1117", foreground: "c9d1d9", cursor: "c9d1d9", selection: "163356",
            ansi: ["484f58", "ff7b72", "3fb950", "d29922", "58a6ff", "bc8cff", "39c5cf", "b1bac4",
                   "6e7681", "ffa198", "56d364", "e3b341", "79c0ff", "d2a8ff", "56d4dd", "f0f6fc"]))
}
