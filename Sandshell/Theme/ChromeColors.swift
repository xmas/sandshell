import AppKit

/// The title bar's and the Files sidebar's colours, derived from a window's
/// resolved palette so every theme (and dark mode) gets its own: the design's
/// values are the default light theme's — a sidebar a step between the title
/// bar and the panes, hairlines a shade darker than the title bar, a white pill.
extension NSColor {
    /// WCAG relative luminance.
    var relativeLuminance: Double {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> Double { v <= 0.03928 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    /// WCAG contrast ratio with `other`.
    func contrast(with other: NSColor) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Text for this color as a background: the theme's, or pure white or
    /// black on a vivid mid-tone, where the theme's softer inks fall short.
    var readableInk: NSColor {
        let ink = ThemeColors.base(dark: prefersLightInk).text
        return contrast(with: ink) >= 4.5 ? ink : prefersLightInk ? .white : .black
    }

    /// Whether light text reads better on this color than dark text does.
    var prefersLightInk: Bool {
        contrast(with: ThemeColors.base(dark: true).text) >= contrast(with: ThemeColors.base(dark: false).text)
    }
}

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
