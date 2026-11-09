import AppKit
import Testing
@testable import Sandshell

/// `NSColor.hex` and `hexString` (Theme/Theme.swift): every color token and
/// saved preference goes through them.
struct ColorHexTests {
    @Test(arguments: ["d97757", "1d63ed", "000000", "ffffff", "0c0d11"])
    func hexRoundTrips(hex: String) {
        #expect(NSColor.hex(hex).hexString == hex)
    }

    @Test func aLeadingHashIsIgnored() {
        #expect(NSColor.hex("#4f8bff").hexString == "4f8bff")
    }

    @Test func uppercaseDigitsRead() {
        #expect(NSColor.hex("D97757").hexString == "d97757")
    }

    @Test(.tags(.edgeCase), arguments: ["", "#", "zz", "not a color"])
    func textThatIsntHexIsBlack(text: String) {
        #expect(NSColor.hex(text).hexString == "000000")
    }

    @Test func colorIsOpaqueSRGB() {
        let color = NSColor.hex("16a34a")
        #expect(color.colorSpace == .sRGB)
        #expect(color.alphaComponent == 1)
    }
}

/// Reading the user's Ghostty theme, from a Ghostty laid out in a temp folder.
struct GhosttyThemeTests {
    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "ghostty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func config(_ home: URL) -> URL { home.appending(path: ".config/ghostty/config") }
    private func theme(_ home: URL, _ name: String) -> URL { home.appending(path: ".config/ghostty/themes/\(name)") }

    @Test func notInstalledIsNothing() throws {
        try withHome { home in
            #expect(GhosttyTheme.load(home: home, xdg: nil, apps: [home.appending(path: "Ghostty.app")]) == nil)
        }
    }

    @Test func lightAndDarkThemesAreEachUsed() throws {
        try withHome { home in
            try write("theme = dark:Night,light:Day\n", config(home))
            try write("background = #111111\nforeground = eeeeee\npalette = 1=#ff0000\n", theme(home, "Night"))
            try write("background = #fafafa\nforeground = #222222\npalette = 1 = #aa0000\n", theme(home, "Day"))
            let got = try #require(GhosttyTheme.load(home: home, xdg: nil, apps: []))
            #expect(got.dark.background == "111111" && got.dark.ansi[1] == "ff0000")
            #expect(got.light.background == "fafafa" && got.light.ansi[1] == "aa0000")
            #expect(got.dark.cursor == "eeeeee", "A theme with no cursor color uses its foreground")
        }
    }

    @Test func oneThemeServesBoth() throws {
        try withHome { home in
            try write("# my config\ntheme = \"Only\"\n", config(home))
            try write("background = #123456\n", theme(home, "Only"))
            let got = try #require(GhosttyTheme.load(home: home, xdg: nil, apps: []))
            #expect(got.light.background == "123456" && got.dark.background == "123456")
        }
    }

    @Test func theConfigsOwnColorsWinOverTheTheme() throws {
        try withHome { home in
            try write("theme = Only\nbackground = #000000\npalette = 3=#abc\n", config(home))
            try write("background = #123456\nforeground = #654321\n", theme(home, "Only"))
            let got = try #require(GhosttyTheme.load(home: home, xdg: nil, apps: []))
            #expect(got.dark.background == "000000" && got.dark.foreground == "654321" && got.dark.ansi[3] == "aabbcc")
        }
    }

    @Test func themesComeFromTheAppToo() throws {
        try withHome { home in
            let app = home.appending(path: "Ghostty.app")
            try write("background = #0a0b0c\n", app.appending(path: "Contents/Resources/ghostty/themes/Bundled"))
            try write("theme = Bundled\n", config(home))
            #expect(GhosttyTheme.load(home: home, xdg: nil, apps: [app])?.dark.background == "0a0b0c")
        }
    }

    @Test func noThemeSetIsGhosttysDefault() throws {
        try withHome { home in
            let app = home.appending(path: "Ghostty.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let got = try #require(GhosttyTheme.load(home: home, xdg: nil, apps: [app]))
            #expect(got.light == TerminalThemes.alabasterAfterglow.light && got.dark == TerminalThemes.alabasterAfterglow.dark)
        }
    }

    @Test func configFileIncludesAreFollowedAndALoopEnds() throws {
        try withHome { home in
            try write("config-file = ?extra\n", config(home))
            try write("background = #010203\nconfig-file = config\n", home.appending(path: ".config/ghostty/extra"))
            #expect(GhosttyTheme.load(home: home, xdg: nil, apps: [])?.dark.background == "010203")
        }
    }

    @Test(arguments: ["#GGGGGG", "red", "#12345", ""])
    func aColorItCantReadIsIgnored(value: String) {
        #expect(GhosttyTheme.hex(value) == nil)
    }

    @Test func anExplicitChoiceStaysWithoutGhostty() {
        var prefs = ThemePreferences()
        prefs.terminalThemeChosen = true
        prefs.terminalThemeName = "Nord"
        #expect(prefs.effectiveTerminalThemeName == "Nord")
    }
}

