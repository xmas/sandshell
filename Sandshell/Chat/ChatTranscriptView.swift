import AppKit

/// The conversation as one read-only TextKit 2 text view. Rendering everything
/// into a single text storage is what buys the Mac text-system behaviors for
/// free: selection across messages, ⌘F find bar, ⌘E, Look Up, Services, drag a
/// selection out, emacs-style navigation, VoiceOver.
///
/// Each item owns a contiguous segment of the storage; updates replace only
/// the segments whose item changed (streaming touches just the tail). Block
/// backgrounds (code, tool cards, your messages) are drawn by
/// `BlockBackgroundFragment`. The view stays pinned to the bottom unless the
/// user scrolls up.
final class ChatTranscriptView: NSView, NSTextViewDelegate {
    private struct Segment { let id: String; var item: ChatItem; var length: Int }

    private let scrollView = NSScrollView()
    private let textView = TranscriptTextView(usingTextLayoutManager: true)
    private let fragments = BlockFragmentProvider()
    private var segments: [Segment] = []
    private var items: [ChatItem] = []
    private var expanded: Set<String> = []
    private var pending = false
    private var stickToBottom = true
    private var programmaticScroll = false

    /// The session's folder: relative paths in the text resolve against it.
    var workdir: String?
    /// A file path in the text was clicked (with its `:line`, if any).
    var onOpenFile: ((URL, Int?) -> Void)?

