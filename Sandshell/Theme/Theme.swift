import AppKit
import SwiftUI

/// How the app picks its light/dark appearance. This is a single **global**
/// setting for all of Sandshell, owned by `AppAppearance`.
enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

/// Terminal cursor shape. `theme` defers to the engine/theme default (block).
enum CursorStyleSetting: String, Codable, CaseIterable, Identifiable {
    case theme, block, bar, underline
    var id: String { rawValue }
    var label: String {
        switch self {
        case .theme: "Theme"
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        }
    }
}

/// Terminal cursor blink. `theme` defers to the engine/theme default.
enum CursorBlinkSetting: String, Codable, CaseIterable, Identifiable {
    case theme, on, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .theme: "Theme"
        case .on: "On"
        case .off: "Off"
        }
    }
}

/// Whether the terminal follows the global app appearance or is forced to one
/// scheme (so a terminal can stay dark while the rest of the app is light).
enum TerminalAppearanceMode: String, Codable, CaseIterable, Identifiable {
    case followApp, forceLight, forceDark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .followApp: "Follow System"
        case .forceLight: "Force Light"
        case .forceDark: "Force Dark"
        }
    }
}

/// The full set of color tokens the chrome + terminal are themed from. Mirrors
/// the design handoff's light/dark base palettes (`design_handoff_sandshell_gui`).
struct ThemeColors {
    var isDark: Bool
    // Chrome
    var windowBackground: NSColor
    var panel: NSColor          // detail/content background
    var titleBar: NSColor       // window top bar (usually == panel; differs when Main matches the terminal)
    var sidebar: NSColor
    var sidebarFg: NSColor
    var sidebarMuted: NSColor
    var sidebarHover: NSColor
    var selection: NSColor
    var text: NSColor
    var text2: NSColor
    var text3: NSColor
    var border: NSColor
    var hover: NSColor
    var accent: NSColor        // action / control accent
    var accentFg: NSColor
    var key: NSColor           // brand / key color (app mark, emphasis)
    // Terminal
    var termBg: NSColor
    var termText: NSColor
    var termDim: NSColor
    var termAccent: NSColor
    var termGreen: NSColor
    var termRed: NSColor

    /// Apply vibrancy (saturation) to all color tokens.
    mutating func applyVibrancy(_ factor: Double) {
        guard factor != 1.0 else { return }
        windowBackground = windowBackground.withSaturation(factor)
        panel = panel.withSaturation(factor)
        titleBar = titleBar.withSaturation(factor)
        sidebar = sidebar.withSaturation(factor)
        sidebarHover = sidebarHover.withSaturation(factor)
        selection = selection.withSaturation(factor)
        hover = hover.withSaturation(factor)
        accent = accent.withSaturation(factor)
        key = key.withSaturation(factor)
        termBg = termBg.withSaturation(factor)
        termAccent = termAccent.withSaturation(factor)
        termGreen = termGreen.withSaturation(factor)
        termRed = termRed.withSaturation(factor)
    }

    /// Light base ("Daylight").
    static let lightBase = ThemeColors(
        isDark: false,
        windowBackground: .hex("eef0f4"), panel: .hex("ffffff"), titleBar: .hex("ffffff"), sidebar: .hex("ffffff"),
        sidebarFg: .hex("1a1d24"), sidebarMuted: .hex("8b91a0"), sidebarHover: .hex("f2f3f7"),
        selection: .hex("e7eefe"), text: .hex("1a1d24"), text2: .hex("5b6170"), text3: .hex("9aa1ad"),
        border: .hex("e7e9ef"), hover: .hex("f4f5f8"), accent: .hex("1d63ed"), accentFg: .hex("ffffff"),
        key: .hex("1d63ed"),
        termBg: .hex("f7f8fb"), termText: .hex("1f2430"), termDim: .hex("9098a6"),
        termAccent: .hex("1d63ed"), termGreen: .hex("1a7f4b"), termRed: .hex("c0392b"))

    /// Dark base ("Midnight").
    static let darkBase = ThemeColors(
        isDark: true,
        windowBackground: .hex("0c0d11"), panel: .hex("0c0d11"), titleBar: .hex("0c0d11"), sidebar: .hex("0f1116"),
        sidebarFg: .hex("e6e8ee"), sidebarMuted: .hex("7a8190"), sidebarHover: .white(0.06),
        selection: NSColor(srgbRed: 79/255, green: 139/255, blue: 255/255, alpha: 0.18),
        text: .hex("e6e8ee"), text2: .hex("9aa1ad"), text3: .hex("6b7280"),
        border: .white(0.08), hover: .white(0.05), accent: .hex("4f8bff"), accentFg: .hex("ffffff"),
        key: .hex("4f8bff"),
        termBg: .hex("15171d"), termText: .hex("cdd3dc"), termDim: .hex("6b7480"),
        termAccent: .hex("6ea0ff"), termGreen: .hex("46c08a"), termRed: .hex("ff7b72"))

