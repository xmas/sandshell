import Combine
import SwiftUI

/// User colour overrides for the readout. Global, persisted as sRGB hex.
@MainActor
final class ClaudeStatsAppearance: ObservableObject {
    static let shared = ClaudeStatsAppearance()
    private static let key = "claudeStats.colors"
    @Published private(set) var overrides: [ClaudeStatsColorRole: NSColor]

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        var map: [ClaudeStatsColorRole: NSColor] = [:]
        for (k, v) in raw {
            if let role = ClaudeStatsColorRole(rawValue: k), let c = NSColor.fromHex(v) { map[role] = c }
        }
        overrides = map
    }

    func color(_ role: ClaudeStatsColorRole, fallback: NSColor) -> NSColor { overrides[role] ?? fallback }
    func isOverridden(_ role: ClaudeStatsColorRole) -> Bool { overrides[role] != nil }

    /// `nil` clears the override (back to the theme colour).
    func set(_ role: ClaudeStatsColorRole, _ color: NSColor?) {
        if let color { overrides[role] = color } else { overrides.removeValue(forKey: role) }
        persist()
    }
    func resetAll() {
        overrides = [:]
        persist()
    }

    /// `color(_:fallback:)` / `set(_:_:)` as one, for a colour picker's
    /// binding (`$appearance[color: role, fallback: …]`).
    subscript(color role: ClaudeStatsColorRole, fallback fallback: NSColor) -> Color {
        get { Color(nsColor: color(role, fallback: fallback)) }
        set { set(role, NSColor(newValue)) }
    }

    private func persist() {
        var raw: [String: String] = [:]
        for (role, c) in overrides { raw[role.rawValue] = c.hexString }
        UserDefaults.standard.set(raw, forKey: Self.key)
    }
}

private extension NSColor {
    /// `#rrggbb` / `rrggbb` → sRGB colour; nil for anything else (unlike `hex(_:)`).
    static func fromHex(_ hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
