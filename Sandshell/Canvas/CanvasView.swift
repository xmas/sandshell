import AppKit
import SwiftUI
import WebKit

/// A board on a zoomable, pannable surface: each artboard a web view sized to
/// it, titled above. Scroll anywhere or drag the empty space to pan (⌥-scroll
/// scrolls a page itself); pinch to zoom; ⌥-click or right-click ▸ Add Note
/// leaves a note on a page for the chat. Watches the board folder and reloads
/// what changed, so the agent's edits show as they land. See docs/canvas.md.
@MainActor
final class CanvasView: NSView {
    private let scrollView = CanvasScrollView()
    private let document = CanvasDocumentView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var board: CanvasBoard?
    private var folder: URL?
    private var artboardViews: [String: ArtboardView] = [:]
    /// When each file artboard's file was last seen changed (a reload only for those).
    private var modified: [String: Date] = [:]
    private var watcher: FileWatcher?
    private var zoomedToFit = false
    /// Notes waiting to go to the chat.
    private(set) var notes: [CanvasNote] = []
    private var notePopover: NSPopover?
    private let notesBar = NSStackView()
    private let notesLabel = NSTextField(labelWithString: "")
    private let commentButton = NSButton(title: "Comment", target: nil, action: nil)
    /// Clicks and drags on a page leave comments, instead of reaching the page.
    private(set) var isCommenting = false
    /// Instead of finding the chat (tests).
    var onSendNotes: ((String, [ChatAttachment]) -> Bool)?

