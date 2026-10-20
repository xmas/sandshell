-- The redesigned chrome: the sidebar footer's terminal and Status Debug buttons (no gear /
-- bug / Search buttons), the title bar's Sandbox group and Files button, and
-- the pane strip's breadcrumb. (How the strip condenses as a pane narrows is
-- checked by the title-strip self-test, which can resize panes.)
--
-- argv: {bundleID, windowTitle}
on run argv
	set bundleID to item 1 of argv
	set windowTitle to item 2 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")
	tell Helpers to waitUntilRunning(bundleID, 20)

	repeat with ident in {"sidebar-terminal", "sidebar-debug", "toolbar-sandbox", "toolbar-files", "context-folder"}
		Helpers's axWaitForIdentifier(windowTitle, ident as text, 30)
	end repeat
	set ids to Helpers's axIdentifiers(windowTitle)
	repeat with gone in {"pane-files", "pane-chat-mode"}
		if ids contains (gone as text) then error "the old pane buttons are still there: " & gone
	end repeat
	set tree to Helpers's axCommand("dump", windowTitle, "")
	if tree contains "label=Folder settings" then error "the sidebar footer still has its settings button"
	return "PASS: 06_window_chrome — one-line sidebar footer, title bar Sandbox group + Files, pane breadcrumb; no old footer buttons"
end run
