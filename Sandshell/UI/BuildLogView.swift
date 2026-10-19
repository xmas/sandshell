import AppKit

/// sbx's output while it makes a sandbox (`BuildLog`), under the pane's
/// "Building…" status: the image pull, kit installs and the rest, as a
/// terminal would show them. Follows the end unless scrolled up.
final class BuildLogView: NSView {
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var shown = BuildLog()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.setAccessibilityIdentifier("build-log")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ log: BuildLog) {
        guard log != shown else { return }
        let atEnd = isScrolledToEnd
        // The same build grown: add what's new (keeps a selection, cheap per tick).
        if let storage = textView.textStorage, log.dropped == shown.dropped,
           log.lines.count >= shown.lines.count, Array(log.lines.prefix(shown.lines.count)) == shown.lines {
            storage.append(styled(Array(log.lines.dropFirst(shown.lines.count)), leadingBreak: !shown.isEmpty))
        } else {
            textView.textStorage?.setAttributedString(styled(log.lines, leadingBreak: false))
        }
        shown = log
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    func applyTheme(_ c: ThemeColors) {
        layer?.backgroundColor = c.termBg.cgColor
        layer?.borderColor = c.border.cgColor
        colors = c
        textView.textStorage?.setAttributedString(styled(shown.lines, leadingBreak: false))
    }

    private var colors: ThemeColors?

    /// A step that's done in green, one that failed in red, the image's
    /// layers (one line each) dimmed.
    private func styled(_ lines: [String], leadingBreak: Bool) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let color: NSColor = switch trimmed.first {
            case "✓", "✔": colors?.termGreen ?? .systemGreen
            case "✗", "✘": colors?.termRed ?? .systemRed
            default: Self.isLayer(trimmed) ? colors?.termDim ?? .secondaryLabelColor : colors?.termText ?? .labelColor
            }
            out.append(NSAttributedString(string: (i > 0 || leadingBreak ? "\n" : "") + line,
                                          attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }

    /// `1560168ac5fb already present`: a layer's digest, then what became of it.
    private static func isLayer(_ trimmed: String) -> Bool {
        let digest = trimmed.prefix { $0 != " " }
        return digest.count == 12 && digest.allSatisfy(\.isHexDigit)
    }

    private var isScrolledToEnd: Bool {
        let visible = scroll.contentView.documentVisibleRect
        return visible.maxY >= textView.bounds.maxY - 24
    }
}
