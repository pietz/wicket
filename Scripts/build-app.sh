#!/bin/zsh
# Builds Wicket as an app bundle from the SwiftPM package, with the SwiftPM resource bundle in
# Contents/Resources and Sparkle in Contents/Frameworks.
#   Scripts/build-app.sh             Wicket Dev, release config: build/Wicket Dev.app
#   Scripts/build-app.sh debug       Wicket Dev, debug config
#   Scripts/build-app.sh --release   Wicket, Developer ID, for Scripts/release.sh: build/Wicket.app
# Wicket Dev (app.wicket.Wicket.dev) runs beside the released app: its own config folder, ⌃⌥Space
# and no updates (Edition), and the wicket-dev:// URL scheme where the release has wicket://. It signs
# with the first "Apple Development" identity if present (a stable identity keeps TCC grants, like
# Accessibility, across rebuilds), otherwise ad hoc. Override the identity with WICKET_SIGN_IDENTITY.
# Building never launches the app.
set -euo pipefail
cd "${0:A:h}/.."

edition=dev config=release
case "${1:-}" in
  --release) edition=release ;;
  debug) config=debug ;;
  "") ;;
  *) echo "usage: Scripts/build-app.sh [debug | --release]" >&2; exit 2 ;;
esac

swift build -c "$config" --product Wicket -Xswiftc -warnings-as-errors
bin="$(swift build -c "$config" --show-bin-path)"

if [[ $edition == release ]]; then
  app="build/Wicket.app"
  identity="${WICKET_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application: .*\(34MWWCL4H2\)/ {print $2; exit}')}"
  [[ -n $identity ]] || { echo "no Developer ID Application identity for team 34MWWCL4H2" >&2; exit 1; }
  timestamp=(--timestamp)
else
  app="build/Wicket Dev.app"
  identity="${WICKET_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ {print $2; exit}')}"
  identity="${identity:--}"
  timestamp=()
fi
# Hardened runtime, except ad hoc: there its library validation refuses the embedded Sparkle.
runtime=(--options runtime)
[[ $identity == - ]] && runtime=()

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/Wicket" "$app/Contents/MacOS/Wicket"
# Wicket's own resources, found through Bundle.module. Not "*.bundle": a stale .build can hold the
# test targets' bundles of an earlier layout.
ditto "$bin/Wicket_WicketApp.bundle" "$app/Contents/Resources/Wicket_WicketApp.bundle"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$app/Contents/Info.plist"

# SwiftPM links the executable against Sparkle at an absolute .build path; point it at the bundle.
exe="$app/Contents/MacOS/Wicket"
for rpath in $(otool -l "$exe" | awk '/LC_RPATH/ {getline; getline; print $2}' | grep '^/'); do
  install_name_tool -delete_rpath "$rpath" "$exe"
done
install_name_tool -add_rpath @executable_path/../Frameworks "$exe" 2>/dev/null

plist="$app/Contents/Info.plist"
if [[ $edition == release ]]; then
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
else
  cp Resources/AppIcon-Dev.icns "$app/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.wicket.Wicket.dev" \
    -c "Set :CFBundleName Wicket Dev" -c "Set :CFBundleDisplayName Wicket Dev" \
    -c "Set :CFBundleURLTypes:0:CFBundleURLName app.wicket.Wicket.dev" \
    -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 wicket-dev" \
    -c "Delete :SUFeedURL" -c "Delete :SUPublicEDKey" -c "Delete :SUEnableAutomaticChecks" "$plist"
fi

# Inside out, never --deep: Sparkle's helpers (as Sparkle's docs list them), the framework, then
# the app. Downloader.xpc keeps its own entitlements.
sign() { codesign --force --sign "$identity" $runtime $timestamp "$@" >/dev/null; }
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
# Audio input: the hardened runtime blocks the microphone without it (voice input).
sign --entitlements Resources/Wicket.entitlements "$app"
echo "built $app ($config, signed: $identity)"
