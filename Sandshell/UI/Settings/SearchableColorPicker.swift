import SwiftUI

/// A pop-up of named colors with a search field, for the appearance editor.
struct SearchableColorPicker: View {
    /// A color it offers: its hex, and the theme name it's listed under.
    struct Entry: Hashable {
        let hex: String
        let name: String
    }

    let label: String
    let items: [Entry]
    @Binding var selected: String
    @State private var isOpen = false

    private var selectedName: String {
        items.first { $0.hex == selected }?.name ?? selected
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(NSColor.hex(selected))).frame(width: 12, height: 12)
                Text(selectedName).font(.role(.body)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.symbol(.meta)).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        // Which setting it is ("Icon Color"), then the color it's set to.
        .accessibilityLabel(label)
        .accessibilityValue(selectedName)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ColorPickerDropdown(selected: $selected, isOpen: $isOpen, allItems: items)
        }
    }
}

private struct ColorPickerDropdown: View {
    @Binding var selected: String
    @Binding var isOpen: Bool
    let allItems: [SearchableColorPicker.Entry]
    @State private var query = ""

    private var filtered: [SearchableColorPicker.Entry] {
        query.isEmpty ? allItems : allItems.filter { $0.name.localizedStandardContains(query) }
    }

    @ViewBuilder private func rowView(hex: String, name: String) -> some View {
        Button {
            selected = hex
            isOpen = false
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(NSColor.hex(hex))).frame(width: 14, height: 14)
                Text(name).font(.role(.body))
                Spacer()
                if hex == selected {
                    Image(systemName: "checkmark").font(.symbol(.meta)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search…", text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.map { $0.hex }, id: \.self) { hex in
                        rowView(hex: hex, name: allItems.first(where: { $0.hex == hex })?.name ?? "")
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: max(56, min(CGFloat(filtered.count) * 28 + 8, 220)))
        }
        .frame(width: 210)
    }
}
