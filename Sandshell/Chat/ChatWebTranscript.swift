import AppKit
import WebKit

/// A chat's transcript: the Remote Control web page (`remote/web`) in its
/// transcript-only mode, fed from the chat's `ChatFeed` as a device's event
/// stream would be. WebKit lays out and paints all the text the page has, and
/// the page checks every patch follows on from the last (else it asks for
/// everything again) — so what the chat has, shows.
///
/// The window has the rest (composer, cards, choosers). From the page come
/// what a transcript does: open a file (paths the Mac found on disk,
/// `FileLinks`), open a link in the browser, copy, fork from a reply, undo a
/// turn's changes.
@MainActor
final class ChatWebTranscript: NSView {
    static let scheme = "sandshell-web"
    /// The text's column (the composer lines up with it): at most this wide.
    static let readableWidth: CGFloat = 800

    let source: any ChatFeedSource
    private(set) var webView: WKWebView!
    private let relay = Relay()
    private(set) var isReady = false

    /// The session's folder: relative paths in the text resolve against it.
    var workdir: String?
    /// A file path in the text was clicked (with its `:line`, if any).
    var onOpenFile: ((URL, Int?) -> Void)?
    /// Fork the conversation into a new chat, up to and including this reply's text.
    var onFork: ((_ replyText: String) -> Void)? { didSet { sendConfig() } }
    /// "Undo" on a turn's changed-files line.
    var onUndo: ((_ turn: String) -> Void)? { didSet { sendConfig() } }
    /// Where Copy puts things (self-tests use their own, not the clipboard).
    var pasteboard = NSPasteboard.general

