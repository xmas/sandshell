import AppKit
import SwiftUI

struct FolderRow: View {
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
