-- Shared handlers for the Sandshell release UI-test suite (tests/ui/*.applescript).
--
-- Loaded via `load script` from each test file — see tests/ui/README.md for how
-- the suite is structured and why it drives Sandshell this way.

use scripting additions

-- MARK: Apple Event bridge ('Shll' class; see AppDelegate.swift testEventClass)
--
-- Sandshell registers two raw Apple Event handlers purely for test automation:
--   'Shll'/'stat' — returns JSON describing every window + session (name, agent,
--                   workdir, running/live state, unread flag, elapsed work time).
--   'Shll'/'news' — creates a new session in the frontmost window's current
--                   folder/agent context (same as ⌘N), then returns the same
--                   status JSON.
-- Both are addressed with raw `«event Shllstat»` / `«event Shllnews»` syntax
-- since there's no .sdef — Sandshell isn't a scriptable application in the
-- traditional sense, just one with a couple of test hooks wired in.

on shllStatus(bundleID)
	tell application id bundleID to «event Shllstat»
	return result as text
end shllStatus

on shllNewSession(bundleID)
	tell application id bundleID to «event Shllnews»
	return result as text
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
	tell application "System Events" to click el
	return el
end clickIdentifier

on clickLabel(containerRef, label, timeoutSeconds)
	set el to my waitForLabel(containerRef, label, timeoutSeconds)
	tell application "System Events" to click el
	return el
end clickLabel
