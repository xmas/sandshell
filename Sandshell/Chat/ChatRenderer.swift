import AppKit

// MARK: - Block backgrounds (TextKit 2)

extension NSAttributedString.Key {
    /// Paragraph-level block styling (`BlockStyle`): drawn as a rounded
    /// background behind consecutive paragraphs by `BlockBackgroundFragment`.
    static let chatBlock = NSAttributedString.Key("SandshellChatBlock")
    /// A `TableRule` drawn above a table row's first line by `BlockBackgroundFragment`.
    static let chatTableRule = NSAttributedString.Key("SandshellChatTableRule")
    /// Marks a table's text: it was laid out for a width, so the transcript
    /// lays it out again when its own width changes.
    static let chatTable = NSAttributedString.Key("SandshellChatTable")
    /// A `PlanMark` drawn before a plan entry's first line by `BlockBackgroundFragment`.
    static let chatPlanMark = NSAttributedString.Key("SandshellChatPlanMark")
    /// A `CopyBlock` over a code block's or table's block: what its hover Copy copies.
    static let chatCopyBlock = NSAttributedString.Key("SandshellChatCopyBlock")
}

/// The source of a code block (its code, without the fences), a table (its
/// Markdown) or a tool call (its title, input and whole output). A class, so
/// neighbouring blocks never merge into one range.
final class CopyBlock: NSObject, @unchecked Sendable {
    enum Kind { case code, table, tool }
    let kind: Kind
    let text: String
    init(_ kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// The line above a table row: under the header, or between body rows.
final class TableRule: NSObject, @unchecked Sendable {
    let isHeader: Bool
    /// Where the table's text starts (the block's inset) and how wide it is.
    let leading: CGFloat
    let width: CGFloat
    /// How far above the row's first line the rule sits (half the gap between rows).
    let offset: CGFloat
    init(isHeader: Bool, leading: CGFloat, width: CGFloat, offset: CGFloat) {
        self.isHeader = isHeader
        self.leading = leading
        self.width = width
        self.offset = offset
    }

    var color: NSColor { isHeader ? .tertiaryLabelColor : .quaternaryLabelColor }
    var thickness: CGFloat { isHeader ? 1 : 0.5 }
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
        case .code: NSColor.labelColor.withAlphaComponent(0.055)
        case .card: NSColor.labelColor.withAlphaComponent(0.04)
        case .user: NSColor.controlAccentColor.withAlphaComponent(0.11)
        case .added: NSColor.systemGreen.withAlphaComponent(0.14)
        case .removed: NSColor.systemRed.withAlphaComponent(0.13)
        case .hunk: NSColor.systemBlue.withAlphaComponent(0.08)
        }
    }

    /// Diff lines span the full width with square corners.
    var isFullWidth: Bool {
        switch kind {
        case .added, .removed, .hunk: true
        default: false
        }
    }
}

/// Layout fragment that paints its paragraph's block background, spanning the
/// container width (minus a margin) so consecutive paragraphs form one block.
final class BlockBackgroundFragment: NSTextLayoutFragment {
    var style: BlockStyle?
    var rule: TableRule?
    var mark: PlanMark?
    static let margin: CGFloat = 4
    static let radius: CGFloat = 8