    /// Empty space around the artboards.
    static let margin: CGFloat = 120

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = CanvasClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // A board pans freely, diagonally too — not locked to one axis like a page.
        scrollView.usesPredominantAxisScrolling = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 4
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = document
        addSubview(scrollView)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true
        addSubview(messageLabel)
        let send = NSButton(title: "Send to Chat", target: self, action: #selector(sendNotesClicked))
        send.setAccessibilityIdentifier("canvas-send-notes")
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearNotesClicked))
        clear.setAccessibilityIdentifier("canvas-clear-notes")
        notesLabel.font = .role(.bodyEmphasis)
        notesBar.setViews([notesLabel, clear, send], in: .leading)
        notesBar.orientation = .horizontal
        notesBar.spacing = 10
        notesBar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        notesBar.wantsLayer = true
        notesBar.layer?.cornerRadius = 10
        notesBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        notesBar.layer?.borderWidth = 1
        notesBar.layer?.borderColor = NSColor.separatorColor.cgColor
        notesBar.translatesAutoresizingMaskIntoConstraints = false
        notesBar.isHidden = true
        addSubview(notesBar)
        commentButton.setButtonType(.pushOnPushOff)
        commentButton.bezelStyle = .rounded
        commentButton.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        commentButton.imagePosition = .imageLeading
        commentButton.target = self
        commentButton.action = #selector(commentClicked)
        commentButton.toolTip = "Click a page to comment on that spot, or drag to comment on an area"
        commentButton.setAccessibilityIdentifier("canvas-comment")
        commentButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commentButton)
        NSLayoutConstraint.activate([
            commentButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            commentButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            notesBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            notesBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        setAccessibilityIdentifier("canvas")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Show the board in `folder` (nil = nothing), watching it for changes.
    func show(_ folder: URL?) {
        guard folder != self.folder else { return }
        self.folder = folder
        watcher = nil
        zoomedToFit = false
        clearNotes()
        for view in artboardViews.values { view.removeFromSuperview() }
        artboardViews = [:]
        modified = [:]
        board = nil
        guard let folder else { return reload() }
        watcher = FileWatcher(path: folder.path(percentEncoded: false), latency: 0.2) { [weak self] in self?.reload() }
        reload()
    }

    /// Read board.json again: artboards added, moved or gone follow it, and
    /// a file artboard whose file changed reloads.
    func reload() {
        guard let folder else {
            board = nil
            return showMessage(nil)
        }
        switch CanvasBoard.load(folder: folder) {
        case .failure(let error):
            // Keep what's on screen while the agent's rewriting it; say so only when there's nothing.
            if board == nil { showMessage(error.localizedDescription) }
        case .success(let loaded):
            board = loaded
            showMessage(loaded.artboards.isEmpty ? "Nothing on this board yet. Describe what to design in the chat beside it." : nil)
            layoutArtboards(loaded)
        }
    }

    private func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
        scrollView.isHidden = text != nil && artboardViews.isEmpty
    }

    private func layoutArtboards(_ board: CanvasBoard) {
        let frames = board.frames()
        for (id, view) in artboardViews where !board.artboards.contains(where: { $0.id == id }) {
            view.removeFromSuperview()
            artboardViews[id] = nil
            modified[id] = nil
        }
        let bounds = frames.values.reduce(CGRect.null) { $0.union($1) }
        let origin = CGPoint(x: Self.margin - (bounds.isNull ? 0 : bounds.minX),
                             y: Self.margin + ArtboardView.titleHeight - (bounds.isNull ? 0 : bounds.minY))
        for artboard in board.artboards {
            guard let frame = frames[artboard.id] else { continue }
            let view = artboardViews[artboard.id] ?? {
                let v = ArtboardView()
                let id = artboard.id
                v.onNote = { [weak self] point, area in self?.beginNote(on: id, at: point, area: area) }
                v.isCommenting = isCommenting
                document.addSubview(v)
                artboardViews[artboard.id] = v
                return v
            }()
            view.frame = CGRect(x: frame.minX + origin.x, y: frame.minY + origin.y - ArtboardView.titleHeight,
                                width: frame.width, height: frame.height + ArtboardView.titleHeight)
            view.title = artboard.title
            let source = board.fileURL(of: artboard) ?? artboard.url
            let stamp = board.fileURL(of: artboard).flatMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            if view.source != source {
                view.load(source, readAccess: board.folder)
            } else if let stamp, stamp != modified[artboard.id] {
                view.reloadPage()
            }
            modified[artboard.id] = stamp
        }
        let size = bounds.isNull ? .zero : bounds.size
        document.setFrameSize(NSSize(width: size.width + 2 * Self.margin,
                                     height: size.height + 2 * Self.margin + ArtboardView.titleHeight))
        if !zoomedToFit, !board.artboards.isEmpty {
            zoomedToFit = true
            DispatchQueue.main.async { [weak self] in self?.zoomToFit() }
        }
    }

    /// Everything on screen at once (never larger than 100 %), centered.
    func zoomToFit() {
        guard document.frame.width > 0, scrollView.contentSize.width > 0 else { return }
        let fit = min(scrollView.contentSize.width / document.frame.width,
                      scrollView.contentSize.height / document.frame.height, 1)
        scrollView.magnification = max(fit, scrollView.minMagnification)
        let visible = scrollView.contentView.bounds.size
        let doc = document.frame
        scrollView.contentView.scroll(to: NSPoint(x: doc.midX - visible.width / 2, y: doc.midY - visible.height / 2))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func zoom(by factor: CGFloat) {
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(scrollView.magnification * factor, centeredAt: center)
    }

    // MARK: Notes

    @objc private func commentClicked() { setCommenting(commentButton.state == .on) }

    func setCommenting(_ on: Bool) {
        isCommenting = on
        commentButton.state = on ? .on : .off
        for view in artboardViews.values { view.isCommenting = on }
    }

    /// A click or drag in comment mode, or ⌥-click: what's there, then ask what to change.
    private func beginNote(on id: String, at point: CGPoint, area: CGRect? = nil) {
        Task { [weak self] in
            guard let self, let view = self.artboardViews[id] else { return }
            let element = await view.element(at: point, area: area)
            self.notePopover?.close()
            #if DEBUG
            self.debugNoteElement = element
            #endif
            let entry = CanvasNoteEntry(element: element?.selector) { [weak self] text, send in
                self?.notePopover?.close()
                self?.notePopover = nil
                self?.addNote(CanvasNote(artboard: id, point: point, area: area, element: element, text: text))
                if send { Task { [weak self] in await self?.sendNotes() } }
            }
            let anchor = view.noteAnchor
            let spot = area ?? CGRect(origin: point, size: CGSize(width: 1, height: 1))
            let rect = NSRect(x: spot.minX, y: anchor.isFlipped ? spot.minY : anchor.bounds.height - spot.maxY,
                              width: spot.width, height: spot.height)
            _ = NSPopover.toggle(&self.notePopover, below: anchor, rect: rect) { .hosting(entry) }
        }
    }

    func addNote(_ note: CanvasNote) {
        notes.append(note)
        showNotes()
    }

    private func clearNotes() {
        notes = []
        showNotes()
    }

    /// Each artboard's pins (numbered as in the message), and the bar.
    private func showNotes() {
        for (id, view) in artboardViews { view.setPins(marks(on: id)) }
        notesLabel.stringValue = notes.count == 1 ? "1 note" : "\(notes.count) notes"
        notesBar.isHidden = notes.isEmpty
    }

    private func marks(on id: String) -> [CanvasNote.Mark] {
        notes.enumerated().filter { $0.element.artboard == id }
            .map { CanvasNote.Mark(number: $0.offset + 1, point: $0.element.point, area: $0.element.area) }
    }

    /// The notes as one message, with a screenshot of each artboard they're
    /// on. Kept if there's no chat to take them.
    func sendNotes() async {
        guard let board, !notes.isEmpty else { return }
        var shots: [ChatAttachment] = []
        var seen: Set<String> = []
        for id in notes.map(\.artboard) where seen.insert(id).inserted {
            guard let view = artboardViews[id], let image = await view.snapshot(),
                  let png = CanvasNote.markedPNG(image, marks: marks(on: id)) else { continue }
            shots.append(ChatAttachment(kind: .image(data: png, mimeType: "image/png", name: "\(id).png")))
        }
        let message = CanvasNote.message(notes, board: board)
        let sent = onSendNotes?(message, shots)
            ?? (NSApp.delegate as? AppDelegate)?.sendCanvasNotes(message, attachments: shots, board: board.folder) ?? false
        if sent {
            clearNotes()
        } else {
            Alerts.inform("No chat to send to", "Open a chat in this folder’s window, then send the notes.", in: window)
        }
    }

    @objc private func sendNotesClicked() { Task { await sendNotes() } }
    @objc private func clearNotesClicked() { clearNotes() }

    #if DEBUG
    var debugArtboardIDs: [String] { (board?.artboards ?? []).map(\.id).filter { artboardViews[$0] != nil } }
    var debugLoadedCount: Int { artboardViews.values.filter(\.hasLoaded).count }
    var debugReloads: Int { artboardViews.values.reduce(0) { $0 + $1.reloads } }
    var debugMessage: String? { messageLabel.isHidden ? nil : messageLabel.stringValue }
    var debugMagnification: CGFloat { scrollView.magnification }
    func debugPageText(_ id: String) async -> String? { await artboardViews[id]?.pageText() }
    func debugElement(_ id: String, at point: CGPoint) async -> CanvasNote.Element? { await artboardViews[id]?.element(at: point) }
    func debugPins(_ id: String) -> Int { artboardViews[id]?.pinCount ?? 0 }
    /// A click (no `to`) or drag on an artboard in comment mode, as the mouse makes it.
    func debugCommentGesture(_ id: String, from: CGPoint, to: CGPoint? = nil) {
        guard let overlay = artboardViews[id]?.debugOverlay, let window = overlay.window else { return }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown, from) { overlay.mouseDown(with: down) }
        if let to, let drag = event(.leftMouseDragged, to) { overlay.mouseDragged(with: drag) }
        if let up = event(.leftMouseUp, to ?? from) { overlay.mouseUp(with: up) }
    }
    /// Whether a page gets its clicks (no overlay in the way).
    func debugOverlayShown(_ id: String) -> Bool { artboardViews[id]?.debugOverlay.isHidden == false }
    var debugNotesBarShown: Bool { !notesBar.isHidden }
    /// What the last note being written is pointing at.
    private(set) var debugNoteElement: CanvasNote.Element?
    var debugNotePopoverShown: Bool { notePopover?.isShown == true }
    /// A click at `point` on an artboard's page, as the page gets it.
    func debugClick(_ id: String, at point: CGPoint, option: Bool) {
        guard let web = artboardViews[id]?.debugWebView, let window = web.window else { return }
        let local = NSPoint(x: point.x, y: web.isFlipped ? point.y : web.bounds.height - point.y)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: web.convert(local, to: nil),
                                       modifierFlags: option ? .option : [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)
        if let event { web.mouseDown(with: event) }
    }
    var debugNotesBarText: String { notesLabel.stringValue }
    /// Where the view is on the board (the clip view's origin).
    var debugVisibleOrigin: NSPoint { scrollView.contentView.bounds.origin }
    /// One step of a trackpad gesture over an artboard's page (phase: 1 began, 2 changed, 4 ended).
    func debugGesture(over id: String, dx: Int32, dy: Int32, phase: Int64) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        guard let event = NSEvent(cgEvent: cg) else { return }
        artboardViews[id]?.debugWebView.scrollWheel(with: event)
    }
    /// A scroll over the board's empty space.
    func debugScrollBoard(dx: Int32, dy: Int32) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return }
        scrollView.scrollWheel(with: event)
    }
    /// A mouse wheel's scroll over an artboard's page, as the page gets it.
    func debugScroll(over id: String, dx: Int32, dy: Int32, option: Bool = false) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        if option { cg.flags = .maskAlternate }
        guard let event = NSEvent(cgEvent: cg) else { return }
        artboardViews[id]?.debugWebView.scrollWheel(with: event)
    }
    #endif
}