    /// Fork the conversation into a new chat, up to and including this reply's text.
    var onFork: ((_ replyText: String) -> Void)?
    /// "Undo" on a turn's changed-files line.
    var onUndo: ((_ turn: String) -> Void)?
    /// The reply under the pointer: a soft highlight behind it and Copy / Fork.
    private var hovered: Int?
    private let hoverBackground = NSView()
    private let replyActions = NSStackView()
    /// Shown only where forking is wired (not in a subagent's window).
    private weak var forkButton: NSButton?

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
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scrollView.documentView = tv
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: Self.minInset, height: 16)
        tv.delegate = self
        // Links color themselves (linkify): a tool group's line stays gray.
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        tv.textLayoutManager?.delegate = fragments
        tv.setAccessibilityIdentifier("chat-transcript")

        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 8
        hoverBackground.isHidden = true
        tv.addSubview(hoverBackground, positioned: .below, relativeTo: nil)
        let copy = Self.actionButton("doc.on.doc", "Copy", #selector(copyReply), self)
        let fork = Self.actionButton("arrow.triangle.branch", "Fork to New Chat", #selector(forkReply), self)
        copy.setAccessibilityIdentifier("chat-reply-copy")
        fork.setAccessibilityIdentifier("chat-reply-fork")
        replyActions.setViews([copy, fork], in: .leading)
        forkButton = fork
        replyActions.spacing = 2
        replyActions.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        replyActions.wantsLayer = true
        replyActions.layer?.cornerRadius = 7
        replyActions.layer?.borderWidth = 1
        replyActions.isHidden = true
        tv.addSubview(replyActions)
        tv.onHover = { [weak self] point in self?.hover(at: point) }
        tv.replyMenuItems = { [weak self] point in self?.replyMenuItems(at: point) ?? [] }

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The text reads in a centered column at most this wide (the Claude
    /// app's); the scroller stays at the pane's edge.
    static let readableWidth: CGFloat = 800
    private static let minInset: CGFloat = 20

    /// The text's side inset in a transcript `width` wide: the margin, or
    /// whatever centers a readable-width column.
    static func sideInset(forWidth width: CGFloat) -> CGFloat {
        max(minInset, ((width - readableWidth) / 2).rounded(.down))
    }

    override func layout() {
        super.layout()
        let side = Self.sideInset(forWidth: scrollView.contentSize.width)
        guard textView.textContainerInset.width != side else { return }
        let keep = stickToBottom
        textView.textContainerInset.width = side
        if keep { scrollToBottom() }
    }

    #if DEBUG
    var debugTextInset: CGFloat { textView.textContainerInset.width }
    var debugContentWidth: CGFloat { scrollView.contentSize.width }
    #endif

    /// Coalesce bursts of streaming updates into one pass per runloop turn.
    func update(_ items: [ChatItem]) {
        self.items = items
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.apply(self.items)
        }
    }

    /// Runs of consecutive tool calls become one group each.
    static func grouped(_ items: [ChatItem]) -> [ChatItem] {
        var out: [ChatItem] = []
        var run: [ChatItem.ToolCall] = []
        func flush() { if !run.isEmpty { out.append(.toolGroup(run)); run = [] } }
        for item in items {
            if case .tool(let call) = item { run.append(call) } else { flush(); out.append(item) }
        }
        flush()
        return out
    }

    private func apply(_ items: [ChatItem], force: Set<String> = []) {
        let items = Self.grouped(items)
        guard let storage = textView.textStorage else { return }
        // Items are append-only with in-place updates; anything else (a new
        // session's history, removals) is a full rebuild.
        let compatible = segments.count <= items.count && zip(segments, items).allSatisfy { $0.id == $1.id }
        if !compatible {
            segments = []
            storage.setAttributedString(NSAttributedString())
        }
        storage.beginEditing()
        var location = 0
        for (i, item) in items.enumerated() {
            if i < segments.count {
                if segments[i].item != item || force.contains(item.id) || Self.contains(item, force) {
                    let rendered = render(item)
                    storage.replaceCharacters(in: NSRange(location: location, length: segments[i].length), with: rendered)
                    segments[i] = Segment(id: item.id, item: item, length: rendered.length)
                }
            } else {
                let rendered = render(item)
                storage.append(rendered)
                segments.append(Segment(id: item.id, item: item, length: rendered.length))
            }
            location += segments[i].length
        }
        storage.endEditing()
        if stickToBottom { scrollToBottom() }
    }

    private func render(_ item: ChatItem) -> NSAttributedString {
        linkify(ChatRenderer.render(item, expanded: expanded.contains(item.id),
                                    isExpanded: { [expanded] in expanded.contains($0) }))
    }

    /// A group holding one of `ids` (a card inside it was toggled).
    private static func contains(_ item: ChatItem, _ ids: Set<String>) -> Bool {
        guard !ids.isEmpty, case .toolGroup(let calls) = item else { return false }
        return calls.contains { ids.contains("tool-\($0.id)") }
    }

    private func scrollToBottom() {
        guard let tlm = textView.textLayoutManager else { return }
        // TextKit 2 lays out lazily; make sure the tail is real before scrolling.
        if let last = tlm.textContentManager?.documentRange.endLocation,
           let tail = tlm.location(last, offsetBy: -min(2000, textView.textStorage?.length ?? 0)),
           let range = NSTextRange(location: tail, end: last) {
            tlm.ensureLayout(for: range)
        }
        programmaticScroll = true
        textView.scrollToEndOfDocument(nil)
        programmaticScroll = false
    }

    /// Follow new output only while the user is at (or near) the bottom.
    @objc private func scrolled() {
        guard !programmaticScroll, let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView.bounds
        stickToBottom = clip.maxY >= doc.frame.height - 24
    }

    /// Run a find action (⌘F/⌘G…) against the transcript, from anywhere in
    /// the chat (the composer forwards these).
    func performFind(_ sender: Any?) {
        window?.makeFirstResponder(textView)
        textView.performTextFinderAction(sender)
    }

    // MARK: Links

    private static let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// Path-like tokens: absolute, ~/, ./, or relative with a slash or an
    /// extension (a backslash-escaped space is part of the name), optionally
    /// followed by :line(:col).
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"(?<![\w/.~-])((?:~|\.{1,2})?/?(?:[A-Za-z0-9_.@+-]|\\ )+(?:/(?:[A-Za-z0-9_.@+-]|\\ )+)*)(?::(\d+))?(?::\d+)?"#)
    /// A path in double quotes, where it may contain plain spaces (backticks are
    /// inline code by the time this runs; single quotes pair up across prose).
    private static let quotedPattern = try? NSRegularExpression(pattern: #""([^"\n]{3,300})""#)
    /// A trailing :line(:col) on a quoted path.
    private static let lineSuffix = try? NSRegularExpression(pattern: #":(\d+)(?::\d+)?$"#)

    /// URLs open in the browser; paths that exist on this Mac open in Files.
    private func linkify(_ rendered: NSAttributedString) -> NSAttributedString {
        let text = rendered.string
        guard text.count < 200_000 else { return rendered }
        let ns = text as NSString
        let out = NSMutableAttributedString(attributedString: rendered)
        let whole = NSRange(location: 0, length: out.length)
        func free(_ r: NSRange) -> Bool {
            var linked = false
            out.enumerateAttribute(.link, in: r) { v, _, stop in if v != nil { linked = true; stop.pointee = true } }
            return !linked
        }
        // Markdown links arrive uncolored; color every link but a tool group's line.
        out.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard let value else { return }
            let toggle = (value as? URL).map { $0.scheme == "sandshell-chat" && $0.path.hasPrefix("/group-") } ?? false
            if !toggle { out.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range) }
        }
        Self.urlDetector?.enumerateMatches(in: text, range: whole) { m, _, _ in
            guard let m, let url = m.url, ["http", "https"].contains(url.scheme ?? ""), free(m.range) else { return }
            out.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: m.range)
        }
        guard let workdir, let pattern = Self.pathPattern else { return out }
        let fm = FileManager.default
        var checked = 0
        /// The file `token` names, if it exists (relative to the session's folder).
        func existing(_ token: String) -> String? {
            guard checked < 400 else { return nil }
            checked += 1
            let expanded = (token.replacingOccurrences(of: "\\ ", with: " ") as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : (workdir as NSString).appendingPathComponent(expanded)
            return fm.fileExists(atPath: path) ? path : nil
        }
        func link(_ path: String, _ range: NSRange, line: String?) {
            guard free(range) else { return }
            var link = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
            if let line { link?.fragment = "L" + line }
            if let url = link?.url { out.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: range) }
        }
        func trimmed(_ token: String) -> String {
            var token = token
            while let last = token.last, ".,;:)".contains(last) { token.removeLast() }
            return token
        }
        func looksLikePath(_ token: String) -> Bool {
            token.count >= 3 && (token.contains("/") || token.contains(".")) && !token.hasPrefix("http")
        }

        // `My Folder/notes.md` (inline code — the backticks are gone by now),
        // "…/Read Me.txt:12"
        var spans = (Self.quotedPattern?.matches(in: text, range: whole) ?? []).map { $0.range(at: 1) }
        out.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue,
                  InlinePresentationIntent(rawValue: raw).contains(.code) else { return }
            spans.append(range)
        }
        for span in spans {
            var inner = span
            var line: String?
            if let l = Self.lineSuffix?.firstMatch(in: text, range: inner) {
                line = ns.substring(with: l.range(at: 1))
                inner.length = l.range.location - inner.location
            }
            let token = ns.substring(with: inner).trimmingCharacters(in: .whitespaces)
            guard looksLikePath(token), token.contains(" ") || token.contains("\\ "),
                  let path = existing(token) else { continue }
            link(path, inner, line: line)
        }

        for m in pattern.matches(in: text, range: whole) {
            guard checked < 400 else { break }
            let r1 = m.range(at: 1)
            let token = trimmed(ns.substring(with: r1))
            guard looksLikePath(token) else { continue }
            let line = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
            if let path = existing(token) {
                link(path, NSRange(location: r1.location, length: (token as NSString).length), line: line)
                continue
            }
            // An unquoted path with spaces ("/Users/me/My Folder/a.txt"): the
            // longest run of following words, on this line, that names a file.
            guard token.hasPrefix("/") || token.hasPrefix("~/"), m.range.location + m.range.length < ns.length,
                  ns.character(at: m.range.location + m.range.length) == 0x20 else { continue }
            let lineEnd = ns.rangeOfCharacter(from: .newlines, range: NSRange(
                location: r1.location, length: ns.length - r1.location)).location
            // A few hundred characters is plenty for a path; long lines stay cheap.
            let rest = ns.substring(with: NSRange(location: r1.location,
                                                  length: min((lineEnd == NSNotFound ? ns.length : lineEnd) - r1.location, 300)))
            let words = rest.components(separatedBy: " ")
            guard words.count >= 2 else { continue }
            var best: (path: String, length: Int, line: String?)?
            for count in 2...min(words.count, 8) {
                var candidate = trimmed(words.prefix(count).joined(separator: " "))
                var candidateLine: String?
                let cns = candidate as NSString
                if let l = Self.lineSuffix?.firstMatch(in: candidate, range: NSRange(location: 0, length: cns.length)) {
                    candidateLine = cns.substring(with: l.range(at: 1))
                    candidate = trimmed(cns.substring(to: l.range.location))
                }
                if let path = existing(candidate) { best = (path, (candidate as NSString).length, candidateLine) }
            }
            if let best { link(best.path, NSRange(location: r1.location, length: best.length), line: best.line) }
        }
        return out
    }

    // MARK: Reply hover

    private static func actionButton(_ symbol: String, _ label: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        NSButton.symbol(symbol, label: label, size: NSSize(width: 24, height: 20), target: target, action: action)
    }

    /// Which reply (agent text segment) is under `point`, and its frame.
    private func reply(at point: NSPoint) -> (index: Int, frame: NSRect)? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let char = textView.characterIndexForInsertion(at: point)
        var location = 0
        for (i, segment) in segments.enumerated() {
            defer { location += segment.length }
            guard char >= location, char < location + segment.length else { continue }
            guard case .agentText = segment.item, let frame = frame(of: NSRange(location: location, length: segment.length)),
                  frame.insetBy(dx: -12, dy: -6).contains(point) else { return nil }
            return (i, frame)
        }
        return nil
    }

    private func frame(of range: NSRange) -> NSRect? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: range.location),
              let end = tcm.location(start, offsetBy: max(0, range.length - 1)),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        var union: NSRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
            union = union.map { $0.union(rect) } ?? rect
            return true
        }
        let origin = textView.textContainerOrigin
        return union.map { NSRect(x: textView.textContainerInset.width, y: $0.minY + origin.y,
                                  width: textView.bounds.width - 2 * textView.textContainerInset.width,
                                  height: $0.height) }
    }

    private func hover(at point: NSPoint?) {
        let hit = point.flatMap { reply(at: $0) }
        hovered = hit?.index
        guard let hit else {
            hoverBackground.isHidden = true
            replyActions.isHidden = true
            return
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        hoverBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(dark ? 0.06 : 0.035).cgColor
        hoverBackground.frame = hit.frame.insetBy(dx: -10, dy: -6)
        hoverBackground.isHidden = false
        replyActions.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        replyActions.layer?.borderColor = NSColor.separatorColor.cgColor
        forkButton?.isHidden = onFork == nil
        let size = replyActions.fittingSize
        replyActions.frame = NSRect(x: hoverBackground.frame.maxX - size.width - 6,
                                    y: hoverBackground.frame.minY - size.height / 2,
                                    width: size.width, height: size.height)
        replyActions.isHidden = false
    }

    private var hoveredText: String? {
        guard let i = hovered, i < segments.count, case .agentText(_, let text) = segments[i].item else { return nil }
        return text
    }

    #if DEBUG
    /// Self-test: hover the first reply (as the pointer would).
    func debugHoverFirstReply() {
        var location = 0
        for segment in segments {
            if case .agentText = segment.item, let f = frame(of: NSRange(location: location, length: segment.length)) {
                return hover(at: NSPoint(x: f.midX, y: f.midY))
            }
            location += segment.length
        }
    }
    var debugReplyActionsShown: Bool { !replyActions.isHidden }
    /// Self-test: every link in the transcript as (text, link).
    var debugLinks: [(String, String)] {
        guard let storage = textView.textStorage else { return [] }
        var out: [(String, String)] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if let v { out.append(((storage.string as NSString).substring(with: r), "\(v)")) }
        }
        return out
    }
    func debugApplyNow(_ items: [ChatItem]) { apply(items) }
    /// Self-test: the transcript's text.
    var debugText: String { textView.string }
    /// Self-test: click a "Show more" / group link by id.
    func debugToggle(_ id: String) {
        _ = textView(textView, clickedOnLink: ChatRenderer.toggleURL(id), at: 0)
    }
    #endif

    @objc private func copyReply() {
        guard let i = hovered else { return }
        copyReplyText(at: i)
    }

    @objc private func forkReply() {
        guard let text = hoveredText else { return }
        onFork?(text)
    }

    /// File ▸ Print: the whole transcript, paginated.
    func printTranscript() {
        let op = NSPrintOperation(view: textView)
        op.jobTitle = window?.title ?? "Conversation"
        if let window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    /// A reply as its Markdown (plain text) and as it looks (rich text).
    private func copyReplyText(at index: Int) {
        guard index < segments.count, case .agentText(_, let markdown) = segments[index].item else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown, forType: .string)
        if let storage = textView.textStorage {
            let start = segments[..<index].reduce(0) { $0 + $1.length }
            let range = NSRange(location: start, length: segments[index].length)
            if NSMaxRange(range) <= storage.length,
               let rtf = storage.attributedSubstring(from: range).rtf(from: NSRange(location: 0, length: range.length), documentAttributes: [:]) {
                pb.setData(rtf, forType: .rtf)
            }
        }
    }

    /// Right-click on a reply: the hover actions, reachable without a pointer hover.
    private func replyMenuItems(at point: NSPoint) -> [NSMenuItem] {
        guard let hit = reply(at: point), case .agentText(_, let text) = segments[hit.index].item else { return [] }
        var items = [NSMenuItem("Copy Reply") { [weak self] in self?.copyReplyText(at: hit.index) }]
        if onFork != nil { items.append(NSMenuItem("Fork from This Reply") { [weak self] in self?.onFork?(text) }) }
        items.append(NSMenuItem("Share Reply…") { [weak self] in
            guard let self, let frame = self.frame(of: NSRange(location: self.segments[..<hit.index].reduce(0) { $0 + $1.length },
                                                                length: self.segments[hit.index].length)) else { return }
            NSSharingServicePicker(items: [text as NSString]).show(relativeTo: frame, of: self.textView, preferredEdge: .minY)
        })
        return items
    }

    // MARK: NSTextViewDelegate

    /// "Show more / Show less" links on tool cards and thoughts.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, url.isFileURL {
            let line = url.fragment.flatMap { $0.hasPrefix("L") ? Int($0.dropFirst()) : nil }
            var clean = URLComponents(url: url, resolvingAgainstBaseURL: false)
            clean?.fragment = nil
            if let file = clean?.url { onOpenFile?(file, line) }
            return true
        }
        if let url = link as? URL, url.scheme == "sandshell-chat", url.host == "undo" {
            onUndo?(url.lastPathComponent)
            return true
        }
        guard let url = link as? URL, url.scheme == "sandshell-chat", url.host == "toggle" else { return false }
        let id = url.path.removingPercentEncoding.map { String($0.dropFirst()) } ?? ""
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        let keep = stickToBottom
        stickToBottom = false   // don't jump while the user reads what they opened
        apply(items, force: [id])
        stickToBottom = keep
        return true
    }
}
