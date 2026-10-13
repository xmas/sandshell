-- Sandshell first-install assistant.
-- Compile to an app:  scripts/build-installer.sh  →  "dist/Sandshell Installer.app"
-- Helps a new user install Sandshell from the docker.com Drive releases folder:
-- finds/downloads the DMG, copies the app to /Applications, then hands off to a
-- Terminal window running the bundled "Sandshell Setup.command" (which removes
-- the Gatekeeper quarantine, installs/updates the sbx CLI — restarting the
-- daemon when needed — signs in to sbx, and launches the app).

property appName : "Sandshell"
property driveFolder : "https://drive.google.com/drive/folders/1TDO_iVfaobA3tYiF8JM_1NA_DBpEANjl"
property installedApp : "/Applications/Sandshell.app"
property setupTmp : "/tmp/Sandshell Setup.command"

on run
	try
		display dialog "Welcome — this assistant installs " & appName & "." & return & return & ¬
			"It will help you download the latest release, copy " & appName & " into your Applications " & ¬
			"folder, then open Terminal to set up the sbx CLI and sign you in." ¬
			buttons {"Quit", "Continue"} default button "Continue" ¬
			with title appName & " Installer" with icon note
		if button returned of result is "Quit" then return

		set theUser to do shell script "id -un"
		set dmgPath to locateDMG()
		installFrom(dmgPath, theUser)
		runSetupInTerminal()

		display dialog appName & " is installed. A Terminal window is finishing setup — it installs or " & ¬
			"updates the sbx CLI, signs you in, and launches " & appName & "." & return & return & ¬
			"Follow any prompts there (you may be asked for your password and to sign in)." ¬
			buttons {"Done"} default button "Done" with title appName & " Installer" with icon note
	on error errMsg number errNum
		if errNum is -128 then return -- user cancelled
		display alert "Couldn’t finish installing " & appName message errMsg as critical
	end try
end run

-- Find the newest Sandshell DMG in ~/Downloads; if none, open the Drive folder
-- and wait for the user to download one.
on locateDMG()
	repeat
		set found to ""
		try
			set found to do shell script ¬
				"ls -t \"$HOME\"/Downloads/" & appName & "-*.dmg 2>/dev/null | head -1"
		end try
		if found is not "" then return found

		do shell script "open " & quoted form of driveFolder
		display dialog "Download the latest " & appName & " disk image (Sandshell-<version>.dmg) into your " & ¬
			"Downloads folder, then click Continue." & return & return & ¬
			"The releases folder just opened in your browser — sign in with your docker.com account if asked." ¬
			buttons {"Quit", "Continue"} default button "Continue" ¬
			with title appName & " Installer" with icon note
		if button returned of result is "Quit" then error number -128
	end repeat
end locateDMG

-- Mount the DMG, copy the app to /Applications (owned by the user so the setup
-- script can de-quarantine it without sudo), copy the bundled setup script out,
-- then unmount. Needs admin rights to write to /Applications.
on installFrom(dmgPath, theUser)
	set mountPoint to "/tmp/sandshell-install"
	set sh to "set -e; MP=" & quoted form of mountPoint & "; U=" & quoted form of theUser & "; " & ¬
		"hdiutil detach \"$MP\" >/dev/null 2>&1 || true; " & ¬
		"hdiutil attach " & quoted form of dmgPath & " -nobrowse -noverify -mountpoint \"$MP\" >/dev/null; " & ¬
		"APP=$(ls -d \"$MP\"/*.app | head -1); " & ¬
		"if [ -z \"$APP\" ]; then hdiutil detach \"$MP\" >/dev/null 2>&1; echo 'No app found in the disk image.' >&2; exit 1; fi; " & ¬
		"rm -rf " & quoted form of installedApp & "; " & ¬
		"ditto \"$APP\" " & quoted form of installedApp & "; " & ¬
		"chown -R \"$U\" " & quoted form of installedApp & "; " & ¬
		"SETUP=$(ls \"$MP\"/*.command 2>/dev/null | head -1); " & ¬
		"if [ -n \"$SETUP\" ]; then cp \"$SETUP\" " & quoted form of setupTmp & "; chown \"$U\" " & quoted form of setupTmp & "; chmod +x " & quoted form of setupTmp & "; xattr -dr com.apple.quarantine " & quoted form of setupTmp & " 2>/dev/null || true; fi; " & ¬
		"hdiutil detach \"$MP\" >/dev/null 2>&1 || true"
	do shell script sh with administrator privileges
end installFrom

-- Run the bundled setup script in a visible Terminal window.
on runSetupInTerminal()
	do shell script "test -f " & quoted form of setupTmp
	tell application "Terminal"
		activate
		do script quoted form of setupTmp
	end tell
end runSetupInTerminal
