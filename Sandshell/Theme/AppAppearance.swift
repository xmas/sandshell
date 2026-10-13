import AppKit
import Combine

/// The **single, global** source of truth for the app's light/dark appearance.
///
/// Light/Dark/System is one setting for all of Sandshell. This object owns it:
/// it sets the process-wide `NSApp.appearance` in exactly one place, observes the
/// system appearance once (so `.system` mode reacts with a single update), and
/// publishes `isDark` — the resolved current state — for everything else to read
/// synchronously (`AppAppearance.shared.isDark`) or observe (`$isDark`). Changing
/// `mode` here flips the whole app; per-window `ThemeController`s just follow.
@MainActor
final class AppAppearance: ObservableObject {
    static let shared = AppAppearance()

    private static let key = "appAppearanceMode"

    /// The global Light/Dark/System setting. Setting it re-applies app-wide.
    @Published var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    /// Whether the app is rendering dark right now — the resolved truth everything
    /// derives from. Read it directly, or observe `$isDark` to react to changes.
    @Published private(set) var isDark = false

    private var systemObserver: NSKeyValueObservation?

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let m = AppearanceMode(rawValue: raw) {
            mode = m
        } else {
            // First run: inherit the legacy per-root default's mode if the user had
            // one, otherwise follow the system.
            mode = ThemeDefaults.legacyMode ?? .system
        }
        // `apply()` touches NSApp; defer to `start()` once the app is up.
    }

    /// Call once at launch (after `NSApp` exists). Applies the chosen appearance
    /// app-wide and begins following the system for `.system` mode.
    func start() {
        apply()
        systemObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.refreshIsDark() }
        }
    }

    /// Set the process-wide appearance — the one place that touches `NSApp.appearance`.
    private func apply() {
        switch mode {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
        refreshIsDark()
    }

    /// Re-derive `isDark`. Cheap and idempotent; the KVO calls it on system flips.
    private func refreshIsDark() {
        let dark: Bool
        switch mode {
        case .light: dark = false
        case .dark: dark = true
        case .system:
            dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        if dark != isDark { isDark = dark }
    }

    /// Authoritative nudge from a view whose `effectiveAppearance` just settled —
    /// sidesteps the launch-time race where an early read returns the wrong scheme.
    func systemAppearanceSettled(_ appearance: NSAppearance) {
        guard mode == .system else { return }
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if dark != isDark { isDark = dark }
    }
}
