import AppKit

/// A Canvas board: `.sandshell/canvas/<board>/board.json` and the artboards'
/// files beside it, written by the agent with its ordinary file tools (the
/// workspace folder is mounted into the sandbox). See docs/canvas.md.
struct CanvasBoard: Equatable, Sendable {
    /// One screen on the board: a page in the board folder, or a URL.
    struct Artboard: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        /// A file in the board folder (relative), or nil for a URL artboard.
        var file: String?
        var url: URL?
        /// Canvas points; nil = laid out in a row after the placed ones.
        var x: CGFloat?
        var y: CGFloat?
        var width: CGFloat
        var height: CGFloat
    }

    /// The board's folder (holds board.json).
    let folder: URL
    var title: String
    var artboards: [Artboard]

    static let fileName = "board.json"
    static let defaultSize = CGSize(width: 390, height: 844)
    /// Space between artboards laid out in a row, and between rows.
    static let gap: CGFloat = 80

    /// Where a workspace keeps its boards.
    static func boardsFolder(root: URL) -> URL {
        root.appending(path: ".sandshell/canvas", directoryHint: .isDirectory)
    }

    /// Make a new empty board, under the first free name (design, design-2, …).
    /// Its folder, and that relative to `root` (what a session keeps).
    static func create(root: URL) throws -> (folder: URL, relative: String) {
        let boards = boardsFolder(root: root)
        var name = "design"
        var n = 1
        while FileManager.default.fileExists(atPath: boards.appending(path: name).path(percentEncoded: false)) {
            n += 1
            name = "design-\(n)"
        }
        let folder = boards.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let title = n == 1 ? "Design" : "Design \(n)"
        try Data(#"{"title": "\#(title)", "artboards": []}"#.utf8).write(to: folder.appending(path: fileName))
        return (folder, ".sandshell/canvas/\(name)")
    }

    /// The board a path is in (`<root>/.sandshell/canvas/<board>/…`, the folder
    /// itself included), if that board has a board.json.
    static func folder(containing url: URL, root: URL) -> URL? {
        let base = boardsFolder(root: root).standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(prefix), let name = path.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        let folder = boardsFolder(root: root).appending(path: String(name), directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: folder.appending(path: fileName).path(percentEncoded: false)) ? folder : nil
    }

    /// The workspace's boards (folders with a board.json), by name.
    static func list(root: URL) -> [URL] {
        let dir = boardsFolder(root: root)
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: fileName).path(percentEncoded: false)) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Why a board couldn't be read.
    enum LoadError: Error, Equatable, LocalizedError {
        case missing, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .missing: "There's no board.json in this folder."
            case .unreadable(let why): "board.json couldn't be read: \(why)"
            }
        }
    }

    static func load(folder: URL) -> Result<CanvasBoard, LoadError> {
        let url = folder.appending(path: fileName)
        guard let data = try? Data(contentsOf: url) else { return .failure(.missing) }
        return parse(data, folder: folder)
    }

    /// board.json → a board. Lenient: an artboard without an id, file or url
    /// is skipped; sizes default to a phone's.
    static func parse(_ data: Data, folder: URL) -> Result<CanvasBoard, LoadError> {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            return .failure(.unreadable("it isn't valid JSON"))
        }
        guard let dict = object as? [String: Any] else { return .failure(.unreadable("it isn't a JSON object")) }
        let raw = dict["artboards"] as? [[String: Any]] ?? []
        var seen: Set<String> = []
        let artboards: [Artboard] = raw.enumerated().compactMap { i, a in
            let file = (a["file"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let url = (a["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == nil ? nil : $0 }
            guard file != nil || url != nil else { return nil }
            var id = (a["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? file ?? "artboard-\(i + 1)"
            while !seen.insert(id).inserted { id += "-\(i + 1)" }
            func number(_ key: String) -> CGFloat? { (a[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
            let title = (a["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? file.map { ($0 as NSString).deletingPathExtension } ?? url?.host() ?? id
            return Artboard(id: id, title: title, file: file, url: url, x: number("x"), y: number("y"),
                            width: max(number("width") ?? defaultSize.width, 40),
                            height: max(number("height") ?? defaultSize.height, 40))
        }
        let title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        return .success(CanvasBoard(folder: folder, title: title, artboards: artboards))
    }

    /// Each artboard's frame on the canvas: placed ones where they say,
    /// the rest in a row to the right of everything placed, top-aligned.
    func frames() -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        var right: CGFloat = 0
        for a in artboards {
            if let x = a.x, let y = a.y {
                out[a.id] = CGRect(x: x, y: y, width: a.width, height: a.height)
                right = max(right, x + a.width + Self.gap)
            }
        }
        for a in artboards where out[a.id] == nil {
            out[a.id] = CGRect(x: right, y: 0, width: a.width, height: a.height)
            right += a.width + Self.gap
        }
        return out
    }

    /// The local file an artboard shows, if it's a file artboard inside the
    /// board folder (a path that climbs out of it is refused).
    func fileURL(of artboard: Artboard) -> URL? {
        guard let file = artboard.file else { return nil }
        let url = folder.appending(path: file).standardizedFileURL
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let path = url.path(percentEncoded: false)
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/") ? url : nil
    }
}

/// A note left on an artboard, for the agent: what to change, and what it's
/// pointing at. See docs/canvas.md.
struct CanvasNote: Equatable, Sendable {
    /// The artboard's id in board.json.
    var artboard: String
    /// Where on the page, in its CSS pixels from the top left.
    var point: CGPoint
    /// A dragged-out region of the page, when it's about an area.
    var area: CGRect?
    /// The element under the point (around the area), from the page; nil if it couldn't say.
    var element: Element?
    var text: String

    /// A note's place on a screenshot or a page.
    struct Mark: Equatable {
        var number: Int
        var point: CGPoint
        var area: CGRect? = nil
    }

    struct Element: Equatable, Sendable, Decodable {
        var selector: String
        var text: String
    }

    /// The notes as one chat message.
    static func message(_ notes: [CanvasNote], board: CanvasBoard) -> String {
        let one = notes.count == 1
        let lines = notes.enumerated().map { i, note -> String in
            let artboard = board.artboards.first { $0.id == note.artboard }
            var place = "Artboard `\(note.artboard)`"
            if let file = artboard?.file { place += " (\(file))" }
            if let element = note.element {
                place += ", at `\(element.selector)`"
                if !element.text.isEmpty { place += " (“\(element.text)”)" }
            }
            place += note.position
            return (one ? "" : "\(i + 1). ") + place + ":\n" + note.text
        }
        return "Canvas \(one ? "note" : "notes") on “\(board.title)” (\(board.folder.path(percentEncoded: false))):\n\n"
            + lines.joined(separator: "\n\n")
    }

    /// Where on the page, in its CSS pixels.
    private var position: String {
        if let area {
            return ", area \(Int(area.width))×\(Int(area.height)) at (\(Int(area.minX)), \(Int(area.minY)))"
        }
        return ", point (\(Int(point.x)), \(Int(point.y)))"
    }

    /// Script that returns the element at (`x`, `y`) as JSON: `Element`, or
    /// null. With `area`: the smallest element around it, from its middle.
    static func elementScript(at point: CGPoint, area: CGRect? = nil) -> String {
        let box = area.map { "{ l: \($0.minX), t: \($0.minY), r: \($0.maxX), b: \($0.maxY) }" } ?? "null"
        return """
        (function (x, y) {
          var at = document.elementFromPoint(x, y);
          if (!at) return null;
          var area = \(box);
          if (area) {
            while (at.parentElement) {
              var r = at.getBoundingClientRect();
              if (r.left <= area.l && r.top <= area.t && r.right >= area.r && r.bottom >= area.b) break;
              at = at.parentElement;
            }
          }
          function step(e) {
            var s = e.tagName.toLowerCase();
            if (e.id) return s + '#' + CSS.escape(e.id);
            var names = Array.from(e.classList).slice(0, 2).map(CSS.escape);
            if (names.length) s += '.' + names.join('.');
            var parent = e.parentElement;
            if (parent) {
              var same = Array.from(parent.children).filter(function (k) { return k.tagName === e.tagName; });
              if (same.length > 1) s += ':nth-of-type(' + (same.indexOf(e) + 1) + ')';
            }
            return s;
          }
          var path = [];
          for (var e = at; e && e !== document.body && e !== document.documentElement; e = e.parentElement) {
            path.unshift(step(e));
            if (e.id) break;
          }
          return JSON.stringify({
            selector: path.join(' > ') || 'body',
            text: (at.innerText || at.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 120)
          });
        })(\(point.x), \(point.y))
        """
    }

    /// `image` as a PNG with numbered marks where the notes point.
    static func markedPNG(_ image: NSImage, marks: [Mark]) -> Data? {
        let marked = NSImage(size: image.size, flipped: true) { rect in
            image.draw(in: rect)
            for mark in marks {
                if let area = mark.area {
                    let outline = NSBezierPath(rect: area)
                    outline.lineWidth = 2
                    NSColor.systemRed.setStroke()
                    outline.stroke()
                }
                let center = mark.area.map { CGPoint(x: $0.minX, y: $0.minY) } ?? mark.point
                let circle = NSRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22)
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: circle).fill()
                let label = NSAttributedString(string: "\(mark.number)", attributes: [
                    .font: NSFont.mark(13, weight: .bold), .foregroundColor: NSColor.white])
                let size = label.size()
                label.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
            }
            return true
        }
        return marked.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }
}

