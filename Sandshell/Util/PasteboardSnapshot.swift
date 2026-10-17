import AppKit

/// Borrowing the clipboard (a terminal's selection is read through its Copy)
/// and putting back what was there.
extension NSPasteboard {
    /// A copy of every item on the pasteboard, each with all its types' data —
    /// several copied files stay several items — to put back with `restore(_:)`.
    func snapshotItems() -> [NSPasteboardItem] {
        (pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Put back what `snapshotItems()` took (an empty snapshot leaves it empty).
    func restore(_ items: [NSPasteboardItem]) {
        clearContents()
        if !items.isEmpty { writeObjects(items) }
    }
}
