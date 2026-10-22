import AppKit
import Combine

/// Pasteboard type for a sidebar session dragged onto a pane.
extension NSPasteboard.PasteboardType {
    static let sandshellSession = NSPasteboard.PasteboardType("com.xmas.sandshell.session")
}

/// The window's detail area as a tree of split panes. Each leaf is a
/// `TerminalStackController` showing one session from the shared
/// `SessionSurfaces` (or nothing yet); splits are native NSSplitViews
/// (draggable dividers), nested either way. Files is never a pane — it's the
/// window's trailing sidebar. The focused pane follows the sidebar selection;
/// the layout (structure, sessions, divider fractions) is saved per window.
@MainActor
final class PaneTreeController: NSViewController, NSSplitViewDelegate {
    /// Split orientation: `.horizontal` = side by side (vertical divider).
    enum Axis: String, Codable { case horizontal, vertical }

    /// Layout tree.
    final class Node {
        enum Kind { case leaf(TerminalStackController), split(Axis, [Node]) }
        var kind: Kind
        weak var parent: Node?
        /// Children's share of the split (sums to 1), kept across rebuilds.
        var fractions: [CGFloat] = []
        init(_ kind: Kind) { self.kind = kind }
        var pane: TerminalStackController? { if case .leaf(let p) = kind { p } else { nil } }
        var children: [Node] { if case .split(_, let c) = kind { c } else { [] } }
    }

    // Window API (same as the old single detail pane).
    var onChromeChange: ((TerminalStackController.Chrome?) -> Void)?
    var onStatusChange: ((String, Bool) -> Void)?
    /// A pane's branch crumb: show the window's Files sidebar (just the changes, or all).
    var onShowFiles: ((_ changesOnly: Bool) -> Void)?
    /// A file link in a pane's chat: open it in the window's Files sidebar (at a line).
    var onOpenFile: ((URL, Int?) -> Void)?

    private let controller: WorkspaceController
    let surfaces: SessionSurfaces
    private var root: Node!
    private(set) var focused: TerminalStackController!
    private var cancellables: Set<AnyCancellable> = []
    private var clickMonitor: Any?
    private let container = PaneDropContainer()
    /// The layout save waiting out its debounce (`scheduleSave`).
    private var saveTask: Task<Void, Never>?
    /// Where this window's layout is saved (see `layoutKey(root:instanceIndex:)`).
    let layoutKey: String
    /// Whether the window opens on its saved layout (a Duplicate Window starts
    /// with one fresh pane instead).
    private let restoresLayout: Bool
    /// The window closed and its layout was dropped (`forgetLayout`): a save
    /// still pending mustn't write it back.
    private var layoutForgotten = false

    /// The layout's defaults key for window `instanceIndex` on `root`: each
    /// window on a folder keeps its own (index 0 the legacy per-folder key).
    nonisolated static func layoutKey(root: URL, instanceIndex: Int) -> String {
        let path = root.standardizedFileURL.path
        return "paneLayout:" + (instanceIndex == 0 ? path : "\(path)#\(instanceIndex)")
    }

