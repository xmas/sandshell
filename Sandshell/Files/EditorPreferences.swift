import AppKit
import Combine

/// Settings ▸ Editor: how the Files editor shows and edits text. One set for
/// the app (every folder's editor), kept in user defaults as one value.
struct EditorPreferences: Codable, Equatable {
    var fontSize: Double = 12.5
    var wrapsLines = true
    var showsLineNumbers = true
    var showsChangeBars = true
    var highlightsCurrentLine = true
    var colorsSyntax = true
    var showsPageGuide = false
    var pageGuideColumn = 80
    var tabWidth = 4
    var indentsWithSpaces = true
    var autoIndents = true
    var trimsTrailingWhitespace = false
    var endsWithNewline = false

    static let fontSizes: ClosedRange<Double> = 9...24
    static let tabWidths = [2, 4, 8]
    static let pageGuideColumns = [72, 80, 100, 120]

    init() {}

    /// A setting a future version dropped or an older one never had keeps its
    /// default, so the rest still load.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditorPreferences()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        fontSize = min(max(value(.fontSize, d.fontSize), Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        wrapsLines = value(.wrapsLines, d.wrapsLines)
        showsLineNumbers = value(.showsLineNumbers, d.showsLineNumbers)
        showsChangeBars = value(.showsChangeBars, d.showsChangeBars)
        highlightsCurrentLine = value(.highlightsCurrentLine, d.highlightsCurrentLine)
        colorsSyntax = value(.colorsSyntax, d.colorsSyntax)
        showsPageGuide = value(.showsPageGuide, d.showsPageGuide)
        pageGuideColumn = max(value(.pageGuideColumn, d.pageGuideColumn), 1)
        tabWidth = min(max(value(.tabWidth, d.tabWidth), 1), 16)
        indentsWithSpaces = value(.indentsWithSpaces, d.indentsWithSpaces)
        autoIndents = value(.autoIndents, d.autoIndents)
        trimsTrailingWhitespace = value(.trimsTrailingWhitespace, d.trimsTrailingWhitespace)
        endsWithNewline = value(.endsWithNewline, d.endsWithNewline)
    }

    /// What Tab inserts at `column` (0-based, tabs counted to their stop):
    /// spaces to the next tab stop, or a tab.
    func indent(atColumn column: Int) -> String {
        indentsWithSpaces ? String(repeating: " ", count: tabWidth - column % tabWidth) : "\t"
    }

    /// The column `offset` is at in `line` (tabs expanded to their stops).
    func column(of offset: Int, in line: String) -> Int {
        var column = 0
        for c in line.utf16.prefix(offset) {
            column = c == 0x09 ? (column / tabWidth + 1) * tabWidth : column + 1
        }
        return column
    }

    /// What saving changes in `text` (UTF-16 ranges → replacements, last
    /// first so each applies as given): trailing spaces and tabs cut from
    /// every line but the one holding `caret`, and a final line break added.
    func saveEdits(in text: NSString, caret: Int? = nil) -> [(range: NSRange, replacement: String)] {
        var edits: [(NSRange, String)] = []
        if endsWithNewline, text.length > 0,
           let last = UnicodeScalar(text.character(at: text.length - 1)),
           !CharacterSet.newlines.contains(last) {
            edits.append((NSRange(location: text.length, length: 0), "\n"))
        }
        guard trimsTrailingWhitespace else { return edits }
        var trims: [(NSRange, String)] = []
        var location = 0
        while location < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            var cut = contentsEnd
            while cut > start, [0x20, 0x09].contains(text.character(at: cut - 1)) { cut -= 1 }
            let holdsCaret = caret.map { $0 >= start && $0 <= contentsEnd } ?? false
            if cut < contentsEnd, !holdsCaret { trims.append((NSRange(location: cut, length: contentsEnd - cut), "")) }
            guard end > location else { break }
            location = end
        }
        return edits + trims.reversed()
    }

    /// `text` as saving leaves it (no caret to spare).
    func tidied(_ text: String) -> String {
        let out = NSMutableString(string: text)
        for edit in saveEdits(in: out) { out.replaceCharacters(in: edit.range, with: edit.replacement) }
        return out as String
    }
}

/// The app's editor preferences, saved as they change; the Files editors
/// follow them live.
@MainActor
final class EditorSettings: ObservableObject {
    static let shared = EditorSettings()
    static let key = "editorPreferences"

    @Published var prefs: EditorPreferences {
        didSet { if prefs != oldValue { save() } }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefs = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(EditorPreferences.self, from: $0) } ?? EditorPreferences()
    }

    func reset() { prefs = EditorPreferences() }

    private func save() {
        if let data = try? JSONEncoder().encode(prefs) { defaults.set(data, forKey: Self.key) }
    }
}
