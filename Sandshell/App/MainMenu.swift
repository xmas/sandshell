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
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // MARK: View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let hideSidebar = viewMenu.addItem(withTitle: "Hide Sidebar",
                                           action: #selector(AppDelegate.hideSidebar(_:)), keyEquivalent: "1")
        hideSidebar.keyEquivalentModifierMask = [.control]
        let showSidebar = viewMenu.addItem(withTitle: "Show Sidebar",
                                           action: #selector(AppDelegate.showSidebar(_:)), keyEquivalent: "2")
        showSidebar.keyEquivalentModifierMask = [.control]
        viewMenu.addItem(.separator())
        let nextSession = viewMenu.addItem(withTitle: "Select Next Session",
                                           action: #selector(AppDelegate.selectNextSession(_:)), keyEquivalent: "]")
        nextSession.keyEquivalentModifierMask = [.command, .shift]
        let prevSession = viewMenu.addItem(withTitle: "Select Previous Session",
                                           action: #selector(AppDelegate.selectPreviousSession(_:)), keyEquivalent: "[")
        prevSession.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        let showTabBar = viewMenu.addItem(withTitle: "Show Tab Bar",
                                          action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "t")
        showTabBar.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: "Show All Tabs",
                         action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: "")

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
        let prevTab = windowMenu.addItem(withTitle: "Show Previous Tab",
                                         action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "\t")
        prevTab.keyEquivalentModifierMask = [.control, .shift]
        let nextTab = windowMenu.addItem(withTitle: "Show Next Tab",
                                         action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        windowMenu.addItem(withTitle: "Move Tab to New Window",
                           action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows",
                           action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
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
            let item = NSMenuItem(title: profile.name, action: #selector(openRoot(_:)), keyEquivalent: "")
            item.target = self
            item.image = profile.menuImage()
            item.toolTip = profile.path
            item.representedObject = profile.url
            menu.addItem(item)
        }
        if roots.isEmpty {
            let none = NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let more = NSMenuItem(title: roots.count > Self.shortListCount ? "See More… (\(roots.count))" : "See More…",
                              action: #selector(AppDelegate.openWorkspaceBrowser(_:)), keyEquivalent: "")
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        menu.addItem(more)
    }

    @objc private func openRoot(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        (NSApp.delegate as? AppDelegate)?.openWorkspace(url)
    }
}
