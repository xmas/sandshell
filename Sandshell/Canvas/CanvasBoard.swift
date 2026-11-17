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
        /// Its page and design (ids), and its name in the design: the
        /// screen's title, or a one-screen design's own.
        var page = ""
        var design = ""
        var name = ""
        /// Its label: "A6" (a design's sixth screen), "A" (a one-screen
        /// design); nil: none (a board made before pages).
        var code: String?
    }

    /// One question on the board: the designs that answer it. The canvas
    /// shows a page at a time.
    struct Page: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        /// The question in a sentence, or what was chosen.
        var note: String?
        var designs: [Design]
        /// Its artboards' ids, design by design: the order to step through.
        var screens: [String] { designs.flatMap(\.screens) }
    }

    /// One answer on a page (an option, A, B…): one screen, or several (its
    /// states or steps, A1, A2…), in a row.
    struct Design: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        /// "A", "B", "0", "G + H"; nil: none.
        var label: String?
        /// Its artboards' ids, in order.
        var screens: [String]
    }

    /// The board's folder (holds board.json).
    let folder: URL
    var title: String
    /// Every screen on the board, page by page, design by design.
    var artboards: [Artboard]
    var pages: [Page]

    /// A board from its artboards alone (board.json without pages): they're
    /// sorted into pages by their titles (`organize`).
    init(folder: URL, title: String, artboards: [Artboard]) {
        self.folder = folder
        self.title = title
        (self.artboards, self.pages) = Self.organize(artboards, boardTitle: title)
    }

    init(folder: URL, title: String, artboards: [Artboard], pages: [Page]) {
        self.folder = folder
        self.title = title
        self.artboards = artboards
        self.pages = pages
    }

    func artboard(_ id: String) -> Artboard? { artboards.first { $0.id == id } }
    func page(_ id: String) -> Page? { pages.first { $0.id == id } }
    /// The page an artboard is on.
    func page(of artboardID: String) -> Page? { artboard(artboardID).flatMap { page($0.page) } }

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
        try Data(#"{"title": "\#(title)", "pages": []}"#.utf8).write(to: folder.appending(path: fileName))
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

    /// An artboard a chat's turn wrote, for the transcript's artboard strip.
    struct Written: Codable, Equatable, Sendable {
        /// Its board's folder name (`.sandshell/canvas/<board>`).
        let board: String
        let boardTitle: String
        let id: String
        let title: String
        /// Its page, relative to the board's folder.
        let file: String
        let width: Double
        let height: Double
    }

    /// The artboards that `paths` (files a turn wrote) are, on the board in
    /// `folder` only, in the order written, each once; files that aren't one
    /// of its artboards' pages are left out.
    static func written(_ paths: [String], on folder: URL) -> [Written] {
        guard case .success(let board) = load(folder: folder) else { return [] }
        var out: [Written] = []
        for path in paths {
            let url = URL(filePath: path).standardizedFileURL
            guard let artboard = board.artboards.first(where: { board.fileURL(of: $0)?.standardizedFileURL == url }),
                  let file = artboard.file, !out.contains(where: { $0.id == artboard.id }) else { continue }
            out.append(Written(board: folder.lastPathComponent, boardTitle: board.title, id: artboard.id,
                               title: artboard.title, file: file, width: artboard.width, height: artboard.height))
        }
        return out
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
        // The agent writes it (a link, a FIFO or a huge file isn't read: it hung the window).
        guard let data = SandboxFile.read(url, limit: 4 * 1024 * 1024) else { return .failure(.missing) }
        return parse(data, folder: folder)
    }

    /// board.json → a board. Lenient: an artboard without an id, file or url
    /// is skipped; sizes default to a phone's. `pages` (pages › designs ›
    /// screens) if it has them; else `artboards`, sorted into pages by title.
    static func parse(_ data: Data, folder: URL) -> Result<CanvasBoard, LoadError> {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            return .failure(.unreadable("it isn't valid JSON"))
        }
        guard let dict = object as? [String: Any] else { return .failure(.unreadable("it isn't a JSON object")) }
        let title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        var seen: Set<String> = []
        if let rawPages = dict["pages"] as? [[String: Any]] {
            let (artboards, pages) = parsePages(rawPages, seen: &seen)
            return .success(CanvasBoard(folder: folder, title: title, artboards: artboards, pages: pages))
        }
        let raw = dict["artboards"] as? [[String: Any]] ?? []
        let artboards = raw.enumerated().compactMap { i, a in artboard(a, fallbackID: "artboard-\(i + 1)", seen: &seen) }
        return .success(CanvasBoard(folder: folder, title: title, artboards: artboards))
    }

    private static func text(_ dict: [String: Any], _ key: String) -> String? {
        (dict[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One artboard's entry (a flat board's, or a screen's), or nil if it has
    /// nothing to show; `size` is what it inherits (its design's).
    private static func artboard(_ a: [String: Any], fallbackID: String, size: CGSize? = nil,
                                 seen: inout Set<String>) -> Artboard? {
        let file = text(a, "file")
        let url = text(a, "url").flatMap(URL.init(string:)).flatMap { $0.scheme == nil ? nil : $0 }
        guard file != nil || url != nil else { return nil }
        var id = text(a, "id") ?? file ?? fallbackID
        var n = 2
        let base = id
        while !seen.insert(id).inserted { id = "\(base)-\(n)"; n += 1 }
        func number(_ key: String) -> CGFloat? { (a[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        let title = text(a, "title") ?? file.map { ($0 as NSString).deletingPathExtension } ?? url?.host() ?? id
        return Artboard(id: id, title: title, file: file, url: url, x: number("x"), y: number("y"),
                        width: max(number("width") ?? size?.width ?? defaultSize.width, 40),
                        height: max(number("height") ?? size?.height ?? defaultSize.height, 40))
    }

    /// A design's default label: A, B … Z, then 27, 28 …
    static func letter(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "\(index + 1)"
    }

    /// `pages` → the artboards (every screen, in order) and the pages they're on.
    private static func parsePages(_ raw: [[String: Any]], seen: inout Set<String>) -> ([Artboard], [Page]) {
        var artboards: [Artboard] = []
        var pages: [Page] = []
        var pageIDs: Set<String> = []
        for (p, rawPage) in raw.enumerated() {
            let pageTitle = text(rawPage, "title") ?? "Page \(p + 1)"
            var pageID = text(rawPage, "id") ?? "page-\(p + 1)"
            while !pageIDs.insert(pageID).inserted { pageID += "-\(p + 1)" }
            var designs: [Design] = []
            for rawDesign in rawPage["designs"] as? [[String: Any]] ?? [] {
                let label = text(rawDesign, "label") ?? letter(designs.count)
                let designID = text(rawDesign, "id") ?? "\(pageID)-\(label.lowercased())"
                let designTitle = text(rawDesign, "title") ?? "Design \(label)"
                func number(_ key: String) -> CGFloat? { (rawDesign[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
                let size = CGSize(width: number("width") ?? defaultSize.width, height: number("height") ?? defaultSize.height)
                // Its screens, or (a design of one) the design itself.
                let rawScreens = rawDesign["screens"] as? [[String: Any]] ?? [rawDesign]
                var screens: [Artboard] = rawScreens.enumerated().compactMap { s, rawScreen in
                    artboard(rawScreen, fallbackID: "\(designID)\(s + 1)", size: size, seen: &seen)
                }
                guard !screens.isEmpty else { continue }
                let single = rawDesign["screens"] == nil
                for i in screens.indices {
                    screens[i].page = pageID
                    screens[i].design = designID
                    screens[i].name = single ? designTitle : screens[i].title
                    screens[i].code = single ? label : "\(label)\(i + 1)"
                    screens[i].title = single ? "\(label) · \(designTitle)" : "\(label)\(i + 1) · \(designTitle) · \(screens[i].name)"
                }
                designs.append(Design(id: designID, title: designTitle, label: label, screens: screens.map(\.id)))
                artboards += screens
            }
            pages.append(Page(id: pageID, title: pageTitle, note: text(rawPage, "note"), designs: designs))
        }
        return (artboards, pages)
    }

    /// A board made before pages, sorted into them by its titles: "Page ·
    /// Design · Screen". The first part is the page (an artboard with no
    /// " · " joins the next one's, as a topic's heading does); artboards that
    /// share the second part are one design's screens, named by the rest.
    /// A board with no " · " in any title is one page of designs.
    static func organize(_ flat: [Artboard], boardTitle: String) -> ([Artboard], [Page]) {
        guard !flat.isEmpty else { return ([], []) }
        let parts = flat.map { $0.title.components(separatedBy: " · ") }
        // "B · Bolder hero" leads with its option's label, not a page.
        var pageKeys: [String?] = parts.map { $0.count >= 2 && !isLabel($0[0]) ? $0[0] : nil }
        if pageKeys.allSatisfy({ $0 == nil }) {
            pageKeys = flat.map { _ in boardTitle }
        } else {
            // A title with no page joins the next page (a heading), else the last.
            var next: String?
            for i in pageKeys.indices.reversed() {
                if let key = pageKeys[i] { next = key } else { pageKeys[i] = next }
            }
            var last: String?
            for i in pageKeys.indices { if let key = pageKeys[i] { last = key } else { pageKeys[i] = last } }
        }
        var order: [String] = []
        var members: [String: [Int]] = [:]
        for (i, key) in pageKeys.enumerated() {
            let key = key ?? boardTitle
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(i)
        }
        var artboards: [Artboard] = []
        var pages: [Page] = []
        var pageIDs: Set<String> = []
        for key in order {
            var pageID = slug(key)
            var n = 2
            while !pageIDs.insert(pageID).inserted { pageID = "\(slug(key))-\(n)"; n += 1 }
            // Designs by the second part, in order of first appearance.
            var designKeys: [String] = []
            var designMembers: [String: [Int]] = [:]
            for i in members[key] ?? [] {
                let p = parts[i]
                let designKey = p.count >= 2 ? p[1] : flat[i].title
                if designMembers[designKey] == nil { designKeys.append(designKey) }
                designMembers[designKey, default: []].append(i)
            }
            var designs: [Design] = []
            for (d, designKey) in designKeys.enumerated() {
                let indices = designMembers[designKey] ?? []
                let designID = "\(pageID)-\(d + 1)"
                let single = indices.count == 1
                var ids: [String] = []
                for i in indices {
                    var a = flat[i]
                    let p = parts[i]
                    a.page = pageID
                    a.design = designID
                    a.name = single
                        ? (p.count >= 2 && p[0] == key ? p.dropFirst().joined(separator: " · ") : a.title)
                        : p.dropFirst(2).joined(separator: " · ")
                    if a.name.isEmpty { a.name = a.title }
                    artboards.append(a)
                    ids.append(a.id)
                }
                let title = single ? (artboards.last?.name ?? designKey) : designKey
                designs.append(Design(id: designID, title: title, label: nil, screens: ids))
            }
            pages.append(Page(id: pageID, title: key, designs: designs))
        }
        return (artboards, pages)
    }

    /// An option's label, as a title's first part: "B", "12", "A2", "0", "Now", "G + H".
    static func isLabel(_ part: String) -> Bool {
        let p = part.replacingOccurrences(of: "✓", with: "").trimmingCharacters(in: .whitespaces)
        return p == "Now" || p.wholeMatch(of: /[A-Z]{1,2}[0-9]{0,2}|[0-9]{1,3}|[A-Z0-9]{1,3}( ?\+ ?[A-Z0-9]{1,3})+/) != nil
    }

    /// A page's id from its title: "Workstreams across the app" → "workstreams-across-the-app".
    static func slug(_ title: String) -> String {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "page" : words.joined(separator: "-")
    }

    /// Each artboard's frame on the canvas: placed ones where they say,
    /// the rest in a row to the right of everything placed, top-aligned.
    func frames() -> [String: CGRect] { Self.frames(artboards) }

    /// Where a page's artboards go, and the headings over its designs.
    struct PageLayout: Equatable {
        var frames: [String: CGRect]
        var headings: [Heading]
        /// A design of several screens: its row's top (its screens' titles
        /// and the heading go above it).
        struct Heading: Equatable {
            var design: String
            var top: CGFloat
        }
    }

    /// A page laid out: a design of several screens is a row of its own under
    /// a heading, its screens left to right; designs of one screen share a row
    /// between them. A page whose artboards say where they go (`x`/`y`, a
    /// board made before pages) keeps them where they are.
    func layout(page id: String) -> PageLayout {
        guard let page = page(id) else { return PageLayout(frames: [:], headings: []) }
        let members = page.screens.compactMap(artboard)
        if members.contains(where: { $0.x != nil && $0.y != nil }) {
            return PageLayout(frames: Self.frames(members), headings: [])
        }
        var frames: [String: CGRect] = [:]
        var headings: [PageLayout.Heading] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        func endRow() {
            if rowHeight > 0 { y += rowHeight + Self.gap }
            x = 0
            rowHeight = 0
        }
        func place(_ a: Artboard) {
            frames[a.id] = CGRect(x: x, y: y, width: a.width, height: a.height)
            x += a.width + Self.gap
            rowHeight = max(rowHeight, a.height)
        }
        for design in page.designs {
            let screens = design.screens.compactMap(artboard)
            if screens.count > 1 {
                endRow()
                y += Self.headingHeight
                headings.append(.init(design: design.id, top: y))
                screens.forEach(place)
                endRow()
            } else if let one = screens.first {
                // A long row of them wraps, so a page of options stays a block.
                if x > 0, x + one.width > Self.rowWidth { endRow() }
                place(one)
            }
        }
        return PageLayout(frames: frames, headings: headings)
    }

    /// How wide a row of one-screen designs gets before it wraps: four desktop screens.
    static let rowWidth: CGFloat = 4 * 1440 + 3 * gap

    /// A design's heading, over its screens' titles.
    static let headingHeight: CGFloat = 34

    static func frames(_ artboards: [Artboard]) -> [String: CGRect] {
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

