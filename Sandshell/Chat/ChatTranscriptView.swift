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
    private struct Segment { let id: String; var item: ChatItem; var length: Int; var hasTable: Bool }

    private let scrollView = NSScrollView()
    private let textView = TranscriptTextView(usingTextLayoutManager: true)
    private let document = FlippedView()
    private let fragments = BlockFragmentProvider()
    private var segments: [Segment] = []
    private var items: [ChatItem] = []
    private var expanded: Set<String> = []
    private var pending = false
    private var stickToBottom = true { didSet { if stickToBottom != oldValue { updateEndCues() } } }
    private var programmaticScroll = false
    /// While there's more below: the text fades out at the bottom edge (into
    /// the composer), and a round ↓ button jumps to the newest.
    private let fade = CAGradientLayer()
    private let jumpButton = NSButton()
    private static let fadeHeight: CGFloat = 36

    /// The session's folder: relative paths in the text resolve against it.
    var workdir: String?
    /// A file path in the text was clicked (with its `:line`, if any).
    var onOpenFile: ((URL, Int?) -> Void)?

    /// Fork the conversation into a new chat, up to and including this reply's text.
    var onFork: ((_ replyText: String) -> Void)?
    /// "Undo" on a turn's changed-files line.
    var onUndo: ((_ turn: String) -> Void)?
    /// The reply under the pointer, which shows Copy / Fork.
    private var hovered: Int?
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
        // The text view sits centered in a full-width document (sized in
        // layout(): the readable column's width at most). Resizing the pane
        // moves it as a whole: its own bounds, and so its laid-out text, stay put.
        tv.autoresizingMask = [.minXMargin, .maxXMargin]
        tv.textContainer?.widthTracksTextView = true
        document.autoresizingMask = [.width]
        document.addSubview(tv)
        scrollView.documentView = document
        tv.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(textHeightChanged),
                                               name: NSView.frameDidChangeNotification, object: tv)
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
        tv.isOverControls = { [weak self] point in self?.isOverActions(point) ?? false }
        tv.replyMenuItems = { [weak self] point in self?.replyMenuItems(at: point) ?? [] }

        scrollView.wantsLayer = true
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor]
        fade.actions = ["colors": NSNull(), "locations": NSNull(), "bounds": NSNull(), "position": NSNull()]
        scrollView.layer?.mask = fade

        jumpButton.configureSymbol("arrow.down", label: "Jump to the Newest", pointSize: 13, weight: .semibold,
                                   tint: .labelColor, target: self, action: #selector(jumpToNewest),
                                   id: "chat-jump-to-newest")
        jumpButton.wantsLayer = true
        jumpButton.layer?.cornerRadius = Self.jumpSize / 2
        jumpButton.layer?.borderWidth = 1
        jumpButton.layer?.shadowOpacity = 0.12
        jumpButton.layer?.shadowRadius = 4
        jumpButton.layer?.shadowOffset = CGSize(width: 0, height: -1)
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(jumpButton)
        NSLayoutConstraint.activate([
            jumpButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            jumpButton.widthAnchor.constraint(equalToConstant: Self.jumpSize),
            jumpButton.heightAnchor.constraint(equalToConstant: Self.jumpSize),
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The text reads in a centered column at most this wide (the Claude
    /// app's); the scroller stays at the pane's edge.
    static let readableWidth: CGFloat = 800
    private static let minInset: CGFloat = 20

    /// The text view's width in a transcript `width` wide: the whole width, up
    /// to the readable column and its margins.
    static func textViewWidth(forWidth width: CGFloat) -> CGFloat {
        min(width, readableWidth + 2 * minInset)
    }

    override func layout() {
        super.layout()
        // A wide pane centers a column of fixed width, so resizing the pane —
        // the sidebar sliding in or out — moves the text without laying it out
        // again; a narrower pane reflows it.
        let clipWidth = scrollView.contentSize.width
        let width = Self.textViewWidth(forWidth: clipWidth)
        if document.frame.width != clipWidth { document.setFrameSize(NSSize(width: clipWidth, height: document.frame.height)) }
        if textView.frame.width != width {
            let keep = stickToBottom
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            if keep { scrollToBottomSoon() }
            refitTablesSoon()
        }
        let x = ((clipWidth - width) / 2).rounded()
        if textView.frame.minX != x { textView.setFrameOrigin(NSPoint(x: x, y: 0)) }
        fade.frame = scrollView.bounds
        // Taller or shorter (the plan pin or a long draft going, a tiled or
        // zoomed window — no live resize): lay out what now shows, or the strip
        // it uncovered stays blank.
        if scrollView.contentSize != laidOutClipSize {
            laidOutClipSize = scrollView.contentSize
            layoutVisibleText()
            layoutVisibleTextSoon()   // and once the scroll view has tiled its clip
        }
        updateEndCues()
    }
    private var laidOutClipSize: NSSize = .zero

    /// Shown again (another session was in the pane, or the terminal view) or
    /// put back in a window: TextKit 2 laid out nothing while it didn't show,
    /// and nothing else asks it to now.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        layoutVisibleTextSoon()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }
        layoutVisibleTextSoon()
        // The window back in view (another Space, uncovered): it may have
        // missed laying out the turn that streamed in meanwhile.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                self.layoutVisibleTextSoon()
            }
        }
    }
    private var occlusionObserver: NSObjectProtocol?

    isolated deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// Once the view's in place (next runloop turn).
    private func layoutVisibleTextSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
            self.layoutVisibleText()
        }
    }

    private static let jumpSize: CGFloat = 30

    /// More below than shows: the fade and the ↓ button; at the end, neither.
    private func updateEndCues() {
        let doc = document.frame.height, clip = scrollView.contentView.bounds
        let more = !stickToBottom && doc > clip.height + 1 && clip.maxY < doc - 24
        let height = max(scrollView.bounds.height, 1)
        let edge = min(Self.fadeHeight / height, 0.5)
        // The mask's alpha: opaque, then fading to nothing over the bottom edge
        // (location 0 at the bottom: y 0 there, or 1 in a flipped layer).
        let bottom: CGFloat = scrollView.layer?.contentsAreFlipped() == true ? 1 : 0
        fade.startPoint = CGPoint(x: 0.5, y: bottom)
        fade.endPoint = CGPoint(x: 0.5, y: 1 - bottom)
        fade.colors = [more ? NSColor.clear.cgColor : NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fade.locations = [0, NSNumber(value: Double(edge)), 1]
        if jumpButton.isHidden == more {
            jumpButton.isHidden = !more
            jumpButton.setAccessibilityElement(more)
        }
        jumpButton.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        jumpButton.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// ↓: to the newest, and follow it again.
    @objc private func jumpToNewest() {
        stickToBottom = true
        scrollToBottom()
    }

    /// The document is as tall as the text.
    @objc private func textHeightChanged() {
        let height = textView.frame.height
        if document.frame.height != height { document.setFrameSize(NSSize(width: document.frame.width, height: height)) }
        layoutVisibleText()
        updateEndCues()
    }

    /// Once per runloop turn, however many times layout asks.
    private func scrollToBottomSoon() {
        guard !bottomPending else { return }
        bottomPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bottomPending = false
            self.scrollToBottom()
        }
    }
    private var bottomPending = false

    #if DEBUG
    /// The text's column (inside the margins), in this view's coordinates.
    var debugTextColumn: NSRect {
        convert(textView.frame, from: textView.superview).insetBy(dx: textView.textContainerInset.width, dy: 0)
    }
    var debugTextViewWidth: CGFloat { textView.frame.width }
    /// Self-test: TextKit 2 has laid out what's on screen, down to the end once scrolled there.
    var debugViewportReachesEnd: Bool {
        guard let tlm = textView.textLayoutManager, let viewport = tlm.textViewportLayoutController.viewportRange else { return false }
        return viewport.endLocation.compare(tlm.documentRange.endLocation) != .orderedAscending
    }
    func debugScrollToBottom() { scrollToBottom() }
    /// Self-test: how much of the text showing on screen TextKit 2 hasn't laid
    /// out — points of the visible text column outside its viewport.
    var debugUnlaidVisibleHeight: CGFloat {
        guard let vlc = textView.textLayoutManager?.textViewportLayoutController else { return .infinity }
        let visible = textView.visibleRect
        let textEnd = min(visible.maxY, textView.frame.height - textView.textContainerInset.height)
        guard textEnd > visible.minY else { return 0 }
        // The viewport is in the text container's coordinates (inside the inset).
        let laid = vlc.viewportBounds.offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
        let above = max(0, min(laid.minY, textEnd) - visible.minY)
        let below = max(0, textEnd - max(laid.maxY, visible.minY))
        return above + below
    }
    /// The fade and the ↓ button show (more below).
    var debugEndCuesShown: Bool { !jumpButton.isHidden }
    /// Where the fade's clear end is, on screen: "bottom" or "top".
    var debugFadeEdge: String {
        let flipped = scrollView.layer?.contentsAreFlipped() ?? false
        return (fade.startPoint.y == 0) != flipped ? "bottom" : "top"
    }
    func debugScroll(toY y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    func debugJumpToNewest() { jumpToNewest() }
    var debugClipOrigin: NSPoint { scrollView.contentView.bounds.origin }
    var debugDocHeight: CGFloat { textView.frame.height }
    #endif

    /// Coalesce bursts of streaming updates into one pass per runloop turn.
    /// The pass draws the latest items (`self.items`), not the first call's.
    func update(_ items: [ChatItem]) {
        self.items = items
        guard !pending else { return }
        pending = true
        Task { [weak self] in
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
                    segments[i] = Segment(id: item.id, item: item, length: rendered.length, hasTable: Self.hasTable(rendered))
                }
            } else {
                let rendered = render(item)
                storage.append(rendered)
                segments.append(Segment(id: item.id, item: item, length: rendered.length, hasTable: Self.hasTable(rendered)))
            }
            location += segments[i].length
        }
        storage.endEditing()
        // Following the end lays it out on the way there; otherwise lay out
        // what shows, so a paragraph changed in place isn't left drawn as it was.
        if stickToBottom { scrollToBottom() } else { layoutVisibleText() }
    }

    private func render(_ item: ChatItem) -> NSAttributedString {
        renderedTableWidth = tableWidth
        return linkify(ChatRenderer.render(item, expanded: expanded.contains(item.id), width: renderedTableWidth,
                                           isExpanded: { [expanded] in expanded.contains($0) }))
    }

    // MARK: Tables

    /// The width tables are fitted to: the text column inside the margins
    /// (the readable column before the first layout).
    private var tableWidth: CGFloat {
        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        let width = (textView.frame.width - 2 * (textView.textContainerInset.width + padding)).rounded(.down)
        return width > 100 ? width : Self.readableWidth
    }
    private var renderedTableWidth: CGFloat = 0
    private var tablesPending = false

    static func hasTable(_ rendered: NSAttributedString) -> Bool {
        var found = false
        rendered.enumerateAttribute(.chatTable, in: NSRange(location: 0, length: rendered.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// The column's width changed: lay out the tables again to fit it (once
    /// per runloop turn, however many times layout asks).
    private func refitTablesSoon() {
        guard !tablesPending, abs(tableWidth - renderedTableWidth) >= 1, segments.contains(where: \.hasTable) else { return }
        tablesPending = true
        Task { [weak self] in
            guard let self else { return }
            self.tablesPending = false
            guard abs(self.tableWidth - self.renderedTableWidth) >= 1 else { return }
            self.apply(self.items, force: Set(self.segments.filter(\.hasTable).map(\.id)))
        }
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
        textHeightChanged()   // the document as tall as the text, laid out to its end
        programmaticScroll = true
        // The clip itself: the text view's scrollToEndOfDocument doesn't reach a
        // scroll view it isn't the document of.
        let clip = scrollView.contentView
        let bottom = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
        scrollView.reflectScrolledClipView(clip)
        programmaticScroll = false
        layoutVisibleText()
    }

    private func layoutVisibleText() {
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    /// Follow new output only while the user is at (or near) the bottom.
    @objc private func scrolled() {
        // The text view isn't the scroll view's document (it sits in a centered
        // one), so TextKit 2 isn't told what scrolled into view: lay that out.
        layoutVisibleText()
        guard !programmaticScroll, let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView.bounds
        stickToBottom = clip.maxY >= doc.frame.height - 24
        updateEndCues()
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
            let toggle = (value as? URL).map {
                $0.scheme == "sandshell-chat" && $0.path(percentEncoded: false).hasPrefix("/group-")
            } ?? false
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
            let expanded = (token.replacing("\\ ", with: " ") as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : (workdir as NSString).appendingPathComponent(expanded)
            return fm.fileExists(atPath: path) ? path : nil
        }
        func link(_ path: String, _ range: NSRange, line: String?) {
            guard free(range) else { return }
            var link = URLComponents(url: URL(filePath: path, directoryHint: .checkFileSystem), resolvingAgainstBaseURL: false)
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

    /// The text a hover bar copies: a reply's Markdown, or your own message.
    private static func copyableText(_ item: ChatItem) -> String? {
        switch item {
        case .agentText(_, let text): text
        case .user(_, let text, _): text.isEmpty ? nil : text
        default: nil
        }
    }

    /// Which reply (or message of yours) is under `point`, and its frame.
    private func reply(at point: NSPoint) -> (index: Int, frame: NSRect)? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let char = textView.characterIndexForInsertion(at: point)
        var location = 0
        for (i, segment) in segments.enumerated() {
            defer { location += segment.length }
            guard char >= location, char < location + segment.length else { continue }
            guard Self.copyableText(segment.item) != nil, let frame = frame(of: NSRange(location: location, length: segment.length)),
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
        // On the action bar (or about to be): still the reply it's for. Half of
        // it sits above the reply, where the reply's own area ends.
        if let point, isOverActions(point) { return }
        let hit = point.flatMap { reply(at: $0) }
        hovered = hit?.index
        guard let hit else {
            replyActions.isHidden = true
            return
        }
        // Just the buttons, no highlight behind the reply.
        let area = hit.frame.insetBy(dx: -10, dy: -6)
        replyActions.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        replyActions.layer?.borderColor = NSColor.separatorColor.cgColor
        // Fork is from a reply; your own messages just copy.
        forkButton?.isHidden = onFork == nil || !isReply(hit.index)
        let size = replyActions.fittingSize
        replyActions.frame = NSRect(x: area.maxX - size.width - 6,
                                    y: area.minY - size.height / 2,
                                    width: size.width, height: size.height)
        replyActions.isHidden = false
    }

    private func isOverActions(_ point: NSPoint) -> Bool {
        !replyActions.isHidden && replyActions.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    private var hoveredText: String? {
        guard let i = hovered, i < segments.count else { return nil }
        return Self.copyableText(segments[i].item)
    }

    private func isReply(_ index: Int) -> Bool {
        guard index < segments.count, case .agentText = segments[index].item else { return false }
        return true
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
    /// Self-test: hover your first message.
    func debugHoverFirstUserMessage() {
        var location = 0
        for segment in segments {
            if case .user = segment.item, let f = frame(of: NSRange(location: location, length: segment.length)) {
                return hover(at: NSPoint(x: f.midX, y: f.midY))
            }
            location += segment.length
        }
    }
    /// Self-test: the pointer moves onto the top half of the hover bar (above the reply).
    func debugHoverActionsTop() { hover(at: NSPoint(x: replyActions.frame.midX, y: replyActions.frame.minY + 2)) }
    var debugReplyActionsShown: Bool { !replyActions.isHidden }
    /// Whether the hover bar offers Fork to New Chat (only where forking is wired).
    var debugForkShown: Bool { !replyActions.isHidden && forkButton?.isHidden == false }
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
    /// Self-test: the plan marks the laid-out fragments draw, in order.
    var debugPlanMarks: [ChatItem.PlanEntry.State] {
        guard let tlm = textView.textLayoutManager else { return [] }
        var marks: [ChatItem.PlanEntry.State] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let mark = (fragment as? BlockBackgroundFragment)?.mark { marks.append(mark.state) }
            return true
        }
        return marks
    }
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
        guard let i = hovered, isReply(i), let text = hoveredText else { return }
        onFork?(text)
    }

    /// File ▸ Print: the whole transcript, paginated.
    func printTranscript() {
        let op = NSPrintOperation(view: textView)
        op.jobTitle = window?.title ?? "Conversation"
        if let window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    /// What was just copied lights up in the accent color and fades.
    private func flashCopied(_ range: NSRange) {
        guard let frame = frame(of: range) else { return }
        let flash = NSView(frame: frame.insetBy(dx: -8, dy: -4))
        flash.wantsLayer = true
        flash.layer?.cornerRadius = 8
        flash.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        textView.addSubview(flash, positioned: .below, relativeTo: nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.55
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            flash.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { flash.removeFromSuperview() } })
    }

    /// A reply as its Markdown (plain text) and as it looks (rich text); a
    /// message of yours as you typed it.
    private func copyReplyText(at index: Int) {
        guard index < segments.count, let markdown = Self.copyableText(segments[index].item) else { return }
        flashCopied(NSRange(location: segments[..<index].reduce(0) { $0 + $1.length }, length: segments[index].length))
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
        guard let hit = reply(at: point), let text = Self.copyableText(segments[hit.index].item) else { return [] }
        guard isReply(hit.index) else {
            return [NSMenuItem("Copy Message") { [weak self] in self?.copyReplyText(at: hit.index) }]
        }
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
        // Decoded once (`toggleURL` encoded it once): an id with a % in it survives.
        let id = String(url.path(percentEncoded: false).dropFirst())
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        let keep = stickToBottom
        stickToBottom = false   // don't jump while the user reads what they opened
        apply(items, force: [id])
        stickToBottom = keep
        return true
    }
}

/// A plain top-down view: the transcript's document, holding its text view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
