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
                    let rendered = ChatRenderer.render(item, expanded: expanded.contains(item.id))
                    storage.replaceCharacters(in: NSRange(location: location, length: segments[i].length), with: rendered)
                    segments[i] = Segment(id: item.id, item: item, length: rendered.length)
                }
            } else {
                let rendered = ChatRenderer.render(item, expanded: expanded.contains(item.id))
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

    // MARK: NSTextViewDelegate

    /// "Show more / Show less" links on tool cards and thoughts.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
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
