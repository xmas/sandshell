import AppKit

/// Builds the standard macOS main menu programmatically. This app has no
/// MainMenu.xib, and the standard keyboard shortcuts (⌘H Hide, ⌘Q Quit, ⌘W Close,
/// ⌘M Minimize, ⌘C/⌘V/⌘X/⌘A, ⌘Z) are wired through main-menu items — without a
/// menu they don't work. Installed from `AppDelegate`.
enum MainMenu {
    @MainActor
    static func install(appName: String) {
        let mainMenu = NSMenu()

        // MARK: App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())

        let services = NSMenu()
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // MARK: File menu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Session",
                         action: #selector(AppDelegate.newSession(_:)), keyEquivalent: "n")
        let newChat = fileMenu.addItem(withTitle: "New Claude Chat",
                                       action: #selector(AppDelegate.newChat(_:)), keyEquivalent: "n")
        newChat.keyEquivalentModifierMask = [.command, .control]
        for agent in SbxCommand.acpAgents where agent != .claude {
            let item = fileMenu.addItem(withTitle: "New \(agent.displayName) Chat",
                                        action: #selector(AppDelegate.newChat(_:)), keyEquivalent: "")
            item.representedObject = agent.rawValue
        }
        let duplicateWindow = fileMenu.addItem(withTitle: "Duplicate Window",
                                               action: #selector(AppDelegate.duplicateWindow(_:)), keyEquivalent: "n")
        duplicateWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(AppDelegate.openWorkspaceBrowser(_:)), keyEquivalent: "o")
        // Rebuilt each time it opens (see RecentRootsMenu): recently opened
        // folders with their colored icons, then "See More…" → the browser.
        let openRecent = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = RecentRootsMenu.shared
        openRecent.submenu = recentMenu
        let openFolder = fileMenu.addItem(withTitle: "Open Folder…",
                                          action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "n")
        openFolder.keyEquivalentModifierMask = [.command, .option]
        let openQuickly = fileMenu.addItem(withTitle: "Open Quickly…", action: #selector(AppDelegate.openQuickly(_:)),
                                           keyEquivalent: "o")
        openQuickly.keyEquivalentModifierMask = [.command, .shift]
        // ⇧⌘F: ⌘F is Find (terminal scrollback search, chat transcript, editor).
        let search = fileMenu.addItem(withTitle: "Search Sessions…",
                                      action: #selector(AppDelegate.showSearch(_:)), keyEquivalent: "f")
        search.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Save", action: #selector(FileEditorController.saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(NSMenuItem("Revert to Saved", action: #selector(FileEditorController.revertDocumentToSaved(_:))))
        fileMenu.addItem(NSMenuItem("Export Conversation…", action: #selector(ChatSessionView.exportConversation(_:)),
                                    key: "e", modifiers: [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem("Print…", action: #selector(ChatSessionView.printDocument(_:)), key: "p"))
        fileMenu.addItem(withTitle: "Welcome to Sandshell…",
                         action: #selector(AppDelegate.runFirstLaunchSetup(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        // ⌘W closes the selected session (or the window if none is selected);
        // ⇧⌘W closes the whole window.
        fileMenu.addItem(withTitle: "Close Session",
                         action: #selector(AppDelegate.closeSessionOrWindow(_:)), keyEquivalent: "w")
        let closeWindow = fileMenu.addItem(withTitle: "Close Window",
                                           action: #selector(AppDelegate.closeWindow(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem("Reopen Closed Session", action: #selector(AppDelegate.reopenClosedSession(_:)),
                                    key: "t", modifiers: [.command, .shift]))

        // MARK: Edit menu (Cut/Copy/Paste/Select All/Undo route via responder chain)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = editMenu.addItem(withTitle: "Paste and Match Style",
                                          action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // Standard text menus: they route through the responder chain, so the
        // chat transcript/composer (and any text field) get them for free.
        editMenu.addItem(submenu("Find", [
            finderItem("Find…", .showFindInterface, "f"),
            finderItem("Find Next", .nextMatch, "g"),
            finderItem("Find Previous", .previousMatch, "g", [.command, .shift]),
            finderItem("Use Selection for Find", .setSearchString, "e"),
            NSMenuItem("Filter Sessions", action: #selector(AppDelegate.focusSessionFilter(_:)), key: "f", modifiers: [.command, .option]),
            NSMenuItem(title: "Jump to Selection", action: #selector(NSResponder.centerSelectionInVisibleArea(_:)),
                       keyEquivalent: "j"),
            .separator(),
            NSMenuItem(title: "Go to Line…", action: #selector(FileEditorController.goToLine(_:)), keyEquivalent: "l"),
        ]))
        editMenu.addItem(submenu("Spelling and Grammar", [
            NSMenuItem(title: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":"),
            NSMenuItem(title: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";"),
            .separator(),
            NSMenuItem(title: "Check Spelling While Typing",
                       action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Check Grammar With Spelling",
                       action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: ""),
        ]))
        editMenu.addItem(submenu("Substitutions", [
            NSMenuItem(title: "Show Substitutions", action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)),
                       keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)),
                       keyEquivalent: ""),
            NSMenuItem(title: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)),
                       keyEquivalent: ""),
            NSMenuItem(title: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)),
                       keyEquivalent: ""),
        ]))
        editMenu.addItem(submenu("Speech", [
            NSMenuItem(title: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: ""),
        ]))

        // MARK: View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let showFiles = viewMenu.addItem(withTitle: "Show Files", action: #selector(AppDelegate.toggleFiles(_:)),
                                         keyEquivalent: "0")
        showFiles.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Split Right", action: #selector(AppDelegate.splitRight(_:)), keyEquivalent: "d")
        let splitDown = viewMenu.addItem(withTitle: "Split Down", action: #selector(AppDelegate.splitDown(_:)), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        let closePane = viewMenu.addItem(withTitle: "Close Pane", action: #selector(AppDelegate.closePane(_:)), keyEquivalent: "w")
        closePane.keyEquivalentModifierMask = [.command, .option]
        let nextPane = viewMenu.addItem(withTitle: "Next Pane", action: #selector(AppDelegate.focusNextPane(_:)), keyEquivalent: "]")
        nextPane.keyEquivalentModifierMask = [.command, .option]
        let prevPane = viewMenu.addItem(withTitle: "Previous Pane", action: #selector(AppDelegate.focusPreviousPane(_:)), keyEquivalent: "[")
        prevPane.keyEquivalentModifierMask = [.command, .option]
        let equalize = viewMenu.addItem(withTitle: "Equalize Panes", action: #selector(AppDelegate.equalizePanes(_:)),
                                        keyEquivalent: "=")
        equalize.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(.separator())
        // Titled Show/Hide by AppDelegate's validation.
        viewMenu.addItem(NSMenuItem("Hide Sidebar", action: #selector(AppDelegate.toggleSessionSidebar(_:)),
                                    key: "s", modifiers: [.command, .control]))
        // The sidebar's one setting: its rows' density (checked: the current one).
        for item in SidebarDensityMenu.shared.items() { viewMenu.addItem(item) }
        viewMenu.addItem(NSMenuItem("Show Session Details", action: #selector(AppDelegate.toggleSessionDetails(_:)),
                                    key: "i", modifiers: [.command, .option]))
        // NSWindow names and validates these (Show/Hide Toolbar).
        viewMenu.addItem(NSMenuItem("Hide Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)),
                                    key: "t", modifiers: [.command, .option]))
        viewMenu.addItem(NSMenuItem("Customize Toolbar…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem("Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                                    key: "f", modifiers: [.command, .control]))

        // MARK: Session menu (the focused pane's session — what the toolbar acts on)
        let sessionItem = NSMenuItem()
        mainMenu.addItem(sessionItem)
        let sessionMenu = NSMenu(title: "Session")
        sessionItem.submenu = sessionMenu
        sessionMenu.addItem(NSMenuItem("Stop", action: #selector(AppDelegate.stopSession(_:)), key: "."))
        sessionMenu.addItem(NSMenuItem("Restart", action: #selector(AppDelegate.restartSession(_:)), key: "r"))
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(NSMenuItem("Show as Chat", action: #selector(AppDelegate.toggleChatTerminal(_:)),
                                       key: "t", modifiers: [.command, .control]))
        sessionMenu.addItem(NSMenuItem("Reveal in Finder", action: #selector(AppDelegate.revealSessionFolder(_:)),
                                       key: "r", modifiers: [.command, .option]))
        sessionMenu.addItem(NSMenuItem("Rename Session…", action: #selector(AppDelegate.renameSession(_:))))
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(NSMenuItem("Select Next Session", action: #selector(AppDelegate.selectNextSession(_:)),
                                       key: "]", modifiers: [.command, .shift]))
        sessionMenu.addItem(NSMenuItem("Select Previous Session", action: #selector(AppDelegate.selectPreviousSession(_:)),
                                       key: "[", modifiers: [.command, .shift]))
        // ⌘] / ⌘[ too, unlisted (the same commands).
        for (key, action) in [("]", #selector(AppDelegate.selectNextSession(_:))),
                              ("[", #selector(AppDelegate.selectPreviousSession(_:)))] {
            let hidden = NSMenuItem(key == "]" ? "Select Next Session" : "Select Previous Session", action: action, key: key)
            hidden.isHidden = true
            hidden.allowsKeyEquivalentWhenHidden = true
            sessionMenu.addItem(hidden)
        }

        // MARK: Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let backgroundTasks = windowMenu.addItem(withTitle: "Background Tasks",
                                                 action: #selector(AppDelegate.showBackgroundTasks(_:)), keyEquivalent: "b")
        backgroundTasks.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        // Always-available way to reopen/focus the main window after it's closed.
        let mainWindowItem = windowMenu.addItem(withTitle: appName,
                                                action: #selector(AppDelegate.showMainWindow(_:)),
                                                keyEquivalent: "0")
        mainWindowItem.keyEquivalentModifierMask = [.command]

        // MARK: Help menu
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        // ⌥⌘/: ⇧⌘/ (⌘?) is the system's own Help-menu search.
        helpMenu.addItem(NSMenuItem("Keyboard Shortcuts", action: #selector(AppDelegate.showKeyboardShortcuts(_:)),
                                    key: "/", modifiers: [.command, .option]))
        helpMenu.addItem(NSMenuItem("Release Notes", action: #selector(AppDelegate.showReleaseNotes(_:))))
        helpMenu.addItem(.separator())
        // Diagnostics (the sidebar footer's old terminal and bug buttons live here now).
        helpMenu.addItem(NSMenuItem("Show Sandshell Log", action: #selector(AppDelegate.showSandshellLog(_:))))
        // Hold ⌃ for the sbx daemon's.
        let daemon = NSMenuItem("Show sbx Daemon Log", action: #selector(AppDelegate.showDaemonLog(_:)))
        daemon.keyEquivalentModifierMask = [.control]
        daemon.isAlternate = true
        helpMenu.addItem(daemon)
        helpMenu.addItem(NSMenuItem("Show Status Debug Window", action: #selector(AppDelegate.showStatusDebug(_:))))
        helpMenu.addItem(NSMenuItem("Open Terminal on This Mac", action: #selector(AppDelegate.openHostTerminal(_:))))
        helpMenu.addItem(withTitle: "Check sbx Daemon Health…",
                         action: #selector(AppDelegate.checkDaemonHealth(_:)), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }
}


/// Delegate for the File ▸ Open Recent submenu: repopulates it on every open
/// from the root registry (most recent first, colored icon marks), ending with
/// "See More…" (the Open Workspace browser) — so it always matches the
/// sidebar header's workspace menu.
@MainActor
final class RecentRootsMenu: NSObject, NSMenuDelegate {
    static let shared = RecentRootsMenu()
    /// How many folders the short menus show before "See More…".
    static let shortListCount = 8

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let roots = RootFolderStore.byRecency()
        for profile in roots.prefix(Self.shortListCount) {
            menu.addItem(profile.menuItem(action: #selector(openRoot(_:)), target: self))
        }
        if roots.isEmpty {
            let none = NSMenuItem("No Recent Folders")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(roots.count > Self.shortListCount ? "See More… (\(roots.count))" : "See More…",
                                action: #selector(AppDelegate.openWorkspaceBrowser(_:)), symbol: "ellipsis.circle"))
    }

    @objc private func openRoot(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        (NSApp.delegate as? AppDelegate)?.openWorkspace(url)
    }
}

// MARK: - Menu helpers

@MainActor private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title, submenu: items)
    item.submenu?.title = title
    return item
}

/// A standard text-finder menu item (`performTextFinderAction:` with the
/// action as its tag) — what NSTextView's find bar responds to.
@MainActor private func finderItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                                   _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: key)
    item.tag = action.rawValue
    item.keyEquivalentModifierMask = modifiers
    return item
}
