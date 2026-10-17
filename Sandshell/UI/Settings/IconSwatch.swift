import SwiftUI

/// An SF Symbol choice in a folder look editor's icon grid.
struct IconSwatch: View {
    let symbol: String; let isSelected: Bool; let tint: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                // Before the background, so its quinary fill is a level of the
                // primary style rather than of this one.
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .background(isSelected ? AnyShapeStyle(Color(NSColor.hex(tint))) : AnyShapeStyle(.quinary),
                            in: .rect(cornerRadius: 7))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
