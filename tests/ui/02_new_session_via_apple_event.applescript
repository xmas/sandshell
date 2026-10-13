-- Exercises the real sbx pipeline end-to-end: focuses the dedicated test
-- workspace window (opened by run-ui-tests.sh via the sandshell:// URL
-- handler, so it never touches any of the user's real folders), sends the
-- 'news' Apple Event (equivalent of ⌘N — "New Session" in the current
-- context), then polls the 'stat' JSON until a new session appears and is
-- reported live. A pass here means `sbx create`, the container, and the
-- embedded terminal all actually work — not just that the UI drew correctly.
--
-- argv: {bundleID, windowTitle}
on run argv
	set bundleID to item 1 of argv
	set windowTitle to item 2 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.applescript")

	tell Helpers to waitUntilRunning(bundleID, 20)
	set proc to Helpers's appProcess(bundleID)

	-- 'news' operates on whichever window is key, so make the test workspace
	-- window frontmost first rather than trusting whatever last had focus.
	tell application "System Events"
		set frontmost of proc to true
		set targetWindow to first window of proc whose title is windowTitle or title starts with (windowTitle & " — ")
		perform action "AXRaise" of targetWindow
	end tell
	delay 0.5

	set beforeJSON to Helpers's shllStatus(bundleID)
	set beforeCount to Helpers's jsonGet(beforeJSON, "len([w for w in d['windows'] if w['title'].split(' — ')[0] == '" & windowTitle & "'][0]['sessions'])") as integer

	Helpers's shllNewSession(bundleID)

	set afterCount to beforeCount
	set deadline to (current date) + 45
	repeat
		set afterJSON to Helpers's shllStatus(bundleID)
		set afterCount to Helpers's jsonGet(afterJSON, "len([w for w in d['windows'] if w['title'].split(' — ')[0] == '" & windowTitle & "'][0]['sessions'])") as integer
		if afterCount > beforeCount then exit repeat
		if (current date) > deadline then error "new session never appeared within 45s (had " & beforeCount & ", still " & afterCount & ")"
		delay 1
	end repeat

	set isLive to Helpers's jsonGet(afterJSON, "[w for w in d['windows'] if w['title'].split(' — ')[0] == '" & windowTitle & "'][0]['sessions'][-1]['isLive']")
	if isLive is not "True" then error "new session was created but isLive=" & isLive & " — the terminal/agent likely failed to start"

	return "PASS: 02_new_session_via_apple_event — sbx create + terminal launch succeeded (sessions " & beforeCount & " → " & afterCount & ")"
end run