    init(controller: WorkspaceController, instanceIndex: Int = 0, restoresLayout: Bool = true) {
        self.controller = controller
        self.surfaces = SessionSurfaces(controller: controller)
        self.layoutKey = Self.layoutKey(root: controller.rootURL, instanceIndex: instanceIndex)
        self.restoresLayout = restoresLayout
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var panes: [TerminalStackController] { leaves(root).compactMap(\.pane) }

    override func loadView() {
        container.onDragUpdate = { [weak self] info in self?.dragUpdated(info) ?? [] }
        container.onDragEnd = { [weak self] in self?.dropOverlay.isHidden = true }
        container.onDrop = { [weak self] info in self?.performDrop(info) ?? false }
        container.registerForDraggedTypes([.sandshellSession])
        dropOverlay.isHidden = true
        view = container

        surfaces.paneShowing = { [weak self] id in self?.panes.first { $0.shownSession == id } }
        surfaces.onTerminalExit = { [weak self] id in
            self?.panes.filter { $0.shownSession == id }.forEach { $0.terminalRuntimeDidExit(id) }
        }
        surfaces.onLaunched = { [weak self] id in
            self?.panes.filter { $0.shownSession == id }.forEach { $0.refresh() }
        }
        surfaces.onChatAgentExit = { [weak self] id in
            self?.panes.first { $0.shownSession == id }?.chatAgentExited(id)
        }
        root = (restoresLayout ? restoreLayout() : nil) ?? Node(.leaf(makePane()))
        // Focus the pane holding the selected session, if the layout has it.
        if case .session(let id)? = controller.selection, let holder = panes.first(where: { $0.shownSession == id }) {
            focused = holder
        } else {
            focused = panes.first(where: { $0.shownSession != nil }) ?? panes.first
            // The sidebar selects what the restored pane shows (not something off screen).
            if let id = focused.shownSession { controller.selection = .session(id) }
        }
        rebuild()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controller.$selection.sink { [weak self] sel in self?.selectionChanged(sel) }.store(in: &cancellables)
        // Clicking anywhere in a pane focuses it.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window else { return event }
            // The toolbar/titlebar is its own area (panes extend up under it):
            // a click there never moves pane focus.
            guard window.contentLayoutRect.contains(event.locationInWindow) else { return event }
            let point = self.view.convert(event.locationInWindow, from: nil)
            if let pane = self.panes.first(where: { $0.view.convert($0.view.bounds, to: self.view).contains(point) }),
               pane !== self.focused {
                self.focus(pane)
            }
            return event
        }
    }

    // MARK: Panes

    /// The sidebar's "+ New Session" menu, for an empty pane's New Session.
    var newSessionMenu: (() -> NSMenu?)?

    private func makePane() -> TerminalStackController {
        let pane = TerminalStackController(controller: controller, surfaces: surfaces)
        pane.onChromeChange = { [weak self, weak pane] chrome in
            if let self, pane === self.toolbarPane { self.onChromeChange?(chrome) }
        }
        pane.onStatusChange = { [weak self, weak pane] text, working in
            if let self, pane === self.toolbarPane { self.onStatusChange?(text, working) }
        }
        pane.onClosePane = { [weak self, weak pane] in if let pane { self?.close(pane) } }
        pane.newSessionMenu = { [weak self] in self?.newSessionMenu?() }
        pane.onSplit = { [weak self, weak pane] edge in
            if let self, let pane { self.split(pane, edge: edge, showing: nil) }
        }
        // Files is the window's sidebar: the pane's session is selected (it
        // has focus from the click), so the sidebar shows its folder.
        pane.onShowFiles = { [weak self, weak pane] changesOnly in
            guard let self, let pane else { return }
            self.focus(pane)
            self.onShowFiles?(changesOnly)
        }
        pane.onOpenFileInFiles = { [weak self, weak pane] url, line in
            guard let self, let pane else { return }
            if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            self.focus(pane)
            self.onOpenFile?(url, line)
        }
        addChild(pane)
        return pane
    }

    /// Focus `pane`: it gets the focus ring, and the sidebar/toolbar follow it.
    func focus(_ pane: TerminalStackController) {
        focused = pane
        for p in panes { p.isFocused = p === pane }
        if let id = pane.shownSession {
            if controller.selection != .session(id) { controller.selection = .session(id) }
        } else if controller.selection != nil {
            controller.selection = nil
        }
        pane.reemitChrome()
    }

    /// Focus `pane` from the keyboard (Next/Previous Pane): the keys go with
    /// the ring.
    private func focusWithKeyboard(_ pane: TerminalStackController) {
        focus(pane)
        giveKeyboard(to: pane)
    }

