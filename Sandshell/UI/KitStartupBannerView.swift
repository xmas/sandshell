import AppKit

/// Inline banner above the framed terminal reporting the sandbox's kit startup:
/// a kit failed, printed a warning, was skipped after an earlier failure, or is
/// still installing. Offers "Show Log" (full dispatcher log in a terminal
/// window) and a dismiss button. Content comes from `KitStartupStatus`.
final class KitStartupBannerView: NSView {
    struct Content: Equatable {
        var agent: AgentKind
        var status: KitStartupStatus

        enum Tone { case failure, warning, progress }

        var tone: Tone {
            if status.problems.contains(where: { if case .failed = $0.outcome { return true }; return false }) { return .failure }
            if status.hasProblems { return .warning }
            return .progress
        }

        var isVisible: Bool { status.hasProblems || (status.isInProgress && !status.installing.isEmpty) }

        var title: String {
            let problems = status.problems
            if problems.count > 1 {
                let list = problems.map { "\($0.name) (\($0.outcome.label))" }.joined(separator: ", ")
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
            let names = status.installing.map(\.name).joined(separator: ", ")
            return "Kits still installing in “\(status.containerName)”: \(names)…"
        }

        var detail: String {
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

    var onShowLog: ((AgentKind) -> Void)?
    var onRebuild: ((AgentKind) -> Void)?
    var onDismiss: ((String) -> Void)?

    /// Kits are baked in at `sbx create`; nothing short of a rebuild picks up a
    /// changed kit, so every problem banner says so next to its Rebuild button.
    static let rebuildHint = "Kits are applied when the sandbox is created — rebuilding is the only way to load a kit update."

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let logButton = NSButton(title: "Show Log", target: nil, action: nil)
    private let rebuildButton = NSButton(title: "Rebuild Sandbox", target: nil, action: nil)
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
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.isSelectable = true
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.stringValue = Self.rebuildHint
        let text = NSStackView(views: [title, detail, hint])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        logButton.bezelStyle = .rounded
        logButton.controlSize = .small
        logButton.target = self
        logButton.action = #selector(showLogClicked)
        logButton.setAccessibilityIdentifier("kit-startup-show-log")
        rebuildButton.bezelStyle = .rounded
        rebuildButton.controlSize = .small
        rebuildButton.target = self
        rebuildButton.action = #selector(rebuildClicked)
        rebuildButton.toolTip = "Recreate this sandbox with the current kits and mounts (ends its running sessions)."
        rebuildButton.setAccessibilityIdentifier("kit-startup-rebuild")
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

        let row = NSStackView(views: [leading, text, logButton, rebuildButton, dismissButton])
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
        case .progress:
            icon.image = nil
        }
        icon.isHidden = content.tone == .progress
        if content.tone == .progress { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        // Still installing: nothing to rebuild yet, and no update hint.
        rebuildButton.isHidden = content.tone == .progress
        hint.isHidden = content.tone == .progress
        applyTone()
    }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        title.textColor = colors.text
        applyTone()
    }

    private func applyTone() {
        let tint: NSColor
        switch content?.tone {
        case .failure?: tint = .systemRed
        case .warning?: tint = .systemOrange
        default: tint = themeColors?.text2 ?? .secondaryLabelColor
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

    @objc private func dismissClicked() {
        guard let content else { return }
        onDismiss?(content.status.signature)
    }
}
