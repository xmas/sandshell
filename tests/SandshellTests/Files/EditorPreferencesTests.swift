import AppKit
import Testing
@testable import Sandshell

/// Settings ▸ Editor (`EditorPreferences`, `EditorSettings`): what Tab
/// inserts, what saving tidies, and that the settings keep.
struct EditorPreferencesTests {
    @Test(arguments: [
        // (spaces?, width, column, inserted)
        (true, 4, 0, "    "),
        (true, 4, 1, "   "),
        (true, 4, 4, "    "),
        (true, 2, 3, " "),
        (false, 4, 2, "\t"),
    ])
    func tabGoesToTheNextStop(spaces: Bool, width: Int, column: Int, inserted: String) {
        var prefs = EditorPreferences()
        prefs.indentsWithSpaces = spaces
        prefs.tabWidth = width
        #expect(prefs.indent(atColumn: column) == inserted)
    }

    @Test func aTabCountsToItsStop() {
        var prefs = EditorPreferences()
        prefs.tabWidth = 4
        #expect(prefs.column(of: 3, in: "\tab") == 6)
        #expect(prefs.column(of: 3, in: "ab\t") == 4)
    }

    @Test func savingTrimsTrailingSpacesButNotOnTheCaretsLine() {
        var prefs = EditorPreferences()
        prefs.trimsTrailingWhitespace = true
        let text = "one  \ntwo\t\nthree   \n" as NSString
        let caret = text.range(of: "three").location + 5
        let out = NSMutableString(string: text)
        for edit in prefs.saveEdits(in: text, caret: caret) { out.replaceCharacters(in: edit.range, with: edit.replacement) }
        #expect(out as String == "one\ntwo\nthree   \n", "You're still typing on that line")
        #expect(prefs.tidied(text as String) == "one\ntwo\nthree\n")
    }

    @Test(arguments: [("a\nb", "a\nb\n"), ("a\n", "a\n"), ("", ""), ("a\r\n", "a\r\n")])
    func savingEndsWithALineBreak(text: String, saved: String) {
        var prefs = EditorPreferences()
        prefs.endsWithNewline = true
        #expect(prefs.tidied(text) == saved)
    }

    @Test func savingChangesNothingByDefault() {
        #expect(EditorPreferences().tidied("a  \nb") == "a  \nb")
    }

    /// A setting another version doesn't know keeps its default, and the rest load.
    @Test func partialOrOddSettingsStillLoad() throws {
        let json = #"{"fontSize": 99, "wrapsLines": false, "tabWidth": "wide", "somethingNew": 1}"#
        let prefs = try JSONDecoder().decode(EditorPreferences.self, from: Data(json.utf8))
        #expect(prefs.fontSize == EditorPreferences.fontSizes.upperBound)
        #expect(prefs.wrapsLines == false)
        #expect(prefs.tabWidth == 4)
        #expect(prefs.highlightsCurrentLine)
    }

    @MainActor @Test func settingsKeep() throws {
        let suite = "SandshellEditorPrefsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorSettings(defaults: defaults)
        #expect(settings.prefs == EditorPreferences())
        settings.prefs.highlightsCurrentLine = false
        settings.prefs.tabWidth = 2
        let again = EditorSettings(defaults: defaults)
        #expect(again.prefs.highlightsCurrentLine == false)
        #expect(again.prefs.tabWidth == 2)
        again.reset()
        #expect(EditorSettings(defaults: defaults).prefs == EditorPreferences())
    }
}

/// Re-coloring the editor without moving its text (`EditorRecolor`,
/// `NSTextView.keepingTopLine`).
@MainActor
struct EditorRecolorTests {
    private static func colored(_ s: String, pink: Set<Character>) -> NSAttributedString {
        let out = NSMutableAttributedString(string: s, attributes: [.foregroundColor: NSColor.labelColor])
        for (i, c) in (s as NSString as String).utf16.enumerated() where pink.contains(Character(UnicodeScalar(c)!)) {
            out.addAttribute(.foregroundColor, value: NSColor.systemPink, range: NSRange(location: i, length: 1))
        }
        return out
    }

    @Test func onlyWhatChangedIsTouched() {
        let before = Self.colored("let x = 1", pink: ["1"])
        #expect(EditorRecolor.changedRuns(from: before, in: before).isEmpty)
        let after = Self.colored("let x = 1", pink: ["1", "x"])
        #expect(EditorRecolor.changedRuns(from: after, in: before)
                == [.init(range: NSRange(location: 4, length: 1), color: .systemPink)])
    }

    @Test func aDifferentLengthRecolorsEverything() {
        let runs = EditorRecolor.changedRuns(from: Self.colored("ab", pink: []), in: Self.colored("abc", pink: []))
        #expect(runs.map(\.range) == [NSRange(location: 0, length: 2)])
    }

    /// The bug: a long file of wrapped lines, scrolled far down, and the
    /// whole buffer recolored (every keystroke did it) — TextKit 2 re-estimated
    /// the document and the text on screen jumped by dozens of lines.
    @Test func recoloringEverythingKeepsTheTopLine() throws {
        let text = (0..<2700).map { i in
            switch i % 7 {
            case 0: "    // comment \(i) that is fairly long and keeps going so that it wraps in a narrow editor column, more words here"
            case 1: "func f\(i)(ctx context.Context, serverName string, params *mcpsdk.CallToolParams) (*mcpsdk.CallToolResult, error) {"
            case 2: ""
            case 3: "        p.logger.Info(\"retrying tool call after initial authentication failure with fresh remote client\", \"server\", serverName)"
            default: "    x := \(i)"
            }
        }.joined(separator: "\n")
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 760, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(usingTextLayoutManager: true)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        window.contentView!.addSubview(scroll)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        /// A display cycle: TextKit 2 lays out the viewport and re-estimates there.
        func settle() {
            tv.layoutSubtreeIfNeeded()
            tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        tv.string = text
        let storage = try #require(tv.textStorage)
        EditorRecolor.apply(Self.colored(text, pink: ["1"]), to: storage)
        settle()
        for _ in 0..<80 { tv.scroll(NSPoint(x: 0, y: tv.visibleRect.minY + 700)); settle() }

        func topLine() -> Int {
            let i = tv.characterIndexForInsertion(at: NSPoint(x: 20, y: tv.visibleRect.minY + 2))
            return (tv.string as NSString).substring(to: i).count { $0 == "\n" } + 1
        }
        let top = topLine()
        #expect(top > 1000)
        tv.keepingTopLine {
            // Everything changes color, as an opened string would.
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        settle()
        #expect(topLine() == top)
    }
}