    /// Where the keys are before the panes change (`keyHolder`). Taking a
    /// view out of the window takes the keys from it (the window becomes
    /// first responder), so `rebuild` and `close` note them first and hand
    /// them back after (`restoreKeys`, `giveKeyboard`).
    private func keysInPanes() -> NSResponder? {
        guard let window = view.window else { return nil }
        return Self.keyHolder(window.firstResponder, in: window, panes: view)
    }

    /// After the panes changed: keys that were in them (`keysInPanes`) go
    /// back to the view that had them while it's still showing, else to what
    /// the focused pane shows.
    private func restoreKeys(_ keys: NSResponder?) {
        guard keys != nil, let window = view.window else { return }
        if let held = Self.returningKeyView(keys, in: window, panes: view) {
            if window.firstResponder !== held { window.makeFirstResponder(held) }
        } else if let focused {
            giveKeyboard(to: focused)
        }
    }

    /// Where the keys are, for a change to the panes in `container` to hand
    /// on: `responder` (the window's first responder) when it's in them, or
    /// the window itself (keys going nowhere); nil while they're elsewhere
    /// (the sidebar, a field in the toolbar), which a change to the panes
    /// leaves alone. A text field being edited holds the window's field
    /// editor, which leaves it once the field is out of the window: the
    /// field is what comes back.
    static func keyHolder(_ responder: NSResponder?, in window: NSWindow, panes container: NSView) -> NSResponder? {
        guard let responder else { return nil }
        if responder === window { return window }
        guard let held = responder as? NSView, held.isDescendant(of: container) else { return nil }
        if let editor = held as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSView, field.isDescendant(of: container) {
            return field
        }
        return held
    }

    /// The view the keys go back to after a change to the panes in
    /// `container`: `keys` (from `keyHolder`) while it's still showing in
    /// them; nil once it's gone, or when they went nowhere — the focused pane
    /// takes them then.
    static func returningKeyView(_ keys: NSResponder?, in window: NSWindow, panes container: NSView) -> NSView? {
        guard let held = keys as? NSView, held.window === window, held.isDescendant(of: container),
              !held.isHiddenOrHasHiddenAncestor else { return nil }
        return held
    }

    /// The keys to what `pane` shows: its chat (the composer, or the agent's
    /// question), or its terminal. A pane with nothing to type into yet — empty, or its session still
    /// starting, which takes them once it's up — takes them from the pane left.
    private func giveKeyboard(to pane: TerminalStackController) {
        guard let window = view.window else { return }
        func isShown(_ v: NSView) -> Bool { v.isDescendant(of: pane.view) && !v.isHiddenOrHasHiddenAncestor }
        if let id = pane.shownSession, let chat = surfaces.chats[id], isShown(chat) {
            chat.focusComposer()
        } else if let id = pane.shownSession, let terminal = surfaces.terminals[id]?.view, isShown(terminal) {
            window.makeFirstResponder(terminal)
        } else if let responder = window.firstResponder as? NSView,
                  panes.contains(where: { $0 !== pane && responder.isDescendant(of: $0.view) }) {
            window.makeFirstResponder(nil)
        }
    }

    /// Sidebar selection → the focused pane, unless another pane already shows it.
    private func selectionChanged(_ selection: SidebarSelection?) {
        guard focused != nil else { return }
        guard case .session(let id)? = selection else {
            return   // deselecting keeps panes' content
        }
        if let other = panes.first(where: { $0.shownSession == id }) {
            if other !== focused { focus(other) }
            return
        }
        focused.show(id)
        focused.reemitChrome()
        scheduleSave()
    }

    // MARK: Splitting

    enum Edge { case leading, trailing, top, bottom }

    /// Split the focused pane (Split Right / Split Down); the new pane is
    /// empty and focused — pick a session in the sidebar to fill it.
    func splitFocused(_ edge: Edge, showing session: UUID? = nil) {
        split(focused, edge: edge, showing: session)
    }

