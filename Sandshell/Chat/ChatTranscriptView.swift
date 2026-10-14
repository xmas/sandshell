import AppKit

/// The conversation as one read-only TextKit 2 text view. Rendering everything
/// into a single text storage is what buys the Mac text-system behaviors for
/// free: selection across messages, ⌘F find bar, ⌘E, Look Up, Services, drag a
/// selection out, emacs-style navigation, VoiceOver.
///
/// Spike: the whole storage is re-rendered (coalesced) on each change;
/// incremental tail appends and inline attachment views (permission cards,
/// images) come later.
final class ChatTranscriptView: NSView {
    private let scrollView = NSTextView.scrollableTextView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }
    private var pendingItems: [ChatItem]?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        let tv = textView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 24, height: 18)
        tv.setAccessibilityIdentifier("chat-transcript")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Coalesce bursts of streaming updates into one render per runloop turn.
    func update(_ items: [ChatItem]) {
        let scheduled = pendingItems != nil
        pendingItems = items
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let items = self.pendingItems else { return }
            self.pendingItems = nil
            self.render(items)
        }
    }

    private func render(_ items: [ChatItem]) {
        let clip = scrollView.contentView
        let atBottom = clip.bounds.maxY >= (scrollView.documentView?.frame.height ?? 0) - 40
        textView.textStorage?.setAttributedString(ChatRenderer.render(items))
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }
}

/// ChatItem → attributed text.
@MainActor
enum ChatRenderer {
    static let body = NSFont.systemFont(ofSize: 13.5)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let small = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static func render(_ items: [ChatItem]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // One speaker header per turn, not per message chunk / tool call.
        var lastSpeaker: String?
        func speaker(_ who: String, _ color: NSColor) {
            guard lastSpeaker != who else { return }
            lastSpeaker = who
            out.append(header(who, color: color))
        }
        for item in items {
            switch item {
            case .user(_, let text, let attachments):
                speaker("You", .controlAccentColor)
                if !text.isEmpty { out.append(markdown(text)) }
                for a in attachments { out.append(line("📎 \(a)", font: small, color: .secondaryLabelColor)) }
                lastSpeaker = "You"
            case .agentText(_, let text):
                speaker("Claude", .systemOrange)
                out.append(markdown(text))
            case .thought(_, let text):
                speaker("Claude", .systemOrange)
                out.append(line(text, font: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask),
                                color: .tertiaryLabelColor))
            case .tool(let call):
                speaker("Claude", .systemOrange)
                out.append(tool(call))
            case .plan(_, let entries):
                speaker("Claude", .systemOrange)
                for e in entries {
                    let mark = e.status == "completed" ? "☑" : e.status == "in_progress" ? "◐" : "☐"
                    out.append(line("\(mark) \(e.content)", font: body, color: .labelColor))
                }
            case .notice(_, let text, let isError):
                out.append(line(text, font: small, color: isError ? .systemRed : .secondaryLabelColor))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
        }
        return out
    }

