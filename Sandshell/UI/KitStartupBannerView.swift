import AppKit

/// Inline banner above the framed terminal reporting the sandbox's kit startup:
/// a kit failed, printed a warning, was skipped after an earlier failure, or is
/// still installing. Offers "Show Log" (full dispatcher log in a terminal
/// window) and a dismiss button. Content comes from `KitStartupStatus`.
/// Otherwise reports kit drift — the container's kits differ from the
/// workspace config — with Adopt / Drop on Next Rebuild.
final class KitStartupBannerView: NSView {
    struct Content: Equatable {
        var agent: AgentKind
        var finding: Finding

        /// What the banner reports: the kit startup run, or a container whose
        /// kits differ from the workspace config (see `KitDrift`).
        enum Finding: Equatable {
            case startup(KitStartupStatus)
            case drift(KitDrift)
        }

        enum Tone { case failure, warning, progress, drift }

        init(agent: AgentKind, status: KitStartupStatus) { self.init(agent: agent, finding: .startup(status)) }
        init(agent: AgentKind, drift: KitDrift) { self.init(agent: agent, finding: .drift(drift)) }
        init(agent: AgentKind, finding: Finding) {
            self.agent = agent
            self.finding = finding
        }

        /// Identity for dismissal: a dismissed banner stays hidden until this changes.
        var signature: String {
            switch finding {
            case .startup(let status): status.signature
            case .drift(let drift): "drift|" + drift.signature
            }
        }

        var tone: Tone {
            guard case .startup(let status) = finding else { return .drift }
            if status.problems.contains(where: { if case .failed = $0.outcome { return true }; return false }) { return .failure }
            if status.hasProblems { return .warning }
            return .progress
        }

        var isVisible: Bool {
            switch finding {
            case .startup(let status): status.hasProblems || (status.isInProgress && !status.installing.isEmpty)
            case .drift(let drift): !drift.isEmpty
            }
        }

        var drift: KitDrift? { if case .drift(let d) = finding { d } else { nil } }

        var title: String {
            switch finding {
            case .startup(let status): Self.startupTitle(status)
            case .drift(let drift): Self.driftTitle(drift)
            }
        }

        var detail: String {
            switch finding {
            case .drift(let drift):
                return (drift.extra.isEmpty ? drift.missing : drift.extra).joined(separator: "  ·  ")
            case .startup(let status):
                let lines = status.problems.first?.detail ?? []
                let text = lines.suffix(2).joined(separator: "  ·  ")
                if status.report?.isAborted == true, status.problems.count > 1 {
                    return text.isEmpty ? "Later kits were skipped." : text
                }
                if status.isInProgress, !status.hasProblems {
                    return "Tools provided by these kits aren’t available yet."
                }
                return text
            }
        }

        var hint: String {
            guard let drift else { return KitStartupBannerView.rebuildHint }
            if drift.extra.isEmpty { return "Rebuild to apply the workspace’s kit list." }
            return "Added outside Sandshell (e.g. sbx kit add). A rebuild uses the workspace’s kit list and would drop "
                + (drift.extra.count == 1 ? "it" : "them") + " — adopt to keep."
        }

        private static func startupTitle(_ status: KitStartupStatus) -> String {
            let problems = status.problems
            if problems.count > 1 {
                let list = problems.map { "\($0.name) (\($0.outcome.label))" }.formatted()
                return "\(problems.count) kits had startup problems in “\(status.containerName)”: \(list)."
            }
            let sandbox = "sandbox “\(status.containerName)”"
            if let p = problems.first {
                switch p.outcome {
                case .failed(let code):
                    return "Kit “\(p.name)” failed while starting \(sandbox) (exit \(code))."
                case .warning:
                    return "Kit “\(p.name)” reported a warning while starting \(sandbox)."
                case .skipped:
                    return "Kit “\(p.name)” didn’t run in \(sandbox) — startup stopped early."
                default:
                    return "Kit “\(p.name)” in \(sandbox): \(p.outcome.label)."
                }
            }
            let names = status.installing.map(\.name).formatted()
            return "Kits still installing in “\(status.containerName)”: \(names)…"
        }

        private static func driftTitle(_ drift: KitDrift) -> String {
            let sandbox = "Sandbox “\(drift.containerName)”"
            if !drift.extra.isEmpty {
                let names = drift.extra.map(KitStartupParser.kitName(forRef:)).formatted()
                let what = drift.extra.count == 1 ? "a kit" : "\(drift.extra.count) kits"
                return "\(sandbox) has \(what) this workspace doesn’t list: \(names)."
            }
            let names = drift.missing.map(KitStartupParser.kitName(forRef:)).formatted()
            return "\(sandbox) is missing configured kit\(drift.missing.count == 1 ? "" : "s"): \(names)."
        }
    }

    var onShowLog: ((AgentKind) -> Void)?
    var onRebuild: ((AgentKind) -> Void)?
    var onDismiss: ((String) -> Void)?
    var onAdopt: ((AgentKind) -> Void)?
    var onIgnoreDrift: ((AgentKind) -> Void)?