    func split(_ pane: TerminalStackController, edge: Edge, showing session: UUID?) {
        guard let leaf = node(for: pane) else { return }
        let axis: Axis = (edge == .leading || edge == .trailing) ? .horizontal : .vertical
        let newPane = makePane()
        let newLeaf = Node(.leaf(newPane))
        let before = edge == .leading || edge == .top
        if let parent = leaf.parent, case .split(let pAxis, var kids) = parent.kind, pAxis == axis,
           let i = kids.firstIndex(where: { $0 === leaf }) {
            kids.insert(newLeaf, at: before ? i : i + 1)
            parent.kind = .split(axis, kids)
            newLeaf.parent = parent
            parent.fractions = []   // equalize
        } else {
            let replacement = Node(.leaf(pane))
            let split = Node(.split(axis, before ? [newLeaf, replacement] : [replacement, newLeaf]))
            leaf.kind = split.kind   // reuse the node in place (keeps its parent link)
            for c in leaf.children { c.parent = leaf }
            leaf.fractions = []
        }
        let keys = rebuild(restoringKeys: false)
        if let session {
            panes.filter { $0 !== newPane && $0.shownSession == session }.forEach { $0.show(nil) }
            newPane.show(session)
        } else {
            newPane.show(nil)
        }
        focus(newPane)
        // Keys that were in the panes go with the ring: to the session it
        // shows (an empty pane has nothing to take them yet).
        if keys != nil { giveKeyboard(to: newPane) }
        scheduleSave()
    }

    /// Close a pane (its session keeps running and can be shown again).
    func close(_ pane: TerminalStackController) {
        guard panes.count > 1, let leaf = node(for: pane), let parent = leaf.parent,
              case .split(let axis, var kids) = parent.kind else { return }
        let keys = keysInPanes()   // (before the pane's view, which may hold them, goes)
        pane.paneClosed()
        kids.removeAll { $0 === leaf }
        if kids.count == 1 {
            let only = kids[0]
            parent.kind = only.kind
            parent.fractions = only.fractions
            for c in parent.children { c.parent = parent }
        } else {
            parent.kind = .split(axis, kids)
            parent.fractions = []
        }
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        rebuild(restoringKeys: false)
        if focused === pane, let next = panes.first {
            // The ring moves on, and keys that were in the panes go with it.
            focus(next)
            if keys != nil { giveKeyboard(to: next) }
        } else {
            restoreKeys(keys)
        }
        scheduleSave()
    }

    func closeFocused() { if let focused { close(focused) } }

    /// Move focus (and the keys) to the next/previous pane in reading order.
    func focusAdjacent(_ delta: Int) {
        let all = panes
        guard all.count > 1, let i = all.firstIndex(where: { $0 === focused }) else { return }
        focusWithKeyboard(all[(i + delta + all.count) % all.count])
    }

    /// Give every split's children equal sizes.
    func equalize() {
        func reset(_ n: Node) { n.fractions = []; n.children.forEach(reset) }
        reset(root)
        rebuild()
        scheduleSave()
    }

    // MARK: View hierarchy

