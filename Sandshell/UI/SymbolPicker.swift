import SwiftUI

/// A searchable grid over `SymbolCatalog` for picking any symbol. Bind a symbol
/// name; choosing one selects it and dismisses.
struct SymbolPickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var query = ""

    private let cols = Array(repeating: GridItem(.fixed(42), spacing: 8), count: 8)

    var body: some View {
        let symbols = SymbolCatalog.available(matching: query)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search symbols", text: $query).textFieldStyle(.plain)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(symbols, id: \.self) { s in
                        Button { choose(s) } label: {
                            Label(SymbolCatalog.spokenName(s), systemImage: s)
                                .labelStyle(.iconOnly)
                                .font(.system(size: 18))
                                .frame(width: 42, height: 42)
                                .background(selection == s ? Color.accentColor : Color.secondary.opacity(0.12),
                                            in: .rect(cornerRadius: 8))
                                .overlay {
                                    if differentiateWithoutColor && selection == s {
                                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary, lineWidth: 2)
                                    }
                                }
                                .foregroundStyle(selection == s ? Color.white : Color.primary)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == s ? .isSelected : [])
                    }
                }
                .padding(12)
            }
            .overlay {
                if symbols.isEmpty { ContentUnavailableView.search(text: query.trimmingCharacters(in: .whitespaces)) }
            }
        }
        .frame(width: 470, height: 440)
    }

    private func choose(_ symbol: String) {
        selection = symbol
        dismiss()
    }
}
