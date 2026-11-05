import AppKit
import WebKit

/// A board on a zoomable, pannable surface: each artboard a web view sized to
/// it, titled above. Scroll anywhere or drag the empty space to pan (⌥-scroll
/// scrolls a page itself); pinch to zoom. Watches the board folder and reloads what changed, so the
/// agent's edits show as they land. See docs/canvas.md.
@MainActor
final class CanvasView: NSView {
    private let scrollView = NSScrollView()
    private let document = CanvasDocumentView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var board: CanvasBoard?
    private var folder: URL?
    private var artboardViews: [String: ArtboardView] = [:]
    /// When each file artboard's file was last seen changed (a reload only for those).
    private var modified: [String: Date] = [:]
    private var watcher: FileWatcher?
    private var zoomedToFit = false

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
        NSLayoutConstraint.activate([
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

    #if DEBUG
    var debugArtboardIDs: [String] { (board?.artboards ?? []).map(\.id).filter { artboardViews[$0] != nil } }
    var debugLoadedCount: Int { artboardViews.values.filter(\.hasLoaded).count }
    var debugReloads: Int { artboardViews.values.reduce(0) { $0 + $1.reloads } }
    var debugMessage: String? { messageLabel.isHidden ? nil : messageLabel.stringValue }
    var debugMagnification: CGFloat { scrollView.magnification }
    func debugPageText(_ id: String) async -> String? { await artboardViews[id]?.pageText() }
    /// Where the view is on the board (the clip view's origin).
    var debugVisibleOrigin: NSPoint { scrollView.contentView.bounds.origin }
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

/// One artboard: its title, then the page in a web view of the artboard's size.
@MainActor
private final class ArtboardView: NSView, WKNavigationDelegate {
    static let titleHeight: CGFloat = 28
    private let titleLabel = NSTextField(labelWithString: "")
    private let webView: WKWebView
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
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 6
        webView.layer?.masksToBounds = true
        webView.layer?.borderWidth = 1
        webView.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(webView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 18)
        webView.frame = NSRect(x: 0, y: Self.titleHeight, width: bounds.width,
                               height: max(bounds.height - Self.titleHeight, 0))
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
    #endif

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
