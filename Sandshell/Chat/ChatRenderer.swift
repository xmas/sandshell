import AppKit

// MARK: - Block backgrounds (TextKit 2)

extension NSAttributedString.Key {
    /// Paragraph-level block styling (`BlockStyle`): drawn as a rounded
    /// background behind consecutive paragraphs by `BlockBackgroundFragment`.
    static let chatBlock = NSAttributedString.Key("SandshellChatBlock")
}

/// Which background a paragraph sits on, and where it falls in its block (so
/// only the block's outer corners are rounded).
final class BlockStyle: NSObject, @unchecked Sendable {
    enum Kind { case code, card, user, added, removed, hunk }
    enum Position { case single, first, middle, last }
    let kind: Kind
    let position: Position
    init(_ kind: Kind, _ position: Position) {
        self.kind = kind
        self.position = position
    }

    var fill: NSColor {
        switch kind {
        case .code: return NSColor.labelColor.withAlphaComponent(0.055)
        case .card: return NSColor.labelColor.withAlphaComponent(0.04)
        case .user: return NSColor.controlAccentColor.withAlphaComponent(0.11)
        case .added: return NSColor.systemGreen.withAlphaComponent(0.14)
        case .removed: return NSColor.systemRed.withAlphaComponent(0.13)
        case .hunk: return NSColor.systemBlue.withAlphaComponent(0.08)
        }
    }

    /// Diff lines span the full width with square corners.
    var isFullWidth: Bool {
        switch kind {
        case .added, .removed, .hunk: return true
        default: return false
        }
    }
}

/// Layout fragment that paints its paragraph's block background, spanning the
/// container width (minus a margin) so consecutive paragraphs form one block.
final class BlockBackgroundFragment: NSTextLayoutFragment {
    var style: BlockStyle?
    static let margin: CGFloat = 4
    static let radius: CGFloat = 8

