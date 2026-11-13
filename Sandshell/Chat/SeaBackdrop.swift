import SwiftUI

/// The empty chat: the tide line across the pane, what to do next under it,
/// the two together in the middle.
struct SeaBackdrop<Content: View>: View {
    var initialStir: Double?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 20) {
            SeaField(initialStir: initialStir)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
