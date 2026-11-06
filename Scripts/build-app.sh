#!/bin/zsh
# Builds build/Wicket.app from the SwiftPM package.
#   Scripts/build-app.sh            release build
#   Scripts/build-app.sh debug      debug build
# Signs with the first "Apple Development" identity if present (a stable identity keeps TCC grants,
# like Accessibility, across rebuilds), otherwise ad hoc. Override with WICKET_SIGN_IDENTITY.
set -euo pipefail
cd "${0:A:h}/.."

config="${1:-release}"
swift build -c "$config" --product Wicket
bin="$(swift build -c "$config" --show-bin-path)"

app="build/Wicket.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Wicket" "$app/Contents/MacOS/Wicket"
cp Resources/Info.plist "$app/Contents/Info.plist"

identity="${WICKET_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${identity:--}" --options runtime "$app" >/dev/null
echo "built $app ($config, signed: ${identity:-ad hoc})"
