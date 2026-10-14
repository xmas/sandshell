-- Drives the Settings ▸ Sandboxes pane through a full Stop → Run → Delete
-- cycle against a single throwaway sandbox that run-ui-tests.sh created via
-- `sbx create` before launching the app. This test only ever touches the row
-- matching `sandboxName` (always "sandshell-uitest-…") — it never interacts
-- with any other row, so a real sandbox sitting in the list is left alone.
--
-- argv: {bundleID, windowTitle, sandboxName}
on run argv
	set bundleID to item 1 of argv
	set windowTitle to item 2 of argv
	set sbName to item 3 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")

	tell Helpers to waitUntilRunning(bundleID, 20)
	set proc to Helpers's appProcess(bundleID)

	-- Everything is addressed inside the test window via AX actions; the
	-- instance stays in the background (never made frontmost).
	tell application "System Events"
		try
			set targetWindow to first window of proc whose name is windowTitle or name starts with (windowTitle & " — ")
		on error
			set names to name of every window of proc
			set AppleScript's text item delimiters to " | "
			error "no window named " & windowTitle & " — windows: " & (names as text)
		end try
	end tell

	-- Open the per-root settings sheet (sidebar gear icon) and switch to
	-- Sandboxes. Searches run inside the sheet: walking the whole window over
	-- AX is too slow.
	Helpers's clickLabel(targetWindow, "Folder settings", 15)
	set deadline to (current date) + 10
	repeat
		tell application "System Events" to set sheetCount to count of sheets of targetWindow
		if sheetCount > 0 then exit repeat
		if (current date) > deadline then error "the settings sheet never opened"
		delay 0.3
	end repeat
	tell application "System Events" to set targetWindow to sheet 1 of targetWindow
	Helpers's clickIdentifier(targetWindow, "inspector-tab-sandboxes", 15)
	Helpers's clickIdentifier(targetWindow, "sandboxes-refresh", 10)

	-- Wait for the throwaway sandbox's row (it may take a beat after refresh).
	Helpers's waitForIdentifier(targetWindow, "sandbox-row-" & sbName, 20)
	-- Expand it to reveal Stop/Run/Rebuild/Delete.
	Helpers's clickIdentifier(targetWindow, "sandbox-row-" & sbName, 10)

	-- sbx may have stopped it after creation. Bring it to running first, then
	-- Stop it (button flips to "Run") and Run it again (flips back to "Stop").
	if Helpers's identifierExists(targetWindow, "sandbox-run-" & sbName) then
		Helpers's clickIdentifier(targetWindow, "sandbox-run-" & sbName, 10)
		Helpers's waitForIdentifier(targetWindow, "sandbox-stop-" & sbName, 30)
	end if
	Helpers's clickIdentifier(targetWindow, "sandbox-stop-" & sbName, 10)
	Helpers's waitForIdentifier(targetWindow, "sandbox-run-" & sbName, 30)
	Helpers's clickIdentifier(targetWindow, "sandbox-run-" & sbName, 10)
	Helpers's waitForIdentifier(targetWindow, "sandbox-stop-" & sbName, 30)

	-- Delete it, confirm the destructive dialog, and wait for the row to vanish.
	Helpers's clickIdentifier(targetWindow, "sandbox-delete-" & sbName, 10)
	Helpers's clickIdentifier(targetWindow, "sandbox-confirm-delete", 10)

	set deadline to (current date) + 15
	repeat
		if not Helpers's identifierExists(targetWindow, "sandbox-row-" & sbName) then exit repeat
		if (current date) > deadline then error "sandbox row for " & sbName & " is still present after Delete"
		delay 1
	end repeat

	Helpers's clickIdentifier(targetWindow, "inspector-close", 10)
	return "PASS: 04_settings_sandboxes_lifecycle — Stop, Run, and Delete all reflected correctly in the Sandboxes pane"
end run