    static func base(dark: Bool) -> ThemeColors { dark ? darkBase : lightBase }
}

/// Persisted appearance preferences (app-global). Key + accent are kept
/// separately for light and dark per the user's requirement.
struct ThemePreferences: Codable, Equatable {
    // Default look ("Workspace"): light detail/terminal with a dark slate sidebar.
    // (Light/Dark/System is global — see `AppAppearance` — and no longer here.)
    var lightKeyHex = "1d63ed"
    var lightAccentHex = "1d63ed"
    var darkKeyHex = "4f8bff"
    var darkAccentHex = "4f8bff"
    /// Keep the sidebar dark even when the rest of the app is light (default on).
    var sidebarAlwaysDark = true
    /// Per-scheme sidebar background + app (detail) background.
    var lightSidebarHex = "ffffff"
    var darkSidebarHex = "27334d"   // msdgcNavy deep
    var lightBackgroundHex = "ffffff"
    var darkBackgroundHex = "0c0d11"
    /// Selected terminal theme preset name, or `TerminalThemes.customName`.
    var terminalThemeName = "Sandshell"
    /// Hand-edited palettes (only consulted when `terminalThemeName == "Custom"`).
    var customTerminalLight: TerminalPalette?
    var customTerminalDark: TerminalPalette?
    /// Terminal cursor + per-terminal appearance override.
    var terminalCursorStyle: CursorStyleSetting = .theme
    var terminalCursorBlink: CursorBlinkSetting = .theme
    var terminalMode: TerminalAppearanceMode = .followApp
    /// The Main (detail) background as an icon-color *hue* from `RootProfile.colors`.
    /// Its lightness follows the global appearance (tint in light mode, dark in dark mode).
    var mainColorHex = "6389de"     // msdgcNavy bright
    /// When set, the Main background follows the terminal theme and only the
    /// window's top bar takes the selected Main color.
    var mainMatchTerminal = false
    /// Vibrancy (saturation) of the detail pane (0.0 = gray, 1.0 = normal, 2.0 = oversaturated).
    var detailVibrancy: Double = 1.0
    /// Vibrancy (saturation) of the sidebar (0.0 = gray, 1.0 = normal, 2.0 = oversaturated).
    var sidebarVibrancy: Double = 1.0

    init() {}

    // Tolerant decoding: fields added after the first release must default when
    // absent so we don't discard a user's saved key/accent on upgrade.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lightKeyHex = try c.decodeIfPresent(String.self, forKey: .lightKeyHex) ?? "1d63ed"
        lightAccentHex = try c.decodeIfPresent(String.self, forKey: .lightAccentHex) ?? "1d63ed"
        darkKeyHex = try c.decodeIfPresent(String.self, forKey: .darkKeyHex) ?? "4f8bff"
        darkAccentHex = try c.decodeIfPresent(String.self, forKey: .darkAccentHex) ?? "4f8bff"
        sidebarAlwaysDark = try c.decodeIfPresent(Bool.self, forKey: .sidebarAlwaysDark) ?? true
        lightSidebarHex = try c.decodeIfPresent(String.self, forKey: .lightSidebarHex) ?? "ffffff"
        darkSidebarHex = try c.decodeIfPresent(String.self, forKey: .darkSidebarHex) ?? "222b3d"
        lightBackgroundHex = try c.decodeIfPresent(String.self, forKey: .lightBackgroundHex) ?? "ffffff"
        darkBackgroundHex = try c.decodeIfPresent(String.self, forKey: .darkBackgroundHex) ?? "0c0d11"
        terminalThemeName = try c.decodeIfPresent(String.self, forKey: .terminalThemeName) ?? "Sandshell"
        customTerminalLight = try c.decodeIfPresent(TerminalPalette.self, forKey: .customTerminalLight)
        customTerminalDark = try c.decodeIfPresent(TerminalPalette.self, forKey: .customTerminalDark)
        terminalCursorStyle = try c.decodeIfPresent(CursorStyleSetting.self, forKey: .terminalCursorStyle) ?? .theme
        terminalCursorBlink = try c.decodeIfPresent(CursorBlinkSetting.self, forKey: .terminalCursorBlink) ?? .theme
        terminalMode = try c.decodeIfPresent(TerminalAppearanceMode.self, forKey: .terminalMode) ?? .followApp
        mainColorHex = try c.decodeIfPresent(String.self, forKey: .mainColorHex) ?? "1d63ed"
        mainMatchTerminal = try c.decodeIfPresent(Bool.self, forKey: .mainMatchTerminal) ?? false
        detailVibrancy = try c.decodeIfPresent(Double.self, forKey: .detailVibrancy) ?? 1.0
        sidebarVibrancy = try c.decodeIfPresent(Double.self, forKey: .sidebarVibrancy) ?? 1.0
    }
}

