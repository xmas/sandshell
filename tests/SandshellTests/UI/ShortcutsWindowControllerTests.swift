import Testing
@testable import Sandshell

// Tests for the Keyboard Shortcuts window's list (`ShortcutsWindowController`):
// the menu bar's shortcuts grouped by menu in menu-bar order (`grouped`), and
// the filter typed above them (`filter(_:by:)`).

struct ShortcutsGroupingTests {
    private func shortcut(_ menu: String, _ title: String) -> ShortcutsWindowController.Shortcut {
        .init(menu: menu, title: title, keys: "⌘X")
    }

    @Test func menusComeInMenuBarOrder() {
        let groups = ShortcutsWindowController.grouped([
            shortcut("App", "Quit Sandshell"), shortcut("File", "New Session"),
            shortcut("Edit", "Undo"), shortcut("View", "Split Right"),
        ])
        #expect(groups.map(\.menu) == ["App", "File", "Edit", "View"])
    }

    @Test("A menu's items after a submenu's stay in the menu's one section")
    func itemsAroundASubmenuShareASection() {
        let groups = ShortcutsWindowController.grouped([
            shortcut("Edit", "Undo"), shortcut("Edit ▸ Find", "Find…"), shortcut("Edit", "Select All"),
        ])
        #expect(groups.map(\.menu) == ["Edit", "Edit ▸ Find"])
        #expect(groups.first?.items.map(\.title) == ["Undo", "Select All"])
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test(.tags(.edgeCase)) func noShortcutsNoSections() {
        #expect(ShortcutsWindowController.grouped([]).isEmpty)
    }
}

struct ShortcutsFilterTests {
    private let groups = ShortcutsWindowController.grouped([
        .init(menu: "File", title: "New Session", keys: "⌘N"),
        .init(menu: "File", title: "Open…", keys: "⌘O"),
        .init(menu: "View", title: "Split Right", keys: "⌘D"),
        .init(menu: "View", title: "Café Mode", keys: "⌃⌘C"),
    ])

    @Test func anEmptyQueryShowsEverything() {
        #expect(ShortcutsWindowController.filter(groups, by: "") == groups)
    }

    @Test("Matching ignores case and accents, like Finder's search", arguments: [
        ("split", "Split Right"),
        ("SPLIT R", "Split Right"),
        ("cafe", "Café Mode"),
        ("CAFÉ", "Café Mode"),
    ])
    func matchesAsFinderDoes(query: String, title: String) {
        let shown = ShortcutsWindowController.filter(groups, by: query)
        #expect(shown.flatMap(\.items).map(\.title) == [title])
    }

    @Test func aMenuNameMatchesEveryItemInIt() {
        let shown = ShortcutsWindowController.filter(groups, by: "file")
        #expect(shown.map(\.menu) == ["File"])
        #expect(shown.first?.items.count == 2)
    }

    @Test func menusLeftEmptyDrop() {
        #expect(ShortcutsWindowController.filter(groups, by: "session").map(\.menu) == ["File"])
        #expect(ShortcutsWindowController.filter(groups, by: "no such command").isEmpty)
    }
}
