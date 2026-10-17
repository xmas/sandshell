import SwiftUI

/// A pane that isn't built yet.
struct StubPaneView: View {
    let title: String
    let symbol: String
    let note: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(note))
            .frame(width: InspectorMetrics.paneWidth, height: 320)
    }
}
