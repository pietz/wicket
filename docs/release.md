# Releasing Wicket

Wicket ships as a notarized DMG on GitHub Releases, updates via Sparkle, and installs via Homebrew from `pietz/homebrew-wicket`. `Scripts/release.sh` prepares everything locally and prints the publishing commands; nothing goes out until you run them.

## Editions

- **Wicket** (`app.wicket.Wicket`): release app built by `Scripts/build-app.sh --release`, signed with Developer ID Application (team `34MWWCL4H2`), hardened runtime, and secure timestamps.
- **Wicket Dev** (`app.wicket.Wicket.dev`): local build via `Scripts/build-app.sh` (or `debug`) into `build/Wicket Dev.app`. DEV icon badge, ⌃⌥Space default hotkey, `~/.config/wicket-dev`, `wicket-dev://` URL scheme, and no updater—runs beside an installed Wicket. `Edition` switches all of this from the bundle ID.

## One-time setup

1. **Notarization credentials.** Create an app-specific password at account.apple.com and store it under `wicket-notary`:

   ```sh
   xcrun notarytool store-credentials wicket-notary --apple-id <apple id> --team-id 34MWWCL4H2
   ```

2. **Sparkle signing key.** Generate Wicket's EdDSA key in the login keychain under account `wicket`, commit its public key as `SUPublicEDKey` in `Resources/Info.plist`:

   ```sh
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account wicket
   ```

   Back up the private key in the owner's password manager as **Wicket Sparkle EdDSA private key** (noting account `wicket` and the public key). Export via `generate_keys --account wicket -x <private path outside checkout>` with restricted permissions, confirm backup, then delete the loose file. Never commit or ship the export. Losing this key breaks updates for all existing installs.

3. **Repositories.** Keep `pietz/wicket` public (release assets and `main`'s `appcast.xml`). Keep `pietz/homebrew-wicket` (containing `Casks/`) checked out at `../homebrew-wicket`.

## Cutting a release

Run `Scripts/check.sh` on a clean working tree (`release.sh` refuses tracked or untracked changes). Signing and notarization require an unlocked macOS login session and login keychain—do not start a release while the session is locked or from an unattended run; unlock and retry if Keychain access stalls. If the Sparkle key was imported (`-f`) rather than generated locally, the first `sign_update` prompts in the UI—click **Always Allow** once, or the release stops after notarization. To sign without the keychain (e.g. headless Mac), export to a private file outside the checkout, run `SPARKLE_KEY_FILE=<file> Scripts/release.sh <version>` (uses `sign_update --ed-key-file`), and delete the file afterward. `WICKET_SIGN_IDENTITY` overrides the identity for `build-app.sh`; `release.sh` always signs the DMG with the team's Developer ID.

```sh
Scripts/release.sh <version>
```

The script:
1. Sets `CFBundleShortVersionString` to `<version>` and increments `CFBundleVersion` past the newest build in `appcast.xml` in `Resources/Info.plist`.
2. Runs `Scripts/build-app.sh --release` and verifies the bundle starts headlessly with `.build` unreadable.
3. Creates and signs `build/Wicket-<version>.dmg` (app + `/Applications` symlink).
4. Notarizes (`notarytool` profile `wicket-notary`), staples, and assesses with `spctl`.
5. Signs for Sparkle (`wicket` key) and prepends the item to `appcast.xml`.
6. Updates version and SHA-256 in `Casks/wicket.rb`.
7. Prints the publish commands: commit, tag, push tag, `gh release create` with DMG, push `main` (last, so the appcast goes live after the DMG), and copy/push the cask to `../homebrew-wicket`.

If notarization fails, `appcast.xml` and `Casks/wicket.rb` stay untouched; revert `Resources/Info.plist` with `git checkout Resources/Info.plist`. Edit GitHub's `--generate-notes` release notes on the release page (which Sparkle displays).

## After publishing

The cask sets `auto_updates true`, so Homebrew hands updates to Sparkle; push `Casks/wicket.rb` to the tap for new installs. Verify on an existing install and a fresh macOS account:

1. **Check for Updates…** installs the update and relaunches with settings, microphone grant, and login item intact.
2. `brew install --cask pietz/wicket/wicket` installs cleanly and opens the panel on first launch.
3. Under hardened runtime: agent answers render, voice listens, Sparkle's update window opens, and Launch at login survives logout/login.

## What a build contains

`build-app.sh` copies:
- `Contents/MacOS/Wicket` and `Contents/MacOS/wicket-js`
- `Contents/Resources/Wicket_WicketApp.bundle` (instructions, CSS, bridge, contract, examples; resolved by `Bundle.wicket` with `Bundle.module` fallback for `swift run`/tests)
- `Contents/Resources/Extensions/<name>/` (`wicket.json`, `main`, Swift sources)
- `Contents/Frameworks/Sparkle.framework`

It strips absolute `.build` `LC_RPATH` entries from `Wicket` and adds `@executable_path/../Frameworks`. Signing runs inside out (never `--deep`): extension `main` binaries, `wicket-js`, Sparkle's `Installer.xpc`, `Downloader.xpc` (`--preserve-metadata=entitlements`), `Autoupdate`, `Updater.app`, `Sparkle.framework`, then the app with `Resources/Wicket.entitlements` (audio input + calendars). `Info.plist` carries microphone/calendar usage strings, URL scheme (`wicket://` vs `wicket-dev://`), and Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`—dropped in Dev).

Non-launching bundle checks:
- `codesign --verify --deep --strict --verbose=2 build/Wicket.app`
- `otool -l build/Wicket.app/Contents/MacOS/Wicket` (no absolute `LC_RPATH`)
- `WICKET_CONFIG_DIR=$(mktemp -d) build/Wicket.app/Contents/MacOS/Wicket --query '1+1'`

Never change the bundle ID, team ID, feed URL, or Sparkle key—existing installs back to 0.0.x rely on them to update.
