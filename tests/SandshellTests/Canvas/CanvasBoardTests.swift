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

    @Test func pagesHoldDesignsAndDesignsHoldScreens() throws {
        let board = try parse("""
            {"title": "Agate", "pages": [
              {"id": "connections", "title": "Connections", "note": "Ways in", "designs": [
                {"title": "A connection picked", "width": 1280, "height": 800, "screens": [
                  {"id": "a1", "title": "Nothing picked", "file": "a1.html"},
                  {"id": "a2", "title": "GitHub", "file": "a2.html", "height": 600}]},
                {"label": "0", "title": "Today", "file": "now.html"}]},
              {"title": "People", "designs": [{"title": "Who is who", "file": "p.html"}]}]}
            """)
        #expect(board.pages.map(\.title) == ["Connections", "People"])
        #expect(board.pages[0].note == "Ways in")
        #expect(board.pages[1].id == "page-2", "an id when it has none")
        #expect(board.artboards.map(\.id) == ["a1", "a2", "now.html", "p.html"], "every screen, page by page")
        let a2 = try #require(board.artboard("a2"))
        #expect(a2.code == "A2" && a2.name == "GitHub" && a2.page == "connections")
        #expect(a2.width == 1280 && a2.height == 600, "the design's size, unless the screen says")
        #expect(board.pages[0].designs.map(\.label) == ["A", "0"], "lettered in order, unless it says")
        #expect(board.artboard("now.html")?.code == "0", "a design of one screen is its own")
        #expect(board.page(of: "p.html")?.title == "People")
    }

    @Test func aBoardMadeBeforePagesIsSortedIntoPagesByItsTitles() throws {
        let board = try parse("""
            {"artboards": [
              {"id": "topic", "title": "Connections flows", "file": "t.html"},
              {"id": "c1", "title": "Connections 1 · a connection picked · nothing picked", "file": "c1.html"},
              {"id": "c2", "title": "Connections 1 · a connection picked · GitHub", "file": "c2.html"},
              {"id": "s9", "title": "Strip · 9 · One strip across the pair", "file": "s9.html"},
              {"id": "s10", "title": "Strip · 10 · Quietest", "file": "s10.html"}]}
            """)
        #expect(board.pages.map(\.title) == ["Connections 1", "Strip"])
        #expect(board.pages[0].designs.map(\.title) == ["Connections flows", "a connection picked"],
                "a heading joins the page after it")
        #expect(board.pages[0].designs[1].screens == ["c1", "c2"])
        #expect(board.artboard("c2")?.name == "GitHub")
        #expect(board.pages[1].designs.map(\.title) == ["9 · One strip across the pair", "10 · Quietest"])
        #expect(board.pages.flatMap(\.designs).allSatisfy { $0.label == nil }, "no letters it didn't have")
    }

    @Test(arguments: [["Welcome", "Welcome — bolder"], ["A · Bolder hero", "B · Quiet hero", "G + H · Both"]])
    func titlesWithoutPagesAreOnePage(titles: [String]) throws {
        let entries = titles.enumerated().map { #"{"id": "x\#($0.offset)", "title": "\#($0.element)", "file": "x.html"}"# }
        let board = try parse(#"{"title": "Onboarding", "artboards": [\#(entries.joined(separator: ","))]}"#)
        #expect(board.pages.count == 1)
        #expect(board.pages[0].title == "Onboarding")
        #expect(board.pages[0].designs.count == titles.count, "each its own design")
    }

    @Test func aPageLaysOutADesignOfSeveralScreensAsARowUnderItsHeading() throws {
        let board = try parse("""
            {"pages": [{"id": "p", "title": "P", "designs": [
              {"title": "One", "file": "o.html", "width": 100, "height": 100},
              {"title": "Two", "file": "t.html", "width": 100, "height": 200},
              {"title": "Flow", "width": 100, "height": 50, "screens": [{"id": "f1", "file": "f1.html"}, {"id": "f2", "file": "f2.html"}]}]}]}
            """)
        let layout = board.layout(page: "p")
        let gap = CanvasBoard.gap
        #expect(layout.frames["o.html"] == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(layout.frames["t.html"] == CGRect(x: 100 + gap, y: 0, width: 100, height: 200), "one-screen designs share a row")
        let top = 200 + gap + CanvasBoard.headingHeight
        #expect(layout.headings == [.init(design: "p-c", top: top)])
        #expect(layout.frames["f1"] == CGRect(x: 0, y: top, width: 100, height: 50))
        #expect(layout.frames["f2"] == CGRect(x: 100 + gap, y: top, width: 100, height: 50))
    }

    @Test func aLongRowOfOptionsWraps() throws {
        let designs = (1...6).map { #"{"title": "Option \#($0)", "file": "o\#($0).html", "width": 1440, "height": 900}"# }
        let board = try parse(#"{"pages": [{"id": "p", "title": "P", "designs": [\#(designs.joined(separator: ","))]}]}"#)
        let frames = board.layout(page: "p").frames
        #expect(frames["o4.html"]?.minY == 0, "four desktop screens to a row")
        #expect(frames["o5.html"] == CGRect(x: 0, y: 900 + CanvasBoard.gap, width: 1440, height: 900))
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

struct CanvasBoardLinkTests {
    @Test func aPathInABoardNamesItsBoard() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "canvas-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let board = CanvasBoard.boardsFolder(root: root).appending(path: "onboarding")
        try FileManager.default.createDirectory(at: board, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: board.appending(path: CanvasBoard.fileName))
        for path in ["board.json", "welcome.html", "img/logo.svg", ""] {
            let found = CanvasBoard.folder(containing: board.appending(path: path), root: root)
            #expect(found?.lastPathComponent == "onboarding", "\(path)")
        }
        #expect(CanvasBoard.folder(containing: root.appending(path: "README.md"), root: root) == nil)
        #expect(CanvasBoard.folder(containing: CanvasBoard.boardsFolder(root: root).appending(path: "missing/a.html"), root: root) == nil,
                "a folder without board.json isn't a board")
    }

    /// Files a turn wrote → the artboards on the chat's own board, in the
    /// order written, once each; anything else is left out.
    @Test func whatATurnWroteOnItsBoard() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "canvas-written-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let board = CanvasBoard.boardsFolder(root: root).appending(path: "design-5")
        try FileManager.default.createDirectory(at: board, withIntermediateDirectories: true)
        try Data("""
            {"title": "Designer", "artboards": [
              {"id": "a", "title": "Door", "file": "a.html", "width": 1280, "height": 760},
              {"id": "b", "title": "Strip", "file": "b.html", "width": 390, "height": 844},
              {"id": "app", "url": "http://localhost:5173/"}]}
            """.utf8).write(to: board.appending(path: CanvasBoard.fileName))
        let path = { (name: String) in board.appending(path: name).path(percentEncoded: false) }
        let other = CanvasBoard.boardsFolder(root: root).appending(path: "other/a.html").path(percentEncoded: false)
        let written = CanvasBoard.written([path("b.html"), path("kit.css"), path("a.html"), path("b.html"), other], on: board)
        #expect(written.map(\.id) == ["b", "a"])
        #expect(written.first == CanvasBoard.Written(board: "design-5", boardTitle: "Designer", id: "b", title: "Strip",
                                                      file: "b.html", width: 390, height: 844))
        #expect(CanvasBoard.written([path("a.html")], on: root).isEmpty, "not a board")
    }
}
