import AppKit
import GhosttyKit
import GhosttyTerminal
import Testing
@testable import Sandshell

// Which ⌘ shortcuts a focused terminal leaves to the menu. A terminal runs its
// Ghostty bindings before the menu sees a key, so the bundled Ghostty is asked
// itself (`ghostty_app_key_is_binding`), configured as every Sandshell
// terminal is (`TerminalSession.applyBase`), about the real main menu's
// shortcuts. The configuration goes through a temp file, removed after.

@MainActor
struct ReleasedMenuKeysTests {
    /// A menu shortcut, as Ghostty's binding check takes it and as its
    /// keybind config writes it ("super+shift+[").
    struct Shortcut: Hashable, CustomTestStringConvertible {
        let character: Character
        let modifiers: ghostty_input_mods_e.RawValue

        init(_ character: Character, _ flags: NSEvent.ModifierFlags) {
            self.character = character
            modifiers = [(NSEvent.ModifierFlags.command, GHOSTTY_MODS_SUPER), (.control, GHOSTTY_MODS_CTRL),
                         (.option, GHOSTTY_MODS_ALT), (.shift, GHOSTTY_MODS_SHIFT)]
                .filter { flags.contains($0.0) }
                .reduce(0) { $0 | $1.1.rawValue }
        }

        /// A menu item's key equivalent (an uppercase letter implies Shift).
        init?(_ item: NSMenuItem) {
            guard let key = item.keyEquivalent.first, item.keyEquivalentModifierMask.contains(.command) else {
                return nil
            }
            var flags = item.keyEquivalentModifierMask
            if key.isUppercase { flags.insert(.shift) }
            self.init(Character(key.lowercased()), flags)
        }

        var trigger: String {
            [(GHOSTTY_MODS_SUPER, "super"), (GHOSTTY_MODS_CTRL, "ctrl"), (GHOSTTY_MODS_ALT, "alt"),
             (GHOSTTY_MODS_SHIFT, "shift")]
                .filter { modifiers & $0.0.rawValue != 0 }
                .map(\.1)
                .joined(separator: "+") + "+\(character)"
        }

        var testDescription: String { trigger }
    }

    /// Ghostty's answer for each shortcut: is it one of its bindings, with its
    /// defaults plus `configuration`?
    private func ghosttyBinds(_ shortcuts: [Shortcut],
                              with configuration: TerminalConfiguration) throws -> [Shortcut: Bool] {
        _ = TerminalController.shared   // starts Ghostty's runtime, once a process
        let file = URL.temporaryDirectory.appending(path: "sandshell-tests-\(UUID().uuidString).ghostty")
        try configuration.rendered.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, file.path(percentEncoded: false))
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0, "Ghostty takes every line of the configuration")

        var runtime = ghostty_runtime_config_s()
        runtime.wakeup_cb = { _ in }
        runtime.action_cb = { _, _, _ in false }
        runtime.read_clipboard_cb = { _, _, _ in false }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, _, _, _ in }
        runtime.close_surface_cb = { _, _ in }
        let app = try #require(ghostty_app_new(&runtime, config))
        defer { ghostty_app_free(app) }

        var answers: [Shortcut: Bool] = [:]
        for shortcut in shortcuts {
            var key = ghostty_input_key_s()
            key.action = GHOSTTY_ACTION_PRESS
            key.mods = ghostty_input_mods_e(rawValue: shortcut.modifiers)
            key.keycode = 0xFFFF   // no physical key: Ghostty's defaults are by character
            key.unshifted_codepoint = shortcut.character.unicodeScalars.first?.value ?? 0
            answers[shortcut] = String(shortcut.character).withCString { text in
                key.text = text
                return ghostty_app_key_is_binding(app, key)
            }
        }
        return answers
    }

    private var sandshellTerminals: TerminalConfiguration {
        TerminalConfiguration { TerminalSession.applyBase(ThemePreferences(), to: &$0) }
    }

    /// Every ⌘ shortcut in the main menu, hidden items included.
    private func menuShortcuts() throws -> [Shortcut] {
        MainMenu.install(appName: "Sandshell")
        let menu = try #require(NSApp.mainMenu)
        func walk(_ menu: NSMenu) -> [Shortcut] {
            menu.items.flatMap { item in (Shortcut(item).map { [$0] } ?? []) + (item.submenu.map(walk) ?? []) }
        }
        return walk(menu)
    }

    @Test("Every menu shortcut reaches the menu but the few left to Ghostty")
    func menuShortcutsGhosttyKeeps() throws {
        let shortcuts = try menuShortcuts()
        try #require(shortcuts.count > 40, "the main menu was read")
        let bound = try ghosttyBinds(shortcuts, with: sandshellTerminals).filter(\.value).map(\.key.trigger)
        let leftToGhostty: Set = [
            "super+v", "super+a", "super+0",                           // paste, select all, font size
            "super+e", "super+g", "super+shift+g", "super+j",          // text find
            "super+d", "super+shift+d", "super+alt+w", "super+ctrl+=", // panes (the app's key monitor)
        ]
        #expect(Set(bound).subtracting(leftToGhostty) == [], "Ghostty would swallow these")
        #expect(leftToGhostty.subtracting(bound) == [], "no longer Ghostty's: release them, or say why not")
    }

    @Test("Shortcuts Ghostty binds by default reach the menu in Sandshell's terminals", arguments: [
        Shortcut("f", [.command, .control]),   // View ▸ Enter Full Screen
        Shortcut("t", [.command, .shift]),     // File ▸ Reopen Closed Session
        Shortcut("i", [.command, .option]),    // View ▸ Show Session Details
        Shortcut("w", [.command, .shift]),     // File ▸ Close Window
        Shortcut("z", [.command]),             // Edit ▸ Undo
        Shortcut("z", [.command, .shift]),     // Edit ▸ Redo
        Shortcut(",", [.command]),             // Settings…
        Shortcut("]", [.command, .shift]),     // Session ▸ Select Next Session
        Shortcut("q", [.command]),             // Quit
    ])
    func releasedFromGhosttyDefaults(_ shortcut: Shortcut) throws {
        let defaults = try ghosttyBinds([shortcut], with: TerminalConfiguration())
        #expect(defaults[shortcut] == true, "Ghostty binds it out of the box")
        let sandshell = try ghosttyBinds([shortcut], with: sandshellTerminals)
        #expect(sandshell[shortcut] == false)
        #expect(TerminalSession.releasedMenuKeys.contains(shortcut.trigger))
    }

    @Test("Each released key is written so Ghostty unbinds something", arguments: TerminalSession.releasedMenuKeys)
    func everyReleasedKeyWasABinding(_ trigger: String) throws {
        // The character forms Ghostty's defaults use: "super+comma" or
        // "super+shift+left_bracket" would name other keys and unbind nothing.
        let parts = trigger.split(separator: "+").map(String.init)
        let character = try #require(parts.last?.first)
        let flags: NSEvent.ModifierFlags = parts.dropLast().reduce(into: []) { flags, name in
            switch name {
            case "super": flags.insert(.command)
            case "ctrl": flags.insert(.control)
            case "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: Issue.record("unexpected modifier \(name)")
            }
        }
        let shortcut = Shortcut(character, flags)
        try #require(shortcut.trigger == trigger)
        #expect(try ghosttyBinds([shortcut], with: TerminalConfiguration())[shortcut] == true,
                "a Ghostty default to release")
        #expect(try ghosttyBinds([shortcut], with: sandshellTerminals)[shortcut] == false)
    }
}
