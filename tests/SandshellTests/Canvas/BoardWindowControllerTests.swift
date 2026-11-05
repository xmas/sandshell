import AppKit
import Testing
@testable import Sandshell

/// A board in a window of its own (`BoardWindowController`): one per board,
/// titled by it, gone from the list once closed. Not made full screen here.
@MainActor
struct BoardWindowControllerTests {
    private func board(title: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sandshell-board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"title": "\#(title)", "artboards": [{"file": "a.html"}]}"#.utf8)
            .write(to: folder.appending(path: CanvasBoard.fileName))
        try Data("<h1>Hi</h1>".utf8).write(to: folder.appending(path: "a.html"))
        return folder
    }

    @Test func oneWindowPerBoardTitledByIt() throws {
        let folder = try board(title: "Onboarding")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = BoardWindowController.show(folder, fullScreen: false)
        defer { first.close() }
        #expect(first.window?.title == "Onboarding")
        #expect(first.debugCanvas.board?.artboards.map(\.id) == ["a.html"])
        let again = BoardWindowController.show(folder, fullScreen: false)
        #expect(again === first, "Opening it again brings that window forward")
        #expect(first.window?.collectionBehavior.contains(.fullScreenPrimary) == true)
    }

    @Test func closingForgetsIt() throws {
        let folder = try board(title: "Settings")
        defer { try? FileManager.default.removeItem(at: folder) }
        let shown = BoardWindowController.show(folder, fullScreen: false)
        shown.close()
        #expect(!BoardWindowController.windows.contains { $0 === shown })
        let fresh = BoardWindowController.show(folder, fullScreen: false)
        defer { fresh.close() }
        #expect(fresh !== shown)
    }
}