    private static func header(_ who: String, color: NSColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 10
        return NSAttributedString(string: who + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: color, .paragraphStyle: p])
    }

    private static func line(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color])
    }

    private static func tool(_ call: ChatItem.ToolCall) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let (glyph, color): (String, NSColor) = switch call.status {
        case "completed": ("✓", .systemGreen)
        case "failed": ("✗", .systemRed)
        case "in_progress": ("⋯", .systemBlue)
        default: ("◌", .secondaryLabelColor)
        }
        out.append(NSAttributedString(string: glyph + " ", attributes: [.font: mono, .foregroundColor: color]))
        out.append(NSAttributedString(string: (call.title.isEmpty ? call.kind : call.title) + "\n",
                                      attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        let indent = NSMutableParagraphStyle()
        indent.headIndent = 18; indent.firstLineHeadIndent = 18
        if !call.output.isEmpty {
            let lines = call.output.split(separator: "\n", omittingEmptySubsequences: false)
            var shown = lines.prefix(14).joined(separator: "\n")
            if lines.count > 14 { shown += "\n```\n… \(lines.count - 14) more lines" }
            let rendered = NSMutableAttributedString(attributedString: markdown(shown, font: small, codeFont: small))
            rendered.addAttribute(.paragraphStyle, value: indent, range: NSRange(location: 0, length: rendered.length))
            rendered.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                  range: NSRange(location: 0, length: rendered.length))
            out.append(rendered)
        }
        for d in call.diffs {
            out.append(NSAttributedString(string: d.path + "\n", attributes: [
                .font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: indent]))
            for l in (d.oldText ?? "").split(separator: "\n").prefix(20) {
                out.append(NSAttributedString(string: "- \(l)\n", attributes: [
                    .font: small, .foregroundColor: NSColor.systemRed, .paragraphStyle: indent]))
            }
            for l in d.newText.split(separator: "\n").prefix(20) {
                out.append(NSAttributedString(string: "+ \(l)\n", attributes: [
                    .font: small, .foregroundColor: NSColor.systemGreen, .paragraphStyle: indent]))
            }
        }
        return out
    }

    /// Line-oriented markdown: fenced code (monospace, tinted), ATX headings,
    /// bullet/numbered lists with hanging indents, block quotes and rules;
    /// inline bold/italic/code/links via Foundation. Tables and syntax
    /// highlighting are follow-ups.
    static func markdown(_ text: String, font: NSFont? = nil, codeFont: NSFont? = nil) -> NSAttributedString {
        let base = font ?? body
        let code = codeFont ?? mono
        let out = NSMutableAttributedString()
        var inFence = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                out.append(NSAttributedString(string: raw + "\n", attributes: [
                    .font: code, .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)]))
                continue
            }
            out.append(block(String(raw), trimmed: trimmed, base: base))
        }
        return out
    }

    private static func block(_ raw: String, trimmed: String, base: NSFont) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 3
        var text = trimmed
        var font = base
        var color = NSColor.labelColor
        var prefix = ""
        if let m = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
            let level = trimmed[m].count - 1
            text = String(trimmed[m.upperBound...])
            font = .systemFont(ofSize: base.pointSize + CGFloat(max(0, 4 - level)) * 1.5, weight: .semibold)
            para.paragraphSpacingBefore = 6
        } else if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
            return NSAttributedString(string: "────────\n", attributes: [.font: base, .foregroundColor: NSColor.separatorColor])
        } else if let m = trimmed.range(of: #"^[-*+] "#, options: .regularExpression) {
            text = String(trimmed[m.upperBound...])
            prefix = "•\t"
        } else if let m = trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) {
            prefix = trimmed[m].trimmingCharacters(in: .whitespaces) + "\t"
            text = String(trimmed[m.upperBound...])
        } else if trimmed.hasPrefix(">") {
            text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            color = .secondaryLabelColor
            para.headIndent = 14; para.firstLineHeadIndent = 14
        }
        if !prefix.isEmpty {
            // Hanging indent: nested by the source's leading spaces.
            let depth = CGFloat((raw.prefix { $0 == " " }.count) / 2)
            let indent = 18 + depth * 16
            para.firstLineHeadIndent = indent - 18
            para.headIndent = indent
            para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        }
        let line = NSMutableAttributedString(string: prefix, attributes: [.font: base, .foregroundColor: NSColor.secondaryLabelColor])
        line.append(inline(text + "\n", font: font, color: color))
        line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
        return line
    }

    private static func inline(_ text: String, font base: NSFont = body, color: NSColor = .labelColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: opts) else {
            return NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: color])
        }
        let ns = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: ns.length)
        ns.addAttribute(.foregroundColor, value: color, range: full)
        // Map Foundation's inline intents onto real fonts.
        ns.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            let intent = (value as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
            var font = base
            if intent.contains(.code) { font = mono }
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            ns.addAttribute(.font, value: font, range: range)
        }
        return ns
    }
}
