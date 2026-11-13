import Foundation
import Testing
@testable import Sandshell

/// There's no toolbar (the panes' strips are the title bar): what the
/// toolbars before autosaved is forgotten, so none of their items comes back.
/// Each test uses its own defaults suite, never `.standard`.
struct ToolbarConfigurationTests {
    private let suite = "SandshellToolbarTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    @Test func oldArrangementsAreForgotten() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = ["", ".v2", ".v3", ".v4", ".v5", ".v6"].map { "NSToolbar Configuration MainWindowToolbar" + $0 }
        for key in old { defaults.set(["TB Item Identifiers": ["sessionStatus", "search"]], forKey: key) }
        defaults.set("kept", forKey: "NSToolbar Configuration SomethingElse")
        MainWindowController.forgetOldToolbarConfigurations(defaults)
        #expect(old.allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(defaults.string(forKey: "NSToolbar Configuration SomethingElse") == "kept")
    }
}
