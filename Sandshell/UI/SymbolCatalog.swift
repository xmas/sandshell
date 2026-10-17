import AppKit

/// A broad set of SF Symbol names for the "See more…" picker. (The full
/// ~6000-symbol manifest ships only with the SF Symbols app; this is a wide,
/// searchable selection across categories — names that don't resolve on the
/// running OS are filtered out once, in `available`.)
enum SymbolCatalog {
    static let all: [String] = [
        // folders / files / boxes
        "folder", "folder.fill", "folder.badge.plus", "folder.badge.gearshape", "shippingbox", "shippingbox.fill",
        "cube", "cube.fill", "cube.transparent", "archivebox", "archivebox.fill", "tray", "tray.fill", "tray.full",
        "doc", "doc.fill", "doc.text", "doc.text.fill", "doc.on.doc", "doc.richtext", "note.text", "book", "book.fill",
        "books.vertical", "books.vertical.fill", "newspaper", "newspaper.fill", "text.book.closed",
        // dev / tools
        "hammer", "hammer.fill", "wrench", "wrench.fill", "wrench.and.screwdriver", "wrench.and.screwdriver.fill",
        "screwdriver", "screwdriver.fill", "gearshape", "gearshape.fill", "gearshape.2", "gearshape.2.fill",
        "terminal", "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces", "curlybraces.square",
        "command", "option", "cpu", "cpu.fill", "memorychip", "memorychip.fill", "ladybug", "ladybug.fill",
        // network / cloud / server
        "network", "globe", "globe.americas", "globe.americas.fill", "globe.europe.africa", "wifi", "antenna.radiowaves.left.and.right",
        "server.rack", "externaldrive", "externaldrive.fill", "internaldrive", "internaldrive.fill", "opticaldiscdrive",
        "cloud", "cloud.fill", "icloud", "icloud.fill", "link", "personalhotspot", "point.3.connected.trianglepath.dotted",
        // work / org
        "briefcase", "briefcase.fill", "case", "case.fill", "building.2", "building.2.fill", "building.columns",
        "person", "person.fill", "person.2", "person.2.fill", "person.3", "person.3.fill", "graduationcap", "graduationcap.fill",
        // creative
        "paintbrush", "paintbrush.fill", "paintbrush.pointed", "paintpalette", "paintpalette.fill", "pencil",
        "pencil.tip", "highlighter", "scribble", "lasso", "camera", "camera.fill", "photo", "photo.fill",
        "photo.on.rectangle", "theatermasks", "theatermasks.fill", "wand.and.stars", "wand.and.rays", "sparkles",
        // media
        "play", "play.fill", "play.circle", "pause", "pause.fill", "music.note", "music.note.list", "headphones",
        "mic", "mic.fill", "speaker.wave.2", "speaker.wave.2.fill", "waveform", "waveform.circle", "video", "video.fill",
        // data / charts
        "chart.bar", "chart.bar.fill", "chart.pie", "chart.pie.fill", "chart.line.uptrend.xyaxis", "chart.xyaxis.line",
        "list.bullet", "list.bullet.rectangle", "tablecells", "tablecells.fill", "square.grid.2x2", "square.grid.3x3",
        // status / misc
        "star", "star.fill", "heart", "heart.fill", "bolt", "bolt.fill", "flag", "flag.fill", "bell", "bell.fill",
        "bookmark", "bookmark.fill", "tag", "tag.fill", "pin", "pin.fill", "lock", "lock.fill", "key", "key.fill",
        "shield", "shield.fill", "checkmark.seal", "checkmark.seal.fill", "flame", "flame.fill", "leaf", "leaf.fill",
        "drop", "drop.fill", "sun.max", "sun.max.fill", "moon", "moon.fill", "moon.stars", "cloud.sun", "snowflake",
        "tortoise", "tortoise.fill", "hare", "hare.fill", "ant", "ant.fill", "fish", "fish.fill", "pawprint", "pawprint.fill",
        "cup.and.saucer", "cup.and.saucer.fill", "fork.knife", "takeoutbag.and.cup.and.straw", "gift", "gift.fill",
        "airplane", "car", "car.fill", "bicycle", "tram", "bus", "ferry", "fuelpump", "fuelpump.fill",
        "house", "house.fill", "map", "map.fill", "location", "location.fill", "mappin", "mappin.circle.fill",
        "rocket", "flask", "atom", "function", "sum", "percent", "number", "textformat", "character",
        "circle", "circle.fill", "square", "square.fill", "triangle", "triangle.fill", "diamond", "diamond.fill",
        "hexagon", "hexagon.fill", "seal", "seal.fill", "shippingbox.circle", "puzzlepiece", "puzzlepiece.fill",
        "gamecontroller", "gamecontroller.fill", "dice", "dice.fill", "crown", "crown.fill", "trophy", "trophy.fill",
    ]

    /// The names in `all` that resolve on the running OS, worked out once.
    static let available = all.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    /// The available names containing `query` (trimmed; case- and
    /// diacritic-insensitive), or all of them for a blank query.
    static func available(matching query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? available : available.filter { $0.localizedStandardContains(q) }
    }

    /// What VoiceOver reads (and Voice Control answers to) for a symbol in the
    /// picker: its name in words ("folder.badge.plus" → "folder badge plus").
    /// Not the system's own symbol description, which often names a use rather
    /// than the picture ("folder" reads "move", "star" reads "favorite").
    static func spokenName(_ symbol: String) -> String {
        symbol.replacing(".", with: " ")
    }
}