    init(source: any ChatFeedSource) {
        self.source = source
        super.init(frame: .zero)
        relay.owner = self
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(relay, forURLScheme: Self.scheme)
        config.userContentController.addScriptMessageHandler(relay, contentWorld: .page, name: "sandshell")
        // Before the page's own script: it's the transcript alone.
        config.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('embedded', 'transcript-only');",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: bounds, configuration: config)
        webView.navigationDelegate = relay
        webView.autoresizingMask = [.width, .height]
        // The chat's own background shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = ChatTextZoom.scale
        webView.setAccessibilityIdentifier("chat-transcript")
        addSubview(webView)
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://app/s/\(source.feedID.uuidString)")!))
        source.feed.listen(self) { view, event in
            switch event {
            case .state(let now): view.send(now)
            case .patch(let patch): view.send("patch", patch)
            }
        }
        // The text size, and the fonts (Settings ▸ Editor), changed.
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: ChatTextZoom.didChange, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func textChanged() {
        webView.pageZoom = ChatTextZoom.scale
        sendConfig()
    }

    // MARK: To the page

    /// `window.sandshellReceive(name, data)`, as an event stream would.
    /// One that doesn't arrive leaves the page behind: it gets everything again.
    private func send(_ name: String, _ value: some Encodable) {
        guard isReady else { return }
        guard let data = try? JSONEncoder().encode(value), var json = String(data: data, encoding: .utf8) else {
            Log.error(.app, "chat transcript: couldn't encode the \(name)")
            resendSoon()
            return
        }
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        webView.evaluateJavaScript("window.sandshellReceive(\"\(name)\", \(json))") { [weak self] _, error in
            guard let error else { return }
            Log.error(.app, "chat transcript: the page didn't take the \(name): \(error.localizedDescription)")
            self?.resendSoon()
        }
    }

    private func send(_ state: ChatFeed.Snapshot) {
        let session = RemoteWire.SessionSummary(id: source.feedID, name: "", agent: "", agentName: "", folder: "",
                                                phase: state.status.phase, waiting: nil, isCheck: false)
        send("state", RemoteWire.State(session: session, status: state.status, items: state.items, omitted: 0, rev: state.rev))
    }

    /// Everything, as a new page (or one that lost its place) starts from.
    fileprivate func sendState() { if isReady { send(source.feed.state()) } }

    private func resendSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sendState() }
    }

    struct Config: Encodable {
        let canFork: Bool
        let canUndo: Bool
        let replyFont: String
        let messageFont: String
        /// The type scale's three sizes, in points (the page's px; zoom is the view's).
        let sizes: Sizes
    }

    struct Sizes: Encodable, Equatable {
        let small: CGFloat
        let ui: CGFloat
        let reading: CGFloat

        /// The app's scale (`TypeRole`), which the page's CSS is written in.
        static let app = Sizes(small: TypeRole.meta.pointSize, ui: TypeRole.body.pointSize,
                               reading: TypeRole.reading.pointSize)
    }

    /// What this transcript offers, its fonts and sizes.
    private func sendConfig() {
        send("config", Config(canFork: onFork != nil, canUndo: onUndo != nil,
                              replyFont: Self.cssFamily(ChatFonts.reply), messageFont: Self.cssFamily(ChatFonts.message),
                              sizes: .app))
    }

    /// A Settings font family as CSS.
    static func cssFamily(_ family: String) -> String {
        switch family {
        case ChatFonts.system: "-apple-system, system-ui, sans-serif"
        case ChatFonts.newYork: "ui-serif, \"New York\", Georgia, serif"
        default: "\"\(family.replacing("\"", with: "").replacing("\\", with: ""))\", -apple-system, system-ui, sans-serif"
        }
    }

    /// The page is loaded and listening: what it offers, everything, then patches.
    fileprivate func pageReady() {
        isReady = true
        sendConfig()
        sendState()
    }

    /// WebKit's page process went (memory pressure, a crash): load the page again.
    fileprivate func pageDied() {
        Log.error(.app, "chat transcript: the page's process ended; loading it again")
        isReady = false
        webView.reload()
    }

    // MARK: Find, print

    /// ⌘F / ⌘G / ⇧⌘G (the composer passes them on): the page's find bar.
    func performFind(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        let action = switch NSTextFinder.Action(rawValue: tag) {
        case .nextMatch?: "next"
        case .previousMatch?: "previous"
        case .hideFindInterface?: "hide"
        default: "show"
        }
        if action == "show" { window?.makeFirstResponder(webView) }
        webView.evaluateJavaScript("window.sandshellFind?.(\"\(action)\")", completionHandler: nil)
    }

    /// File ▸ Print: the whole transcript, paginated.
    func printTranscript() {
        guard let window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        // WebKit prints nothing from a print view without a size.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: From the page

    fileprivate func command(_ name: String, _ body: [String: Any]) -> (Any?, String?) {
        func ok(_ value: some Encodable) -> (Any?, String?) {
            let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
            return (["status": 200, "body": String(decoding: data, as: UTF8.self)], nil)
        }
        func ok() -> (Any?, String?) { (["status": 200, "body": "{}"], nil) }
        switch name {
        case "ready": pageReady()
        // It missed a patch, or one didn't apply: everything again.
        case "resync": sendState()
        case "fileLinks":
            guard let workdir, let text = body["text"] as? String else { return ok(["links": [FileLinks.Link]()]) }
            let code = body["code"] as? [String] ?? []
            return ok(["links": FileLinks.find(in: text, code: code, workdir: workdir)])
        case "openFile":
            guard let path = body["path"] as? String, path.hasPrefix("/") else { break }
            onOpenFile?(URL(filePath: path), body["line"] as? Int)
        case "openURL":
            guard let url = (body["url"] as? String).flatMap(URL.init(string:)),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { break }
            NSWorkspace.shared.open(url)
        case "copy":
            guard let text = body["text"] as? String else { break }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if let html = body["html"] as? String, !html.isEmpty { pasteboard.setString(html, forType: .html) }
        case "fork":
            if let text = body["text"] as? String { onFork?(text) }
        case "undo":
            if let turn = body["turn"] as? String { onUndo?(turn) }
        default:
            return (nil, "Not a command: \(name)")
        }
        return ok()
    }

    /// The page's files, and the transcript's images at the addresses the page uses.
    fileprivate func serve(_ url: URL) -> (data: Data, type: String)? {
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        if parts.count == 6, parts[0] == "api", parts[1] == "sessions", parts[3] == "images", let index = Int(parts[5]) {
            return RemoteWire.image(in: source.items, item: parts[4], index: index).map { ($0, "application/octet-stream") }
        }
        guard let root = RemoteRoutes.webRoot?.standardizedFileURL else { return nil }
        let name = parts.isEmpty || parts.first == "s" ? "index.html" : parts.joined(separator: "/")
        let file = root.appending(path: name).standardizedFileURL
        guard file.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false)),
              let data = try? Data(contentsOf: file) else { return nil }
        return (data, RemoteRoutes.contentType(file.pathExtension))
    }

    #if DEBUG
    /// The transcript as the page shows it.
    func debugTranscriptText() async -> String {
        (try? await webView.evaluateJavaScript("document.getElementById('transcript').innerText") as? String) ?? ""
    }
    /// Runs `script` (a function body) in the page; its result if it's a Bool.
    func debugRun(_ script: String) async -> Bool? {
        (try? await webView.callAsyncJavaScript(script, contentWorld: .page)) as? Bool
    }
    func debugValue(_ script: String) async -> Any? {
        try? await webView.callAsyncJavaScript(script, contentWorld: .page)
    }
    /// The text's column, as the page lays it out (in this view).
    func debugTextColumn() async -> NSRect {
        let js = """
            const t = document.getElementById('transcript'), cs = getComputedStyle(t);
            const inner = t.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
            const w = Math.min(inner, 800);
            return [t.getBoundingClientRect().left + parseFloat(cs.paddingLeft) + (inner - w) / 2, w];
            """
        guard let r = await debugValue(js) as? [Double], r.count == 2 else { return .zero }
        let zoom = webView.pageZoom
        return NSRect(x: r[0] * zoom, y: 0, width: r[1] * zoom, height: bounds.height)
    }
    /// Waits until the page has loaded and shows what the source has.
    func debugSettled(timeout: TimeInterval = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if isReady, await debugRun("return state.rev !== null && !state.resyncing") == true {
                let want = RemoteWire.items(source.items, session: source.feedID).map(\.id)
                if let shown = await debugValue("return state.order") as? [String], shown == want { return true }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    #endif

    /// WebKit keeps its handlers: this one holds the view weakly.
    private final class Relay: NSObject, WKScriptMessageHandlerWithReply, WKURLSchemeHandler, WKNavigationDelegate {
        weak var owner: ChatWebTranscript?

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { owner?.pageDied() }

        /// Only the page itself loads here; a link goes to the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, url.scheme != ChatWebTranscript.scheme else { return .allow }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return .cancel
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard let owner, let body = message.body as? [String: Any], let name = body["name"] as? String else {
                return (nil, "Not a command")
            }
            // Its fields: in `body` as JSON (as a device's POST), or alongside the name.
            var fields = body
            if let json = body["body"] as? String, let data = json.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                fields.merge(decoded) { $1 }
            }
            return owner.command(name, fields)
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url, let found = owner?.serve(url) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": found.type])!
            task.didReceive(response)
            task.didReceive(found.data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }
}
