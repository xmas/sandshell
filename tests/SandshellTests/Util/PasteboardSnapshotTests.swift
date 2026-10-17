import AppKit
import Testing
@testable import Sandshell

/// A terminal's ⌘F (scrollback) and its selection's context menu borrow the
/// clipboard to read text, then put back what was there with
/// `NSPasteboard.snapshotItems()` / `restore(_:)`.
/// Each test uses a pasteboard of its own, never the person's clipboard.
struct PasteboardSnapshotTests {
    /// A private pasteboard for `body`, released afterwards.
    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: .init("SandshellTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try body(pasteboard)
    }

    /// Stand-in for the borrow: the terminal's copy replaces everything.
    private func borrow(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString("scrollback", forType: .string)
    }

    @Test func severalCopiedFilesComeBackAsSeveralItems() throws {
        try withPasteboard { pasteboard in
            let files = ["/tmp/a.txt", "/tmp/b.png", "/tmp/c d.md"].map { URL(fileURLWithPath: $0) }
            let items = files.map { url in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                item.setString(url.lastPathComponent, forType: .string)
                return item
            }
            pasteboard.writeObjects(items)

            let saved = pasteboard.snapshotItems()
            borrow(pasteboard)
            pasteboard.restore(saved)

            let restored = try #require(pasteboard.pasteboardItems)
            #expect(restored.map { $0.string(forType: .fileURL) } == files.map(\.absoluteString))
            #expect(restored.map { $0.string(forType: .string) } == files.map(\.lastPathComponent),
                    "and the borrowed text is gone")
        }
    }

    @Test func everyTypeOfAnItemComesBack() throws {
        try withPasteboard { pasteboard in
            let custom = NSPasteboard.PasteboardType("com.xmas.sandshell.tests.custom")
            let bytes = Data([0, 1, 2, 254, 255])
            let item = NSPasteboardItem()
            item.setString("hello", forType: .string)
            item.setString("<b>hello</b>", forType: .html)
            item.setData(bytes, forType: custom)
            pasteboard.writeObjects([item])

            let saved = pasteboard.snapshotItems()
            borrow(pasteboard)
            pasteboard.restore(saved)

            let restored = try #require(pasteboard.pasteboardItems?.first)
            #expect(pasteboard.pasteboardItems?.count == 1)
            #expect(restored.string(forType: .string) == "hello")
            #expect(restored.string(forType: .html) == "<b>hello</b>")
            #expect(restored.data(forType: custom) == bytes)
        }
    }

    @Test(.tags(.edgeCase)) func anEmptyClipboardStaysEmpty() {
        withPasteboard { pasteboard in
            let saved = pasteboard.snapshotItems()
            #expect(saved.isEmpty)
            borrow(pasteboard)
            pasteboard.restore(saved)
            #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
            #expect(pasteboard.string(forType: .string) == nil, "the borrowed text doesn't stay behind")
        }
    }
}
