import AppKit
import SwiftUI

/// A sandbox, inspected: what `sbx inspect` says about it (image, folders,
/// kits, network, secrets), and what was installed in it since it was made —
/// with Keep as Kit, so a rebuild gets it all again. One window per sandbox.
@MainActor
final class SandboxInspectWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: SandboxInspectWindowController] = [:]

    static func show(sandbox: String, agent: AgentKind, workspace: WorkspaceController, near parent: NSWindow?) {
        let controller = open[sandbox] ?? SandboxInspectWindowController(sandbox: sandbox, agent: agent, workspace: workspace)
        open[sandbox] = controller
        if let parent, controller.window?.isVisible != true, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.maxY - 60))
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    static func debugWindow(_ sandbox: String) -> SandboxInspectWindowController? { open[sandbox] }
    #endif
    let model: SandboxInspectModel

    private init(sandbox: String, agent: AgentKind, workspace: WorkspaceController) {
        model = SandboxInspectModel(sandbox: sandbox, agent: agent, workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = sandbox
        window.subtitle = "Sandbox"
        window.isReleasedWhenClosed = false
        // Wide enough for the changes header's title and its three buttons whole.
        window.minSize = NSSize(width: 640, height: 360)
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SandboxInspectView(model: model))
        model.refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.open[model.sandbox] = nil
    }
}

/// What the inspect window shows, read from the sandbox.
@MainActor
final class SandboxInspectModel: ObservableObject {
    let sandbox: String
    let agent: AgentKind
    private weak var workspace: WorkspaceController?

    @Published private(set) var details: SandboxInspection?
    @Published private(set) var changes: SandboxChanges?
    @Published private(set) var changesError: String?
    @Published private(set) var checking = false
    /// Where Keep as Kit saved the kit, once it has.
    @Published private(set) var savedKit: String?
    @Published private(set) var saveError: String?

    init(sandbox: String, agent: AgentKind, workspace: WorkspaceController) {
        self.sandbox = sandbox
        self.agent = agent
        self.workspace = workspace
    }

    func refresh() {
        checking = true
        changesError = nil
        Task {
            details = await SbxClient.shared.inspect(sandbox)
            do { changes = try await SbxClient.shared.readChanges(inSandbox: sandbox) } catch {
                changes = nil
                changesError = error.localizedDescription
            }
            checking = false
        }
    }

    func keepAsKit() {
        guard let changes, let workspace else { return }
        do {
            savedKit = try workspace.captureChangesAsKit(changes, for: agent)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    func rebuild() {
        let kept = savedKit == nil ? (changes?.isEmpty == false ? " What was added in it and not kept as a kit is lost." : "")
            : " It installs the kit just kept."
        guard Alerts.confirm("Rebuild the sandbox “\(sandbox)”?",
                             "It’s made again from its image and the workspace’s kits; its sessions stop.\(kept)",
                             confirm: "Rebuild") else { return }
        workspace?.rebuildContainer(for: agent, force: true)
    }
}

struct SandboxInspectView: View {
    @ObservedObject var model: SandboxInspectModel

    var body: some View {
        Form {
            Section("Sandbox") {
                LabeledContent("Name", value: model.sandbox)
                LabeledContent("Agent", value: model.details?.agent ?? model.agent.rawValue)
                LabeledContent("State", value: model.details?.state ?? "…")
                if let image = model.details?.image {
                    LabeledContent("Image") { Text(image).font(.role(.code)).textSelection(.enabled) }
                }
                if let digest = model.details?.imageDigest {
                    LabeledContent("Digest") {
                        Text(digest).font(.role(.code)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                if let sessions = model.details?.sessions { LabeledContent("Sessions", value: "\(sessions)") }
            }
            if let details = model.details {
                Section("Folders") {
                    if let main = details.workspace { folder(main, readOnly: false) }
                    ForEach(details.additionalWorkspaces ?? [], id: \.self) { folder($0.dir, readOnly: $0.readOnly == true) }
                }
                Section("Kits") {
                    if (details.kits ?? []).isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(details.kits ?? [], id: \.self) { kit in
                        Text(kit.tildeAbbreviated).font(.role(.code)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Section("Network and secrets") {
                    LabeledContent("Network policy", value: details.networkPolicy?.scope ?? "—")
                    LabeledContent("Secrets", value: (details.secrets ?? []).map(\.name).joined(separator: ", ").nonEmpty ?? "None")
                }
            }
            changesSection
        }
        .formStyle(.grouped)
        .font(.role(.body))
        // The window's least size (the hosting controller sets it from this).
        .frame(minWidth: 640, minHeight: 360)
    }

    private func folder(_ path: String, readOnly: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: readOnly ? "lock.fill" : "externaldrive.fill").font(.symbol(.meta))
                .foregroundStyle(readOnly ? Color.secondary : Color.accentColor)
            Text(path.tildeAbbreviated).font(.role(.code)).lineLimit(1).truncationMode(.middle)
            if readOnly { Text("read-only").font(.role(.meta)).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var changesSection: some View {
        Section {
            if model.checking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking inside the sandbox…").foregroundStyle(.secondary) }
            } else if let error = model.changesError {
                Text(error).foregroundStyle(.secondary)
            } else if let changes = model.changes {
                if changes.isEmpty {
                    Text("Nothing was installed in it since it was made.").foregroundStyle(.secondary)
                } else {
                    changeList("apt", changes.aptPackages)
                    changeList("apt sources", changes.aptFiles.map(\.path))
                    changeList("Python", changes.python.map { "\($0.name) \($0.version)\($0.user ? " (user)" : "")" })
                    changeList("npm", changes.npm.map { "\($0.name) \($0.version)" })
                    changeList("Python tools", changes.uvTools + changes.pipxTools)
                }
                if !changes.notes.isEmpty {
                    changeList("Not capturable", changes.notes)
                }
                if let saved = model.savedKit {
                    Text("Saved as the kit \(saved.tildeAbbreviated), on for this workspace: the next rebuild installs it all again.")
                        .font(.role(.meta)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let error = model.saveError { Text(error).font(.role(.meta)).foregroundStyle(.red) }
            }
        } header: {
            HStack {
                Text("Added since it was made").lineLimit(1).layoutPriority(-1)
                Spacer(minLength: 8)
                Button("Check Again", action: model.refresh).disabled(model.checking).fixedSize()
                Button(model.savedKit == nil ? "Keep as Kit" : "Kept", action: model.keepAsKit)
                    .disabled(model.checking || model.changes?.isEmpty != false || model.savedKit != nil)
                    .help("Save what was added as a kit in this workspace, so a rebuilt sandbox installs it again")
                    .fixedSize()
                Button("Rebuild…", action: model.rebuild).disabled(model.checking)
                    .help("Make the sandbox again from its image and the workspace’s kits")
                    .fixedSize()
            }
        }
    }

    private func changeList(_ title: String, _ items: [String]) -> some View {
        Group {
            if !items.isEmpty {
                LabeledContent(title) {
                    Text(items.joined(separator: "\n")).font(.role(.code)).multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
