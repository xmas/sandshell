import AppKit
import Combine

/// App-global *default* appearance preferences. New root folders inherit these
/// (and the per-pane "Make Default" button writes here). Stored in UserDefaults
/// under the legacy key so an upgrading user's existing look becomes the default.
@MainActor
enum ThemeDefaults {
    private static let defaultsKey = "themePreferences"

    static var prefs: ThemePreferences {
        get {
            if let data = UserDefaults.standard.data(forKey: defaultsKey),
               let saved = try? JSONDecoder().decode(ThemePreferences.self, from: data) {
                return saved
            }
            return ThemePreferences()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    /// The light/dark/system mode a pre-global-appearance build stored inside the
    /// default prefs, used once to seed `AppAppearance` on upgrade. Read from raw
    /// JSON since `ThemePreferences` no longer has a `mode` field.
    static var legacyMode: AppearanceMode? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["mode"] as? String else { return nil }
        return AppearanceMode(rawValue: raw)
    }
}

/// Per-window appearance controller: resolves the effective light/dark palette
/// for one workspace, follows the system when asked, persists preferences back
/// to that workspace's `config.json` (via `persist`), and publishes `colors`
/// for the chrome/terminal of *its* window to observe. One per `WorkspaceController`.
@MainActor
final class ThemeController: ObservableObject {
    @Committed var prefs: ThemePreferences {
        didSet { guard prefs != oldValue else { return }; persist?(prefs); apply() }
    }
    @Committed private(set) var colors: ThemeColors = .lightBase
    /// The sidebar is themed independently (it can be forced dark while the rest
    /// of the app is light), so it gets its own resolved palette.
    @Committed private(set) var sidebarColors: ThemeColors = .lightBase

    /// Persist changed prefs (set by the owner → writes this workspace's config).
    var persist: ((ThemePreferences) -> Void)?

    private var appearanceObserver: AnyCancellable?

    init(prefs: ThemePreferences) {
        self.prefs = prefs
        resolve(mainDark: AppAppearance.shared.isDark)
        // Follow the one global appearance source — when it flips light/dark, every
        // window's palette re-resolves from the same place.
        appearanceObserver = AppAppearance.shared.$isDark
            .removeDuplicates()
            .sink { [weak self] dark in self?.resolve(mainDark: dark) }
    }

    /// Re-resolve after a local prefs change (colors, terminal mode, etc.). The
    /// global light/dark state is read from `AppAppearance`.
    private func apply() { resolve(mainDark: AppAppearance.shared.isDark) }

    /// Resolve both palettes. The sidebar can be forced dark independently.
    private func resolve(mainDark: Bool) {
        let sidebarDark = prefs.sidebarAlwaysDark ? true : mainDark
        // Store terminalIsDark first so mainColors() and downstream observers both
        // read a consistent value. (AppAppearance.$isDark publishes in willSet, so
        // AppAppearance.shared.isDark still holds the old value for the entire
        // synchronous Combine chain — mainDark is the only reliable source.)
        terminalIsDark = switch prefs.terminalMode {
        case .followApp: mainDark
        case .forceLight: false
        case .forceDark: true
        }
        colors = mainColors(dark: mainDark)
        sidebarColors = sidebarPalette(dark: sidebarDark)
    }

    private func mainColors(dark: Bool) -> ThemeColors {
        var c = ThemeColors.base(dark: dark)
        c.key = .hex(dark ? prefs.darkKeyHex : prefs.lightKeyHex)
        c.accent = .hex(dark ? prefs.darkAccentHex : prefs.lightAccentHex)
        c.termAccent = c.accent
        // Terminal colors come from the selected terminal theme so the chrome
        // shares the terminal's exact background/foreground. Use the terminal's
        // own resolved scheme (which may be force-light/dark) so the frame behind
        // the surface matches the terminal even when it diverges from the app.
        let pal = terminalIsDark ? terminalPalettes().dark : terminalPalettes().light
        c.termBg = pal.bgColor
        // Main background: the selected icon hue as a faint tint — always light in
        // light mode, dark in dark mode. The title bar wears a stronger accent of
        // the same hue so it reads as the chosen color. When "match terminal" is
        // on, the detail background follows the terminal theme instead.
        let mainTint: NSColor = .hex(RootProfile.mainTone(forIcon: prefs.mainColorHex, dark: dark))
        c.titleBar = .hex(RootProfile.mainBarTone(forIcon: prefs.mainColorHex, dark: dark))
        c.panel = prefs.mainMatchTerminal ? pal.bgColor : mainTint
        c.termText = pal.fgColor
        c.termDim = pal.dimColor
        c.termGreen = pal.greenColor
        c.termRed = pal.redColor
        c.applyVibrancy(prefs.detailVibrancy)
        return c
    }

    private func sidebarPalette(dark: Bool) -> ThemeColors {
        var c = ThemeColors.base(dark: dark)
        c.key = .hex(dark ? prefs.darkKeyHex : prefs.lightKeyHex)
        c.accent = .hex(dark ? prefs.darkAccentHex : prefs.lightAccentHex)
        c.sidebar = .hex(dark ? prefs.darkSidebarHex : prefs.lightSidebarHex)
        c.applyVibrancy(prefs.sidebarVibrancy)
        return c
    }

    // MARK: - Terminal theme

    /// Whether the terminal should render in its dark variant right now. Follows
    /// the global app appearance unless this workspace forces light/dark.
    /// Stored (not computed) so it reflects the value from the most recent
    /// resolve() call — safe to read inside the $colors Combine chain.
    private(set) var terminalIsDark: Bool = false

    /// The light + dark palettes for the selected terminal theme (preset or the
    /// user's custom colors).
    func terminalPalettes() -> (light: TerminalPalette, dark: TerminalPalette) {
        if prefs.terminalThemeName == TerminalThemes.customName {
            let fallback = TerminalThemes.sandshell
            return (prefs.customTerminalLight ?? fallback.light,
                    prefs.customTerminalDark ?? fallback.dark)
        }
        let preset = TerminalThemes.preset(named: prefs.terminalThemeName) ?? TerminalThemes.sandshell
        return (preset.light, preset.dark)
    }
}
