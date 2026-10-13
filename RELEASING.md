# Releasing Sandshell

Sandshell ships as an unsigned `.dmg` in the docker.com-shared Google Drive
folder, and auto-updates itself from that same folder via the in-app updater
(`Sandshell/Update/Updater.swift`).

Drive releases folder:
<https://drive.google.com/drive/folders/1TDO_iVfaobA3tYiF8JM_1NA_DBpEANjl>

## First-install setup

The DMG ships **`Sandshell Setup.command`** alongside the app (added by
`make-dmg.sh` from `scripts/sandshell-setup.command`). After dragging Sandshell
to Applications, the user double-clicks it; in Terminal it:

1. removes the Gatekeeper quarantine from the (unsigned) app,
2. installs the sbx CLI — or updates it if Homebrew has a newer version,
   restarting the `sandboxd` daemon when sbx is upgraded,
3. runs `sbx login`, then launches Sandshell.

`scripts/sandshell-installer.applescript` is an optional one-click wrapper: it
downloads/locates the DMG, copies the app to /Applications, then opens that same
setup script in Terminal. Build it with `scripts/build-installer.sh` →
`dist/Sandshell Installer.app` (distribute zipped so the `.app` survives Drive
download). Both the installer and the setup script are unsigned, so the very
first thing the user runs needs right-click → Open once.

## Cut a release

```bash
# 1. Bump the version
#    project.yml → settings.base.MARKETING_VERSION, then: xcodegen generate

# 2. Build Release
xcodebuild -project Sandshell.xcodeproj -scheme Sandshell -configuration Release \
  -derivedDataPath build-release -destination 'platform=macOS,arch=arm64' build

# 3. Build the drag-to-Applications DMG  (→ dist/Sandshell-<version>.dmg)
scripts/make-dmg.sh build-release/Build/Products/Release/Sandshell.app <version> dist

# 4. Upload to the Drive releases folder (filename IS the version tag)
gws drive +upload dist/Sandshell-<version>.dmg \
  --parent 1TDO_iVfaobA3tYiF8JM_1NA_DBpEANjl --name Sandshell-<version>.dmg
```

The updater discovers releases by listing the folder for `Sandshell-*.dmg` and
picking the highest version, so **the filename's version is the source of
truth** — keep it in sync with `MARKETING_VERSION`.

## One-time: OAuth client for the updater

The Drive folder is docker.com-domain-restricted (public link-sharing is blocked
by org policy), so the updater signs the user in with Google OAuth (read-only
Drive scope) to read it. Create the client once:

1. Google Cloud Console → project **docker-ai-sandbox** → APIs & Services.
2. Enable the **Google Drive API**.
3. OAuth consent screen → **Internal** (docker.com), add scope
   `…/auth/drive.readonly`.
4. Credentials → Create Credentials → **OAuth client ID** → type **Desktop app**.
5. Copy the **Client ID** and **Client secret** into `Updater.swift`
   (`clientID` / `clientSecret`). Desktop clients support the loopback redirect
   the updater uses, so no redirect URIs need registering.

Until those are filled in, "Check for Updates…" reports that updates aren't
configured and the launch check is a no-op.

## Notes

- **Unsigned build.** No Developer ID is configured, so the app is ad-hoc
  signed. First launch needs right-click → Open (Gatekeeper). The updater strips
  `com.apple.quarantine` from the new bundle after download so the relaunch
  isn't blocked.
- The updater swaps `Bundle.main.bundleURL` in place (e.g.
  `/Applications/Sandshell.app`) via a detached script that waits for the app to
  quit, then relaunches.
