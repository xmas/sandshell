-- Smoke test: the app launches and its 'stat' Apple Event hook round-trips
-- valid JSON. This is the cheapest possible signal that a build isn't
-- completely broken (crash on launch, hung main thread, AE handlers not
-- registered) and should run first in every release-test pass.

-- argv: {bundleID}
on run argv
	set bundleID to item 1 of argv
	set thisDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set Helpers to load script POSIX file (thisDir & "/lib/Helpers.applescript")

	tell Helpers to waitUntilRunning(bundleID, 20)
	set statusJSON to Helpers's shllStatus(bundleID)
	set winCount to Helpers's jsonGet(statusJSON, "d['windowCount']")
	if (winCount as integer) < 1 then error "expected windowCount >= 1, got " & winCount

	return "PASS: 00_launch_and_status — status Apple Event reported " & winCount & " window(s)"
end run
