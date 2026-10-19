import AppKit

/// The title bar's and the Files sidebar's colours, derived from a window's
/// resolved palette so every theme (and dark mode) gets its own: the design's
/// values are the default light theme's — a sidebar a step between the title
/// bar and the panes, hairlines a shade darker than the title bar, a white pill.
extension ThemeColors {
    /// The Files sidebar's background: halfway from the title bar to the panes.
    var filesSidebar: NSColor { mix(titleBar, panel, 0.5) }

    /// Chrome hairlines: the Files sidebar's leading edge and header rule, the
    /// Sandbox pill's border. A shade off the title bar toward the text.
    var chromeLine: NSColor { mix(titleBar, text, isDark ? 0.16 : 0.08) }

    /// Lines inside a control (between the Sandbox pill's segments): lighter.
    var chromeInnerLine: NSColor { mix(titleBar, text, isDark ? 0.10 : 0.04) }

    /// The Sandbox pill's fill: white on a light title bar, a lifted title-bar
    /// tone on a dark one.
    var pillFill: NSColor { isDark ? mix(titleBar, .white, 0.07) : .white }

    /// The Sandbox pill's label segment: a tint between the pill and the bar.
    var pillLabelFill: NSColor { isDark ? mix(titleBar, .white, 0.03) : mix(titleBar, .white, 0.6) }

    /// A pressed / on toolbar button (the Files toggle while Files shows).
    var chromePressed: NSColor { text.withAlphaComponent(isDark ? 0.14 : 0.08) }

    /// A hovered toolbar button.
    var chromeHover: NSColor { text.withAlphaComponent(isDark ? 0.09 : 0.05) }

    private func mix(_ a: NSColor, _ b: NSColor, _ fraction: CGFloat) -> NSColor {
        (a.usingColorSpace(.sRGB) ?? a).blended(withFraction: fraction, of: b.usingColorSpace(.sRGB) ?? b) ?? a
    }
}
