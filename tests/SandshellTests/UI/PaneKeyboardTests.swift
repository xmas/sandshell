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
