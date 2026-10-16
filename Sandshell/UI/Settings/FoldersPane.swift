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
                Text("Sessions start in one of these folders. Renaming moves the directory on disk; "
                     + "sessions already running keep their old working directory until reopened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        .confirmationDialog(
            "Remove “\(pendingRemove.map(controller.displayName(for:)) ?? "")” from Sandshell?",
            isPresented: Binding(get: { pendingRemove != nil },
                                 set: { if !$0 { pendingRemove = nil } }),
            presenting: pendingRemove
        ) { folder in
            Button("Remove", role: .destructive) { controller.hideFolder(folder.id); pendingRemove = nil }
                .accessibilityIdentifier("folders-confirm-remove")
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { folder in
            Text(sessionImpact(folder) + "The directory stays on disk.")
        }
        .confirmationDialog(
            "Move “\(pendingTrash.map(controller.displayName(for:)) ?? "")” to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil },
                                 set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { folder in
            Button("Move to Trash", role: .destructive) { controller.trashFolder(folder.id); pendingTrash = nil }
                .accessibilityIdentifier("folders-confirm-trash")
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: { folder in
            Text(sessionImpact(folder) + "The directory and everything in it moves to the Trash.")
        }
    }

    private func sessionImpact(_ folder: Folder) -> String {
        let n = controller.sessions(in: folder.id).count
        return n == 0 ? "" : "Its \(n) session\(n == 1 ? "" : "s") will be removed from the sidebar. "
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
                    Text(controller.displayName(for: folder)).fontWeight(.medium)
                } else {
                    HStack(spacing: 0) {
                        if !parentPrefix.isEmpty { Text(parentPrefix).foregroundStyle(.secondary) }
                        TextField("Folder name", text: $name)
                            .textFieldStyle(.plain).fontWeight(.medium)
                            .onSubmit(commitRename)
                            .onDisappear(perform: commitRename)
                            .accessibilityIdentifier("folder-name-\(folder.relativePath)")
                    }
                }
                Text(controller.folderURL(for: folder).path)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            let n = controller.sessions(in: folder.id).count
            Text(n == 1 ? "1 session" : "\(n) sessions").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.folderURL(for: folder)])
                }
                if !folder.isRoot {
                    Divider()
                    Button("Remove from Sandshell…", action: requestRemove)
                    Button("Move to Trash…", role: .destructive, action: requestTrash)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("folder-actions-\(folder.relativePath)")
        }
        // A rename can sanitize the name (e.g. "/" → "-"); show what was applied.
        .onChange(of: folder.relativePath) { _, _ in name = Self.leaf(folder) }
    }

    private func commitRename() {
        controller.renameFolder(folder.id, to: name)
        // Reset if rejected (empty, or the move failed); onChange covers success.
        if controller.folder(id: folder.id)?.relativePath == folder.relativePath { name = Self.leaf(folder) }
    }
}
