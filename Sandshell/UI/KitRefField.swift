import AppKit
import SwiftUI

/// "Choose Folder…  [kit reference]  Add" — adding a kit (Settings ▸ Kits) or
/// an agent from its kit (Settings ▸ Agents), one row for both.
struct KitRefAddRow: View {
    @Binding var ref: String
    var prompt: String
    var busy = false
    var addID: String?
    var onBrowse: () -> Void
    var onAdd: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Choose Folder…", action: onBrowse).disabled(busy)
            TextField("Kit reference", text: $ref, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { onAdd(ref) }
            if busy { ProgressView().controlSize(.small) }
            Button("Add") { onAdd(ref) }
                .disabled(busy || ref.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier(addID ?? "kit-add")
        }
    }
}

extension NSOpenPanel {
    /// Pick a kit folder or .zip; nil if cancelled.
    @MainActor static func chooseKit(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
