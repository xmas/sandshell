-- Runs straight after the runner opens a brand-new workspace, while its
-- sandbox is still being created:
--   1. the sidebar's empty state shows the build progress (or "No sessions
--      yet" if the build already finished),
--   2. 'news' (⌘N) creates a session immediately — session creation is never
--      gated on the build — and it goes live once the sandbox is up,
--   3. after the build, the empty-state placeholder is gone.
-- A pass means `sbx create`, the container and the embedded terminal all work.
--
-- argv: {bundleID, windowTitle}
on run argv
	set bundleID to item 1 of argv
	set windowTitle to item 2 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")
	tell Helpers to waitUntilRunning(bundleID, 20)

	set beforeCount to Helpers's windowGet(bundleID, windowTitle, "len(w['sessions'])") as integer
	if beforeCount is not 0 then error "expected a fresh workspace with no sessions, found " & beforeCount

	-- 1. Empty state: build progress while building, else "No sessions yet".
	set sawBuilding to false
	set deadline to (current date) + 10
	repeat
		set building to Helpers's windowGet(bundleID, windowTitle, "w['isBuilding']")
		set placeholder to Helpers's windowGet(bundleID, windowTitle, "w.get('emptyState')")
		if building is "True" then
			set activity to Helpers's windowGet(bundleID, windowTitle, "w.get('activity')")
			if activity is not "None" and placeholder is not activity then error "while building, the empty state should show the build progress \"" & activity & "\", got \"" & placeholder & "\""
			if activity is not "None" then
				set sawBuilding to true
				exit repeat
			end if
		else if placeholder is "No sessions yet" then
			exit repeat
		end if
		if (current date) > deadline then error "empty state never showed build progress or \"No sessions yet\" (last: " & placeholder & ")"
		delay 0.3
	end repeat

	-- 2. New Session right away (possibly mid-build).
	set buildingAtNew to Helpers's windowGet(bundleID, windowTitle, "w['isBuilding']")
	Helpers's shllNewSession(bundleID)
	set deadline to (current date) + 10
	repeat
		if (Helpers's windowGet(bundleID, windowTitle, "len(w['sessions'])") as integer) > 0 then exit repeat
		if (current date) > deadline then error "New Session did not add a session within 10s (building: " & buildingAtNew & ")"
		delay 0.3
	end repeat

	set deadline to (current date) + 240
	repeat
		if Helpers's windowGet(bundleID, windowTitle, "w['sessions'][0]['isLive']") is "True" then exit repeat
		if (current date) > deadline then error "session never went live within 240s — sbx create or the terminal launch failed"
		delay 1
	end repeat

	-- 3. Placeholder gone once the build is over and a session exists.
	set deadline to (current date) + 60
	repeat
		if Helpers's windowGet(bundleID, windowTitle, "w['isBuilding']") is "False" then exit repeat
		if (current date) > deadline then error "sandbox still building 60s after the session went live"
		delay 1
	end repeat
	set placeholder to Helpers's windowGet(bundleID, windowTitle, "w.get('emptyState')")
	if placeholder is not "None" then error "empty state still showing \"" & placeholder & "\" with a live session"

	set summary to "build overlay not observed (sandbox came up first)"
	if sawBuilding then set summary to "build overlay shown"
	if buildingAtNew is "True" then set summary to summary & "; New Session issued mid-build"
	return "PASS: 02_new_session_while_building — " & summary & "; session went live"
end run