// MARK: - NSColor helpers

extension NSColor {
    /// sRGB color from a `RRGGBB` (or `#RRGGBB`) hex string.
    static func hex(_ hex: String) -> NSColor {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = Scanner(string: s).scanUInt64(representation: .hexadecimal) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

    /// `RRGGBB` hex of the color in sRGB (no leading `#`).
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02x%02x%02x",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    /// Adjust saturation by a factor (0 = grayscale, 1 = normal, 2 = double saturation).
    func withSaturation(_ factor: Double) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newS = min(1.0, s * factor)
        return NSColor(hue: h, saturation: newS, brightness: b, alpha: a)
    }
}

// MARK: - Type scale

/// The app's type roles. Every font in the chrome comes from one of these;
/// this file is the only place that names a point size. Weight means state
/// (unread, emphasized) and colour means status, so there are two weights.
enum TypeRole: CaseIterable, Sendable {
    /// 15 pt semibold: sidebar and window titles, section heads.
    case title
    /// 13 pt: names, menu items, buttons, the composer, chat prose.
    case body
    /// 13 pt semibold: an unread name, selected emphasis.
    case bodyEmphasis
    /// 11.5 pt: sublines, crumbs, timestamps, captions, toolbar labels.
    case meta
    /// 11 pt SF Mono: paths, branches, diff counts, timers, token and cost readouts.
    case code

    var pointSize: CGFloat {
        switch self {
        case .title: 15
        case .body, .bodyEmphasis: 13
        case .meta: 11.5
        case .code: 11
        }
    }

    var weight: NSFont.Weight {
        switch self {
        case .title, .bodyEmphasis: .semibold
        case .body, .meta, .code: .regular
        }
    }

    /// An SF Symbol beside text of this role: 16 pt in body contexts, 12 pt in meta ones.
    var symbolPointSize: CGFloat {
        switch self {
        case .title, .body, .bodyEmphasis: 16
        case .meta, .code: 12
        }
    }
}

extension NSFont {
    static func role(_ role: TypeRole) -> NSFont { self.role(role, weight: role.weight) }

    /// A role at another weight — semibold for emphasis, medium only where a
    /// status word needs it.
    static func role(_ role: TypeRole, weight: NSFont.Weight) -> NSFont {
        role == .code ? .monospacedSystemFont(ofSize: role.pointSize, weight: weight)
            : .systemFont(ofSize: role.pointSize, weight: weight)
    }

    /// An invisible line's font: only its height counts (the transcript's spacer lines).
    static func spacer(_ height: CGFloat) -> NSFont { .systemFont(ofSize: height) }

    /// Letters drawn as part of a graphic and scaled with it — a badge's glyph,
    /// a theme preview's miniature — not type.
    static func mark(_ size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSFont {
        monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    static func role(_ role: TypeRole) -> Font { Font(NSFont.role(role) as CTFont) }
    static func role(_ role: TypeRole, weight: NSFont.Weight) -> Font { Font(NSFont.role(role, weight: weight) as CTFont) }
    static func mark(_ size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> Font {
        Font(NSFont.mark(size, weight: weight, monospaced: monospaced) as CTFont)
    }

    /// An SF Symbol sized for text of this role.
    static func symbol(_ role: TypeRole, weight: Font.Weight = .regular) -> Font {
        .system(size: role.symbolPointSize, weight: weight)
    }
}

extension NSImage.SymbolConfiguration {
    /// An SF Symbol sized for text of this role.
    static func role(_ role: TypeRole, weight: NSFont.Weight = .regular) -> NSImage.SymbolConfiguration {
        .init(pointSize: role.symbolPointSize, weight: weight)
    }
}
