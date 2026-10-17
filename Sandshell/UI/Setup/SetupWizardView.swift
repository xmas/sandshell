import SwiftUI

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
    /// The chosen folder has been opened before (registered, or carrying a
    /// configured `.sandshell/config.json`), so it skips the wizard — see
    /// `onOpenExisting`. Checked when a folder is chosen.
    @State private var isKnownWorkspace: Bool
    @State private var icon: String
    @State private var colorHex: String
    @State private var sidebarHex: String
    @State private var mountModel: MountConfigModel?
    @State private var kitModel: KitConfigModel?

    private let home = URL.homeDirectory

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
        let path = Self.plainPath(defaultRoot)
        let p = RootProfile.makeDefault(path: path)
        _rootPath = State(initialValue: path)
        _isKnownWorkspace = State(initialValue: RootFolderStore.isKnown(path))
        _icon = State(initialValue: p.icon)
        _colorHex = State(initialValue: p.colorHex)
        _sidebarHex = State(initialValue: p.sidebarHex)
    }

    private var rootURL: URL { URL(filePath: rootPath, directoryHint: .checkFileSystem) }
    private var profile: RootProfile {
        RootProfile(path: Self.plainPath(rootURL), icon: icon, colorHex: colorHex, sidebarHex: sidebarHex)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon).resizable().frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                }
                Text(welcome ? "Welcome to Sandshell" : "New Workspace").font(.title2.bold())
                if welcome {
                    Text("The easiest way to use Docker sbx. Choose where you want to do your work.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 400)
                }
            }
            .padding(.top, 18).padding(.bottom, 6)
            HStack(spacing: 8) {
                ForEach(SetupStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .frame(width: 8, height: 8)
                }
                Text("Step \(step.rawValue + 1) of \(SetupStep.allCases.count) · \(step.title)")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
            }
            .padding(.vertical, 10)
            Divider()
            SetupStepContent(step: step, rootPath: rootPath, isKnownWorkspace: isKnownWorkspace,
                             icon: $icon, colorHex: $colorHex, sidebarHex: $sidebarHex,
                             mountModel: mountModel, kitModel: kitModel, onChooseFolder: chooseFolder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SetupWizardFooter(step: step, welcome: welcome, isKnownWorkspace: isKnownWorkspace,
                              onDefault: onDefault, onCancel: onCancel, onBack: goBack,
                              onNext: advance, onOpenExisting: openExisting, onCreate: create)
        }
        .frame(width: 580, height: 680)
    }

    private func goBack() {
        step = SetupStep(rawValue: step.rawValue - 1) ?? .folder
    }

    private func openExisting() {
        onOpenExisting(rootURL)
    }

    private func advance() {
        // Checked again here: the folder may have been opened elsewhere since it was chosen.
        if step == .folder, RootFolderStore.isKnown(rootPath) { onOpenExisting(rootURL); return }
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
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = Self.plainPath(url)
            isKnownWorkspace = RootFolderStore.isKnown(rootPath)
        }
    }

    private func create() {
        onCreate(rootURL, profile,
                 mountModel?.policy() ?? .makeDefault(home: home),
                 kitModel?.enabledRefs ?? [])
    }

    /// A file URL's path without the trailing "/" a directory URL carries
    /// (`path(percentEncoded:)` keeps it; the old `path` dropped it).
    nonisolated static func plainPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
