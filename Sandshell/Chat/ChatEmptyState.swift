import SwiftUI

/// An empty chat: a sea of creatures to stir up, over what to do next.
struct ChatEmptyState: View {
    let agent: String
    let folder: String

    var body: some View {
        SeaBackdrop {
            VStack(spacing: 14) {
                Text("What should \(agent) work on?")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("It works in \(folder), inside its sandbox. Type / for commands, @ to mention a file, or drop files here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .accessibilityElement(children: .combine)
        }
    }
}
