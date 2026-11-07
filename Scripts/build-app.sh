#!/bin/zsh
# Builds build/Wicket.app from the SwiftPM package, with the `wicket` tool in Contents/Helpers
# (Contents/MacOS/wicket would collide with Contents/MacOS/Wicket on a case-insensitive volume).
#   Scripts/build-app.sh            release build
#   Scripts/build-app.sh debug      debug build
# Signs with the first "Apple Development" identity if present (a stable identity keeps TCC grants,
# like Accessibility, across rebuilds), otherwise ad hoc. Override with WICKET_SIGN_IDENTITY.
set -euo pipefail
cd "${0:A:h}/.."

config="${1:-release}"
swift build -c "$config" --product Wicket
swift build -c "$config" --product WicketCLI
bin="$(swift build -c "$config" --show-bin-path)"

app="build/Wicket.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/Wicket" "$app/Contents/MacOS/Wicket"
cp "$bin/WicketCLI" "$app/Contents/Helpers/wicket"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# The extension guide, which Make a Command hands the agent (BuildPrompt.bundledGuide).
cp docs/extensions.md "$app/Contents/Resources/extensions.md"

identity="${WICKET_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${identity:--}" --options runtime "$app/Contents/Helpers/wicket" >/dev/null
codesign --force --sign "${identity:--}" --options runtime "$app" >/dev/null
echo "built $app ($config, signed: ${identity:-ad hoc})"
