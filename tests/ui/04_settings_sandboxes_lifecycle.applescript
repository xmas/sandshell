-- Drives the Settings ▸ Sandboxes pane through a full Stop → Run → Delete
-- cycle against a single throwaway sandbox that run-ui-tests.sh created via
-- `sbx create` before launching the app. This test only ever touches the row
-- matching `sandboxName` (always "sandshell-uitest-…") — it never interacts
-- with any other row, so a real sandbox sitting in the list is left alone.
-- Driven through the in-app `ax` bridge (works with the screen locked).
--
-- argv: {bundleID, windowTitle, sandboxName}
on run argv
	set windowTitle to item 2 of argv
	set sbName to item 3 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")

	-- Open the per-root settings sheet (sidebar gear icon) and switch to Sandboxes.
	Helpers's axPressLabel(windowTitle, "Folder settings", 15)
	Helpers's axWaitForSheet(windowTitle, 10)
	Helpers's axPressIdentifier(windowTitle, "inspector-tab-sandboxes", 15)
	Helpers's axPressIdentifier(windowTitle, "sandboxes-refresh", 10)

	-- Wait for the throwaway sandbox's row (it may take a beat after refresh),
	-- then expand it to reveal Stop/Run/Rebuild/Delete.
	Helpers's axWaitForIdentifier(windowTitle, "sandbox-row-" & sbName, 20)
	Helpers's axPressIdentifier(windowTitle, "sandbox-row-" & sbName, 10)

	-- sbx may have stopped it after creation. Bring it to running first, then
	-- Stop it (button flips to "Run") and Run it again (flips back to "Stop").
	if Helpers's axIdentifierExists(windowTitle, "sandbox-run-" & sbName) then
		Helpers's axPressIdentifier(windowTitle, "sandbox-run-" & sbName, 10)
		Helpers's axWaitForIdentifier(windowTitle, "sandbox-stop-" & sbName, 60)
	end if
	Helpers's axPressIdentifier(windowTitle, "sandbox-stop-" & sbName, 10)
	Helpers's axWaitForIdentifier(windowTitle, "sandbox-run-" & sbName, 60)
	Helpers's axPressIdentifier(windowTitle, "sandbox-run-" & sbName, 10)
	Helpers's axWaitForIdentifier(windowTitle, "sandbox-stop-" & sbName, 60)

	-- Delete it, confirm the destructive dialog, and wait for the row to vanish.
	Helpers's axPressIdentifier(windowTitle, "sandbox-delete-" & sbName, 10)
	Helpers's axPressIdentifier(windowTitle, "sandbox-confirm-delete", 10)

	set deadline to (current date) + 15
	repeat
		if not Helpers's axIdentifierExists(windowTitle, "sandbox-row-" & sbName) then exit repeat
		if (current date) > deadline then error "sandbox row for " & sbName & " is still present after Delete"
		delay 1
	end repeat

	Helpers's axPressIdentifier(windowTitle, "inspector-close", 10)
	return "PASS: 04_settings_sandboxes_lifecycle — Stop, Run, and Delete all reflected correctly in the Sandboxes pane"
end run
