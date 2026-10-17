import SwiftUI

/// Inspector ▸ Folders: the workspace's working directories (the folders
/// sessions start in). The flat sidebar has no folder rows, so renaming,
/// removing and adding folders lives here.
struct FoldersPaneView: View {
    @ObservedObject var controller: WorkspaceController
    @State private var pendingRemove: Folder?
    @State private var pendingTrash: Folder?

    var body: some View {
        Form {
            Section {
                ForEach(controller.folders) { folder in
                    FolderRow(folder: folder, controller: controller,
                              requestRemove: { pendingRemove = folder },
                              requestTrash: { pendingTrash = folder })
                }
            } header: {
                HStack {
                    Text("Working Directories")
                    Spacer()
                    Button("New Folder") { controller.addFolder(name: "New Folder") }
                        .accessibilityIdentifier("folders-new")
                    Button("Add Existing…", action: chooseExisting)
                        .accessibilityIdentifier("folders-add-existing")
                }
            } footer: {
                Text("""
                    Sessions start in one of these folders. Renaming moves the directory on disk; \
                    sessions already running keep their old working directory until reopened.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        .confirmationDialog(
            "Remove “\(pendingRemove.map(controller.displayName(for:)) ?? "")” from Sandshell?",
            item: $pendingRemove
        ) { folder in
            Button("Remove", role: .destructive) { controller.hideFolder(folder.id) }
                .accessibilityIdentifier("folders-confirm-remove")
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text(removeMessage(folder))
        }
        .confirmationDialog(
            "Move “\(pendingTrash.map(controller.displayName(for:)) ?? "")” to the Trash?",
            item: $pendingTrash
        ) { folder in
            Button("Move to Trash", role: .destructive) { controller.trashFolder(folder.id) }
                .accessibilityIdentifier("folders-confirm-trash")
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text(trashMessage(folder))
        }
    }

    private func removeMessage(_ folder: Folder) -> LocalizedStringKey {
        let n = controller.sessions(in: folder.id).count
        return n == 0 ? "The directory stays on disk."
            : "Its ^[\(n) session](inflect: true) will be removed from the sidebar. The directory stays on disk."
    }

    private func trashMessage(_ folder: Folder) -> LocalizedStringKey {
        let n = controller.sessions(in: folder.id).count
        return n == 0 ? "The directory and everything in it moves to the Trash."
            : """
              Its ^[\(n) session](inflect: true) will be removed from the sidebar. \
              The directory and everything in it moves to the Trash.
              """
    }

    private func chooseExisting() {
        controller.chooseExistingFolder()
    }
}
