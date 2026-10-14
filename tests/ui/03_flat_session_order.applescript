-- The sidebar is one flat list of sessions, most recently active first.
-- Adds a second session and checks it lands on top, and that the sidebar's
-- rows (sidebarSessionIDs) are exactly the controller's ordered session list.
--
-- argv: {bundleID, windowTitle}
on run argv
	set bundleID to item 1 of argv
	set windowTitle to item 2 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")
	tell Helpers to waitUntilRunning(bundleID, 20)

	set beforeIDs to Helpers's windowGet(bundleID, windowTitle, "' '.join(s['id'] for s in w['sessions'])")
	set beforeCount to Helpers's windowGet(bundleID, windowTitle, "len(w['sessions'])") as integer
	delay 1.1 -- createdAt has second-level ordering in practice; keep the two apart

	Helpers's shllNewSession(bundleID)
	set deadline to (current date) + 60
	repeat
		if (Helpers's windowGet(bundleID, windowTitle, "len(w['sessions'])") as integer) > beforeCount then exit repeat
		if (current date) > deadline then error "second session never appeared"
		delay 0.5
	end repeat

	set newID to Helpers's windowGet(bundleID, windowTitle, "[s['id'] for s in w['sessions'] if s['id'] not in '" & beforeIDs & "'.split()][0]")
	set firstID to Helpers's windowGet(bundleID, windowTitle, "w['sessions'][0]['id']")
	if firstID is not newID then error "newest session should be first in the list; first is " & firstID & ", new is " & newID

	-- Wait for the sidebar to catch up, then compare row order.
	set deadline to (current date) + 10
	repeat
		set same to Helpers's windowGet(bundleID, windowTitle, "w['sidebarSessionIDs'] == [s['id'] for s in w['sessions']]")
		if same is "True" then exit repeat
		if (current date) > deadline then error "sidebar rows " & Helpers's windowGet(bundleID, windowTitle, "w['sidebarSessionIDs']") & " don't match session order " & Helpers's windowGet(bundleID, windowTitle, "[s['id'] for s in w['sessions']]")
		delay 0.5
	end repeat

	set deadline to (current date) + 120
	repeat
		if Helpers's windowGet(bundleID, windowTitle, "[s for s in w['sessions'] if s['id'] == '" & newID & "'][0]['isLive']") is "True" then exit repeat
		if (current date) > deadline then error "second session never went live"
		delay 1
	end repeat

	return "PASS: 03_flat_session_order — new session on top; sidebar rows match session order (" & (beforeCount + 1) & " sessions)"
end run
