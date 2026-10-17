import AppKit
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

private struct FolderRow: View {
    let folder: Folder
    @ObservedObject var controller: WorkspaceController
    let requestRemove: () -> Void
    let requestTrash: () -> Void
    @State private var name: String

    init(folder: Folder, controller: WorkspaceController,
         requestRemove: @escaping () -> Void, requestTrash: @escaping () -> Void) {
        self.folder = folder
        self.controller = controller
        self.requestRemove = requestRemove
        self.requestTrash = requestTrash
        _name = State(initialValue: Self.leaf(folder))
    }

    /// The renameable last path segment; `renameFolder` keeps the parent.
    private static func leaf(_ folder: Folder) -> String { (folder.relativePath as NSString).lastPathComponent }

    private var parentPrefix: String {
        let parent = (folder.relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent + "/"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.isRoot ? "house" : "folder")
                .foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if folder.isRoot {
                    // The root's name is the workspace folder itself — not renameable.
                    Text(controller.displayName(for: folder))
                } else {
                    HStack(spacing: 0) {
                        if !parentPrefix.isEmpty { Text(parentPrefix).foregroundStyle(.secondary) }
                        TextField("Folder name", text: $name)
                            .textFieldStyle(.plain)
                            .onSubmit(commitRename)
                            .onDisappear(perform: commitRename)
                            .accessibilityIdentifier("folder-name-\(folder.relativePath)")
                    }
                }
                Text(controller.folderURL(for: folder).path)
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            let n = controller.sessions(in: folder.id).count
            Text("^[\(n) session](inflect: true)").font(.caption).foregroundStyle(.secondary)
            Menu("Folder Actions", systemImage: "ellipsis.circle") {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.folderURL(for: folder)])
                }
                if !folder.isRoot {
                    Divider()
                    Button("Remove from Sandshell…", action: requestRemove)
                    Button("Move to Trash…", role: .destructive, action: requestTrash)
                }
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("folder-actions-\(folder.relativePath)")
        }
        // A rename can sanitize the name (e.g. "/" → "-"); show what was applied.
        .onChange(of: folder.relativePath) { _, _ in name = Self.leaf(folder) }
    }

    private func commitRename() {
        do {
            try controller.renameFolder(folder.id, to: name)
        } catch {
            // The move failed (e.g. a folder by that name is already there).
            name = Self.leaf(folder)
            Alerts.inform("Couldn’t rename “\(Self.leaf(folder))”", error.localizedDescription, style: .warning)
            return
        }
        // Reset if rejected without an error (empty, or unchanged once sanitized);
        // onChange covers success.
        if controller.folder(id: folder.id)?.relativePath == folder.relativePath { name = Self.leaf(folder) }
    }
}