    /// Rebuild the split views from the tree (pane views are reparented).
    /// The tree leaves the window and comes back, which would drop the keys:
    /// keys that were in the panes go back to the view that had them (else to
    /// the focused pane's content) unless `restoringKeys` is false, when the
    /// caller hands them on itself. Returns where they were (`keysInPanes`).
    @discardableResult
    private func rebuild(restoringKeys: Bool = true) -> NSResponder? {
        let keys = keysInPanes()
        // Building splits fires divider-tagged resizes from AppKit's own layout;
        // ignore them until our positions are applied.
        applyingFractions = true
        view.subviews.filter { $0 !== dropOverlay }.forEach { $0.removeFromSuperview() }
        let top = build(root)
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top, positioned: .below, relativeTo: dropOverlay.superview === view ? dropOverlay : nil)
        if dropOverlay.superview !== view { view.addSubview(dropOverlay) }
        NSLayoutConstraint.activate([
            // Below the toolbar: the header is one strip across the window, and
            // pane dividers only split the content under it.
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            top.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let many = panes.count > 1
        for p in panes {
            p.showsFocusRing = many
            p.isFocused = p === focused
        }
        if restoringKeys { restoreKeys(keys) }
        // Divider positions need the splits' real sizes: apply them after
        // this layout pass (positions computed from zero would clamp to the minimum).
        view.layoutSubtreeIfNeeded()
        Task { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.applyFractions(self.root)
            self.applyingFractions = false
            self.panes.forEach { $0.redrawSurface() }
        }
        return keys
    }

    /// Set while we position dividers ourselves (don't record those as user moves).
    private var applyingFractions = false

    private func build(_ node: Node) -> NSView {
        switch node.kind {
        case .leaf(let pane):
            pane.view.removeFromSuperview()
            return pane.view
        case .split(let axis, let kids):
            let split = PaneSplitView()
            split.isVertical = axis == .horizontal
            split.dividerStyle = .thin
            split.delegate = self
            split.node = node
            for kid in kids {
                kid.parent = node
                split.addArrangedSubview(build(kid))
            }
            return split
        }
    }

    /// Apply saved fractions (or equal shares) to every split, top-down.
    private func applyFractions(_ node: Node) {
        guard case .split(_, let kids) = node.kind, let split = splitView(for: node) else { return }
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        guard total > 0 else { return }
        let dividers = CGFloat(kids.count - 1) * split.dividerThickness
        let available = max(total - dividers, 0)
        let shares = node.fractions.count == kids.count ? node.fractions
            : Array(repeating: 1 / CGFloat(kids.count), count: kids.count)
        var position: CGFloat = 0
        for i in 0..<(kids.count - 1) {
            position += available * shares[i]
            split.setPosition(position, ofDividerAt: i)
            position += split.dividerThickness
        }
        kids.forEach(applyFractions)
    }

    private func splitView(for node: Node) -> PaneSplitView? {
        func find(_ v: NSView) -> PaneSplitView? {
            if let s = v as? PaneSplitView, s.node === node { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return find(view)
    }

    private func leaves(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        if case .leaf = node.kind { return [node] }
        return node.children.flatMap(leaves)
    }

    private func node(for pane: TerminalStackController) -> Node? { leaves(root).first { $0.pane === pane } }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let minimum: CGFloat = splitView.isVertical ? 280 : 160
        let start = splitView.isVertical ? splitView.arrangedSubviews[index].frame.minX : splitView.arrangedSubviews[index].frame.minY
        return max(proposed, start + minimum)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let minimum: CGFloat = splitView.isVertical ? 280 : 160
        let next = splitView.arrangedSubviews[index + 1].frame
        let end = splitView.isVertical ? next.maxX : next.maxY
        return min(proposed, end - minimum)
    }

    /// Remember divider positions as fractions (survive window resizes, relaunch).
    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only real divider drags (AppKit tags them with the divider index) —
        // not the resizes from building splits or our own positioning.
        guard !applyingFractions, notification.userInfo?["NSSplitViewDividerIndex"] != nil,
              let split = notification.object as? PaneSplitView, let node = split.node,
              split.window?.inLiveResize == false else { return }
        let sizes = split.arrangedSubviews.map { split.isVertical ? $0.frame.width : $0.frame.height }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return }
        node.fractions = sizes.map { $0 / total }
        scheduleSave()
    }

    // MARK: Drag a session onto a pane

    private let dropOverlay = DropZoneOverlay()
    private var dropTarget: (TerminalStackController, Edge?)?

