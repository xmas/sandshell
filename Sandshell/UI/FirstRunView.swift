import AppKit
import SwiftUI

/// The setup steps shown for a new workspace.
enum SetupStep: Int, CaseIterable {
    case folder, look, mounts, kits
    var title: String {
        switch self {
        case .folder: return "Folder"
        case .look: return "Look"
        case .mounts: return "Mounts"
        case .kits: return "Kits"
        }
    }
}

/// Multi-step new-workspace wizard, used for both the first-launch Welcome
/// (`welcome: true`, adds the intro + a "Default" shortcut) and Open Folder.
/// Steps: choose the folder, its look, mounts, and kits.
struct SetupWizardView: View {
    let welcome: Bool
    let onCreate: (URL, RootProfile, MountPolicy, [String]) -> Void
    let onDefault: () -> Void
    let onCancel: () -> Void
    /// The chosen folder is a workspace the app already knows — open it like any
    /// other existing workspace instead of walking through look/mounts/kits.
    let onOpenExisting: (URL) -> Void

    @State private var step: SetupStep = .folder
    @State private var rootPath: String
    @State private var icon: String
    @State private var colorHex: String
    @State private var sidebarHex: String
    @State private var mountModel: MountConfigModel?
    @State private var kitModel: KitConfigModel?

    private let home = FileManager.default.homeDirectoryForCurrentUser

    init(welcome: Bool, defaultRoot: URL,
         onCreate: @escaping (URL, RootProfile, MountPolicy, [String]) -> Void,
         onDefault: @escaping () -> Void = {},
         onCancel: @escaping () -> Void = {},
         onOpenExisting: @escaping (URL) -> Void = { _ in }) {
        self.welcome = welcome
        self.onCreate = onCreate
        self.onDefault = onDefault
        self.onCancel = onCancel
        self.onOpenExisting = onOpenExisting
        let p = RootProfile.makeDefault(path: defaultRoot.path)
        _rootPath = State(initialValue: defaultRoot.path)
        _icon = State(initialValue: p.icon)
        _colorHex = State(initialValue: p.colorHex)
        _sidebarHex = State(initialValue: p.sidebarHex)
    }

    private var rootURL: URL { URL(fileURLWithPath: rootPath) }
    private var profile: RootProfile {
        RootProfile(path: rootURL.path, icon: icon, colorHex: colorHex, sidebarHex: sidebarHex)
    }

    var body: some View {
        VStack(spacing: 0) {
            heading
            stepIndicator
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 580, height: 680)
    }

    // MARK: Heading + indicator

    @ViewBuilder private var heading: some View {
        VStack(spacing: 6) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon).resizable().frame(width: 56, height: 56)
            }
            Text(welcome ? "Welcome to Sandshell" : "New Workspace").font(.title2.bold())
            if welcome {
                Text("The easiest way to use Docker sbx. Choose where you want to do your work.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 400)
            }
        }
        .padding(.top, 18).padding(.bottom, 6)
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
            Text("Step \(step.rawValue + 1) of \(SetupStep.allCases.count) · \(step.title)")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
        }
        .padding(.vertical, 10)
    }

    // MARK: Step content

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .folder:
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text(rootPath).truncationMode(.middle).lineLimit(1).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                } header: {
                    Text("Folder")
                } footer: {
                    if isKnownWorkspace {
                        Text("This folder is already a Sandshell workspace — Next opens it with its saved look, mounts, and kits.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Your work happens here; it's mounted into the sandbox. You can change "
                             + "its look, mounts, and kits in the next steps.")
                            .font(.caption).foregroundStyle(.secondary)
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

    // MARK: Footer / navigation

    private var footer: some View {
        HStack(spacing: 10) {
            if welcome && step == .folder {
                Button("Default", action: onDefault)
                    .help("Create ~/Sandshell with default settings.")
            } else {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            Spacer()
            if step != .folder {
                Button("Back") { step = SetupStep(rawValue: step.rawValue - 1) ?? .folder }
            }
            if step == .kits {
                Button("Create Workspace", action: create).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else if step == .folder && isKnownWorkspace {
                Button("Open Workspace") { onOpenExisting(rootURL) }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Next", action: advance).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    /// A folder that has been opened before (registered, or carrying a configured
    /// `.sandshell/config.json`) skips the wizard — see `onOpenExisting`.
    private var isKnownWorkspace: Bool { RootFolderStore.isKnown(rootPath) }

    private func advance() {
        if step == .folder, isKnownWorkspace { onOpenExisting(rootURL); return }
        if step == .folder { buildModels() }   // models depend on the chosen root
        step = SetupStep(rawValue: step.rawValue + 1) ?? step
    }

    private func buildModels() {
        mountModel = MountConfigModel(home: home, root: rootURL, policy: .makeDefault(home: home))
        kitModel = KitConfigModel(enabledRefs: KitStore.defaultRefs)   // registry defaults preselected
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder you want to work in."
        panel.directoryURL = rootURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { rootPath = url.path }
    }

    private func create() {
        onCreate(rootURL, profile,
                 mountModel?.policy() ?? .makeDefault(home: home),
                 kitModel?.enabledRefs ?? [])
    }
}

/// Hosts the setup wizard in its own window (first launch + Open Folder).
@MainActor
final class SetupWindowController: NSWindowController {
    init(welcome: Bool,
         onCreate: @escaping (URL, RootProfile, MountPolicy, [String]) -> Void,
         onDefault: @escaping () -> Void = {}) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        super.init(window: window)
        let view = SetupWizardView(
            welcome: welcome,
            defaultRoot: WorkspaceBootstrap.defaultRoot,
            onCreate: { [weak self] url, profile, policy, kits in
                onCreate(url, profile, policy, kits); self?.close()
            },
            onDefault: { [weak self] in onDefault(); self?.close() },
            onCancel: { [weak self] in self?.close() },
            onOpenExisting: { [weak self] url in
                Log.info(.app, "setup: \(url.path) is a known workspace — opening directly")
                (NSApp.delegate as? AppDelegate)?.openWorkspace(url)
                self?.close()
            })
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
