-- Verifies the main menu bar still has the load-bearing items a release
-- depends on. Read-only (never clicks anything); menus are read off the
-- accessibility tree, which works while the test instance stays in the
-- background.
--
-- argv: {bundleID}
on run argv
	set bundleID to item 1 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")

	tell Helpers to waitUntilRunning(bundleID, 20)
	set proc to Helpers's appProcess(bundleID)

	tell application "System Events"
		set fileItemNames to name of menu items of menu "File" of menu bar item "File" of menu bar 1 of proc
		set topLevelNames to name of menu bar items of menu bar 1 of proc
	end tell

	set requiredTopLevel to {"File", "Edit", "View", "Window", "Help"}
	repeat with r in requiredTopLevel
		if (r as text) is not in topLevelNames then error "menu bar is missing top-level menu: " & (r as text)
	end repeat

	set requiredFileItems to {"New Session", "New Claude Chat", "Open…", "Open Folder…", "Duplicate Window", "Close Session", "Close Window"}
	repeat with r in requiredFileItems
		if (r as text) is not in fileItemNames then error "File menu is missing item: " & (r as text)
	end repeat

	return "PASS: 01_menu_structure — menu bar and File menu contain the expected items"
end run
