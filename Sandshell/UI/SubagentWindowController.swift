import AppKit

/// A subagent's own conversation, read-only — its prompt, its tool calls, its
/// replies — following along while it works. One window per subagent.
@MainActor
final class SubagentWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: SubagentWindowController] = [:]

    private var info: SubagentInfo
    private weak var workspace: WorkspaceController?
    private let transcript = ChatTranscriptView()
    private let status = NSTextField(labelWithString: "")
    private var follow: Task<Void, Never>?
    private var lastModified: Date?

    static func show(_ info: SubagentInfo, workspace: WorkspaceController) {
        let controller = open[info.id] ?? SubagentWindowController(info, workspace: workspace)
        open[info.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    static func debugWindow(_ id: String) -> SubagentWindowController? { open[id] }
    var debugTranscriptText: String { transcript.debugText }
    #endif

    private init(_ info: SubagentInfo, workspace: WorkspaceController) {
        self.info = info
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = info.title
        window.subtitle = [info.agentType.map { "\($0) subagent" } ?? "Subagent",
                           workspace.session(id: info.sessionID)?.name].compactMap { $0 }.joined(separator: " · ")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SubagentWindow")
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        window.delegate = self

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let root = NSView()
        for v in [transcript, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: root.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        window.contentView = root
        if !window.setFrameUsingName("SubagentWindow") { window.center() }
        load()
        // Follow it while it works (and pick up its state from the sidebar's poll).
        follow = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                if let latest = self.workspace?.subagents[self.info.sessionID]?.first(where: { $0.id == self.info.id }) {
                    self.info = latest
                }
                self.load()
            }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func load() {
        let url = info.transcript
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        updateStatus()
        guard modified != lastModified else { return }
        lastModified = modified
        Task { [weak self] in
            let items = await Task.detached(priority: .utility) { SubagentScanner.items(url) }.value
            self?.transcript.update(items)
        }
    }

    private func updateStatus() {
        switch info.state {
        case .running: status.stringValue = "Working… (read-only)"
        case .done: status.stringValue = "Finished \(Format.ago(info.lastWrite))"
        case .failed: status.stringValue = "Failed"
        case .stopped: status.stringValue = "Stopped"
        }
    }

    func windowWillClose(_ notification: Notification) {
        follow?.cancel()
        Self.open[info.id] = nil
    }
}
