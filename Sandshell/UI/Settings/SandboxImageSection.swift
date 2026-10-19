import SwiftUI

/// General ▸ Sandbox Image: which template the folder's sandboxes are built
/// from. A Custom image's field is a draft until Return, or until it goes away.
struct SandboxImageSection: View {
    @ObservedObject var controller: WorkspaceController
    /// The Custom field's text; follows the controller when it changes.
    @State private var customImage: String

    init(controller: WorkspaceController) {
        self.controller = controller
        _customImage = State(initialValue: controller.customImage)
    }

    private var imageChannel: Binding<ImageChannel> {
        Binding(get: { controller.imageChannel },
                set: { controller.setImageChannel($0, customImage: customImage) })
    }

    var body: some View {
        Section {
            Picker("Base Image", selection: imageChannel) {
                ForEach(ImageChannel.allCases) { Text($0.displayName).tag($0) }
            }
            .accessibilityIdentifier("general-image-channel")
            // Here rather than on the field, so a change made while it's hidden
            // still reaches the draft.
            .onChange(of: controller.customImage) { _, new in customImage = new }
            if controller.imageChannel == .custom {
                TextField("Custom Image", text: $customImage,
                          prompt: Text("docker/sandbox-templates:claude-code-docker-0.5.0 or any image"))
                    .textFieldStyle(.roundedBorder)
                    .font(.role(.code))
                    .onSubmit(commitCustomImage)
                    // Also commit when Settings closes without Return being pressed.
                    .onDisappear(perform: commitCustomImage)
            }
            if let t = controller.workspace.templateImage(for: controller.primaryAgent) {
                Text("sbx create -t \(t)").font(.role(.code)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !controller.customAgents.isEmpty {
                // `-t` would replace a kit agent's own image (see ImageChannel.templateImage).
                let names = controller.customAgents.map(\.displayName)
                Text("Built-in agents only — kit agents (\(names, format: .list(type: .and))) always run the image from their own kit.")
                    .font(.role(.meta)).foregroundStyle(.secondary)
            }
            HStack {
                Text(controller.isBuilding ? "Rebuilding…" : "Changes apply when a sandbox is (re)built.")
                    .font(.role(.meta)).foregroundStyle(.secondary)
                Spacer()
                Button("Rebuild Sandboxes Now") { controller.rebuildAll() }
                    .disabled(controller.isBuilding)
                    .accessibilityIdentifier("general-rebuild-now")
            }
        } header: {
            Text("Sandbox Image")
        } footer: {
            Text("Stable is Docker’s released template (updated every few weeks — the Claude Code baked into it goes "
                 + "stale, and new models refuse old versions). Nightly is rebuilt every day from Docker’s main branch with "
                 + "the current Claude Code; less tested. Either way the tag is re-pulled on every rebuild.")
                .font(.role(.meta)).foregroundStyle(.secondary)
        }
    }

    /// Send the field's text while Custom is still the channel: picking another
    /// one sent it already, and another window may have changed it since.
    private func commitCustomImage() {
        guard controller.imageChannel == .custom else { return }
        controller.setImageChannel(.custom, customImage: customImage)
    }
}
