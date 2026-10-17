import SwiftUI

/// The colored rounded square with a white mark, in SwiftUI: agents (brand
/// logo, a custom agent's symbol, or its glyph), folders and profiles. One
/// look everywhere — the AppKit `AgentBadgeView` draws the same.
///
/// VoiceOver reads it as one image. A symbol keeps its spoken name; a logo or
/// a glyph has none worth hearing ("eight spoked asterisk"), so where the
/// badge is the only sign of the agent, label it with the agent's name.
struct BadgeMark: View {
    enum Content { case image(NSImage), symbol(String), glyph(String) }
    let color: NSColor
    let content: Content
    var side: Double = 20

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.28)
            .fill(Color(nsColor: color))
            .frame(width: side, height: side)
            .overlay {
                switch content {
                case .image(let image):
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                        .frame(width: side * 0.6, height: side * 0.6).foregroundStyle(.white)
                case .symbol(let name):
                    Image(systemName: name).font(.system(size: side * 0.5, weight: .semibold)).foregroundStyle(.white)
                case .glyph(let text):
                    Text(text).font(.system(size: side * 0.45, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                }
            }
            .accessibilityElement(children: speaksForItself ? .combine : .ignore)
            .accessibilityAddTraits(.isImage)
    }

    private var speaksForItself: Bool {
        switch content {
        case .symbol: true
        case .image, .glyph: false
        }
    }
}

extension AgentKind {
    /// What the agent's badge shows: its logo, else a custom agent's symbol,
    /// else its glyph.
    var badgeContent: BadgeMark.Content {
        if let image = badgeImageName.flatMap({ NSImage(named: $0) }) { return .image(image) }
        if let symbol = customSymbol { return .symbol(symbol) }
        return .glyph(badgeGlyph)
    }
}
