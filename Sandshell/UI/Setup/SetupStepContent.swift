import SwiftUI

/// The setup wizard's current step: the folder (and whether it's already a
/// workspace), its look, its mounts, or its kits.
struct SetupStepContent: View {
    let step: SetupStep
    let rootPath: String
    let isKnownWorkspace: Bool
    @Binding var icon: String
    @Binding var colorHex: String
    @Binding var sidebarHex: String
    let mountModel: MountConfigModel?
    let kitModel: KitConfigModel?
    let onChooseFolder: () -> Void

    var body: some View {
        switch step {
        case .folder:
            Form {
                Section {
                    HStack(spacing: 8) {
                        Label {
                            Text(rootPath).truncationMode(.middle).lineLimit(1).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "folder")
                        }
                        Spacer()
                        Button("Choose…", action: onChooseFolder)
                    }
                } header: {
                    Text("Folder")
                } footer: {
                    if isKnownWorkspace {
                        Text("This folder is already a Sandshell workspace — Next opens it with its saved look, mounts, and kits.")
                            .font(.role(.meta)).foregroundStyle(.secondary)
                    } else {
                        Text("Your work happens here; it's mounted into the sandbox. You can change its look, mounts, and kits in the next steps.")
                            .font(.role(.meta)).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        case .look:
            Form { Section("Look") { FolderLookEditor(icon: $icon, colorHex: $colorHex, sidebarHex: $sidebarHex) } }
                .formStyle(.grouped)
        case .mounts:
            if let mountModel {
                MountConfigView(model: mountModel, confirmTitle: "", confirmInfo: "",
                                onConfirm: { _ in }, onCancel: {}, embedded: true)
            }
        case .kits:
            if let kitModel {
                KitConfigView(model: kitModel, embedded: true)
            }
        }
    }
}
