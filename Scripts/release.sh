#!/bin/zsh
# Cuts a release: bumps the version, builds and signs Wicket, makes a notarized, stapled DMG, signs
# it for Sparkle, adds it to appcast.xml and the cask, then prints the commands that publish it.
# It publishes nothing itself. One-time setup and the full sequence: docs/release.md.
#   Scripts/release.sh <version>
set -euo pipefail
cd "${0:A:h}/.."

version="${1:?usage: Scripts/release.sh <version, like 0.0.2>}"
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must look like 0.0.2" >&2; exit 2; }
sparkle_bin=.build/artifacts/sparkle/Sparkle/bin
repo=https://github.com/pietz/wicket
dmg="build/Wicket-$version.dmg"
# SPARKLE_KEY_FILE: the Sparkle private key exported to a private file (docs/release.md), signed with
# instead of the login keychain, whose access dialog otherwise waits on the release Mac's screen.
key_file=${SPARKLE_KEY_FILE:-}
[[ -z $key_file || -r $key_file ]] || { echo "SPARKLE_KEY_FILE is not a readable file: $key_file" >&2; exit 2; }
url="$repo/releases/download/v$version/Wicket-$version.dmg"

# The build is of the working tree and the tag of the commit: any change, tracked or untracked, would be
# shipped without being in the tag.
if [[ -n $(git status --porcelain --untracked-files=all) ]]; then
  echo "the working tree has uncommitted or untracked changes; commit or remove them first" >&2; exit 1
fi
if grep -q "<sparkle:shortVersionString>$version<" appcast.xml; then
  echo "$version is already in appcast.xml" >&2; exit 1
fi
if grep -q REPLACE_WITH_SPARKLE_PUBLIC_KEY Resources/Info.plist; then
  echo "SUPublicEDKey in Resources/Info.plist is still the placeholder (docs/release.md)" >&2; exit 1
fi

# The build number Sparkle compares: one past the newest in the appcast, 1 for the first release.
last=$(grep -o '<sparkle:version>[0-9]*' appcast.xml | grep -o '[0-9]*$' | sort -n | tail -1 || true)
build=$(( ${last:-0} + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
  -c "Set :CFBundleVersion $build" Resources/Info.plist
echo "== Wicket $version ($build)"

Scripts/build-app.sh --release
# The app must run without this checkout, so start it headless with the build folder unreadable; only
# the exit status counts.
(
  check=$(mktemp -d)
  trap 'rm -rf "$check"' EXIT
  WICKET_CONFIG_DIR="$check/config" sandbox-exec -p "(version 1)(allow default)(deny file-read* (subpath \"$PWD/.build\"))" \
    build/Wicket.app/Contents/MacOS/Wicket --query 1+1 >/dev/null || {
    echo "build/Wicket.app does not run without .build" >&2; exit 1
  }
)
identity=$(security find-identity -v -p codesigning | awk '/Developer ID Application:.*34MWWCL4H2/ {print $2; exit}')  # by hash: names with non-ASCII letters don't round-trip

# A plain drag-to-Applications disk image: the app and a link to /Applications.
stage=$(mktemp -d)
ditto build/Wicket.app "$stage/Wicket.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
diskutil image create from --format ULFO --volumeName Wicket "$stage" "$dmg" >/dev/null
rm -rf "$stage"
codesign --force --sign "$identity" --timestamp "$dmg"

echo "== notarizing (a few minutes)"
xcrun notarytool submit "$dmg" --keychain-profile wicket-notary --wait | tee build/notary.log
grep -q "status: Accepted" build/notary.log || {
  echo "notarization failed; see: xcrun notarytool log <id> --keychain-profile wicket-notary" >&2; exit 1
}
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"

# Sparkle's EdDSA signature, from the "wicket" key in the login keychain or SPARKLE_KEY_FILE.
if [[ -n $key_file ]]; then signing=(--ed-key-file "$key_file"); else signing=(--account wicket); fi
enclosure=$("$sparkle_bin/sign_update" "${signing[@]}" "$dmg")
item="    <item>
      <title>Wicket $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$repo/releases/tag/v$version</sparkle:fullReleaseNotesLink>
      <enclosure url=\"$url\" type=\"application/octet-stream\" $enclosure/>
    </item>"
feed=$(<appcast.xml)
marker="    <!-- releases -->"
print -r -- "${feed/"$marker"/$marker
$item}" > appcast.xml
xmllint --noout appcast.xml

sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" \
  -e "s/^  sha256 .*/  sha256 \"$sha\"/" Casks/wicket.rb

cat <<EOF

Built, notarized and stapled: $dmg
Updated Resources/Info.plist ($version, build $build), appcast.xml and Casks/wicket.rb.
Nothing is published yet. To publish, in this order (the appcast goes live last, once the DMG exists):

  git add Resources/Info.plist appcast.xml Casks/wicket.rb
  git commit -m "Release $version"
  git tag v$version
  git push origin v$version
  gh release create v$version "$dmg" --verify-tag --prerelease --title "Wicket $version" --generate-notes
  git push origin main
  cp Casks/wicket.rb ../homebrew-wicket/Casks/wicket.rb
  git -C ../homebrew-wicket commit -am "wicket $version" && git -C ../homebrew-wicket push
EOF
