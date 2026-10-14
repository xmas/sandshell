-- Shared handlers for the Sandshell release UI-test suite (tests/ui/*.applescript).
--
-- Loaded via `load script` from each test file — see tests/ui/README.md for how
-- the suite is structured and why it drives Sandshell this way.

use scripting additions

-- MARK: Test bridge
--
-- The headless test instance (scripts/run-ui-tests.sh) is driven through files
-- in $SANDSHELL_UITEST_BRIDGE rather than Apple Events — every fresh test build
-- would otherwise need an Automation approval. See UITestHeadless in
-- Sandshell/App/SelfTest.swift. Commands mirror the 'Shll' Apple Events:
--   stat        — JSON describing every window + session (sidebar order, build
--                 state, empty-state text, live/unread state, work time).
--   news        — new session in the active window (same as ⌘N), then stat.
--   open <url>  — handle a sandshell:// URL, then stat.
-- (`bundleID` arguments are kept for System Events lookups.)

on bridge(command)
	set dir to system attribute "SANDSHELL_UITEST_BRIDGE"
	if dir is "" then error "SANDSHELL_UITEST_BRIDGE is not set — run via scripts/run-ui-tests.sh"
	return do shell script "d=" & quoted form of dir & "; rm -f \"$d/response\"; printf %s " & quoted form of command & " > \"$d/request.tmp\" && mv \"$d/request.tmp\" \"$d/request\"; i=0; while [ ! -f \"$d/response\" ]; do i=$((i+1)); [ $i -gt 300 ] && { echo 'test bridge: no response in 30s' >&2; exit 1; }; sleep 0.1; done; cat \"$d/response\""
end bridge

on shllStatus(bundleID)
	return my bridge("stat")
end shllStatus

on shllNewSession(bundleID)
	return my bridge("news")
end shllNewSession

-- MARK: Process lookup

on appIsRunning(bundleID)
	tell application "System Events"
		return (count of (every application process whose bundle identifier is bundleID)) > 0
	end tell
end appIsRunning

on appProcess(bundleID)
	tell application "System Events"
		return first application process whose bundle identifier is bundleID
	end tell
end appProcess

on waitUntilRunning(bundleID, timeoutSeconds)
	set deadline to (current date) + timeoutSeconds
	repeat
		if my appIsRunning(bundleID) then return true
		if (current date) > deadline then error "timed out waiting for " & bundleID & " to launch"
		delay 0.5
	end repeat
end waitUntilRunning

-- MARK: JSON

-- Extract a value from a JSON string via a Python expression over the parsed
-- object `d` (e.g. "d['windowCount']"). AppleScript has no built-in JSON
-- parser, and shelling the JSON text through a command line risks quoting
-- bugs, so it's written to a temp file first and read back by python3.
on jsonGet(jsonText, pyExpr)
	set tmp to "/tmp/sandshell-uitest-status.json"
	set fRef to open for access (POSIX file tmp) with write permission
	set eof of fRef to 0
	write jsonText to fRef
	close access fRef
	return do shell script "python3 -c " & quoted form of ("import json
d = json.load(open('" & tmp & "'))
print(" & pyExpr & ")")
end jsonGet

-- MARK: Accessibility-tree search
--
-- Elements are found either by their AXIdentifier (stable, added specifically
-- for these tests — see SandboxesPane.swift / InspectorView.swift) or, where
-- no identifier was worth adding, by their accessible name/title.

on findByIdentifier(containerRef, ident)
	tell application "System Events"
		try
			return (first UI element of containerRef whose value of attribute "AXIdentifier" is ident)
		end try
		try
			set kids to UI elements of containerRef
		on error
			return missing value
		end try
	end tell
	repeat with child in kids
		set found to my findByIdentifier(child, ident)
		if found is not missing value then return found
	end repeat
	return missing value
end findByIdentifier

on findByLabel(containerRef, label)
	tell application "System Events"
		try
			return (first UI element of containerRef whose name is label)
		end try
		try
			set kids to UI elements of containerRef
		on error
			return missing value
		end try
	end tell
	repeat with child in kids
		set found to my findByLabel(child, label)
		if found is not missing value then return found
	end repeat
	return missing value
end findByLabel

on waitForIdentifier(containerRef, ident, timeoutSeconds)
	set deadline to (current date) + timeoutSeconds
	repeat
		set found to my findByIdentifier(containerRef, ident)
		if found is not missing value then return found
		if (current date) > deadline then error "timed out waiting for AXIdentifier \"" & ident & "\""
		delay 0.5
	end repeat
end waitForIdentifier

on waitForLabel(containerRef, label, timeoutSeconds)
	set deadline to (current date) + timeoutSeconds
	repeat
		set found to my findByLabel(containerRef, label)
		if found is not missing value then return found
		if (current date) > deadline then error "timed out waiting for element named \"" & label & "\""
		delay 0.5
	end repeat
end waitForLabel

on identifierExists(containerRef, ident)
	return my findByIdentifier(containerRef, ident) is not missing value
end identifierExists

on clickIdentifier(containerRef, ident, timeoutSeconds)
	set el to my waitForIdentifier(containerRef, ident, timeoutSeconds)
	-- AXPress, not `click`: no synthetic mouse event, so it works on the
	-- headless (transparent, click-through, background) test instance.
	tell application "System Events" to perform action "AXPress" of el
	return el
end clickIdentifier

on clickLabel(containerRef, label, timeoutSeconds)
	set el to my waitForLabel(containerRef, label, timeoutSeconds)
	tell application "System Events" to perform action "AXPress" of el
	return el
end clickLabel

-- MARK: Test-window status

-- Python expression for the test window's entry in the status JSON.
on testWindowExpr(windowTitle)
	return "[w for w in d['windows'] if w['title'].split(' — ')[0] == '" & windowTitle & "'][0]"
end testWindowExpr

-- Evaluate a Python expression over `w`, the test window's status entry.
on windowGet(bundleID, windowTitle, pyExpr)
	set statusJSON to my shllStatus(bundleID)
	return my jsonGet(statusJSON, "(lambda w: " & pyExpr & ")(" & my testWindowExpr(windowTitle) & ")")
end windowGet