    private var backgroundRect: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.maxX
        let inset = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        let margin = style?.isFullWidth == true ? 0 : Self.margin
        let x = margin + inset - layoutFragmentFrame.minX
        return CGRect(x: x, y: 0, width: width - 2 * (margin + inset), height: layoutFragmentFrame.height)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(backgroundRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let style {
            let rect = backgroundRect.offsetBy(dx: point.x, dy: point.y)
            let r = style.isFullWidth ? 0 : Self.radius
            let roundTop = style.position == .first || style.position == .single
            let roundBottom = style.position == .last || style.position == .single
            let path = CGMutablePath()
            // Fragment coordinates are flipped (y grows downward).
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + (roundTop ? r : 0)))
            if roundTop {
                path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
                path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
            } else {
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            if roundBottom {
                path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
                path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
            } else {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
            path.closeSubpath()
            context.saveGState()
            context.addPath(path)
            context.setFillColor(style.fill.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}

/// Hands out `BlockBackgroundFragment`s for paragraphs carrying `.chatBlock`.
final class BlockFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let style = paragraph.attributedString.attribute(.chatBlock, at: 0, effectiveRange: nil) as? BlockStyle {
            let fragment = BlockBackgroundFragment(textElement: textElement, range: textElement.elementRange)
            fragment.style = style
            return fragment
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

// MARK: - Renderer

/// ChatItem → attributed text, one segment per item. `expanded` holds the ids
/// of items the user opened ("Show more"); links use `sandshell-chat://toggle/<id>`.
@MainActor
enum ChatRenderer {
    static let body = NSFont.systemFont(ofSize: 13.5)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let small = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let pad: CGFloat = 14           // text inset inside a block
    static let maxImageWidth: CGFloat = 520

    static func toggleURL(_ id: String) -> URL {
        URL(string: "sandshell-chat://toggle/\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)")!
    }

    /// `isExpanded` answers for the cards inside a tool group.
    static func render(_ item: ChatItem, expanded: Bool,
                       isExpanded: (String) -> Bool = { _ in false }) -> NSAttributedString {
        switch item {
        case .user(_, let text, let attachments):
            var paras = text.isEmpty ? [] : plainParagraphs(text, font: body)
            paras += attachments.map { line("📎 \($0)", font: small, color: .secondaryLabelColor) }
            if paras.isEmpty { return NSAttributedString() }
            return spaced(blocked(paras, .user), before: 14, after: 6)
        case .agentText(_, let text):
            return spaced(markdown(text), before: 4, after: 4)
        case .thought(let id, let text):
            return spaced(thought(id: id, text: text, expanded: expanded), before: 2, after: 2)
        case .tool(let call):
            return spaced(tool(call, expanded: expanded), before: 4, after: 4)
        case .toolGroup(let calls):
            return spaced(toolGroup(calls, id: item.id, expanded: expanded, isExpanded: isExpanded), before: 4, after: 4)
        case .plan(_, let entries):
            let paras = entries.map { e -> NSAttributedString in
                let mark = e.status == "completed" ? "☑" : e.status == "in_progress" ? "◐" : "☐"
                return line("\(mark)  \(e.content)", font: body,
                            color: e.status == "completed" ? .secondaryLabelColor : .labelColor)
            }
            return spaced(blocked([line("Plan", font: .systemFont(ofSize: 11.5, weight: .semibold),
                                        color: .secondaryLabelColor)] + paras, .card), before: 4, after: 4)
        case .image(_, let data):
            return image(data)
        case .fileChanges(let turn, let paths, let restored):
            return spaced(fileChanges(turn: turn, paths: paths, restored: restored), before: 2, after: 6)
        case .notice(_, let text, let isError):
            return spaced(line(text, font: .systemFont(ofSize: 11.5), color: isError ? .systemRed : .secondaryLabelColor),
                          before: 4, after: 4)
        }
    }

    // MARK: Pieces

    /// The turn is one path component, its "/", "?" and "#" escaped
    /// (the transcript hands Undo the URL's `lastPathComponent`).
    static func undoURL(_ turn: String) -> URL {
        let component = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return URL(string: "sandshell-chat://undo/\(turn.addingPercentEncoding(withAllowedCharacters: component) ?? turn)")!
    }

    /// "Changed 3 files: a.swift, b.swift, c.swift · Undo", or once undone,
    /// "Restored 3 files to before this message".
    private static func fileChanges(turn: String, paths: [String], restored: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11.5)
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let list = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " +\(names.count - 4) more" : "")
        let count = paths.count == 1 ? "1 file" : "\(paths.count) files"
        let out = NSMutableAttributedString()
        if restored {
            out.append(NSAttributedString(string: "↺  Restored \(count) to before this message", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        } else {
            out.append(NSAttributedString(string: "✎  Changed \(count): \(list)", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor, .toolTip: paths.joined(separator: "\n")]))
            out.append(NSAttributedString(string: "   ", attributes: [.font: font]))
            out.append(NSAttributedString(string: "Undo", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.controlAccentColor,
                .link: undoURL(turn), .toolTip: "Put these files back as they were before this message"]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        return out
    }

    private static func line(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color])
    }

    private static func plainParagraphs(_ text: String, font: NSFont) -> [NSAttributedString] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line(String($0), font: font, color: .labelColor) }
    }

    /// Wrap paragraphs in a block: inset text, mark positions for the background.
    private static func blocked(_ paragraphs: [NSAttributedString], _ kind: BlockStyle.Kind) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, p) in paragraphs.enumerated() {
            let position: BlockStyle.Position = paragraphs.count == 1 ? .single
                : i == 0 ? .first : i == paragraphs.count - 1 ? .last : .middle
            let m = NSMutableAttributedString(attributedString: p)
            let range = NSRange(location: 0, length: m.length)
            let style = (m.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent += pad
            style.headIndent += pad
            style.tailIndent = -pad
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            // Top/bottom padding inside the block.
            if position == .first || position == .single { style.paragraphSpacingBefore = 7 }
            if position == .last || position == .single { style.paragraphSpacing = 7 }
            m.addAttribute(.paragraphStyle, value: style, range: range)
            m.addAttribute(.chatBlock, value: BlockStyle(kind, position), range: range)
            out.append(m)
        }
        return out
    }

