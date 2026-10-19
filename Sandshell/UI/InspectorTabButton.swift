import SwiftUI

/// One tab in the inspector strip: a tinted rounded-square icon + label, with a
/// full selection highlight behind the selected tab (matches the Settings look).
struct InspectorTabButton: View {
    let pane: InspectorPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(pane.color)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: pane.symbol)
                            .font(.mark(13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Text(pane.title).font(.role(.meta))

                    .foregroundStyle(.primary).lineLimit(1)
            }
            .frame(width: 70)
            .padding(.vertical, 5)
            .background(isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear,
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("inspector-tab-\(pane.rawValue)")
    }
}
