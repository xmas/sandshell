import SwiftUI

/// The Search window's bottom bar: what's listed, the keyboard hints, and the
/// button that opens the selected result.
struct SearchFooter: View {
    let store: SearchStore
    let onOpenSelected: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            counts.font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text("↑↓ to select · ↩ to open · esc to close")
                .font(.caption).foregroundStyle(.tertiary)
            Button(store.selected?.isLive == false ? "Restore Session" : "Show Session", action: onOpenSelected)
                .disabled(store.selected == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var counts: Text {
        let live = store.liveCount, past = store.pastCount
        return store.matchedQuery.isEmpty
            ? Text("^[\(live) open session](inflect: true), ^[\(past) past conversation](inflect: true) in this workspace")
            : Text("Matches in this workspace: ^[\(live) open session](inflect: true), ^[\(past) past conversation](inflect: true)")
    }
}