    private var backgroundRect: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.maxX
        let inset = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        let margin = style?.isFullWidth == true ? 0 : Self.margin
        let x = margin + inset - layoutFragmentFrame.minX
        return CGRect(x: x, y: 0, width: width - 2 * (margin + inset), height: layoutFragmentFrame.height)
    }

    /// The table rule, in fragment coordinates: across the table, `offset`
    /// above the row's first line.
    private var ruleRect: CGRect? {
        guard let rule else { return nil }
        let inset = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        let top = textLineFragments.first?.typographicBounds.minY ?? 0
        return CGRect(x: inset + rule.leading - layoutFragmentFrame.minX, y: top - rule.offset - rule.thickness / 2,
                      width: rule.width, height: rule.thickness)
    }

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds.union(backgroundRect)
        return ruleRect.map { bounds.union($0) } ?? bounds
    }

    /// The plan mark, in fragment coordinates: in the indent, centred on the
    /// first line's capitals.
    private var markRect: CGRect? {
        guard let mark, let first = textLineFragments.first else { return nil }
        let inset = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        let baseline = first.typographicBounds.minY + first.glyphOrigin.y
        let midY = baseline - mark.capHeight / 2
        return CGRect(x: inset + mark.leading - layoutFragmentFrame.minX, y: midY - mark.diameter / 2,
                      width: mark.diameter, height: mark.diameter)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        defer {
            if let mark, let rect = markRect {
                // Fragment coordinates are flipped (y grows downward).
                PlanGlyph.draw(mark.state, in: rect.offsetBy(dx: point.x, dy: point.y), context: context, flipped: true)
            }
            if let rule, let rect = ruleRect {
                context.saveGState()
                context.setFillColor(rule.color.cgColor)
                context.fill(rect.offsetBy(dx: point.x, dy: point.y))
                context.restoreGState()
            }
        }
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
            fragment.rule = paragraph.attributedString.attribute(.chatTableRule, at: 0, effectiveRange: nil) as? TableRule
            fragment.mark = paragraph.attributedString.attribute(.chatPlanMark, at: 0, effectiveRange: nil) as? PlanMark
            return fragment
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

// MARK: - Renderer

/// Markdown → attributed text, for the Files preview (a chat's transcript is
/// the web page, `ChatWebTranscript`).
@MainActor
enum ChatRenderer {
    /// Prose and code at View ▸ Make Text Bigger's size (`TextZoom`).
    static var body: NSFont { .content(.body) }
    static var mono: NSFont { .content(.code) }
    static let pad: CGFloat = 14           // text inset inside a block
    /// The text column a table fits when its view doesn't say (the Files preview).
    static let defaultWidth: CGFloat = 560

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
            // Top/bottom padding inside the block, on top of the paragraph's own.
            if position == .first || position == .single { style.paragraphSpacingBefore += 7 }
            if position == .last || position == .single { style.paragraphSpacing += 7 }
            m.addAttribute(.paragraphStyle, value: style, range: range)
            m.addAttribute(.chatBlock, value: BlockStyle(kind, position), range: range)
            out.append(m)
        }
        return out
    }

    private static func spacer(_ height: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = height
        p.maximumLineHeight = height
        return NSAttributedString(string: "\n", attributes: [.font: NSFont.spacer(1), .paragraphStyle: p])
    }

    // MARK: Markdown

    /// Typeface for Markdown prose (code, tables and inline code stay monospaced).
    struct Prose {
        var serif: Bool
        /// The family chosen in Settings (`ChatFonts`), for a reply.
        var family: String?
        /// The agent's replies.
        @MainActor static var reply: Prose {
            Prose(serif: ChatFonts.reply != ChatFonts.system, family: ChatFonts.reply)
        }
        /// Chat transcript: the system font.
        static let chat = Prose(serif: false)
        /// A Markdown document (Files preview): New York unless Settings ▸
        /// Editor ▸ Markdown Preview says otherwise.
        @MainActor static var document: Prose {
            let family = ChatFonts.document
            switch family {
            case ChatFonts.newYork: return Prose(serif: true)
            case ChatFonts.system: return Prose(serif: false)
            default: return Prose(serif: true, family: family)
            }
        }

        /// A type role in the prose face.
        @MainActor func font(_ role: TypeRole = .body) -> NSFont {
            if let family { return ChatFonts.font(family, role) }
            let system = NSFont.content(role)
            guard serif, let serif = system.fontDescriptor.withDesign(.serif) else { return system }
            return NSFont(descriptor: serif, size: system.pointSize) ?? system
        }
    }

    /// Line-oriented markdown: fenced code (highlighted, on a block), tables
    /// (fitted to `width`, the text column), ATX headings, bullet/numbered
    /// lists with hanging indents, quotes and rules; inline
    /// bold/italic/code/links via Foundation.
    static func markdown(_ text: String, prose: Prose = .chat, width: CGFloat = defaultWidth) -> NSAttributedString {
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
                out.append(copyable(codeBlock(code, language: lang), CopyBlock(.code, text: code.joined(separator: "\n"))))
                continue
            }
            if let found = MarkdownTable.parse(lines, at: i) {
                let source = lines[i..<found.end].joined(separator: "\n")
                out.append(copyable(table(found.table, prose: prose, width: width), CopyBlock(.table, text: source)))
                i = found.end
                continue
            }
            out.append(block(lines[i], trimmed: trimmed, prose: prose))
            i += 1
        }
        return out
    }

    /// Tags the block (not the space around it) with what its Copy copies.
    private static func copyable(_ block: NSAttributedString, _ copy: CopyBlock) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: block)
        out.enumerateAttribute(.chatBlock, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            if value != nil { out.addAttribute(.chatCopyBlock, value: copy, range: range) }
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

    /// Space between a table's columns, and above and below each row's text
    /// (a rule sits in the middle of the gap between rows).
    static let tableGap: CGFloat = 18
    static let tableRowPad: CGFloat = 4

    /// A Markdown table on a card, as a grid fitted to `width` (the text
    /// column): columns on tab stops in the prose face, the header semibold,
    /// rules under the header and between rows, `:--:` alignments honored.
    /// Cells that don't fit their column wrap onto more lines of the row (and
    /// `<br>` breaks one); inline Markdown renders. Only a table with more
    /// columns than can fit at all becomes one record per row. Either way the
    /// text stays selectable and findable.
    private static func table(_ table: MarkdownTable, prose: Prose, width: CGFloat) -> NSAttributedString {
        let columns = table.columns
        guard columns > 0 else { return NSAttributedString() }
        let headFont = prose.font(.bodyEmphasis), bodyFont = prose.font()
        let head = (0..<columns).map { tableCell(cell(table.header, $0), headFont) }
        let body = table.rows.map { row in (0..<columns).map { tableCell(cell(row, $0), bodyFont) } }
        let all = [head] + body
        let natural = (0..<columns).map { c in
            all.map { MarkdownTable.wrap($0[c], width: .greatestFiniteMagnitude).map { ceil($0.size().width) + 1 }.max() ?? 0 }
                .max() ?? 0
        }
        // A long word (a path, a URL) may break rather than widen its column past this.
        let minimum = (0..<columns).map { c in min(all.map { MarkdownTable.widestWord($0[c]) + 1 }.max() ?? 0, 160) }
        let available = width - 2 * pad - tableGap * CGFloat(columns - 1)
        guard let widths = MarkdownTable.columnWidths(natural: natural, minimum: minimum, available: available) else {
            return records(table, prose: prose)
        }
        let alignments = (0..<columns).map { $0 < table.alignments.count ? table.alignments[$0] : .left }
        let total = widths.reduce(0, +) + tableGap * CGFloat(columns - 1)

        // Every column's stop: left at its start, right at its end, center in its middle.
        // The first column needs one only when it isn't left-aligned (lines then start with a tab).
        let leadingTab = alignments[0] != .left
        var stops: [NSTextTab] = []
        var x = pad
        for c in 0..<columns {
            switch alignments[c] {
            case .right: stops.append(NSTextTab(textAlignment: .right, location: x + widths[c]))
            case .center: stops.append(NSTextTab(textAlignment: .center, location: x + widths[c] / 2))
            case .left: if c > 0 { stops.append(NSTextTab(textAlignment: .left, location: x)) }
            }
            x += widths[c] + tableGap
        }

        var paras: [NSAttributedString] = []
        for (r, row) in all.enumerated() {
            let font = r == 0 ? headFont : bodyFont
            let wrapped = (0..<columns).map { MarkdownTable.wrap(row[$0], width: widths[$0]) }
            let height = wrapped.map(\.count).max() ?? 1
            for l in 0..<height {
                let line = NSMutableAttributedString()
                for c in 0..<columns {
                    if c > 0 || leadingTab { line.append(NSAttributedString(string: "\t", attributes: [.font: font])) }
                    if l < wrapped[c].count { line.append(wrapped[c][l]) }
                }
                line.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                let para = NSMutableParagraphStyle()
                para.tabStops = stops
                para.defaultTabInterval = 0
                para.lineBreakMode = .byTruncatingTail
                para.lineSpacing = 1.5
                if l == 0, r > 0 { para.paragraphSpacingBefore = tableRowPad }
                if l == height - 1, r < all.count - 1 { para.paragraphSpacing = tableRowPad }
                let range = NSRange(location: 0, length: line.length)
                line.addAttribute(.paragraphStyle, value: para, range: range)
                line.addAttribute(.chatTable, value: true, range: range)
                if l == 0, r > 0 {
                    line.addAttribute(.chatTableRule, value: TableRule(isHeader: r == 1, leading: pad, width: total,
                                                                      offset: tableRowPad), range: range)
                }
                paras.append(line)
            }
        }
        return spacedBlock(paras)
    }

    private static func cell(_ row: [String], _ c: Int) -> String { c < row.count ? row[c] : "" }

    /// A cell's inline Markdown; `<br>` becomes a line separator.
    private static func tableCell(_ text: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSAttributedString {
        inline(text.replacing(/<br\s*\/?>/.ignoresCase(), with: "\u{2028}"), font: font, color: color)
    }

    /// A table with more columns than fit: the first cell heads each row; the
    /// other columns follow as labelled lines, values hanging past the widest label.
    private static func records(_ table: MarkdownTable, prose: Prose) -> NSAttributedString {
        let columns = table.columns
        let headFont = prose.font(.bodyEmphasis)
        let labelFont = prose.font(.meta)
        let labels = (0..<columns).map {
            tableCell(cell(table.header, $0).trimmingCharacters(in: .whitespaces), labelFont, .secondaryLabelColor)
        }
        let labelWidth = labels.dropFirst().map { ceil($0.size().width) }.max() ?? 0
        let stacked = labelWidth > 170
        let gapLine = NSAttributedString(string: "\n", attributes: [.font: NSFont.spacer(6)])
        var paras: [NSAttributedString] = []
        for (r, row) in table.rows.enumerated() {
            if r > 0 { paras.append(gapLine) }
            let title = NSMutableAttributedString(attributedString: tableCell(cell(row, 0), headFont))
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
                field.append(tableCell(value, prose.font()))
                field.append(NSAttributedString(string: "\n", attributes: [.font: prose.font()]))
                field.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: field.length))
                paras.append(field)
            }
        }
        let out = NSMutableAttributedString(attributedString: spacedBlock(paras))
        out.addAttribute(.chatTable, value: true, range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func spacedBlock(_ paras: [NSAttributedString]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(spacer(4))
        out.append(blocked(paras, .card))
        out.append(spacer(4))
        return out
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
            font = prose.font(level <= 2 ? .title : .bodyEmphasis)
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
                font = NSFont.content(.code)

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
        // So ' opens a string only where the language would: a Rust lifetime or an
        // apostrophe in a word would otherwise run on into a comment after it.
        let string = #""(\\.|[^"\\\n])*"|"# + singleQuoted(lang) + #"|`(\\.|[^`\\])*`"#
        let comment = (hashComments ? #"#.*$"# : #"//.*$"#) + #"|/\*[\s\S]*?\*/"#
        if let re = try? NSRegularExpression(pattern: "(?<string>\(string))|\(comment)", options: .anchorsMatchLines) {
            for m in re.matches(in: source, range: full) {
                let isString = m.range(withName: "string").location != NSNotFound
                out.addAttribute(.foregroundColor, value: isString ? NSColor.systemRed : .secondaryLabelColor, range: m.range)
            }
        }
        return out
    }

    /// Languages where ' only ever opens a character literal (Swift has no
    /// single-quoted literal at all): Rust's lifetimes and labels ('static,
    /// 'outer:) are left alone.
    private static let charLiteralQuotes: Set<String> = [
        "swift", "rust", "go", "c", "h", "cc", "cpp", "cxx", "hpp", "c++", "objc", "m", "mm",
        "java", "kotlin", "kt", "scala", "cs", "csharp",
    ]

    /// The pattern for a single-quoted literal in `lang`.
    private static func singleQuoted(_ lang: String) -> String {
        if charLiteralQuotes.contains(lang) {
            // One character, or one escape ('\n', '\'', '\u{1F600}', '\x7f').
            return #"'([^'\\\n]|\\[^\n][^'\\\n]{0,9})'"#
        }
        switch lang {
        case "shell":
            // No escapes inside, and an escaped \' outside opens nothing.
            return #"(?<!\\)'[^'\n]*'"#
        case "python":
            // Not an apostrophe in a word (don't); string prefixes are fine (f'…', rb'…').
            return #"(?<![\p{L}\p{N}_])[rRbBuUfF]{0,2}'(\\.|[^'\\\n])*'"#
        default:
            // Not an apostrophe in a word (don't, it's).
            return #"(?<![\p{L}\p{N}_])'(\\.|[^'\\\n])*'"#
        }
    }
}