    private func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        // Only this window's folder's sessions (another window's would open empty here).
        guard let raw = info.draggingPasteboard.string(forType: .sandshellSession),
              let id = UUID(uuidString: raw), controller.session(id: id) != nil else { return [] }
        let point = view.convert(info.draggingLocation, from: nil)
        guard let pane = panes.first(where: { $0.view.convert($0.view.bounds, to: view).contains(point) }) else {
            dropOverlay.isHidden = true
            return []
        }
        let frame = pane.view.convert(pane.view.bounds, to: view)
        let fx = (point.x - frame.minX) / frame.width, fy = (point.y - frame.minY) / frame.height
        var edge: Edge?
        var zone = frame
        if fx < 0.25 { edge = .leading; zone.size.width /= 2 }
        else if fx > 0.75 { edge = .trailing; zone.origin.x += frame.width / 2; zone.size.width /= 2 }
        else if fy > 0.75 { edge = view.isFlipped ? .bottom : .top; zone.origin.y += frame.height / 2; zone.size.height /= 2 }
        else if fy < 0.25 { edge = view.isFlipped ? .top : .bottom; zone.size.height /= 2 }
        dropTarget = (pane, edge)
        dropOverlay.frame = zone.insetBy(dx: 6, dy: 6)
        dropOverlay.isHidden = false
        return .move
    }

    private func performDrop(_ info: NSDraggingInfo) -> Bool {
        dropOverlay.isHidden = true
        guard let raw = info.draggingPasteboard.string(forType: .sandshellSession), let id = UUID(uuidString: raw),
              controller.session(id: id) != nil, let (pane, edge) = dropTarget else { return false }
        if let edge {
            split(pane, edge: edge, showing: id)
        } else {
            panes.filter { $0 !== pane && $0.shownSession == id }.forEach { $0.show(nil) }
            pane.show(id)
            focus(pane)
            scheduleSave()
        }
        return true
    }

    // MARK: Persistence

    typealias Saved = SavedPaneLayout

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !self.layoutForgotten else { return }
            self.saveTask = nil
            @MainActor func encode(_ n: Node) -> Saved {
                switch n.kind {
                case .leaf(let p): Saved(session: p.shownSession)
                case .split(let a, let kids): Saved(axis: a, children: kids.map(encode), fractions: n.fractions)
                }
            }
            if let data = try? JSONEncoder().encode(encode(self.root)) {
                UserDefaults.standard.set(data, forKey: self.layoutKey)
            }
        }
    }

    /// The window closed while the app runs (not at quit, whose layout is
    /// restored at launch): drop its saved layout, so the next window to take
    /// its index doesn't open on the sessions this one showed.
    func forgetLayout() {
        layoutForgotten = true
        UserDefaults.standard.removeObject(forKey: layoutKey)
    }

    private func restoreLayout() -> Node? {
        // An earlier build's Files panes are gone (Files is the sidebar now).
        guard let data = UserDefaults.standard.data(forKey: layoutKey),
              let saved = (try? JSONDecoder().decode(Saved.self, from: data))?.withoutFiles() else { return nil }
        var seen: Set<UUID> = []
        @MainActor func decode(_ s: Saved) -> Node? {
            if let axis = s.axis, let kids = s.children?.compactMap(decode), !kids.isEmpty {
                if kids.count == 1 { return kids[0] }
                let n = Node(.split(axis, kids))
                kids.forEach { $0.parent = n }
                if let fractions = s.fractions, fractions.count == kids.count { n.fractions = fractions }
                return n
            }
            let pane = makePane()
            // Restore only sessions that still exist, each in one pane.
            if let id = s.session, controller.session(id: id) != nil, seen.insert(id).inserted {
                pane.show(id)
            }
            return Node(.leaf(pane))
        }
        return decode(saved)
    }

    // MARK: Window API (forwarded to the focused pane)

    func teardown() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panes.forEach { $0.teardown() }
        surfaces.backgroundTasks.stop()
    }

    /// Files opened with the app (Dock, `open -a`): into the toolbar's session.
    @discardableResult
    func insertExternalItems(_ urls: [URL]) -> Bool { toolbarPane?.insertExternalItems(urls) ?? false }

    func queueDraft(_ text: String, urls: [URL], send: Bool, for id: UUID) {
        (panes.first { $0.shownSession == id } ?? focused)?.queueDraft(text, urls: urls, send: send, for: id)
    }

    func dropFiles(_ urls: [URL], on id: UUID) {
        (panes.first { $0.shownSession == id } ?? focused)?.dropFiles(urls, on: id)
    }

    /// "Change this" from a diff line in Files, to the session's agent.
    func askAgent(_ text: String, on id: UUID) {
        (panes.first { $0.shownSession == id } ?? focused)?.askAgent(text, on: id)
    }

    /// The pane the toolbar speaks for: the focused one.
    var toolbarPane: TerminalStackController? { focused }

    @objc func revealInFinderClicked() { toolbarPane?.revealInFinderClicked() }
    @objc func stopClicked() { toolbarPane?.stopClicked() }
    @objc func headerRestartClicked() { toolbarPane?.headerRestartClicked() }
    @objc func toggleChatClicked() { toolbarPane?.toggleChatClicked() }
}

