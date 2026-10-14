-- Smoke test: the app launches, the test bridge's stat round-trips
-- valid JSON, and the sandshell://open URL the runner sent opened the test
-- workspace's window. The cheapest "is this build alive" signal — run first.

-- argv: {bundleID, windowTitle}
on run argv
	set bundleID to item 1 of argv
	set windowTitle to item 2 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")

	tell Helpers to waitUntilRunning(bundleID, 20)
	set deadline to (current date) + 20
	repeat
		set statusJSON to Helpers's shllStatus(bundleID)
		set found to Helpers's jsonGet(statusJSON, "any(w['title'].split(' — ')[0] == '" & windowTitle & "' for w in d['windows'])")
		if found is "True" then exit repeat
		if (current date) > deadline then error "sandshell://open never opened a window titled " & windowTitle & " (status: " & statusJSON & ")"
		delay 0.5
	end repeat
	set winCount to Helpers's jsonGet(statusJSON, "d['windowCount']")

	return "PASS: 00_launch_and_status — test bridge works; URL scheme opened the test window (" & winCount & " window(s))"
end run