    /// A kit's contents are read when the sandbox is (re)created, so a changed
    /// kit only loads on a rebuild; adding a kit goes through `sbx kit add`
    /// (Settings ▸ Kits) and doesn't need one.
    nonisolated static let rebuildHint = "Rebuilding reloads every kit’s contents (the way to pick up a kit update); adding a new kit doesn’t need a rebuild."

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator.spinner()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let logButton = NSButton(title: "Show Log", target: nil, action: nil)
    private let rebuildButton = NSButton(title: "Rebuild Sandbox", target: nil, action: nil)
    private let adoptButton = NSButton(title: "Adopt into Workspace", target: nil, action: nil)
    private let ignoreButton = NSButton(title: "Drop on Next Rebuild", target: nil, action: nil)
    private let dismissButton = NSButton()
    private var content: Content?
    private var themeColors: ThemeColors?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        setAccessibilityIdentifier("kit-startup-banner")

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .role(.body, weight: .semibold)

        title.font = .role(.bodyEmphasis)
        title.maximumNumberOfLines = 2
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .role(.code)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.isSelectable = true
        hint.font = .role(.meta)

        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, detail, hint])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        logButton.bezelStyle = .push
        logButton.controlSize = .small
        logButton.target = self
        logButton.action = #selector(showLogClicked)
        logButton.setAccessibilityIdentifier("kit-startup-show-log")
        rebuildButton.bezelStyle = .push
        rebuildButton.controlSize = .small
        rebuildButton.target = self
        rebuildButton.action = #selector(rebuildClicked)
        rebuildButton.toolTip = "Recreate this sandbox with the current kits and mounts (ends its running sessions)."
        rebuildButton.setAccessibilityIdentifier("kit-startup-rebuild")
        adoptButton.bezelStyle = .push
        adoptButton.controlSize = .small
        adoptButton.target = self
        adoptButton.action = #selector(adoptClicked)
        adoptButton.toolTip = "Add these kits to the workspace’s kit list. The sandbox already has them, so nothing is rebuilt."
        adoptButton.setAccessibilityIdentifier("kit-drift-adopt")
        ignoreButton.bezelStyle = .push
        ignoreButton.controlSize = .small
        ignoreButton.target = self
        ignoreButton.action = #selector(ignoreClicked)
        ignoreButton.toolTip = "Leave these kits in the sandbox for now and stop reporting them; the next rebuild drops them."
        ignoreButton.setAccessibilityIdentifier("kit-drift-ignore")
        dismissButton.isBordered = false
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.imagePosition = .imageOnly
        dismissButton.controlSize = .small
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.toolTip = "Dismiss"
        dismissButton.setAccessibilityIdentifier("kit-startup-dismiss")

        let leading = NSView()
        leading.translatesAutoresizingMaskIntoConstraints = false
        leading.addSubview(icon)
        leading.addSubview(spinner)

        let row = NSStackView(views: [leading, text, adoptButton, ignoreButton, logButton, rebuildButton, dismissButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            leading.widthAnchor.constraint(equalToConstant: 20),
            leading.heightAnchor.constraint(equalToConstant: 20),
            icon.centerXAnchor.constraint(equalTo: leading.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: leading.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ content: Content) {
        self.content = content
        title.stringValue = content.title
        detail.stringValue = content.detail
        detail.isHidden = content.detail.isEmpty
        switch content.tone {
        case .failure:
            icon.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: "Failed")
            icon.contentTintColor = .systemRed
        case .warning:
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            icon.contentTintColor = .systemOrange
        case .drift:
            icon.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Kits differ")
            icon.contentTintColor = .systemBlue
        case .progress:
            icon.image = nil
        }
        icon.isHidden = content.tone == .progress
        if content.tone == .progress { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        hint.stringValue = content.hint
        let drift = content.drift
        let hasExtra = drift.map { !$0.extra.isEmpty } ?? false
        adoptButton.isHidden = !hasExtra
        ignoreButton.isHidden = !hasExtra
        logButton.isHidden = drift != nil
        // Still installing: nothing to rebuild yet, and no update hint. Extra
        // kits: rebuilding is exactly what would lose them, so no button.
        rebuildButton.isHidden = content.tone == .progress || hasExtra
        hint.isHidden = content.tone == .progress
        applyTone()
    }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        title.textColor = colors.text
        applyTone()
    }

    private func applyTone() {
        let tint: NSColor = switch content?.tone {
        case .failure?: .systemRed
        case .warning?: .systemOrange
        case .drift?: .systemBlue
        default: themeColors?.text2 ?? .secondaryLabelColor
        }
        layer?.backgroundColor = tint.withAlphaComponent(0.10).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
    }

    @objc private func showLogClicked() {
        guard let content else { return }
        onShowLog?(content.agent)
    }

    @objc private func rebuildClicked() {
        guard let content else { return }
        onRebuild?(content.agent)
    }

    @objc private func adoptClicked() {
        guard let content else { return }
        onAdopt?(content.agent)
    }

    @objc private func ignoreClicked() {
        guard let content else { return }
        onIgnoreDrift?(content.agent)
    }

    @objc private func dismissClicked() {
        guard let content else { return }
        onDismiss?(content.signature)
    }
}
