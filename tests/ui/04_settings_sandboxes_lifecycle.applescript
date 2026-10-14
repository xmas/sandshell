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
		set targetWindow to first window of proc whose title is windowTitle or title starts with (windowTitle & " — ")
	end tell

	-- Open the per-root settings sheet (sidebar gear icon) and switch to Sandboxes.
	Helpers's clickLabel(targetWindow, "Folder settings", 15)
	Helpers's clickIdentifier(targetWindow, "inspector-tab-sandboxes", 15)
	Helpers's clickIdentifier(targetWindow, "sandboxes-refresh", 10)

	-- Wait for the throwaway sandbox's row (it may take a beat after refresh).
	Helpers's waitForIdentifier(targetWindow, "sandbox-row-" & sbName, 20)

	-- Stop it, and wait for the button to flip from "Stop" to "Run".
	Helpers's clickIdentifier(targetWindow, "sandbox-stop-" & sbName, 10)
	Helpers's waitForIdentifier(targetWindow, "sandbox-run-" & sbName, 20)

	-- Run it again, and wait for the button to flip back to "Stop".
	Helpers's clickIdentifier(targetWindow, "sandbox-run-" & sbName, 10)
	Helpers's waitForIdentifier(targetWindow, "sandbox-stop-" & sbName, 20)

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
	return "PASS: 03_settings_sandboxes_lifecycle — Stop, Run, and Delete all reflected correctly in the Sandboxes pane"
end run
