# Releasing Wicket

Wicket ships as a notarized DMG on GitHub Releases, updates itself with Sparkle, and installs with Homebrew from the `pietz/homebrew-wicket` tap. `Scripts/release.sh` does everything up to publishing and prints the publishing commands; nothing goes out until you run them.

## Editions

- **Wicket** (`app.wicket.Wicket`): the released app. `Scripts/build-app.sh --release` builds it, signed with the Developer ID Application certificate of team 34MWWCL4H2, hardened runtime and secure timestamps. Only `release.sh` should need it.
- **Wicket Dev** (`app.wicket.Wicket.dev`): every local build, `Scripts/build-app.sh` (or `debug`), into `build/Wicket Dev.app`. It has a DEV badge on its icon, ⌃⌥Space as its default hotkey, `~/.config/wicket-dev` as its folder and no updater, so it runs next to an installed Wicket without touching it. `Edition` in the app decides all of this from the bundle id.

## One-time setup

1. **Notarization credentials.** Create an app-specific password at account.apple.com, then store it in the keychain under the profile the script uses:

   ```sh
   xcrun notarytool store-credentials wicket-notary --apple-id <apple id> --team-id 34MWWCL4H2
   ```

2. **Sparkle signing key.** Generate Wicket's own EdDSA key (kept in the login keychain under the account `wicket`, separate from any other app's), then put the public key it prints into `SUPublicEDKey` in `Resources/Info.plist`, and commit that:

   ```sh
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account wicket
   ```

   Back the private key up into the owner's password manager as a secure attachment named **Wicket Sparkle EdDSA private key**, with the account `wicket` and public key noted beside it. Export with `generate_keys --account wicket -x <private path outside the checkout>`, using a private folder with restricted permissions. Never commit the export or put it in a release asset. Keep any existing export until the owner confirms the backup, then remove the loose copy. The signing copy stays in the login keychain; `release.sh` reads it with `sign_update --account wicket`. Losing it means installed copies can never update again.

3. **Repositories.** The source repo `pietz/wicket` must be public: the DMG is a release asset and the appcast is read from `main`. Create the tap `pietz/homebrew-wicket` with one folder, `Casks/`, and check it out next to this repo (`../homebrew-wicket`).

## Cutting a release

Run `Scripts/check.sh` first, from a clean working tree: the script refuses to start when `git status` shows any change, tracked or untracked, since it builds the working tree but the tag holds only the commit. Signing and notarization need the owner's unlocked macOS login session and accessible login keychain; do not start a release while the session is locked or from an unattended locked-session run. Unlock and retry from that session if Keychain access stalls. On a Mac where the Sparkle key was imported (`generate_keys --account wicket -f <file>`) and not created, the first `sign_update` waits on a Keychain dialog on that Mac's screen: answer it with Always Allow once, or the release stops after notarization. To sign without the keychain, as on a headless release Mac, export the key to a private file (`generate_keys --account wicket -x <file>` in a folder only you can read, outside the checkout) and run `SPARKLE_KEY_FILE=<file> Scripts/release.sh <version>`, which passes it to `sign_update --ed-key-file`; delete the file afterwards. Unset, the script signs from the keychain as before. `WICKET_SIGN_IDENTITY` can override the identity used by `build-app.sh`; `release.sh` still selects the team's Developer ID identity to sign the DMG.

```sh
Scripts/release.sh <version>
```

It:

1. sets `CFBundleShortVersionString` to the version and `CFBundleVersion` to one past the newest build in `appcast.xml` (1 for the first release) in `Resources/Info.plist`;
2. builds and signs Wicket (`build-app.sh --release`);
3. makes `build/Wicket-<version>.dmg` (the app and an Applications link) and signs it;
4. notarizes it with `notarytool` (profile `wicket-notary`, a few minutes) and staples the ticket;
5. signs it for Sparkle with the `wicket` key and adds an item to `appcast.xml`;
6. writes the version and checksum into `Casks/wicket.rb`;
7. prints the publishing commands: commit, tag, push the tag, `gh release create` with the DMG, push `main` (the appcast goes live last, once the DMG exists), and copy the cask to the tap.

If notarization fails, the script stops before touching the appcast or cask; `git checkout Resources/Info.plist` undoes the version bump. Release notes are GitHub's (`--generate-notes`); edit them on the release page. Sparkle shows the release page from its update window.

## After publishing

The cask declares `auto_updates`, so Homebrew leaves updates to Sparkle; copy the new `Casks/wicket.rb` to the tap so new installs get this version. Then, on a Mac with the previous release installed, and once on a fresh account:

1. **Check for Updates…** offers the new version and installs it; Wicket relaunches with its settings, microphone grant and login item intact.
2. `brew install --cask pietz/wicket/wicket` on the fresh account installs it, and the first launch shows the panel.
3. In the signed release bundle: an agent answer renders (WebKit under the hardened runtime), voice listens, Sparkle's update window opens, and Launch at login survives a log out and in.

## What a build contains

`build-app.sh` copies the executable, SwiftPM's `Wicket_WicketApp.bundle` (agent instructions, answer stylesheet, bridge, extension contract and the web-search, currency, quicklinks and agenda examples; found through `Bundle.wicket` in `Contents/Resources`, with `Bundle.module` as the fallback for `swift run` and tests), the four bundled extensions in `Contents/Resources/Extensions/<name>` (each with `wicket.json`, `main`, `main.swift` and `JSON.swift`) and `Sparkle.framework`. SwiftPM links the executable against Sparkle at an absolute `.build` path, so the script removes absolute rpaths and adds `@executable_path/../Frameworks`. Signing goes inside out, never `--deep`: the extension binaries, Sparkle's `Installer.xpc`, `Downloader.xpc` (keeping its own entitlements), `Autoupdate` and `Updater.app`, then the framework, then the app with `Resources/Wicket.entitlements` (audio input only). Info.plist holds the microphone usage string, the `wicket://` URL type (Wicket Dev gets `wicket-dev://`) and, for the release edition, `SUFeedURL`, `SUPublicEDKey` and `SUEnableAutomaticChecks`; Wicket Dev gets another bundle id and name and loses the three Sparkle keys. `release.sh` bumps only `CFBundleShortVersionString` and `CFBundleVersion`.

To check a bundle without launching it: `codesign --verify --deep --strict --verbose=2 build/Wicket.app`, `otool -l build/Wicket.app/Contents/MacOS/Wicket` (no absolute `LC_RPATH`), and run its executable in headless mode against a throwaway folder, for example `WICKET_CONFIG_DIR=$(mktemp -d) build/Wicket.app/Contents/MacOS/Wicket --query '1+1'`, which proves dyld finds Sparkle and the bundle starts; its output shows whether the calculator answered. `release.sh` runs this with `.build` unreadable and checks only the exit status, so a bundle that still needs the checkout stops the release.

Keep the bundle id, team, feed URL and Sparkle key unchanged: they are what lets every installed copy, back to 0.0.x, update.
