import AppKit
import CryptoKit
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

    /// Stepping through the artboards in the board's order: ‹ › and Fit, and
    /// the one shown ("3 of 25 · its title").
    private let stepper = NSStackView()
    /// Which artboard is shown; click for every artboard, to go to one.
    private let stepLabel = NSButton(title: "", target: nil, action: nil)
    /// The artboard last stepped to (nil: none yet, or the whole board).
    private(set) var stepIndex: Int?

    /// The artboards' web storage, one for the canvas (not one each).
    private let dataStore = WKWebsiteDataStore.nonPersistent()
    /// Pages loading at once, at most: the rest wait their turn.
    static let loadingAtOnce = 4
    /// Pages kept loaded while out of view, at most (the rest unload to their pictures).
    static let pagesKept = 8
    /// Zoomed out past this, an artboard that has a picture keeps it: the
    /// page wouldn't look any different that small.
    static let picturesBelow: CGFloat = 0.3
    private var loadScheduled = false
    /// The board has been zoomed to fit once it opened: until then what's
    /// "in view" is the corner it starts at, not what will show.
    private var placed = false

    /// The page shown (nil: none, an empty board). `showsAllPages`: every
    /// page instead, as a card each.
    private(set) var pageID: String?
    private(set) var showsAllPages = false
    /// The page each board was last on (this run), to come back to.
    private static var lastPage: [URL: String] = [:]
    /// Over the page: its name and note. Over each design of several
    /// screens: its label and name. All Pages: a card per page.
    private let pageTitleLabel = NSTextField(wrappingLabelWithString: "")
    private var headingViews: [NSTextField] = []
    private var cardViews: [PageCard] = []
    static let pageHeaderHeight: CGFloat = 64

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
        pageTitleLabel.isSelectable = false
        document.addSubview(pageTitleLabel)
        // Scrolled or zoomed: what came into view loads.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
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
        let previous = NSButton.symbol("chevron.left", label: "Previous Artboard (⌘[)", pointSize: 13, tint: .labelColor,
                                       size: NSSize(width: 26, height: 24), target: self, action: #selector(previousArtboard),
                                       id: "canvas-previous")
        let next = NSButton.symbol("chevron.right", label: "Next Artboard (⌘])", pointSize: 13, tint: .labelColor,
                                   size: NSSize(width: 26, height: 24), target: self, action: #selector(nextArtboard),
                                   id: "canvas-next")
        let fit = NSButton.symbol("arrow.up.left.and.down.right.magnifyingglass", label: "Show the Whole Canvas",
                                  pointSize: 13, tint: .labelColor, size: NSSize(width: 26, height: 24),
                                  target: self, action: #selector(showWholeBoard), id: "canvas-fit")
        stepLabel.isBordered = false
        stepLabel.font = .role(.meta)
        stepLabel.lineBreakMode = .byTruncatingTail
        stepLabel.imagePosition = .imageTrailing
        stepLabel.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        stepLabel.target = self
        stepLabel.action = #selector(stepLabelClicked)
        stepLabel.toolTip = "Go to an artboard"
        stepLabel.refusesFirstResponder = true
        stepLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stepLabel.setAccessibilityIdentifier("canvas-step")
        stepper.setViews([previous, stepLabel, next, fit], in: .leading)
        previous.toolTip = "Previous Screen (⌘[)"
        next.toolTip = "Next Screen (⌘])"
        fit.toolTip = "Show the Whole Page"
        stepper.orientation = .horizontal
        stepper.spacing = 4
        stepper.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stepper.wantsLayer = true
        stepper.layer?.cornerRadius = 9
        stepper.layer?.borderWidth = 1
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.isHidden = true
        addSubview(stepper)
        NSLayoutConstraint.activate([
            stepper.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stepper.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stepper.trailingAnchor.constraint(lessThanOrEqualTo: commentButton.leadingAnchor, constant: -12),
            stepLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        restyleBars()
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
    /// The board was read (again): its artboards may have changed.
    var onLoad: (() -> Void)?

    func show(_ folder: URL?) {
        guard folder != self.folder else { return }
        self.folder = folder
        watcher = nil
        pendingReveal = nil
        clearNotes()
        clearPage()
        pageID = nil
        showsAllPages = false
        board = nil
        guard let folder else { return reload() }
        ArtboardPictures.prune()
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
            // The agent touched something that changes nothing here (another
            // page's file, board.json rewritten the same): leave the views be.
            if loaded == board, showsAllPages || !pageFilesChanged(loaded) { return }
            board = loaded
            if !showsAllPages {
                // The page it's on, while it's still there; else the one asked
                // for, the one it was on last time, the first.
                let next = [pageID, pendingReveal.flatMap { loaded.page(of: $0)?.id }, Self.lastPage[folder]]
                    .compactMap { $0 }.first { loaded.page($0) != nil } ?? loaded.pages.first?.id
                if next != pageID {
                    clearPage()
                    pageID = next
                }
            }
            showMessage(loaded.artboards.isEmpty ? "Nothing on this board yet. Describe what to design in the chat beside it." : nil)
            layoutArtboards(loaded)
        }
        updateStepper()
        onLoad?()
    }

    /// Whether a file on the shown page changed since it was laid out.
    private func pageFilesChanged(_ board: CanvasBoard) -> Bool {
        guard let page = pageID.flatMap({ board.page($0) }) else { return true }
        return page.screens.contains { id in
            guard let artboard = board.artboard(id), let file = board.fileURL(of: artboard) else { return false }
            return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate != modified[id]
        }
    }

    private func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
        scrollView.isHidden = text != nil && artboardViews.isEmpty
    }

    /// Everything on the canvas goes: a page changed, or the board did.
    private func clearPage() {
        for view in artboardViews.values { view.removeFromSuperview() }
        artboardViews = [:]
        modified = [:]
        for view in headingViews { view.removeFromSuperview() }
        headingViews = []
        for view in cardViews { view.removeFromSuperview() }
        cardViews = []
        stepIndex = nil
        zoomedToFit = false
        placed = false
    }

    /// The shown page's artboards: a view each, where the page puts them, its
    /// designs' headings over their rows, its name over it all.
    private func layoutArtboards(_ board: CanvasBoard) {
        if showsAllPages { return layoutAllPages(board) }
        let page = pageID.flatMap({ board.page($0) })
        let layout = pageID.map { board.layout(page: $0) } ?? CanvasBoard.PageLayout(frames: [:], headings: [])
        let frames = layout.frames
        for (id, view) in artboardViews where frames[id] == nil {
            view.removeFromSuperview()
            artboardViews[id] = nil
            modified[id] = nil
        }
        // What the page covers: its artboards with their titles, its headings.
        let title = ArtboardView.titleHeight, heading = CanvasBoard.headingHeight
        var extent = frames.values.reduce(CGRect.null) {
            $0.union(CGRect(x: $1.minX, y: $1.minY - title, width: $1.width, height: $1.height + title))
        }
        for h in layout.headings {
            extent = extent.union(CGRect(x: extent.isNull ? 0 : extent.minX, y: h.top - title - heading, width: 1, height: heading))
        }
        let origin = CGPoint(x: Self.margin - (extent.isNull ? 0 : extent.minX),
                             y: Self.margin + Self.pageHeaderHeight - (extent.isNull ? 0 : extent.minY))
        for id in page?.screens ?? [] {
            guard let artboard = board.artboard(id), let frame = frames[id] else { continue }
            let view = artboardViews[artboard.id] ?? {
                let v = ArtboardView(dataStore: dataStore)
                let id = artboard.id
                v.onNote = { [weak self] point, area in self?.beginNote(on: id, at: point, area: area) }
                v.onSettled = { [weak self] in self?.loadVisibleSoon() }
                v.onWanted = { [weak v] in v?.startLoad() }
                v.isCommenting = isCommenting
                document.addSubview(v)
                artboardViews[artboard.id] = v
                return v
            }()
            view.frame = CGRect(x: frame.minX + origin.x, y: frame.minY + origin.y - title,
                                width: frame.width, height: frame.height + title)
            view.title = Self.shortTitle(artboard)
            let source = board.fileURL(of: artboard) ?? artboard.url
            let stamp = board.fileURL(of: artboard).flatMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            if view.source != source {
                view.prepare(source, readAccess: board.folder, stamp: stamp)
            } else if let stamp, stamp != modified[artboard.id] {
                view.changed(stamp: stamp)
            }
            modified[artboard.id] = stamp
        }
        for view in headingViews { view.removeFromSuperview() }
        headingViews = layout.headings.compactMap { h in
            guard let design = page?.designs.first(where: { $0.id == h.design }) else { return nil }
            let label = NSTextField(labelWithAttributedString: Self.heading(design))
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: origin.x, y: h.top + origin.y - title - heading + 6,
                                 width: max(extent.isNull ? 0 : extent.maxX - extent.minX, 300), height: heading - 10)
            document.addSubview(label)
            return label
        }
        let size = extent.isNull ? .zero : extent.size
        showPageHeader(page.map { Self.pageSummary($0, board: board) }, note: page?.note,
                       at: NSRect(x: Self.margin, y: Self.margin, width: max(size.width, 400), height: Self.pageHeaderHeight - 16))
        loadVisibleSoon()
        document.setFrameSize(NSSize(width: max(size.width, 400) + 2 * Self.margin,
                                     height: size.height + 2 * Self.margin + Self.pageHeaderHeight))
        fitOnce(empty: frames.isEmpty)
    }

    /// Zoomed to fit once, when there's something to fit; then what's in view
    /// may load.
    private func fitOnce(empty: Bool) {
        if !zoomedToFit, !empty {
            zoomedToFit = true
            DispatchQueue.main.async { [weak self] in
                self?.zoomToFit()
                if let id = self?.pendingReveal { self?.reveal(id) }
                self?.placed = true
                self?.loadVisibleSoon()
            }
        } else if let id = pendingReveal {
            DispatchQueue.main.async { [weak self] in self?.reveal(id) }
        }
    }

    private func showPageHeader(_ title: NSAttributedString?, note: String?, at frame: NSRect) {
        let text = NSMutableAttributedString(attributedString: title ?? NSAttributedString())
        if let note {
            text.append(NSAttributedString(string: "\n" + note, attributes: [
                .font: NSFont.role(.body), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        pageTitleLabel.attributedStringValue = text
        pageTitleLabel.frame = frame
        pageTitleLabel.isHidden = title == nil
    }

    /// "Connections   2 designs · 21 screens"
    static func pageSummary(_ page: CanvasBoard.Page, board: CanvasBoard) -> NSAttributedString {
        let text = NSMutableAttributedString(string: page.title, attributes: [
            .font: NSFont.role(.title), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "   " + count(page), attributes: [
            .font: NSFont.role(.meta), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    /// "2 designs · 21 screens", or "5 screens" when each design is one.
    static func count(_ page: CanvasBoard.Page) -> String {
        let screens = page.screens.count
        let s = "\(screens) screen\(screens == 1 ? "" : "s")"
        return page.designs.count == screens ? s : "\(page.designs.count) design\(page.designs.count == 1 ? "" : "s") · \(s)"
    }

    /// A design's heading: "A  A connection picked  12 screens".
    static func heading(_ design: CanvasBoard.Design) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let label = design.label {
            text.append(NSAttributedString(string: label + "  ", attributes: [
                .font: NSFont.role(.title), .foregroundColor: NSColor.controlAccentColor]))
        }
        text.append(NSAttributedString(string: design.title, attributes: [
            .font: NSFont.role(.title), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "   \(design.screens.count) screens", attributes: [
            .font: NSFont.role(.meta), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    /// An artboard's title on the canvas and in menus: "A6 · GitHub", or a
    /// board made before pages, its name in its design.
    static func shortTitle(_ artboard: CanvasBoard.Artboard) -> String {
        guard !artboard.name.isEmpty else { return artboard.title }
        return artboard.code.map { "\($0) · \(artboard.name)" } ?? artboard.name
    }

    // MARK: Pages

    /// The shown page's artboards, in order: what ‹ › step through.
    var pageScreens: [String] {
        guard !showsAllPages, let board, let page = pageID.flatMap({ board.page($0) }) else { return [] }
        return page.screens.filter { board.artboard($0) != nil }
    }

    /// Show a page (and, when it's there, one of its artboards).
    func showPage(_ id: String, reveal artboard: String? = nil) {
        guard let board, board.page(id) != nil else { return }
        if id != pageID || showsAllPages { clearPage() }
        pageID = id
        showsAllPages = false
        if let folder { Self.lastPage[folder] = id }
        stepIndex = artboard.flatMap { pageScreens.firstIndex(of: $0) }
        pendingReveal = artboard
        layoutArtboards(board)
        updateStepper()
        onLoad?()
    }

    /// The page after the one shown (or before), in the board's order.
    func stepPage(by delta: Int) {
        guard let pages = board?.pages, !pages.isEmpty else { return }
        let i = pageID.flatMap { id in pages.firstIndex { $0.id == id } }
        let next = i.map { min(max($0 + (showsAllPages ? 0 : delta), 0), pages.count - 1) } ?? (delta > 0 ? 0 : pages.count - 1)
        if next != i || showsAllPages { showPage(pages[next].id) }
    }

    /// Every page as a card: a picture of each design's first screens.
    @objc func showAllPages() {
        guard let board, !board.pages.isEmpty, !showsAllPages else { return }
        clearPage()
        showsAllPages = true
        layoutArtboards(board)
        updateStepper()
        onLoad?()
    }

    private func layoutAllPages(_ board: CanvasBoard) {
        for view in cardViews { view.removeFromSuperview() }
        let columns = max(1, Int(Double(board.pages.count).squareRoot().rounded(.up)))
        let size = PageCard.size, gap: CGFloat = 40
        cardViews = board.pages.enumerated().map { i, page in
            let card = PageCard(page: page, board: board, current: page.id == pageID)
            card.frame = NSRect(x: Self.margin + CGFloat(i % columns) * (size.width + gap),
                                y: Self.margin + Self.pageHeaderHeight + CGFloat(i / columns) * (size.height + gap),
                                width: size.width, height: size.height)
            card.onOpen = { [weak self] in self?.showPage(page.id) }
            document.addSubview(card)
            return card
        }
        let rows = (board.pages.count + columns - 1) / columns
        let width = CGFloat(columns) * (size.width + gap) - gap
        let height = CGFloat(rows) * (size.height + gap) - gap
        let screens = board.artboards.count
        let title = NSMutableAttributedString(string: board.title, attributes: [.font: NSFont.role(.title), .foregroundColor: NSColor.labelColor])
        title.append(NSAttributedString(string: "   \(board.pages.count) pages · \(screens) screen\(screens == 1 ? "" : "s")",
                                        attributes: [.font: NSFont.role(.meta), .foregroundColor: NSColor.secondaryLabelColor]))
        showPageHeader(title, note: nil, at: NSRect(x: Self.margin, y: Self.margin, width: width, height: Self.pageHeaderHeight - 16))
        document.setFrameSize(NSSize(width: width + 2 * Self.margin, height: height + 2 * Self.margin + Self.pageHeaderHeight))
        fitOnce(empty: board.pages.isEmpty)
    }

    // MARK: Loading what's in view

    @objc private func visibleAreaChanged() { loadVisibleSoon() }

    func loadVisibleSoon() {
        guard !loadScheduled else { return }
        loadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.loadScheduled = false
            self?.loadVisible()
        }
    }

    /// Load the pages in view (and a little around it), nearest the middle
    /// first, a few at a time: a board of forty opened all forty at once.
    /// Zoomed far out, an artboard with a picture stays a picture.
    private func loadVisible() {
        guard placed else { return }
        let visible = scrollView.contentView.bounds
        guard visible.width > 0, visible.height > 0 else { return }
        let near = visible.insetBy(dx: -visible.width / 2, dy: -visible.height / 2)
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let tiny = scrollView.magnification < Self.picturesBelow
        // A page out of view (or too small to see, with a picture) is hidden:
        // WebKit stops drawing it. An animated page kept drawing for nobody.
        for view in artboardViews.values where view.hasWebView {
            view.setParked(!view.frame.intersects(near) || (tiny && view.hasPicture))
        }
        // Past a few, the pages put away longest go back to their pictures: a
        // web view each kept every page ever looked at in memory.
        let parked = artboardViews.values.filter { $0.hasWebView && $0.isParked }
        if parked.count > Self.pagesKept {
            for view in parked.sorted(by: { $0.parkedAt < $1.parkedAt }).prefix(parked.count - Self.pagesKept) { view.unload() }
        }
        var loading = artboardViews.values.count(where: \.isLoading)
        let waiting = artboardViews.values
            .filter { $0.pending != nil && $0.frame.intersects(near) && !(tiny && $0.hasPicture) }
            .sorted { hypot($0.frame.midX - center.x, $0.frame.midY - center.y) < hypot($1.frame.midX - center.x, $1.frame.midY - center.y) }
        for view in waiting where loading < Self.loadingAtOnce {
            view.startLoad()
            loading += 1
        }
    }

    /// An artboard to bring into view once the board is laid out.
    private var pendingReveal: String?

    /// Bring one artboard into view, centered, as large as fits (never past
    /// 100 %); on another page, that page first.
    func reveal(_ id: String) {
        if let board, let page = board.page(of: id), page.id != pageID || showsAllPages {
            return showPage(page.id, reveal: id)
        }
        guard let view = artboardViews[id], scrollView.contentSize.width > 0 else { pendingReveal = id; return }
        pendingReveal = nil
        let frame = view.frame.insetBy(dx: -24, dy: -24)
        let fit = min(scrollView.contentSize.width / frame.width, scrollView.contentSize.height / frame.height, 1)
        scrollView.magnification = max(fit, scrollView.minMagnification)
        let visible = scrollView.contentView.bounds.size
        scrollView.contentView.scroll(to: NSPoint(x: frame.midX - visible.width / 2, y: frame.midY - visible.height / 2))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Stepping through

    /// The screen after the one shown (the first, from the whole page), in
    /// the page's order: design by design, each one's screens in turn.
    @objc func nextArtboard() { step(by: 1) }
    @objc func previousArtboard() { step(by: -1) }

    /// The whole page (on All Pages: the page it came from).
    @objc func showWholeBoard() {
        if showsAllPages, let id = pageID ?? board?.pages.first?.id { return showPage(id) }
        stepIndex = nil
        zoomToFit()
        updateStepper()
    }

    func step(by delta: Int) {
        let count = pageScreens.count
        guard count > 0 else { return }
        // The buttons don't take focus: the canvas does (in `go`), so the arrows go on from here.
        go(to: stepIndex.map { min(max($0 + delta, 0), count - 1) } ?? (delta > 0 ? 0 : count - 1))
    }

    /// The first screen of the design after the one shown (or before).
    func stepDesign(by delta: Int) {
        guard let board, let page = pageID.flatMap({ board.page($0) }), !page.designs.isEmpty, !showsAllPages else { return }
        let shown = stepIndex.flatMap { pageScreens.indices.contains($0) ? board.artboard(pageScreens[$0])?.design : nil }
        let i = shown.flatMap { id in page.designs.firstIndex { $0.id == id } }
        let next = i.map { min(max($0 + delta, 0), page.designs.count - 1) } ?? (delta > 0 ? 0 : page.designs.count - 1)
        if let first = page.designs[next].screens.first, let index = pageScreens.firstIndex(of: first) { go(to: index) }
    }

    /// "3 of 21 · A3 · Agate's sandbox"; the whole page: its name and size;
    /// All Pages: how many.
    private func updateStepper() {
        let screens = pageScreens
        stepper.isHidden = board?.artboards.isEmpty ?? true
        if showsAllPages, let board {
            stepLabel.title = "\(board.pages.count) pages · \(board.artboards.count) screens"
        } else if let i = stepIndex, screens.indices.contains(i), let artboard = board?.artboard(screens[i]) {
            stepLabel.title = "\(i + 1) of \(screens.count) · \(Self.shortTitle(artboard))"
        } else {
            stepIndex = nil
            let page = pageID.flatMap { board?.page($0) }
            let count = page.map(Self.count) ?? "0 screens"
            stepLabel.title = (board?.pages.count ?? 0) > 1 ? "\(page?.title ?? "") · \(count)" : count
        }
        stepLabel.setAccessibilityLabel(stepLabel.title)
        restyleBars()
    }

    /// The step label's text and the bars' fill, in the canvas's own appearance:
    /// set once as a fixed color, the bar was white over a dark canvas, its
    /// buttons white on it.
    private func restyleBars() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for bar in [stepper, notesBar] {
                bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                bar.layer?.borderColor = NSColor.separatorColor.cgColor
            }
            stepLabel.contentTintColor = .secondaryLabelColor
            stepLabel.attributedTitle = NSAttributedString(string: stepLabel.title, attributes: [
                .font: NSFont.role(.meta), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyleBars()
    }

    // MARK: Menus

    /// The step label's menu: this page's designs, the shown one open to its
    /// screens (the others' in a submenu each), then the other pages.
    func artboardMenu() -> NSMenu {
        let menu = NSMenu()
        guard let board else { return menu }
        let shown = stepIndex.flatMap { pageScreens.indices.contains($0) ? pageScreens[$0] : nil }
        if let page = pageID.flatMap({ board.page($0) }), !showsAllPages {
            menu.addItem(.sectionHeader(title: page.title))
            let open = shown.flatMap { board.artboard($0)?.design }
            for design in page.designs {
                if design.screens.count > 1 {
                    let item = NSMenuItem(Self.designTitle(design)) { [weak self] in self?.goTo(design.screens[0]) }
                    item.badge = NSMenuItemBadge(count: design.screens.count)
                    if design.id == open {
                        menu.addItem(item)
                        for id in design.screens { if let a = board.artboard(id) { menu.addItem(screenItem(a, indent: 1, shown: shown)) } }
                    } else {
                        item.submenu = screensMenu(design, board: board, shown: shown)
                        menu.addItem(item)
                    }
                } else if let a = design.screens.first.flatMap(board.artboard) {
                    menu.addItem(screenItem(a, indent: 0, shown: shown))
                }
            }
        }
        let others = board.pages.filter { $0.id != pageID || showsAllPages }
        if !others.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: showsAllPages ? "Pages" : "Other Pages"))
            for page in others {
                let item = NSMenuItem(page.title) { [weak self] in self?.showPage(page.id) }
                item.submenu = designsMenu(page, board: board, shown: shown)
                menu.addItem(item)
            }
        }
        if board.pages.count > 1 {
            menu.addItem(.separator())
            let all = NSMenuItem("All Pages") { [weak self] in self?.showAllPages() }
            all.state = showsAllPages ? .on : .off
            menu.addItem(all)
        }
        return menu
    }

    /// View ▸ Go To: page › design › screen.
    func goToMenu() -> NSMenu {
        let menu = NSMenu()
        guard let board else { return menu }
        let shown = stepIndex.flatMap { pageScreens.indices.contains($0) ? pageScreens[$0] : nil }
        for page in board.pages {
            let item = NSMenuItem(page.title) { [weak self] in self?.showPage(page.id) }
            item.state = page.id == pageID && !showsAllPages ? .on : .off
            item.submenu = designsMenu(page, board: board, shown: shown)
            menu.addItem(item)
        }
        return menu
    }

    /// The strip's menu (the canvas's half beside its chat): the pages.
    func pagesMenu() -> NSMenu {
        let menu = NSMenu()
        guard let board, !board.pages.isEmpty else { return menu }
        menu.addItem(.sectionHeader(title: "Pages"))
        for page in board.pages {
            let item = NSMenuItem(page.title) { [weak self] in self?.showPage(page.id) }
            item.state = page.id == pageID && !showsAllPages ? .on : .off
            item.badge = NSMenuItemBadge(string: Self.count(page))
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem("All Pages") { [weak self] in self?.showAllPages() }
        all.state = showsAllPages ? .on : .off
        menu.addItem(all)
        let next = NSMenuItem("Next Page") { [weak self] in self?.stepPage(by: 1) }
        next.keyEquivalent = "]"
        next.keyEquivalentModifierMask = [.command, .option]
        let previous = NSMenuItem("Previous Page") { [weak self] in self?.stepPage(by: -1) }
        previous.keyEquivalent = "["
        previous.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(next)
        menu.addItem(previous)
        return menu
    }

    /// What the strip says beside its chat: "Canvas · Connections".
    var stripLabel: String {
        guard let board, !board.artboards.isEmpty else { return "Canvas" }
        if showsAllPages { return "Canvas · All Pages" }
        return pageID.flatMap({ board.page($0) }).map { "Canvas · \($0.title)" } ?? "Canvas"
    }

    static func designTitle(_ design: CanvasBoard.Design) -> String {
        design.label.map { "\($0) · \(design.title)" } ?? design.title
    }

    private func screenItem(_ artboard: CanvasBoard.Artboard, indent: Int, shown: String?) -> NSMenuItem {
        let item = NSMenuItem(Self.shortTitle(artboard)) { [weak self] in self?.goTo(artboard.id) }
        item.indentationLevel = indent
        item.state = artboard.id == shown ? .on : .off
        return item
    }

    private func screensMenu(_ design: CanvasBoard.Design, board: CanvasBoard, shown: String?) -> NSMenu {
        let menu = NSMenu()
        for id in design.screens { if let a = board.artboard(id) { menu.addItem(screenItem(a, indent: 0, shown: shown)) } }
        return menu
    }

    /// A page's designs: one screen, an item; several, a submenu of them.
    private func designsMenu(_ page: CanvasBoard.Page, board: CanvasBoard, shown: String?) -> NSMenu {
        let menu = NSMenu()
        for design in page.designs {
            if design.screens.count > 1 {
                let item = NSMenuItem(Self.designTitle(design)) { [weak self] in self?.goTo(design.screens[0]) }
                item.submenu = screensMenu(design, board: board, shown: shown)
                item.state = design.screens.contains { $0 == shown } ? .mixed : .off
                menu.addItem(item)
            } else if let a = design.screens.first.flatMap(board.artboard) {
                menu.addItem(screenItem(a, indent: 0, shown: shown))
            }
        }
        return menu
    }

    /// Show an artboard, on whichever page it is.
    func goTo(_ id: String) {
        guard let board, let page = board.page(of: id) else { return }
        if page.id != pageID || showsAllPages { return showPage(page.id, reveal: id) }
        if let index = pageScreens.firstIndex(of: id) { go(to: index) }
    }

    /// Show the artboard at `index` in the page's order.
    func go(to index: Int) {
        let ids = pageScreens
        guard ids.indices.contains(index) else { return }
        stepIndex = index
        reveal(ids[index])
        updateStepper()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    @objc private func stepLabelClicked() {
        artboardMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: stepLabel.bounds.height + 4), in: stepLabel)
    }

    /// The canvas the View menu's canvas commands act on: the one with
    /// focus (or holding it, a page in it), else the one showing in the window.
    static func target(in window: NSWindow?) -> CanvasView? {
        var view = window?.firstResponder as? NSView
        while let v = view {
            if let canvas = v as? CanvasView, canvas.board?.artboards.isEmpty == false { return canvas }
            view = v.superview
        }
        func find(_ v: NSView) -> CanvasView? {
            if let canvas = v as? CanvasView, !canvas.isHiddenOrHasHiddenAncestor, canvas.board?.artboards.isEmpty == false {
                return canvas
            }
            return v.subviews.lazy.compactMap(find).first
        }
        return window?.contentView.flatMap(find)
    }

    override var acceptsFirstResponder: Bool { true }

    /// While the canvas itself has focus (a page in it may want its keys):
    /// ← → (and Space, ⇧Space) step the screens, ↑ ↓ the designs; on All
    /// Pages, Return opens the page it came from.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .rightArrow?: return step(by: 1)
        case .leftArrow?: return step(by: -1)
        case .downArrow?: return stepDesign(by: 1)
        case .upArrow?: return stepDesign(by: -1)
        case .carriageReturn?, .enter?: if showsAllPages { return showWholeBoard() }
        default: break
        }
        if event.charactersIgnoringModifiers == " " { return step(by: event.modifierFlags.contains(.shift) ? -1 : 1) }
        super.keyDown(with: event)
    }

    /// While anything in the canvas has focus, a page in it too: ⌘] ⌘[ step
    /// the screens, ⌥⌘] ⌥⌘[ the pages, ⌘↑ shows All Pages.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command), let responder = window?.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self)
        else { return super.performKeyEquivalent(with: event) }
        switch (flags, event.charactersIgnoringModifiers) {
        case (.command, "]"): step(by: 1); return true
        case (.command, "["): step(by: -1); return true
        case ([.command, .option], "]"): stepPage(by: 1); return true
        case ([.command, .option], "["): stepPage(by: -1); return true
        default: break
        }
        if flags == .command, event.specialKey == .upArrow, (board?.pages.count ?? 0) > 1 { showAllPages(); return true }
        return super.performKeyEquivalent(with: event)
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
    /// Artboards with a live web view (loaded, or loading).
    var debugLoadedViewCount: Int { artboardViews.values.count(where: \.hasWebView) }
    /// Artboards whose page is hidden (out of view).
    var debugParkedIDs: [String] { artboardViews.filter { $0.value.isParked }.map(\.key).sorted() }
    /// Artboards that have made their web view.
    var debugWebViewCount: Int { artboardViews.values.filter(\.hasWebView).count }
    /// Every web view made is on the app's process pool.
    var debugSharesProcessPool: Bool {
        artboardViews.values.compactMap(\.debugProcessPool).allSatisfy { $0 === WKProcessPool.app }
    }
    var debugMessage: String? { messageLabel.isHidden ? nil : messageLabel.stringValue }
    /// All Pages' cards, by their pages' titles; a click on one.
    var debugCardTitles: [String] { cardViews.compactMap { $0.accessibilityLabel() } }
    func debugOpenCard(_ title: String) { _ = cardViews.first { $0.accessibilityLabel() == title }?.accessibilityPerformPress() }
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
        // A click on the board's space gives the canvas the keys (← → step).
        if let canvas = enclosingScrollView?.superview as? CanvasView { window?.makeFirstResponder(canvas) }
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

@MainActor
extension WKProcessPool {
    /// The app's web views share one. A configuration left without one makes
    /// its own, and each new one registers with the system for power changes
    /// on the main thread: a big board's artboards, all at once, hung there.
    static let app = WKProcessPool()
}

/// One artboard: its title, then the page in a web view of the artboard's size.
@MainActor
private final class ArtboardView: NSView, WKNavigationDelegate {
    static let titleHeight: CGFloat = 28
    private let titleLabel = NSTextField(labelWithString: "")
    private let dataStore: WKWebsiteDataStore
    /// Its page, made when it first loads: an artboard that's never in view
    /// never starts one (making forty at once, as a big board opened, held
    /// the window up on WebKit's start-up).
    private var web: ArtboardWebView?
    private var webView: ArtboardWebView { web ?? makeWebView() }
    /// The page has a view (it's loaded, or loading).
    var hasWebView: Bool { web != nil }
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
    /// Waiting for its turn to load (`CanvasView.loadVisible`): its page, and
    /// what the page may read.
    private(set) var pending: (url: URL?, readAccess: URL)?
    /// Asked to load, not finished yet.
    private(set) var isLoading = false
    /// Its last picture, over the page until the page is in: shown at once
    /// when the board opens, so a big board doesn't wait on its pages.
    private let picture = ArtboardPicture()
    /// The cached picture's name: the page's file and when it changed.
    private var pictureKey: String?
    /// It has a picture (a board zoomed far out needn't load the page).
    var hasPicture: Bool { picture.image != nil }
    /// Loaded or failed: the canvas loads the next.
    var onSettled: (() -> Void)?
    /// Clicked before its page was in: load it now.
    var onWanted: (() -> Void)?

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    override var isFlipped: Bool { true }

    /// `dataStore`: the canvas's, shared by its artboards (one each started a
    /// WebKit session per artboard: a big board was slow to open).
    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
        super.init(frame: .zero)
        titleLabel.font = .role(.body)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        overlay.onComment = { [weak self] point, area in self?.onNote?(point, area) }
        overlay.isHidden = true
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true
        picture.imageScaling = .scaleAxesIndependently
        picture.onClick = { [weak self] in self?.onWanted?() }
        addSubview(picture)
        addSubview(overlay)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 18)
        let page = pageFrame
        web?.frame = page
        picture.frame = page
        overlay.frame = page
    }

    private var pageFrame: NSRect {
        NSRect(x: 0, y: Self.titleHeight, width: bounds.width, height: max(bounds.height - Self.titleHeight, 0))
    }

    private func makeWebView() -> ArtboardWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.processPool = .app
        let view = ArtboardWebView(frame: pageFrame, configuration: config)
        view.navigationDelegate = self
        view.onNote = { [weak self] point in self?.onNote?(point, nil) }
        view.allowsMagnification = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(view, positioned: .below, relativeTo: picture)
        web = view
        return view
    }

    /// Its page, to load when the canvas gets to it; its last picture until then.
    func prepare(_ url: URL?, readAccess: URL, stamp: Date?) {
        source = url
        hasLoaded = false
        isLoading = false
        pending = (url, readAccess)
        pictureKey = url.flatMap { ArtboardPictures.key($0, stamp: stamp) }
        picture.image = nil
        picture.isHidden = false
        if let key = pictureKey {
            Task { [weak self] in
                let image = await ArtboardPictures.image(key)
                guard let self, self.pictureKey == key, !self.hasLoaded else { return }
                self.picture.image = image
            }
        }
    }

    /// Load the page it was prepared with (now its turn).
    func startLoad() {
        guard let pending else { return }
        self.pending = nil
        load(pending.url, readAccess: pending.readAccess)
    }

    /// Its file changed: a page that's in reloads; one not yet in will load
    /// the new file (its old picture is no picture of it); one put away
    /// reloads when it's back (the agent writing a page nobody's looking at
    /// reloaded it and took a loading turn from the ones in view).
    func changed(stamp: Date?) {
        pictureKey = source.flatMap { ArtboardPictures.key($0, stamp: stamp) }
        if pending != nil { picture.image = nil; return }
        if isParked { reloadWhenBack = true; return }
        reloadPage()
    }

    /// Out of view: its page hidden (WebKit doesn't draw a hidden view), its
    /// picture showing; back in view, the page again (reloaded, if its file
    /// changed meanwhile).
    private(set) var isParked = false
    private var reloadWhenBack = false

    /// When it was put away (the longest away unload first).
    private(set) var parkedAt = Date.distantPast
    /// What it was loaded with, to load again after `unload`.
    private var loadedWith: (url: URL?, readAccess: URL)?

    func setParked(_ parked: Bool) {
        guard let web, parked != isParked else { return }
        isParked = parked
        if parked { parkedAt = .now }
        web.isHidden = parked
        if parked {
            picture.isHidden = false
        } else if reloadWhenBack {
            reloadWhenBack = false
            reloadPage()
        } else if hasLoaded {
            picture.isHidden = true
        }
    }

    /// Back to its picture, its web view gone (and its page's memory with it):
    /// it loads again, like any page, when it's in view.
    func unload() {
        guard let view = web else { return }
        view.navigationDelegate = nil
        view.stopLoading()
        view.removeFromSuperview()
        web = nil
        isParked = false
        reloadWhenBack = false
        hasLoaded = false
        isLoading = false
        picture.isHidden = false
        pending = loadedWith
    }

    func load(_ url: URL?, readAccess: URL) {
        loadedWith = (url, readAccess)
        source = url
        hasLoaded = false
        isLoading = url != nil
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
        isLoading = true
        webView.reloadFromOrigin()
    }

    #if DEBUG
    var debugWebView: WKWebView { webView }
    var debugProcessPool: WKProcessPool? { web?.configuration.processPool }
    var pinCount: Int { pins.count }
    var debugOverlay: NSView { overlay }
    #endif

    /// Where a note's popover points from.
    var noteAnchor: NSView { web ?? picture }

    /// The element at `point`, from the page; nil if it won't say.
    func element(at point: CGPoint, area: CGRect? = nil) async -> CanvasNote.Element? {
        guard let web else { return nil }
        let json = try? await web.evaluateJavaScript(CanvasNote.elementScript(at: point, area: area)) as? String
        return json.flatMap { try? JSONDecoder().decode(CanvasNote.Element.self, from: Data($0.utf8)) }
    }

    func snapshot() async -> NSImage? {
        guard let web else { return picture.image }
        if isParked, let image = picture.image { return image }
        return try? await web.takeSnapshot(configuration: nil)
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
        guard let web else { return nil }
        return try? await web.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoaded = true
        isLoading = false
        onSettled?()
        // A moment for it to draw, then the page shows and its picture is kept for next time.
        let key = pictureKey
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.hasLoaded, !self.isParked else { return }
            self.picture.isHidden = true
            guard let key, let image = try? await self.webView.takeSnapshot(configuration: Self.pictureSnapshot()),
                  let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            ArtboardPictures.save(picture, key: key)
        }
    }

    /// Pictures are small: a board's thumbnail, not the page at full size.
    private static func pictureSnapshot() -> WKSnapshotConfiguration {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 640
        return config
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Log.error(.app, "canvas: \(source?.lastPathComponent ?? "-") didn't load: \(error.localizedDescription)")
        settleFailed()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Log.error(.app, "canvas: \(source?.lastPathComponent ?? "-") didn't load: \(error.localizedDescription)")
        settleFailed()
    }

    private func settleFailed() {
        isLoading = false
        picture.isHidden = true   // what the page shows of its failure
        onSettled?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.error(.app, "canvas: \(source?.lastPathComponent ?? "-")'s page process ended; reloading")
        webView.reload()
    }
}

/// An artboard's last picture, over its page until the page is in. A click
/// on it asks for the page (comments, links need it).
@MainActor
private final class ArtboardPicture: NSImageView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// All Pages: a page as a card — its name and size, then a row of pictures
/// per design (its first screens). Nothing loads here: a big board is its
/// pictures alone. A click opens the page.
@MainActor
final class PageCard: NSView {
    static let size = CGSize(width: 520, height: 300)
    var onOpen: (() -> Void)?
    private let current: Bool
    private var thumbs: [NSImageView] = []

    init(page: CanvasBoard.Page, board: CanvasBoard, current: Bool) {
        self.current = current
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        let title = NSTextField(labelWithAttributedString: CanvasView.pageSummary(page, board: board))
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 16, y: 14, width: Self.size.width - 32, height: 20)
        addSubview(title)
        let height: CGFloat = 40, rows = 5
        var y: CGFloat = 48
        for design in page.designs.prefix(rows) {
            var x: CGFloat = 16
            if let label = design.label {
                let mark = NSTextField(labelWithString: label)
                mark.font = .role(.meta, weight: .semibold)
                mark.textColor = .secondaryLabelColor
                mark.lineBreakMode = .byClipping
                mark.frame = NSRect(x: x, y: y + 12, width: 22, height: 16)
                addSubview(mark)
                x += 26
            }
            for id in design.screens {
                guard let artboard = board.artboard(id) else { continue }
                let width = min(max(height * artboard.width / artboard.height, 24), 96)
                guard x + width <= Self.size.width - 16 else { break }
                let thumb = NSImageView(frame: NSRect(x: x, y: y, width: width, height: height))
                thumb.imageScaling = .scaleAxesIndependently
                thumb.wantsLayer = true
                thumb.layer?.cornerRadius = 3
                thumb.layer?.masksToBounds = true
                addSubview(thumb)
                thumbs.append(thumb)
                let file = board.fileURL(of: artboard)
                let stamp = file.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
                if let file, let key = ArtboardPictures.key(file, stamp: stamp) {
                    Task { [weak thumb] in
                        let image = await ArtboardPictures.image(key)
                        thumb?.image = image
                    }
                }
                x += width + 6
            }
            y += height + 10
        }
        if page.designs.count > rows {
            let more = NSTextField(labelWithString: "+ \(page.designs.count - rows) more designs")
            more.font = .role(.meta)
            more.textColor = .tertiaryLabelColor
            more.sizeToFit()
            more.frame.origin = NSPoint(x: Self.size.width - 16 - more.frame.width, y: Self.size.height - 14 - more.frame.height)
            addSubview(more)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(page.title)
        setAccessibilityIdentifier("canvas-page-card")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = current ? 2 : 1
        layer?.borderColor = (current ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        for thumb in thumbs {
            thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            thumb.layer?.borderWidth = 1
            thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) { onOpen?() }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
}

/// Pictures of artboards, kept in Caches by their file and its date, so a
/// board opens with every artboard showing at once. Old ones go after 30 days.
enum ArtboardPictures {
    nonisolated static var folder: URL { URL.cachesDirectory.appending(path: "Sandshell/Canvas Pictures", directoryHint: .isDirectory) }

    /// A file's picture name for this version of it (none for a URL: a server's page changes on its own).
    nonisolated static func key(_ url: URL, stamp: Date?) -> String? {
        guard url.isFileURL, let stamp else { return nil }
        let text = "\(url.resolvingSymlinksInPath().path(percentEncoded: false))|\(stamp.timeIntervalSince1970)"
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Pictures read this run, kept in memory (a board reloads its pictures
    /// as the agent writes, All Pages a card's worth at a time).
    @MainActor private static let recent: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    @MainActor static func image(_ key: String) async -> NSImage? {
        if let image = recent.object(forKey: key as NSString) { return image }
        let file = folder.appending(path: key + ".png")
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
        guard let image = data.flatMap(NSImage.init(data:)) else { return nil }
        recent.setObject(image, forKey: key as NSString)
        return image
    }

    /// Encoded off the main thread (a TIFF of each page, then a PNG, ran on it).
    static func save(_ image: CGImage, key: String) {
        let file = folder.appending(path: key + ".png")
        Task.detached(priority: .utility) {
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
    }

    /// Pictures not written in 30 days go (boards change; old versions pile up).
    static func prune() {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let old = Date.now.addingTimeInterval(-30 * 86_400)
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let date, date < old { try? fm.removeItem(at: file) }
            }
        }
    }
}
