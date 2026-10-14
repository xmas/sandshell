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
    /// The reply under the pointer: a soft highlight behind it and Copy / Fork.
    private var hovered: Int?
    private let hoverBackground = NSView()
    private let replyActions = NSStackView()

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
        tv.textContainerInset = NSSize(width: 20, height: 16)
        tv.delegate = self
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
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
        replyActions.spacing = 2
        replyActions.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        replyActions.wantsLayer = true
        replyActions.layer?.cornerRadius = 7
        replyActions.layer?.borderWidth = 1
        replyActions.isHidden = true
        tv.addSubview(replyActions)
        tv.onHover = { [weak self] point in self?.hover(at: point) }

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

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

    private func apply(_ items: [ChatItem], force: Set<String> = []) {
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
                if segments[i].item != item || force.contains(item.id) {
                    let rendered = linkify(ChatRenderer.render(item, expanded: expanded.contains(item.id)))
                    storage.replaceCharacters(in: NSRange(location: location, length: segments[i].length), with: rendered)
                    segments[i] = Segment(id: item.id, item: item, length: rendered.length)
                }
            } else {
                let rendered = linkify(ChatRenderer.render(item, expanded: expanded.contains(item.id)))
                storage.append(rendered)
                segments.append(Segment(id: item.id, item: item, length: rendered.length))
            }
            location += segments[i].length
        }
        storage.endEditing()
        if stickToBottom { scrollToBottom() }
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
    /// extension, optionally followed by :line(:col).
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"(?<![\w/.~-])((?:~|\.{1,2})?/?[A-Za-z0-9_.@+-]+(?:/[A-Za-z0-9_.@+-]+)*)(?::(\d+))?(?::\d+)?"#)

    /// URLs open in the browser; paths that exist on this Mac open in Files.
    private func linkify(_ rendered: NSAttributedString) -> NSAttributedString {
        let text = rendered.string
        guard text.count < 200_000 else { return rendered }
        let out = NSMutableAttributedString(attributedString: rendered)
        let whole = NSRange(location: 0, length: out.length)
        func free(_ r: NSRange) -> Bool {
            var linked = false
            out.enumerateAttribute(.link, in: r) { v, _, stop in if v != nil { linked = true; stop.pointee = true } }
            return !linked
        }
        Self.urlDetector?.enumerateMatches(in: text, range: whole) { m, _, _ in
            guard let m, let url = m.url, ["http", "https"].contains(url.scheme ?? ""), free(m.range) else { return }
            out.addAttribute(.link, value: url, range: m.range)
        }
        guard let workdir, let pattern = Self.pathPattern else { return out }
        let fm = FileManager.default
        var checked = 0
        for m in pattern.matches(in: text, range: whole) {
            guard checked < 300, let r = Range(m.range(at: 1), in: text) else { continue }
            var token = String(text[r])
            while let last = token.last, ".,;:)".contains(last) { token.removeLast() }
            guard token.count >= 3, token.contains("/") || token.contains("."), !token.hasPrefix("http") else { continue }
            checked += 1
            let expanded = (token as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : (workdir as NSString).appendingPathComponent(expanded)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let range = NSRange(location: m.range(at: 1).location, length: (token as NSString).length)
            guard free(range) else { continue }
            var link = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
            if let lr = Range(m.range(at: 2), in: text) { link?.fragment = "L" + text[lr] }
            if let url = link?.url { out.addAttribute(.link, value: url, range: range) }
        }
        return out
    }

    // MARK: Reply hover

    private static func actionButton(_ symbol: String, _ label: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.toolTip = label
        b.contentTintColor = .secondaryLabelColor
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
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
    #endif

    @objc private func copyReply() {
        guard let text = hoveredText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func forkReply() {
        guard let text = hoveredText else { return }
        onFork?(text)
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
