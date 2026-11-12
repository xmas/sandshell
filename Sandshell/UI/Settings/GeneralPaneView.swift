import SwiftUI

/// Settings ▸ General for **this** workspace only: its folder identity (icon,
/// color, sidebar), whether it opens at launch, primary agent, base image,
/// archive cadence, appearance. Other folders are managed from the Open
/// Workspace browser (⌘O), not here. The controls read the controller, so a
/// change made in another window on the folder shows here too.
struct GeneralPaneView: View {
    @ObservedObject var controller: WorkspaceController
    /// The stepper's minutes. The interval isn't published, so the pane keeps
    /// its own copy and takes another window's change when it next redraws.
    @State private var archiveMinutes: Double
    @AppStorage(ChatSession.keepsRunningKey) private var keepChatsRunning = true
    @AppStorage(StatusMenuController.key) private var menuBarStatus = true
    @State private var keepAwake = KeepAwake.isEnabled

    init(controller: WorkspaceController) {
        self.controller = controller
        _archiveMinutes = State(initialValue: Self.minutes(controller.archiveInterval))
    }

    private var editing: RootProfile { controller.rootProfile }

    private static func minutes(_ interval: TimeInterval) -> Double { (interval / 60).rounded() }

    private var primaryAgent: Binding<AgentKind> {
        Binding(get: { controller.primaryAgent }, set: { controller.setPrimaryAgent($0) })
    }

    var body: some View {
        Form {
            ThisFolderSection(controller: controller)
            Section("Agents") {
                Picker("Primary Agent", selection: primaryAgent) {
                    ForEach(controller.availableAgents) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
            }
            Section {
                Toggle("Keep chats running when Sandshell quits", isOn: $keepChatsRunning)
                Toggle("Keep the Mac awake while agents work", isOn: $keepAwake)
                    .onChange(of: keepAwake) { _, on in KeepAwake.isEnabled = on }
                Toggle("Show agents’ status in the menu bar", isOn: $menuBarStatus)
                    .onChange(of: menuBarStatus) { _, on in StatusMenuController.isEnabled = on }
            } header: {
                Text("While You’re Away")
            } footer: {
                Text("A Claude or Codex chat’s turn finishes in its sandbox after Sandshell quits or its window closes, "
                     + "and the chat picks up where it is when you’re back. These settings are for every folder.")
            }
            SandboxImageSection(controller: controller)
            Section("Archive") {
                Stepper(value: $archiveMinutes, in: 1...240, step: 1) {
                    Text("Auto-archive every \(Int(archiveMinutes)) min")
                }
                .onChange(of: archiveMinutes) { _, new in controller.setArchiveInterval(new * 60) }
                .onChange(of: controller.archiveInterval) { _, new in archiveMinutes = Self.minutes(new) }
            }
            RemoteControlSettingsSection(hub: .shared, devices: .shared)
            Section("Appearance — \(editing.name)") {
                AppearanceEditor(folderName: editing.name,
                                 icon: bind(\.icon), colorHex: bind(\.colorHex),
                                 sidebarHex: bind(\.sidebarHex), theme: controller.theme)
            }
            ThemeScopeButtons(theme: controller.theme)
        }
        .formStyle(.grouped)
        .contentMargins(.bottom, 80, for: .scrollContent)
    }

    /// Edit this folder's look; `updateRootProfile` persists to the registry
    /// and republishes so the sidebar re-renders live.
    private func bind(_ keyPath: WritableKeyPath<RootProfile, String>) -> Binding<String> {
        Binding(
            get: { editing[keyPath: keyPath] },
            set: { newValue in controller.updateRootProfile { $0[keyPath: keyPath] = newValue } })
    }
}