/// Scrolling pans the board: trackpad, Magic Mouse and wheel, in any direction,
/// momentum included. It moves the view itself, rather than leave a board to a
/// scroll view's page physics, which fit a surface that pans past its edges badly.
private final class CanvasScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let line: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let clip = contentView
        let origin = Self.panned(clip.bounds.origin, dx: event.scrollingDeltaX * line, dy: event.scrollingDeltaY * line,
                                 magnification: magnification)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        reflectScrolledClipView(clip)
    }

    /// Where the view goes for a scroll of (`dx`, `dy`) screen points: the
    /// board follows the fingers, the same distance on screen at any zoom.
    static func panned(_ origin: NSPoint, dx: CGFloat, dy: CGFloat, magnification: CGFloat) -> NSPoint {
        let scale = max(magnification, 0.01)
        return NSPoint(x: origin.x - dx / scale, y: origin.y - dy / scale)
    }
}

/// The board's clip view. A board isn't a page: at zoom-to-fit it's all in
/// view, so a plain clip view leaves nothing to scroll. This one pans past the
/// edges, as far as keeps the middle of the view over the board, so it can't
/// get lost.
private final class CanvasClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        guard let doc = documentView?.frame, !doc.isEmpty else { return super.constrainBoundsRect(proposed) }
        var rect = proposed
        rect.origin.x = min(max(rect.origin.x, doc.minX - rect.width / 2), doc.maxX - rect.width / 2)
        rect.origin.y = min(max(rect.origin.y, doc.minY - rect.height / 2), doc.maxY - rect.height / 2)
        return rect
    }
}

