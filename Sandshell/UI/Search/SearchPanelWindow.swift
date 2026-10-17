import AppKit

/// The Search window. Esc anywhere in it closes it (a focused text field
/// passes `cancelOperation:` up the responder chain to here).
final class SearchPanelWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