extension PaneTreeController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { toolbarPane?.validateToolbarItem(item) ?? false }
    func canPerformSessionAction(_ action: Selector) -> Bool { toolbarPane?.canPerformSessionAction(action) ?? false }
    var chatToggleTitle: String { toolbarPane?.chatToggleTitle ?? "Show as Chat" }
}

/// NSSplitView that knows its layout node.
final class PaneSplitView: NSSplitView {
    weak var node: PaneTreeController.Node?
}

/// The detail area's root view: accepts sessions dragged from the sidebar.
final class PaneDropContainer: NSView {
    var onDragUpdate: ((NSDraggingInfo) -> NSDragOperation)?
    var onDragEnd: (() -> Void)?
    var onDrop: ((NSDraggingInfo) -> Bool)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onDragUpdate?(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { onDragUpdate?(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragEnd?() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop?(sender) ?? false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onDragEnd?() }
}

/// Translucent highlight of where a dropped session will land.
final class DropZoneOverlay: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { updateColors() }
    private func updateColors() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            titlePill?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// What dropping does, centered in the zone ("Drop to attach").
    func setTitle(_ title: String, symbol: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .role(.bodyEmphasis)
        label.textColor = .controlAccentColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .role(.bodyEmphasis)
        icon.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        // On a pill of its own: it reads over whatever the zone covers.
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 16
        titlePill = stack
        updateColors()
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    private var titlePill: NSView?
}

/// A window's pane layout as saved: a split (axis, children, their shares) or
/// a leaf (the session it shows, if any).
struct SavedPaneLayout: Codable, Equatable {
    var axis: PaneTreeController.Axis?
    var children: [SavedPaneLayout]?
    var fractions: [CGFloat]?
    var session: UUID?
    /// A Files leaf an earlier build saved (Files was a pane then). Only read,
    /// to drop it: `withoutFiles`.
    var files: LegacyFilesLeaf?

    struct LegacyFilesLeaf: Codable, Equatable {}

    init(axis: PaneTreeController.Axis? = nil, children: [SavedPaneLayout]? = nil, fractions: [CGFloat]? = nil,
         session: UUID? = nil, files: LegacyFilesLeaf? = nil) {
        self.axis = axis
        self.children = children
        self.fractions = fractions
        self.session = session
        self.files = files
    }

    /// The layout with its Files leaves gone: a split left with one child is
    /// that child, the survivors keep their shares (rescaled to fill). Nil when
    /// nothing's left.
    func withoutFiles() -> SavedPaneLayout? {
        guard let axis, let children, !children.isEmpty else { return files == nil ? self : nil }
        let kept = children.indices.compactMap { i in children[i].withoutFiles().map { (i, $0) } }
        guard !kept.isEmpty else { return nil }
        if kept.count == 1 { return kept[0].1 }
        var shares: [CGFloat]?
        if let fractions, fractions.count == children.count {
            let survivors = kept.map { fractions[$0.0] }
            let total = survivors.reduce(0, +)
            if total > 0 { shares = survivors.map { $0 / total } }
        }
        return SavedPaneLayout(axis: axis, children: kept.map(\.1), fractions: shares)
    }
}
