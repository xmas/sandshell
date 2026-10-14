# Releasing Sandshell

Sandshell ships through the Homebrew tap **`xmas/xmas`** (public repo
[xmas/homebrew-xmas](https://github.com/xmas/homebrew-xmas)). This repo is
private, so the DMGs live as release assets on the tap repo:

| What | Where |
|------|-------|
| Cask | `homebrew-xmas/Casks/sandshell.rb` |
| DMG  | `https://github.com/xmas/homebrew-xmas/releases/download/sandshell-v<version>/Sandshell-<version>.dmg` |
| Tag in the tap repo | `sandshell-v<version>` (namespaced — the tap also hosts the old Tauri app's `v<version>` releases) |
| Tag in this repo | `v<version>` |

Install / upgrade:

```bash
brew install --cask xmas/xmas/sandshell
brew upgrade --cask xmas/xmas/sandshell
```

The cask `depends_on cask: "docker/tap/sbx"`. Homebrew only auto-taps (and
trusts) taps named on the command line, so on a Mac that has never installed
sbx through Homebrew, name both: `brew install --cask docker/tap/sbx xmas/xmas/sandshell`.

## Cut a release

Prereqs: `xcodegen`, `gh` (authenticated, push access to xmas/homebrew-xmas),
and a clean clone of the tap next to this repo (`../homebrew-xmas`, override
with `SANDSHELL_TAP_DIR`), on `main` and up to date.

```bash
# 1. Write the CHANGELOG.md section "## v<version> — …" (it becomes the release notes).
# 2. Rehearse — real Release build + DMG, prints the cask diff and every publish command:
scripts/release.sh --dry-run 0.2.20
# 3. Ship:
scripts/release.sh 0.2.20
```

The real run:

1. **Preflight** — on `main`; working tree clean except `project.yml` /
   `CHANGELOG.md`; tag `v<version>` and release `sandshell-v<version>` unused;
   `gh` authenticated; tap clone present, on `main`, clean, level with
   `origin/main`, and its cask is the native-app cask.
2. Sets `MARKETING_VERSION` in `project.yml`, `xcodegen generate`, Release
   build (arm64) into `build-release/`, checks the built version.
3. `scripts/make-dmg.sh` → `dist/Sandshell-<version>.dmg`, then its sha256.
4. Publishes:
   ```bash
   git commit -m "Release <version>" -- project.yml [CHANGELOG.md]
   git tag -a v<version> -m "Sandshell <version>"
   gh release create sandshell-v<version> -R xmas/homebrew-xmas dist/Sandshell-<version>.dmg \
     --title "Sandshell <version>" --notes-file <CHANGELOG section>
   # tap clone: rewrite `version` + `sha256` in Casks/sandshell.rb
   git -C ../homebrew-xmas commit -m "sandshell <version>" -- Casks/sandshell.rb
   git -C ../homebrew-xmas push origin main
   git push origin main && git push origin v<version>
   ```

`--dry-run` never edits `project.yml` (it passes `MARKETING_VERSION=<version>`
to xcodebuild instead), the tap clone, or anything remote; preflight failures
are reported as warnings so you can rehearse on a dirty tree.

If a run fails before the commit step, `project.yml` is restored.

## In-app updates

`Sandshell/Update/Updater.swift` fetches
`raw.githubusercontent.com/xmas/homebrew-xmas/main/Casks/sandshell.rb` and
reads its `version`. When it's newer than the running build:

- **Installed with Homebrew** (a `Caskroom/sandshell` exists): offers to quit
  and run `brew update && brew upgrade --cask xmas/xmas/sandshell` in Terminal,
  then reopen; or copy that command.
- **Otherwise** (DMG install): downloads the DMG from the cask's `url`, swaps the
  bundle in place, strips the quarantine and relaunches.

The cask is the source of truth, so the app never announces a version
`brew upgrade` can't see. A cask whose `url` isn't a `sandshell-v…` tag (i.e.
the old Tauri cask) is ignored. GitHub's raw CDN can lag a push by a few minutes.

## DMG / first-install setup

The DMG ships **`Sandshell Setup.command`** alongside the app (added by
`make-dmg.sh` from `scripts/sandshell-setup.command`). After dragging Sandshell
to Applications, the user runs it in Terminal; it:

1. removes the Gatekeeper quarantine from the (unsigned) app,
2. installs the sbx CLI — or updates it if Homebrew has a newer version,
   restarting the `sandboxd` daemon when sbx is upgraded,
3. runs `sbx login`, links the `sandshell` CLI, then launches Sandshell.

The cask does the equivalent of step 1 (`postflight_steps` → `xattr -dr
com.apple.quarantine`) and links the CLI with a `binary` stanza
(`Sandshell.app/Contents/Resources/sandshell`); `sbx login` is left to the user
(see the cask caveats).

`scripts/sandshell-installer.applescript` is an optional one-click wrapper
(`scripts/build-installer.sh` → `dist/Sandshell Installer.app`).

## Notes

- **Unsigned build.** No Developer ID is configured, so the app is ad-hoc
  signed and not notarized. Current Homebrew (7.x) has no `--no-quarantine`, so
  the cask strips the quarantine itself. A homebrew/cask submission would be
  rejected for failing Gatekeeper; a third-party tap is fine.
- **Version scheme.** `brew outdated`/`brew upgrade` treat any cask version
  that differs from the installed one as an upgrade (it's an inequality check,
  not "greater than"), so moving the `sandshell` cask from the Tauri app's
  0.15.0 to the native 0.2.x line still upgrades existing installs. The in-app
  updater uses "greater than".
