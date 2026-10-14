import AppKit

/// The Files pane: the session folder's tree beside an editor, docked on the
/// window's trailing edge. Follows the active session's working directory.
@MainActor
final class FilesPaneController: NSSplitViewController {
    let tree = FileTreeController()
    let editor = FileEditorController()
    /// "Add to Chat" from the tree's context menu.
    var onAddToChat: (([URL]) -> Void)? {
        get { tree.onAddToChat }
        set { tree.onAddToChat = newValue }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "SandshellFilesSplit"
        let treeItem = NSSplitViewItem(viewController: tree)
        treeItem.minimumThickness = 180
        treeItem.maximumThickness = 420
        treeItem.canCollapse = true
        treeItem.holdingPriority = .init(260)
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 280
        addSplitViewItem(treeItem)
        addSplitViewItem(editorItem)
        tree.onOpen = { [weak self] url in self?.editor.open(url) }
        tree.onOpenAtLine = { [weak self] url, line, query in self?.editor.open(url, line: line, highlight: query) }
        tree.onGitStatus = { [weak self] status in self?.editor.updateGit(status) }
        tree.onFilesChanged = { [weak self] in self?.editor.filesChangedOnDisk() }
    }

    /// Show `folder` (nil = nothing).
    func setRoot(_ folder: URL?) {
        _ = view   // make sure children are loaded
        tree.setRoot(folder)
    }

    func open(_ url: URL) {
        _ = view
        editor.open(url)
    }
}
