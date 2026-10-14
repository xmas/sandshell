-- Settings ▸ Folders (the sidebar has no folder rows any more, so this pane
-- is where folders are renamed, removed and added). Read-only: opens the
-- pane, checks the root folder's row and the New Folder / Add Existing…
-- controls are there, and closes it. Driven through the in-app `ax` bridge
-- (works with the screen locked).
--
-- argv: {bundleID, windowTitle}
on run argv
	set windowTitle to item 2 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")

	Helpers's axPressLabel(windowTitle, "Folder settings", 15)
	Helpers's axWaitForSheet(windowTitle, 10)
	try
		Helpers's axPressIdentifier(windowTitle, "inspector-tab-folders", 15)
		Helpers's axWaitForIdentifier(windowTitle, "folders-new", 10)
		Helpers's axWaitForIdentifier(windowTitle, "folders-add-existing", 10)
		-- The workspace root is a folder too: expect at least one folder row.
		set seen to Helpers's axIdentifiers(windowTitle)
		set rowFound to false
		repeat with i in seen
			if (i as text) starts with "folder-name-" or (i as text) starts with "folder-actions-" then set rowFound to true
		end repeat
		if not rowFound then
			set AppleScript's text item delimiters to ", "
			error "no folder rows in Settings ▸ Folders (identifiers: " & (seen as text) & ")"
		end if
	on error msg
		try
			Helpers's axPressIdentifier(windowTitle, "inspector-close", 5)
		end try
		error msg
	end try
	Helpers's axPressIdentifier(windowTitle, "inspector-close", 10)
	return "PASS: 05_folders_pane — Folders pane lists the workspace's folders with New Folder / Add Existing…"
end run