    /// Vertical space around a segment, carried by an unstyled spacer line so
    /// block backgrounds never absorb it.
    private static func spaced(_ s: NSAttributedString, before: CGFloat, after: CGFloat) -> NSAttributedString {
        guard s.length > 0 else { return s }
        let out = NSMutableAttributedString()
        out.append(spacer(before))
        out.append(s)
        out.append(spacer(after))
        return out
    }

    private static func spacer(_ height: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = height
        p.maximumLineHeight = height
        return NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: p])
    }

    private static func link(_ title: String, id: String) -> NSAttributedString {
        NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .link: toggleURL(id),
            .foregroundColor: NSColor.linkColor])
    }

    private static func thought(id: String, text: String, expanded: Bool) -> NSAttributedString {
        let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12.5), toHaveTrait: .italicFontMask)
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        let out = NSMutableAttributedString()
        out.append(line("Thinking", font: .systemFont(ofSize: 11, weight: .semibold), color: .tertiaryLabelColor))
        let shown = expanded ? lines[...] : lines.prefix(2)
        out.append(line(shown.joined(separator: "\n"), font: italic, color: .tertiaryLabelColor))
        if lines.count > 2 { out.append(link(expanded ? "Show less" : "Show more", id: "thought-\(id)")) }
        return out
    }

    // MARK: Tool groups

    /// One quiet line for a run of tool calls ("Ran git status…", "Ran 3
    /// commands, read 2 files ›"); clicked, it opens to the cards.
    private static func toolGroup(_ calls: [ChatItem.ToolCall], id: String, expanded: Bool,
                                  isExpanded: (String) -> Bool) -> NSAttributedString {
        let running = calls.contains { $0.status == "pending" || $0.status == "in_progress" }
        let failed = calls.filter { $0.status == "failed" }.count
        let head = NSMutableAttributedString(string: groupSummary(calls, running: running) + (expanded ? "  ⌄" : "  ›"),
                                             attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                                                          .foregroundColor: NSColor.secondaryLabelColor,
                                                          .link: toggleURL(id),
                                                          .toolTip: expanded ? "Hide the tool calls" : "Show the tool calls"])
        if failed > 0 {
            head.append(NSAttributedString(string: failed == calls.count && failed == 1 ? "  · failed" : "  · \(failed) failed",
                                           attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                                                        .foregroundColor: NSColor.systemRed]))
        }
        head.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 12.5)]))
        guard expanded else { return head }
        for call in calls {
            head.append(spaced(tool(call, expanded: isExpanded("tool-\(call.id)")), before: 4, after: 4))
        }
        return head
    }

    /// What a tool call does, as a verb + object: (past, present, one, many).
    private enum ToolVerb: Equatable {
        case run, read, edit, search, fetch, other

        init(_ kind: String) {
            switch kind.lowercased() {
            case "execute", "bash", "bashoutput": self = .run
            case "read", "notebookread": self = .read
            case "edit", "delete", "move", "write", "multiedit", "notebookedit": self = .edit
            case "search", "grep", "glob", "ls": self = .search
            case "fetch", "webfetch", "websearch": self = .fetch
            default: self = .other
            }
        }

        var words: (past: String, present: String, one: String, many: String) {
            switch self {
            case .run: ("Ran", "Running", "a command", "commands")
            case .read: ("Read", "Reading", "a file", "files")
            case .edit: ("Edited", "Editing", "a file", "files")
            case .search: ("Searched", "Searching", "once", "times")
            case .fetch: ("Fetched", "Fetching", "a page", "pages")
            case .other: ("Used", "Using", "a tool", "tools")
            }
        }
    }

    static func groupSummary(_ calls: [ChatItem.ToolCall], running: Bool) -> String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if calls.count == 1, let call = calls.first {
            let verb = ToolVerb(call.kind)
            let words = verb.words
            let lead = running ? words.present : words.past
            let raw = clean(call.input.isEmpty ? call.title : call.input)
            let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
            switch verb {
            case .run:
                let short = firstLine.count > 48 ? String(firstLine.prefix(45)) : firstLine
                let cut = short != raw
                return short.isEmpty ? "\(lead) \(words.one)" : "\(lead) \(short)\(cut ? "…" : "")"
            case .read, .edit:
                let name = (firstLine as NSString).lastPathComponent
                return name.isEmpty ? "\(lead) \(words.one)" : "\(lead) \(name)"
            case .search:
                return firstLine.isEmpty ? "\(lead)" : "\(lead) for \(firstLine.count > 40 ? firstLine.prefix(37) + "…" : firstLine)"
            case .fetch:
                return "\(lead) \(URL(string: firstLine)?.host ?? words.one)"
            case .other:
                let title = clean(call.title.isEmpty ? call.kind.capitalized : call.title)
                return title.count > 60 ? String(title.prefix(57)) + "…" : title
            }
        }
        var order: [ToolVerb] = []
        var counts: [ToolVerb: Int] = [:]
        for call in calls {
            let verb = ToolVerb(call.kind)
            if counts[verb] == nil { order.append(verb) }
            counts[verb, default: 0] += 1
        }
        let phrases = order.enumerated().map { i, verb -> String in
            let w = verb.words, n = counts[verb] ?? 0
            let lead = running ? w.present : w.past
            let object = n == 1 ? w.one : verb == .search ? "\(n) times" : "\(n) \(w.many)"
            return "\(i == 0 ? lead : lead.lowercased()) \(object)"
        }
        return phrases.joined(separator: ", ") + (running ? "…" : "")
    }

    // MARK: Tool cards

    private static func tool(_ call: ChatItem.ToolCall, expanded: Bool) -> NSAttributedString {
        var paras: [NSAttributedString] = []
        let (glyph, color): (String, NSColor) = switch call.status {
        case "completed": ("✓", .systemGreen)
        case "failed": ("✗", .systemRed)
        case "in_progress": ("⋯", .systemBlue)
        default: ("◌", .secondaryLabelColor)
        }
        let rawTitle = call.title.isEmpty ? call.kind.capitalized : call.title
        let firstLine = rawTitle.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? rawTitle
        let title = firstLine.count > 120 ? String(firstLine.prefix(117)) + "…" : firstLine
        let head = NSMutableAttributedString(string: glyph + "  ", attributes: [.font: mono, .foregroundColor: color])
        head.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.labelColor]))
        paras.append(head)

        // Lines beyond the collapsed limits (shown when expanded, up to 400).
        var overflow = 0
        func appendLines(_ text: String, limit: Int, color: NSColor) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for l in lines.prefix(expanded ? 400 : limit) { paras.append(line(String(l), font: small, color: color)) }
            overflow += max(0, lines.count - limit)
        }
        // The full command/path when the title is just its first line or a label.
        var input = call.input.isEmpty ? (rawTitle.contains("\n") ? rawTitle : "") : call.input
        // Don't repeat what the title already says (its first line, or a path).
        if input.hasPrefix(firstLine) {
            input = String(input.dropFirst(firstLine.count)).trimmingCharacters(in: .newlines)
        }
        if title.contains(input.trimmingCharacters(in: .whitespaces)) { input = "" }
        if !input.isEmpty { appendLines(input, limit: 3, color: .secondaryLabelColor) }
        let output = stripFences(call.output).trimmingCharacters(in: .newlines)
        if !output.isEmpty {
            if !input.isEmpty { paras.append(line("", font: .systemFont(ofSize: 4), color: .clear)) }
            appendLines(output, limit: 8, color: .labelColor)
        }
        for d in call.diffs {
            if !title.contains(d.path) && !title.contains((d.path as NSString).lastPathComponent) {
                paras.append(line(d.path, font: small, color: .secondaryLabelColor))
            }
            let old = (d.oldText ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
            let new = d.newText.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
            let all = (d.oldText == nil ? [] : old) + new
            for l in all.prefix(expanded ? 400 : 12) {
                paras.append(line(l, font: small, color: l.hasPrefix("-") ? .systemRed : .systemGreen))
            }
            overflow += max(0, all.count - 12)
        }
        if overflow > 0 {
            paras.append(link(expanded ? "Show less" : "Show \(overflow) more line\(overflow == 1 ? "" : "s")",
                              id: "tool-\(call.id)"))
        }
        let out = NSMutableAttributedString(attributedString: blocked(paras, .card))
        for data in call.images { out.append(image(data)) }
        return out
    }

    private static func stripFences(_ s: String) -> String {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("```") { lines.removeFirst() }
        if let last = lines.last(where: { !$0.isEmpty }), last.hasPrefix("```"),
           let idx = lines.lastIndex(of: last) { lines.remove(at: idx) }
        return lines.joined(separator: "\n")
    }

    private static func image(_ data: Data) -> NSAttributedString {
        let attachment = ImageAttachment(data: data)
        guard let img = attachment.image else { return NSAttributedString() }
        let size = img.size
        let scale = min(1, maxImageWidth / max(size.width, 1))
        attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        let s = NSMutableAttributedString(attachment: attachment)
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 6
        p.paragraphSpacing = 4
        s.append(NSAttributedString(string: "\n"))
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    // MARK: Markdown

    /// Typeface for Markdown prose (code, tables and inline code stay monospaced).
    struct Prose {
        var size: CGFloat
        var serif: Bool
        /// Chat transcript: the system font at the transcript size.
        static let chat = Prose(size: 13.5, serif: false)
        /// A Markdown document (Files preview): New York, a little larger.
        static let document = Prose(size: 15, serif: true)

        func font(_ size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
            let size = size ?? self.size
            let system = NSFont.systemFont(ofSize: size, weight: weight)
            guard serif, let serif = system.fontDescriptor.withDesign(.serif) else { return system }
            return NSFont(descriptor: serif, size: size) ?? system
        }
    }

    /// Line-oriented markdown: fenced code (highlighted, on a block), tables,
    /// ATX headings, bullet/numbered lists with hanging indents, quotes and
    /// rules; inline bold/italic/code/links via Foundation.
    static func markdown(_ text: String, prose: Prose = .chat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // "\r\n" is one Character, not a "\n" (a file saved on Windows).
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.map(String.init)
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1   // closing fence (or end of a still-streaming block)
                out.append(codeBlock(code, language: lang))
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                var rows: [String] = [lines[i], lines[i + 1]]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[i]); i += 1
                }
                out.append(table(rows, prose: prose))
                continue
            }
            out.append(block(lines[i], trimmed: trimmed, prose: prose))
            i += 1
        }
        return out
    }

    private static func codeBlock(_ lines: [String], language: String) -> NSAttributedString {
        let source = lines.joined(separator: "\n")
        let highlighted = SyntaxHighlighter.highlight(source, language: language, font: mono)
        // Split back into paragraphs so each line gets block positioning.
        var paras: [NSAttributedString] = []
        var start = 0
        let ns = highlighted.string as NSString
        for l in lines {
            let len = (l as NSString).length
            let piece = NSMutableAttributedString(attributedString: highlighted.attributedSubstring(from: NSRange(location: start, length: len)))
            piece.append(NSAttributedString(string: "\n", attributes: [.font: mono]))
            paras.append(piece)
            start += len + 1
            if start > ns.length { break }
        }
        if paras.isEmpty { paras = [NSAttributedString(string: "\n", attributes: [.font: mono])] }
        let out = NSMutableAttributedString()
        out.append(spacer(4))
        out.append(blocked(paras, .code))
        out.append(spacer(4))
        return out
    }

    private static func isTableSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.range(of: #"^\|?(\s*:?-{2,}:?\s*\|)+\s*:?-*:?\s*\|?$"#, options: .regularExpression) != nil
    }

    /// A Markdown table on a card. One that fits a narrow transcript is a grid
    /// on tab stops in the prose face, header in semibold above a rule; a wider
    /// one (long cells, many columns) becomes one record per row, its first cell
    /// as a heading over "header  value" lines that wrap on their own, since
    /// cells can't wrap inside a grid of tab stops. Inline Markdown renders in
    /// both; the text stays selectable and findable.
    private static func table(_ rows: [String], prose: Prose) -> NSAttributedString {
        let cells = rows.map(tableCells)
        let separator = rows.count > 1 ? tableCells(rows[1]) : []
        let body = Array(cells.dropFirst(2))
        let header = cells.first ?? []
        let columns = cells.map(\.count).max() ?? 0
        guard columns > 0 else { return NSAttributedString() }
        let headFont = prose.font(weight: .semibold)
        func render(_ cell: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSAttributedString {
            inline(cell.replacingOccurrences(of: #"<br\s*/?>"#, with: "\u{2028}", options: [.regularExpression, .caseInsensitive]),
                   font: font, color: color)
        }
        func cell(_ row: [String], _ c: Int) -> String { c < row.count ? row[c] : "" }

        // Measure each column as one line; a grid only if it all fits.
        let gap: CGFloat = 18
        var widths = [CGFloat](repeating: 0, count: columns)
        var breaks = false
        for (r, row) in ([header] + body).enumerated() {
            for c in 0..<columns {
                let text = cell(row, c)
                breaks = breaks || text.range(of: #"<br\s*/?>"#, options: [.regularExpression, .caseInsensitive]) != nil
                widths[c] = max(widths[c], ceil(render(text, r == 0 ? headFont : prose.font()).size().width))
            }
        }
        let total = widths.reduce(0, +) + gap * CGFloat(columns - 1)
        var paras: [NSAttributedString] = []
        if !breaks, total <= 520, widths.allSatisfy({ $0 <= 260 }) {
            let alignments = (0..<columns).map { c -> NSTextAlignment in
                let spec = cell(separator, c)
                return spec.hasSuffix(":") ? (spec.hasPrefix(":") ? .center : .right) : .left
            }
            let para = NSMutableParagraphStyle()
            var x = pad
            para.tabStops = (0..<columns).compactMap { c -> NSTextTab? in
                defer { x += widths[c] + gap }
                guard c > 0 else { return nil }
                switch alignments[c] {
                case .right: return NSTextTab(textAlignment: .right, location: x + widths[c])
                case .center: return NSTextTab(textAlignment: .center, location: x + widths[c] / 2)
                default: return NSTextTab(textAlignment: .left, location: x)
                }
            }
            para.lineBreakMode = .byTruncatingTail
            func gridRow(_ row: [String], _ font: NSFont) -> NSAttributedString {
                let line = NSMutableAttributedString()
                for c in 0..<columns {
                    if c > 0 { line.append(NSAttributedString(string: "\t", attributes: [.font: font])) }
                    line.append(render(cell(row, c), font))
                }
                line.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
                return line
            }
            paras.append(gridRow(header, headFont))
            let ruleFont = NSFont.systemFont(ofSize: 7)
            let dash = max(1, ("─" as NSString).size(withAttributes: [.font: ruleFont]).width)
            paras.append(line(String(repeating: "─", count: max(1, Int((total / dash).rounded(.up)))), font: ruleFont, color: .tertiaryLabelColor))
            paras += body.map { gridRow($0, prose.font()) }
            return spacedBlock(paras)
        }

        // Records: the first cell heads each row; the other columns follow as
        // labelled lines, values hanging past the widest label.
        let labelFont = prose.font(prose.size - 1.5, weight: .medium)
        let labels = (0..<columns).map { render(cell(header, $0).trimmingCharacters(in: .whitespaces), labelFont, .secondaryLabelColor) }
        let labelWidth = labels.dropFirst().map { ceil($0.size().width) }.max() ?? 0
        let stacked = labelWidth > 170
        let gapLine = NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])
        for (r, row) in body.enumerated() {
            if r > 0 { paras.append(gapLine) }
            let title = NSMutableAttributedString(attributedString: render(cell(row, 0), headFont))
            if title.length > 0 {
                title.append(NSAttributedString(string: "\n", attributes: [.font: headFont]))
                let p = NSMutableParagraphStyle()
                p.paragraphSpacing = 2
                title.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: title.length))
                paras.append(title)
            }
            for c in 1..<max(columns, 1) {
                let value = cell(row, c)
                guard !value.isEmpty else { continue }
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 1.5
                let field = NSMutableAttributedString()
                if labels[c].length == 0 {
                    p.headIndent = 12
                    p.firstLineHeadIndent = 12
                } else if stacked {
                    field.append(labels[c])
                    field.append(NSAttributedString(string: "\u{2028}", attributes: [.font: labelFont]))
                    p.headIndent = 12
                    p.firstLineHeadIndent = 12
                } else {
                    field.append(labels[c])
                    field.append(NSAttributedString(string: "\t", attributes: [.font: labelFont]))
                    p.headIndent = labelWidth + 12
                    p.tabStops = [NSTextTab(textAlignment: .left, location: pad + labelWidth + 12)]
                }
                field.append(render(value, prose.font()))
                field.append(NSAttributedString(string: "\n", attributes: [.font: prose.font()]))
                field.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: field.length))
                paras.append(field)
            }
        }
        return spacedBlock(paras)
    }

    private static func spacedBlock(_ paras: [NSAttributedString]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(spacer(4))
        out.append(blocked(paras, .card))
        out.append(spacer(4))
        return out
    }

    /// A table row's cells: split on pipes that aren't escaped or in code.
    private static func tableCells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = [], current = "", inCode = false, escaped = false
        for ch in t {
            if escaped { current.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            switch ch {
            case "\\": escaped = true
            case "`": inCode.toggle(); current.append(ch)
            case "|" where !inCode: cells.append(current); current = ""
            default: current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func block(_ raw: String, trimmed: String, prose: Prose) -> NSAttributedString {
        let body = prose.font()
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = prose.serif ? 7 : 4
        para.lineSpacing = prose.serif ? 3 : 1.5
        var text = trimmed
        var font = body
        var color = NSColor.labelColor
        var prefix = ""
        if let m = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
            let level = trimmed[m].count - 1
            text = String(trimmed[m.upperBound...])
            font = prose.font(body.pointSize + CGFloat(max(0, 4 - level)) * 1.5, weight: .semibold)
            para.paragraphSpacingBefore = 8
        } else if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
            return NSAttributedString(string: "\n", attributes: [.font: body])
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
            let depth = CGFloat((raw.prefix { $0 == " " }.count) / 2)
            let indent = 20 + depth * 18
            para.firstLineHeadIndent = indent - 16
            para.headIndent = indent
            para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            para.paragraphSpacing = 2
        }
        let out = NSMutableAttributedString(string: prefix, attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor])
        out.append(inline(text + "\n", font: font, color: color))
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        return out
    }

    static func inline(_ text: String, font base: NSFont = body, color: NSColor = .labelColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: opts) else {
            return NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: color])
        }
        let ns = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: ns.length)
        ns.addAttribute(.foregroundColor, value: color, range: full)
        ns.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            let intent = (value as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
            var font = base
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular)
                ns.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.07), range: range)
            }
            if intent.contains(.stronglyEmphasized) { font = withTrait(font, .bold, .boldFontMask) }
            if intent.contains(.emphasized) { font = withTrait(font, .italic, .italicFontMask) }
            ns.addAttribute(.font, value: font, range: range)
        }
        return ns
    }

    /// Bold/italic that keeps the face's design (NSFontManager can drop New
    /// York back to the plain system font).
    private static func withTrait(_ font: NSFont, _ trait: NSFontDescriptor.SymbolicTraits,
                                  _ fallback: NSFontTraitMask) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: d, size: font.pointSize) ?? NSFontManager.shared.convert(font, toHaveTrait: fallback)
    }
}