/// The board's surface (top-down). Dragging its empty space pans the board.
private final class CanvasDocumentView: NSView {
    override var isFlipped: Bool { true }
    private var dragStart: NSPoint?
    private var originAtStart: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return super.mouseDown(with: event) }
        dragStart = event.locationInWindow
        originAtStart = clip.bounds.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let scale = max(scrollView.magnification, 0.01)
        // The window's y goes up, this view's down.
        let origin = NSPoint(x: originAtStart.x - (event.locationInWindow.x - start.x) / scale,
                             y: originAtStart.y + (event.locationInWindow.y - start.y) / scale)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}

/// An artboard's page. Scrolling over it pans the board, as in a design tool
/// (the artboards cover most of it); with ⌥ held it scrolls the page itself.
/// Pinching zooms the board.
private final class ArtboardWebView: WKWebView {
    /// Whether the scroll gesture under way goes to the page.
    private var scrollsPage = false
    /// A note asked for at this point on the page (CSS pixels from the top left).
    var onNote: ((CGPoint) -> Void)?

    private func pagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), let onNote else { return super.mouseDown(with: event) }
        onNote(pagePoint(event))
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard onNote != nil else { return }
        let point = pagePoint(event)
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(NSMenuItem("Add Note") { [weak self] in self?.onNote?(point) }, at: 0)
    }

    override func scrollWheel(with event: NSEvent) {
        // Decided as a gesture starts and kept through its momentum; a mouse
        // wheel's clicks (no phases) each decide.
        if event.phase.contains(.mayBegin) || event.phase.contains(.began)
            || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            scrollsPage = event.modifierFlags.contains(.option)
        }
        if scrollsPage { return super.scrollWheel(with: event) }
        guard let scrollView = enclosingScrollView else { return super.scrollWheel(with: event) }
        scrollView.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else { return super.magnify(with: event) }
        scrollView.magnify(with: event)
    }
}

