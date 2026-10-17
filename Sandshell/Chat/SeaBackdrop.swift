import SwiftUI

/// The empty chat: the sea's band above the prompt, the sea itself spread over
/// the whole pane so bubbles never meet an edge.
struct SeaBackdrop<Content: View>: View {
    var initialSplash: CGPoint?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) {
            Color.clear
                .frame(maxWidth: SeaField.size.width)
                .frame(height: SeaField.size.height)
                .anchorPreference(key: SeaBandKey.self, value: .bounds) { $0 }
            content.allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .backgroundPreferenceValue(SeaBandKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor { SeaField(band: proxy[anchor], initialSplash: initialSplash) }
            }
        }
    }
}

/// Where the band sits, for the sea behind it.
private struct SeaBandKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}
