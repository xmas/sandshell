import SwiftUI

/// General ▸ This Folder: the folder's badge and path, and whether it's the
/// one opened at launch.
struct ThisFolderSection: View {
    @ObservedObject var controller: WorkspaceController
    /// Whether this folder is the one opened at launch when no windows are
    /// restored (the app-global `RootFolderStore.defaultPath`).
    @State private var opensAtLaunch: Bool

    init(controller: WorkspaceController) {
        self.controller = controller
        let current = RootFolderStore.standardize(controller.rootURL.path)
        _opensAtLaunch = State(initialValue: RootFolderStore.defaultPath == current)
    }

    private var editing: RootProfile { controller.rootProfile }
    private var currentPath: String { RootFolderStore.standardize(controller.rootURL.path) }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                BadgeMark(color: .hex(editing.colorHex), content: .symbol(editing.icon), side: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(editing.name).font(.role(.title))
                    Text(controller.rootURL.path).font(.role(.code))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Toggle("Open this folder at launch", isOn: $opensAtLaunch)
                .onChange(of: opensAtLaunch) { _, on in setOpensAtLaunch(on) }
                .accessibilityIdentifier("general-open-at-launch")
        } header: {
            Text("This Folder")
        } footer: {
            Text("Used only when Sandshell has no windows to restore at launch. "
                 + "Other folders live in the Open Workspace browser (⌘O).")
                .font(.role(.meta)).foregroundStyle(.secondary)
        }
    }

    /// Make this folder the one opened at launch, or stop it being that one
    /// (leaving another folder's choice alone).
    private func setOpensAtLaunch(_ on: Bool) {
        if on {
            RootFolderStore.defaultPath = currentPath
        } else if RootFolderStore.defaultPath == currentPath {
            RootFolderStore.defaultPath = nil
        }
    }
}