/// Over a page in comment mode: a click comments on that spot, a drag on the
/// area it draws. Scrolling and pinching pass through to the board.
private final class CommentOverlay: NSView {
    override var isFlipped: Bool { true }
    var onComment: ((CGPoint, CGRect?) -> Void)?
    private var start: CGPoint?
    private let band = NSView()

    private func location(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func region(to end: CGPoint) -> CGRect? {
        guard let start else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        return rect.width >= 8 && rect.height >= 8 ? rect : nil   // less is a shaky click
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = location(event)
        if band.superview == nil {
            band.wantsLayer = true
            band.layer?.borderWidth = 1.5
            band.layer?.borderColor = NSColor.controlAccentColor.cgColor
            band.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            addSubview(band)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let area = region(to: location(event)) else { return band.isHidden = true }
        band.isHidden = false
        band.frame = area
    }

    override func mouseUp(with event: NSEvent) {
        band.isHidden = true
        guard let start else { return }
        let end = location(event)
        let area = region(to: end)
        self.start = nil
        onComment?(area.map { CGPoint(x: $0.midX, y: $0.midY) } ?? start, area)
    }
}

/// A pin on a page: clicks go through it to the page.
private final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What to change, asked at the point a note is left.
private struct CanvasNoteEntry: View {
    var element: String?
    /// The note, and whether to send now.
    var onDone: (String, Bool) -> Void
    @State private var text = ""

    private var note: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let element {
                Text(element).font(.role(.meta)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            TextField("What should change?", text: $text, axis: .vertical)
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("Add Another") { onDone(note, false) }
                Button("Send to Chat") { onDone(note, true) }.keyboardShortcut(.defaultAction)
            }
            .disabled(note.isEmpty)
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// One artboard: its title, then the page in a web view of the artboard's size.
@MainActor
private final class ArtboardView: NSView, WKNavigationDelegate {
    static let titleHeight: CGFloat = 28
    private let titleLabel = NSTextField(labelWithString: "")
    private let webView: ArtboardWebView
    private var pins: [NSView] = []
    private var areaBoxes: [NSView] = []
    private let overlay = CommentOverlay()
    var onNote: ((CGPoint, CGRect?) -> Void)?
    /// Comment mode: the overlay takes the page's clicks and drags.
    var isCommenting: Bool {
        get { !overlay.isHidden }
        set { overlay.isHidden = !newValue }
    }
    private(set) var source: URL?
    private(set) var hasLoaded = false
    private(set) var reloads = 0

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    override var isFlipped: Bool { true }

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = ArtboardWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        titleLabel.font = .role(.body)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        webView.navigationDelegate = self
        webView.onNote = { [weak self] point in self?.onNote?(point, nil) }
        overlay.onComment = { [weak self] point, area in self?.onNote?(point, area) }
        overlay.isHidden = true
        webView.allowsMagnification = false
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 6
        webView.layer?.masksToBounds = true
        webView.layer?.borderWidth = 1
        webView.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(webView)
        addSubview(overlay)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 18)
        webView.frame = NSRect(x: 0, y: Self.titleHeight, width: bounds.width,
                               height: max(bounds.height - Self.titleHeight, 0))
        overlay.frame = webView.frame
    }

    func load(_ url: URL?, readAccess: URL) {
        source = url
        hasLoaded = false
        guard let url else {
            webView.loadHTMLString("", baseURL: nil)
            return
        }
        if url.isFileURL {
            // Both by their real paths: WebKit compares them as given (/tmp is /private/tmp).
            webView.loadFileURL(url.resolvingSymlinksInPath(), allowingReadAccessTo: readAccess.resolvingSymlinksInPath())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func reloadPage() {
        reloads += 1
        hasLoaded = false
        webView.reloadFromOrigin()
    }

    #if DEBUG
    var debugWebView: WKWebView { webView }
    var pinCount: Int { pins.count }
    var debugOverlay: NSView { overlay }
    #endif

    /// Where a note's popover points from.
    var noteAnchor: NSView { webView }

    /// The element at `point`, from the page; nil if it won't say.
    func element(at point: CGPoint, area: CGRect? = nil) async -> CanvasNote.Element? {
        let json = try? await webView.evaluateJavaScript(CanvasNote.elementScript(at: point, area: area)) as? String
        return json.flatMap { try? JSONDecoder().decode(CanvasNote.Element.self, from: Data($0.utf8)) }
    }

    func snapshot() async -> NSImage? {
        try? await webView.takeSnapshot(configuration: nil)
    }

    /// Numbered pins over the page where its notes point.
    func setPins(_ marks: [CanvasNote.Mark]) {
        for pin in pins + areaBoxes { pin.removeFromSuperview() }
        areaBoxes = []
        pins = marks.map { mark in
            if let area = mark.area {
                let box = ClickThroughView(frame: area.offsetBy(dx: 0, dy: Self.titleHeight))
                box.wantsLayer = true
                box.layer?.borderWidth = 2
                box.layer?.borderColor = NSColor.systemRed.cgColor
                box.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
                addSubview(box)
                areaBoxes.append(box)
            }
            let center = mark.area.map { CGPoint(x: $0.minX, y: $0.minY) } ?? mark.point
            let label = NSTextField(labelWithString: "\(mark.number)")
            label.font = .mark(12, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 3, width: 22, height: 16)
            let pin = ClickThroughView(frame: NSRect(x: center.x - 11, y: Self.titleHeight + center.y - 11, width: 22, height: 22))
            pin.wantsLayer = true
            pin.layer?.cornerRadius = 11
            pin.layer?.backgroundColor = NSColor.systemRed.cgColor
            pin.addSubview(label)
            addSubview(pin)
            return pin
        }
    }

    func pageText() async -> String? {
        try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoaded = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Log.error(.app, "canvas: \(source?.lastPathComponent ?? "-") didn't load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Log.error(.app, "canvas: \(source?.lastPathComponent ?? "-") didn't load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.error(.app, "canvas: \(source?.lastPathComponent ?? "-")'s page process ended; reloading")
        webView.reload()
    }
}
