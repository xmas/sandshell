import AppKit
import Combine

/// Pasteboard type for a sidebar session dragged onto a pane.
extension NSPasteboard.PasteboardType {
    static let sandshellSession = NSPasteboard.PasteboardType("com.xmas.sandshell.session")
}

/// The window's detail area as a tree of split panes. Each leaf is a
/// `TerminalStackController` showing one session from the shared
/// `SessionSurfaces`, or a Files surface (tree + editor) for a session's
/// folder; splits are native NSSplitViews (draggable dividers), nested either
/// way. The focused pane follows the sidebar selection — a Files pane stays put
/// and the selection goes to the last session pane instead; the layout
/// (structure, sessions, Files panes, divider fractions) is saved per window.
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
    var onToggleSidebar: (() -> Void)?
    var onChromeChange: ((TerminalStackController.Chrome?) -> Void)?
    var onStatusChange: ((String, Bool) -> Void)?

    private let controller: WorkspaceController
    let surfaces: SessionSurfaces
    private var root: Node!
    private(set) var focused: TerminalStackController!
    /// The session pane focused most recently (sidebar picks land there while
    /// a Files pane has focus).
    private weak var lastSessionPane: TerminalStackController?
    private var sidebarCollapsed = false
    private var cancellables: Set<AnyCancellable> = []
    private var clickMonitor: Any?
    private let container = PaneDropContainer()
    private var saveScheduled = false
    private var layoutKey: String { "paneLayout:" + controller.rootURL.standardizedFileURL.path }

    init(controller: WorkspaceController) {
        self.controller = controller
        self.surfaces = SessionSurfaces(controller: controller)
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

        surfaces.isShown = { [weak self] id in self?.panes.contains { $0.shownSession == id } ?? false }
        surfaces.onTerminalExit = { [weak self] id in
            self?.panes.filter { $0.shownSession == id }.forEach { $0.terminalRuntimeDidExit(id) }
        }
        root = restoreLayout() ?? Node(.leaf(makePane()))
        // Focus the pane holding the selected session, if the layout has it.
        if case .session(let id)? = controller.selection, let holder = panes.first(where: { $0.shownSession == id }) {
            focused = holder
        } else {
            focused = panes.first
        }
        rebuild()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controller.$selection.sink { [weak self] sel in self?.selectionChanged(sel) }.store(in: &cancellables)
        // Clicking anywhere in a pane focuses it.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            let point = self.view.convert(event.locationInWindow, from: nil)
            if let pane = self.panes.first(where: { $0.view.convert($0.view.bounds, to: self.view).contains(point) }),
               pane !== self.focused {
                self.focus(pane)
            }
            return event
        }
    }

    // MARK: Panes

    private func makePane() -> TerminalStackController {
        let pane = TerminalStackController(controller: controller, surfaces: surfaces)
        pane.onToggleSidebar = { [weak self] in self?.onToggleSidebar?() }
        pane.onChromeChange = { [weak self, weak pane] chrome in
            if let self, pane === self.focused { self.onChromeChange?(chrome) }
        }
        pane.onStatusChange = { [weak self, weak pane] text, working in
            if let self, pane === self.focused { self.onStatusChange?(text, working) }
        }
        pane.onClosePane = { [weak self, weak pane] in if let pane { self?.close(pane) } }
        pane.onSplit = { [weak self, weak pane] edge in
            if let self, let pane { self.split(pane, edge: edge, showing: nil) }
        }
        pane.onOpenFiles = { [weak self, weak pane] in
            guard let self, let pane else { return }
            let target = pane.shownSession.flatMap { id in
                self.controller.session(id: id).map { FilesTarget(session: id, folder: $0.workdir) }
            } ?? FilesTarget(session: nil, folder: self.controller.rootURL.path)
            if let existing = self.panes.first(where: { $0.shownFiles == target }) { return self.focus(existing) }
            // An empty pane becomes the Files pane; otherwise open one beside it.
            if pane.shownSession == nil && pane.shownFiles == nil {
                pane.showFiles(target)
                self.focus(pane)
                self.scheduleSave()
            } else {
                self.split(pane, edge: .trailing, showing: nil, files: target)
            }
        }
        pane.onFilesAddToChat = { [weak self] urls, target in
            guard let self else { return }
            if let id = target.session ?? self.selectedSession { self.dropFiles(urls, on: id) }
        }
        addChild(pane)
        return pane
    }

    /// Focus `pane`: it gets the focus ring, and the sidebar/toolbar follow it.
    func focus(_ pane: TerminalStackController) {
        focused = pane
        for p in panes { p.isFocused = p === pane }
        // A Files pane leaves the sidebar selection alone.
        guard pane.shownFiles == nil else { return pane.reemitChrome() }
        lastSessionPane = pane
        if let id = pane.shownSession {
            if controller.selection != .session(id) { controller.selection = .session(id) }
        } else if controller.selection != nil {
            controller.selection = nil
        }
        pane.reemitChrome()
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
        if focused.shownFiles != nil {
            // Keep the Files pane: show the session in the last session pane,
            // or in a new one beside the Files.
            if let target = lastSessionPane ?? panes.first(where: { $0.shownFiles == nil }),
               panes.contains(where: { $0 === target }) {
                target.show(id)
                focus(target)
                scheduleSave()
            } else {
                split(focused, edge: .leading, showing: id)
            }
            return
        }
        focused.show(id)
        focused.reemitChrome()
        scheduleSave()
    }

    private var selectedSession: UUID? {
        if case .session(let id)? = controller.selection { id } else { nil }
    }

    // MARK: Files panes

    /// The Files surface of the focused pane, if it shows one.
    var focusedFiles: FilesPaneController? { focused?.filesPane }

    /// Any pane's Files surface (the focused one first).
    var anyFiles: FilesPaneController? { focusedFiles ?? panes.lazy.compactMap(\.filesPane).first }

    /// What "Open Files in Split" shows: the focused pane's session, else the
    /// selected one, else the workspace folder.
    func defaultFilesTarget() -> FilesTarget {
        if let id = focused?.shownSession ?? selectedSession, let s = controller.session(id: id) {
            return FilesTarget(session: id, folder: s.workdir)
        }
        if let files = focused?.shownFiles { return files }
        return FilesTarget(session: nil, folder: controller.rootURL.path)
    }

    /// Open a Files pane to the right of the focused pane (or focus the one
    /// already showing `target`).
    func openFiles(_ target: FilesTarget) {
        if let existing = panes.first(where: { $0.shownFiles == target }) { return focus(existing) }
        split(focused, edge: .trailing, showing: nil, files: target)
    }

    // MARK: Splitting

    enum Edge { case leading, trailing, top, bottom }

    /// Split the focused pane (Split Right / Split Down); the new pane is
    /// empty and focused — pick a session in the sidebar to fill it.
    func splitFocused(_ edge: Edge, showing session: UUID? = nil) {
        split(focused, edge: edge, showing: session)
    }

    func split(_ pane: TerminalStackController, edge: Edge, showing session: UUID?, files: FilesTarget? = nil) {
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
        rebuild()
        if let files {
            newPane.showFiles(files)
        } else if let session {
            panes.filter { $0 !== newPane && $0.shownSession == session }.forEach { $0.show(nil) }
            newPane.show(session)
        } else {
            newPane.show(nil)
        }
        focus(newPane)
        scheduleSave()
    }

    /// Close a pane (its session keeps running and can be shown again).
    func close(_ pane: TerminalStackController) {
        guard panes.count > 1, let leaf = node(for: pane), let parent = leaf.parent,
              case .split(let axis, var kids) = parent.kind, pane.confirmLeavingFiles() else { return }
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
        rebuild()
        if focused === pane, let next = panes.first { focus(next) }
        scheduleSave()
    }

    func closeFocused() { if let focused { close(focused) } }

    /// Move focus to the next/previous pane in reading order.
    func focusAdjacent(_ delta: Int) {
        let all = panes
        guard all.count > 1, let i = all.firstIndex(where: { $0 === focused }) else { return }
        focus(all[(i + delta + all.count) % all.count])
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
    private func rebuild() {
        // Building splits fires divider-tagged resizes from AppKit's own layout;
        // ignore them until our positions are applied.
        applyingFractions = true
        view.subviews.filter { $0 !== dropOverlay }.forEach { $0.removeFromSuperview() }
        let top = build(root)
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top, positioned: .below, relativeTo: dropOverlay.superview === view ? dropOverlay : nil)
        if dropOverlay.superview !== view { view.addSubview(dropOverlay) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor),
            top.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let many = panes.count > 1
        for p in panes {
            p.showsFocusRing = many
            p.isFocused = p === focused
            p.setSidebarCollapsed(sidebarCollapsed)
        }
        // Divider positions need the splits' real sizes: apply them after
        // this layout pass (positions computed from zero would clamp to the minimum).
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.applyFractions(self.root)
            self.applyingFractions = false
            self.panes.forEach { $0.redrawSurface() }
        }
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
        guard info.draggingPasteboard.string(forType: .sandshellSession) != nil else { return [] }
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
              let (pane, edge) = dropTarget else { return false }
        if let edge {
            split(pane, edge: edge, showing: id)
        } else {
            guard pane.confirmLeavingFiles() else { return false }
            panes.filter { $0 !== pane && $0.shownSession == id }.forEach { $0.show(nil) }
            pane.show(id)
            focus(pane)
            scheduleSave()
        }
        return true
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var axis: Axis?
        var children: [Saved]?
        var fractions: [CGFloat]?
        var session: UUID?
        var files: FilesTarget?
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            @MainActor func encode(_ n: Node) -> Saved {
                switch n.kind {
                case .leaf(let p): return Saved(session: p.shownSession, files: p.shownFiles)
                case .split(let a, let kids): return Saved(axis: a, children: kids.map(encode), fractions: n.fractions)
                }
            }
            if let data = try? JSONEncoder().encode(encode(self.root)) {
                UserDefaults.standard.set(data, forKey: self.layoutKey)
            }
        }
    }

    private func restoreLayout() -> Node? {
        guard let data = UserDefaults.standard.data(forKey: layoutKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        var seen: Set<UUID> = []
        @MainActor func decode(_ s: Saved) -> Node? {
            if let axis = s.axis, let kids = s.children?.compactMap(decode), !kids.isEmpty {
                if kids.count == 1 { return kids[0] }
                let n = Node(.split(axis, kids))
                kids.forEach { $0.parent = n }
                n.fractions = s.fractions?.count == kids.count ? s.fractions! : []
                return n
            }
            let pane = makePane()
            if let files = s.files { pane.showFiles(files); return Node(.leaf(pane)) }
            // Restore only sessions that still exist, each in one pane.
            if let id = s.session, controller.session(id: id) != nil, seen.insert(id).inserted {
                pane.show(id)
            }
            return Node(.leaf(pane))
        }
        return decode(saved)
    }

    // MARK: Window API (forwarded to the focused pane)

    func setSidebarCollapsed(_ collapsed: Bool) {
        sidebarCollapsed = collapsed
        panes.forEach { $0.setSidebarCollapsed(collapsed) }
    }

    func teardown() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panes.forEach { $0.teardown() }
        surfaces.backgroundTasks.stop()
    }

    @discardableResult
    func insertExternalItems(_ urls: [URL]) -> Bool { focused?.insertExternalItems(urls) ?? false }

    func queueDraft(_ text: String, urls: [URL], send: Bool, for id: UUID) {
        (panes.first { $0.shownSession == id } ?? focused)?.queueDraft(text, urls: urls, send: send, for: id)
    }

    func dropFiles(_ urls: [URL], on id: UUID) {
        (panes.first { $0.shownSession == id } ?? focused)?.dropFiles(urls, on: id)
    }

    @objc func revealInFinderClicked() { focused?.revealInFinderClicked() }
    @objc func stopClicked() { focused?.stopClicked() }
    @objc func headerRestartClicked() { focused?.headerRestartClicked() }
    @objc func toggleChatClicked() { focused?.toggleChatClicked() }
}

extension PaneTreeController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { focused?.validateToolbarItem(item) ?? false }
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
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
