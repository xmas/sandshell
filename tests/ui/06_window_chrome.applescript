-- The redesigned chrome: the sidebar footer's terminal and Status Debug buttons (no gear /
-- bug / Search buttons), the sidebar header's sandbox status, the top-right strip's Files
-- toggle (there's no toolbar: the strips are the title bar), and the pane strip's breadcrumb. (How the strip condenses as a pane narrows is
-- checked by the title-strip self-test, which can resize panes.)
--
-- argv: {bundleID, windowTitle}
on run argv
	set bundleID to item 1 of argv
	set windowTitle to item 2 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.scpt")
	tell Helpers to waitUntilRunning(bundleID, 20)

	repeat with ident in {"sidebar-sandbox", "context-folder"}
		Helpers's axWaitForIdentifier(windowTitle, ident as text, 30)
	end repeat
	set ids to Helpers's axIdentifiers(windowTitle)
	repeat with gone in {"pane-files", "pane-chat-mode"}
		if ids contains (gone as text) then error "the old pane buttons are still there: " & gone
	end repeat
	set tree to Helpers's axCommand("dump", windowTitle, "")
	-- (A symbol button's identifier doesn't reach the accessibility tree; its label does.)
	if tree does not contain "label=Open a Terminal on This Mac" or tree does not contain "label=Status Debug" then error "the sidebar footer's terminal and Status Debug buttons are missing"
	if tree contains "label=Folder settings" then error "the sidebar footer still has its settings button"
	if tree does not contain "label=Show or Hide Files" then error "the top-right strip has no Files toggle"
	if ids contains "toolbar-files" or ids contains "toolbar-sandbox" then error "the old toolbar is still there"
	return "PASS: 06_window_chrome — sidebar footer buttons, sidebar sandbox status, strip Files toggle, pane breadcrumb; no toolbar"
end run