// MARK: - Syntax highlighting

/// Small regex highlighter for fenced code: comments, strings, numbers,
/// keywords and capitalized type names. Language-tolerant — unknown languages
/// get the common keyword set.
enum SyntaxHighlighter {
    private static let keywords: [String: Set<String>] = [
        "swift": ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch",
                  "for", "in", "while", "import", "extension", "protocol", "private", "public", "static", "self",
                  "init", "throws", "try", "await", "async", "actor", "nil", "true", "false", "some", "any", "where"],
        "python": ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as",
                   "with", "try", "except", "finally", "raise", "lambda", "yield", "None", "True", "False", "and",
                   "or", "not", "is", "pass", "break", "continue", "async", "await", "self"],
        "js": ["function", "const", "let", "var", "return", "if", "else", "for", "while", "class", "new", "import",
               "export", "from", "default", "async", "await", "try", "catch", "throw", "null", "undefined", "true",
               "false", "this", "typeof", "interface", "type", "extends", "implements"],
        "shell": ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function",
                  "return", "export", "local", "echo", "exit", "set", "cd"],
        "go": ["func", "package", "import", "return", "if", "else", "for", "range", "struct", "type", "interface",
               "var", "const", "go", "defer", "chan", "select", "case", "switch", "nil", "true", "false", "map"],
        "rust": ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "return", "if", "else",
                 "match", "for", "in", "while", "loop", "self", "Self", "async", "await", "move", "true", "false"],
    ]
    private static let aliases: [String: String] = [
        "py": "python", "javascript": "js", "ts": "js", "typescript": "js", "tsx": "js", "jsx": "js",
        "sh": "shell", "bash": "shell", "zsh": "shell", "console": "shell", "golang": "go", "rs": "rust",
    ]

    static func highlight(_ source: String, language: String, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let lang = aliases[language] ?? language
        let full = NSRange(location: 0, length: out.length)
        let hashComments = ["python", "shell", "ruby", "yaml", "toml"].contains(lang)

        func paint(_ pattern: String, _ color: NSColor) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: source, range: full) { out.addAttribute(.foregroundColor, value: color, range: m.range) }
        }
        paint(#"\b\d+(\.\d+)?\b"#, .systemBlue)
        paint(#"\b[A-Z][A-Za-z0-9_]+\b"#, .systemTeal)
        let words = keywords[lang] ?? keywords["swift"]!.union(keywords["js"]!)
        paint(#"\b("# + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#, .systemPink)
        // Strings and comments in one pass, leftmost first: a comment marker in
        // a string ("https://…", "#tag") stays string, a quote in a comment stays comment.
        let string = #""(\\.|[^"\\\n])*"|'(\\.|[^'\\\n])*'|`(\\.|[^`\\])*`"#
        let comment = (hashComments ? #"#.*$"# : #"//.*$"#) + #"|/\*[\s\S]*?\*/"#
        if let re = try? NSRegularExpression(pattern: "(?<string>\(string))|\(comment)", options: .anchorsMatchLines) {
            for m in re.matches(in: source, range: full) {
                let isString = m.range(withName: "string").location != NSNotFound
                out.addAttribute(.foregroundColor, value: isString ? NSColor.systemRed : .secondaryLabelColor, range: m.range)
            }
        }
        return out
    }
}
