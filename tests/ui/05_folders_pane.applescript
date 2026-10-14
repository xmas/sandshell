-- Settings ▸ Folders (the sidebar has no folder rows any more, so this pane
-- is where folders are renamed, removed and added). Read-only: opens the
-- pane, checks the root folder's row and the New Folder / Add Existing…
-- controls are there, and closes it.
--
-- argv: {bundleID, windowTitle}
on run argv
	set bundleID to item 1 of argv
	set windowTitle to item 2 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")

	tell Helpers to waitUntilRunning(bundleID, 20)
	set proc to Helpers's appProcess(bundleID)
	tell application "System Events"
		set targetWindow to first window of proc whose name is windowTitle or name starts with (windowTitle & " — ")
	end tell

	Helpers's clickLabel(targetWindow, "Folder settings", 15)
	set deadline to (current date) + 10
	repeat
		tell application "System Events" to set sheetCount to count of sheets of targetWindow
		if sheetCount > 0 then exit repeat
		if (current date) > deadline then error "the settings sheet never opened"
		delay 0.3
	end repeat
	tell application "System Events" to set sheetRef to sheet 1 of targetWindow
	try
		Helpers's clickIdentifier(sheetRef, "inspector-tab-folders", 15)
		Helpers's waitForIdentifier(sheetRef, "folders-new", 10)
		Helpers's waitForIdentifier(sheetRef, "folders-add-existing", 10)
		-- The workspace root is a folder too: expect at least one folder row.
		set seen to {}
		tell application "System Events"
			repeat with e in (entire contents of sheetRef)
				try
					set end of seen to (value of attribute "AXIdentifier" of e) as text
				end try
			end repeat
		end tell
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
			Helpers's clickIdentifier(sheetRef, "inspector-close", 5)
		end try
		error msg
	end try
	Helpers's clickIdentifier(sheetRef, "inspector-close", 10)
	return "PASS: 05_folders_pane — Folders pane lists the workspace's folders with New Folder / Add Existing…"
end run
