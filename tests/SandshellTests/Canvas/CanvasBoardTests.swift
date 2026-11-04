import Foundation
import Testing
@testable import Sandshell

struct CanvasBoardTests {
    let folder = URL(filePath: "/work/.sandshell/canvas/onboarding", directoryHint: .isDirectory)

    func parse(_ json: String) throws -> CanvasBoard {
        try CanvasBoard.parse(Data(json.utf8), folder: folder).get()
    }

    @Test func readsTitleAndArtboards() throws {
        let board = try parse("""
            {"title": "Onboarding", "artboards": [
              {"id": "welcome", "title": "Welcome", "file": "welcome.html", "x": 0, "y": 0, "width": 390, "height": 844},
              {"id": "app", "url": "http://localhost:5173/", "width": 1280, "height": 800}]}
            """)
        #expect(board.title == "Onboarding")
        #expect(board.artboards.map(\.id) == ["welcome", "app"])
        #expect(board.artboards[1].url?.absoluteString == "http://localhost:5173/")
        #expect(board.artboards[1].title == "localhost", "a URL artboard is titled by its host")
    }

    @Test func fillsInWhatTheAgentLeftOut() throws {
        let board = try parse(#"{"artboards": [{"file": "a.html"}, {"file": "a.html"}]}"#)
        #expect(board.title == "onboarding", "titled by its folder")
        #expect(board.artboards.map(\.id) == ["a.html", "a.html-2"], "ids are unique")
        #expect(board.artboards[0].title == "a")
        #expect(board.artboards[0].width == CanvasBoard.defaultSize.width)
        #expect(board.artboards[0].height == CanvasBoard.defaultSize.height)
    }

    @Test(arguments: [#"{"id": "x"}"#, #"{"file": ""}"#, #"{"url": "no scheme"}"#])
    func skipsArtboardsWithNothingToShow(artboard: String) throws {
        let board = try parse(#"{"artboards": [\#(artboard), {"file": "ok.html"}]}"#)
        #expect(board.artboards.map(\.id) == ["ok.html"])
    }

    @Test(arguments: ["", "{", "[]", "\"board\""])
    func refusesWhatIsntABoard(json: String) {
        guard case .failure(.unreadable) = CanvasBoard.parse(Data(json.utf8), folder: folder) else {
            Issue.record("\(json) should be unreadable")
            return
        }
    }

    @Test func unplacedArtboardsFollowInARow() throws {
        let board = try parse("""
            {"artboards": [{"id": "a", "file": "a.html", "x": 0, "y": 0, "width": 100, "height": 100},
                           {"id": "b", "file": "b.html", "width": 200, "height": 50},
                           {"id": "c", "file": "c.html", "width": 50, "height": 50}]}
            """)
        let frames = board.frames()
        #expect(frames["a"] == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(frames["b"] == CGRect(x: 100 + CanvasBoard.gap, y: 0, width: 200, height: 50))
        #expect(frames["c"] == CGRect(x: 100 + CanvasBoard.gap + 200 + CanvasBoard.gap, y: 0, width: 50, height: 50))
    }

    @Test(arguments: [("welcome.html", true), ("pages/a.html", true), ("../../secret.txt", false), ("/etc/hosts", true)])
    func filesStayInsideTheBoard(file: String, allowed: Bool) throws {
        let board = try parse(#"{"artboards": [{"id": "x", "file": "\#(file)"}]}"#)
        let url = board.fileURL(of: board.artboards[0])
        #expect((url != nil) == allowed)
        if let url { #expect(url.path(percentEncoded: false).hasPrefix(folder.path(percentEncoded: false))) }
    }

    @Test func listsBoardFoldersWithABoardFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "canvas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let boards = CanvasBoard.boardsFolder(root: root)
        for name in ["zeta", "alpha", "not-a-board"] {
            try FileManager.default.createDirectory(at: boards.appending(path: name), withIntermediateDirectories: true)
        }
        for name in ["zeta", "alpha"] {
            try Data("{}".utf8).write(to: boards.appending(path: "\(name)/\(CanvasBoard.fileName)"))
        }
        #expect(CanvasBoard.list(root: root).map(\.lastPathComponent) == ["alpha", "zeta"])
        #expect(CanvasBoard.list(root: root.appending(path: "nowhere")).isEmpty)
    }
}
