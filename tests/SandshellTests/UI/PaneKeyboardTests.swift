import AppKit
import Testing
@testable import Sandshell

// Where a Files pane's keys go when keyboard focus moves to it (Next/Previous
// Pane, Close Pane): `PaneTreeController.keyView(inFiles:)` picks the file it
// shows — editor, preview or changes — else its file list.

@MainActor
struct FilesKeyViewTests {
    @Test func theShownFileTakesTheKeysOverTheList() {
        let files = NSView()
        let list = NSOutlineView()
        let editor = NSTextView()
        files.addSubview(list)
        files.addSubview(editor)
        #expect(PaneTreeController.keyView(inFiles: files) === editor)
    }

    @Test func aPreviewTakesThemToo() {
        let files = NSView()
        let preview = NSTextView()
        preview.isEditable = false
        files.addSubview(NSOutlineView())
        files.addSubview(preview)
        #expect(PaneTreeController.keyView(inFiles: files) === preview)
    }

    @Test("A hidden editor (no file open, or one Quick Look shows) leaves them to the list")
    func aHiddenEditorLeavesThemToTheList() {
        let files = NSView()
        let list = NSOutlineView()
        let editorScroll = NSView()
        editorScroll.isHidden = true
        editorScroll.addSubview(NSTextView())
        files.addSubview(editorScroll)
        files.addSubview(list)
        #expect(PaneTreeController.keyView(inFiles: files) === list)
    }

    @Test func textThatCantBeSelectedIsSkipped() {
        let files = NSView()
        let list = NSOutlineView()
        let label = NSTextView()
        label.isSelectable = false
        files.addSubview(label)
        files.addSubview(list)
        #expect(PaneTreeController.keyView(inFiles: files) === list)
    }

    @Test(.tags(.edgeCase)) func nothingToTypeIntoIsNil() {
        let files = NSView()
        files.addSubview(NSView())
        #expect(PaneTreeController.keyView(inFiles: files) == nil)
    }
}

// Keys across a change to the panes (Equalize, a split, Close Pane), which
// takes their views out of the window and back: `keyHolder` notes where the
// keys were, `returningKeyView` picks the view they go back to.

@MainActor
struct PaneKeyHolderTests {
    /// A window (never shown) whose content holds the panes beside a sidebar.
    private func makeWindow() -> (window: NSWindow, panes: NSView, sidebar: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let panes = NSView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        content.addSubview(sidebar)
        content.addSubview(panes)
        window.contentView = content
        return (window, panes, sidebar)
    }

    @Test func aViewInThePanesIsNoted() {
        let (window, panes, _) = makeWindow()
        let terminal = NSTextView()
        let pane = NSView()
        pane.addSubview(terminal)
        panes.addSubview(pane)
        #expect(PaneTreeController.keyHolder(terminal, in: window, panes: panes) === terminal)
    }

    @Test func keysGoingNowhereAreNotedAsTheWindow() {
        let (window, panes, _) = makeWindow()
        #expect(PaneTreeController.keyHolder(window, in: window, panes: panes) === window)
    }

    @Test("Keys in the sidebar, or none at all, are left where they are")
    func keysElsewhereAreLeftAlone() {
        let (window, panes, sidebar) = makeWindow()
        let list = NSOutlineView()
        sidebar.addSubview(list)
        #expect(PaneTreeController.keyHolder(list, in: window, panes: panes) == nil)
        #expect(PaneTreeController.keyHolder(nil, in: window, panes: panes) == nil)
    }

    @Test("A text field being edited is noted, not the window's field editor it holds")
    func aFieldBeingEditedIsNoted() throws {
        let (window, panes, _) = makeWindow()
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 22))
        panes.addSubview(field)
        window.makeFirstResponder(field)
        let editor = try #require(window.firstResponder as? NSTextView)
        try #require(editor.isFieldEditor)
        #expect(PaneTreeController.keyHolder(editor, in: window, panes: panes) === field)
    }

    @Test func theViewComesBackWhileItsStillShowing() {
        let (window, panes, _) = makeWindow()
        let terminal = NSTextView()
        panes.addSubview(terminal)
        let keys = PaneTreeController.keyHolder(terminal, in: window, panes: panes)
        // (What a rebuild does: out of the window, then back in a new split.)
        terminal.removeFromSuperview()
        let split = NSSplitView()
        split.addArrangedSubview(terminal)
        panes.addSubview(split)
        #expect(PaneTreeController.returningKeyView(keys, in: window, panes: panes) === terminal)
    }

    @Test("A view gone from the panes (its pane closed) or hidden there doesn't take them back")
    func aViewNoLongerShowingDoesntComeBack() {
        let (window, panes, _) = makeWindow()
        let closed = NSTextView()
        panes.addSubview(closed)
        let keys = PaneTreeController.keyHolder(closed, in: window, panes: panes)
        closed.removeFromSuperview()
        #expect(PaneTreeController.returningKeyView(keys, in: window, panes: panes) == nil)

        let hidden = NSView()
        let terminal = NSTextView()
        hidden.addSubview(terminal)
        panes.addSubview(hidden)
        hidden.isHidden = true
        #expect(PaneTreeController.returningKeyView(terminal, in: window, panes: panes) == nil)
    }

    @Test("Keys that went nowhere go to the focused pane, not back to the window")
    func keysThatWentNowhereDontComeBack() {
        let (window, panes, _) = makeWindow()
        #expect(PaneTreeController.returningKeyView(window, in: window, panes: panes) == nil)
    }
}
