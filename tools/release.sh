#!/bin/zsh
# Build a signed, notarized DMG with WinSwitch, Notepad, Notepad++ and MS Paint and (with --publish) attach it to a
# GitHub release.
#
#   tools/release.sh             # build/WinSwitch-<version>.dmg
#   tools/release.sh --publish   # also create the GitHub release v<version>
#
# Needs:
#   - a "Developer ID Application" certificate in the keychain, named in WINSWITCH_RELEASE_IDENTITY or an untracked
#     .release-identity file (e.g. "Developer ID Application: Your Name (ABCDE12345)");
#   - an App Store Connect API key for notarization: a JSON file with keyId, issuerId and keyPath (path to the .p8),
#     in WINSWITCH_NOTARY_CONFIG (default ~/.appstoreconnect/config.json);
#   - the gh command line tool, signed in, for --publish.
# The version comes from CFBundleShortVersionString in Resources/Info.plist.
set -euo pipefail
cd "${0:A:h}/.."

# A published release must be the code its tag points at: refuse uncommitted changes, and tag the commit built.
if [[ "${1:-}" == "--publish" ]]; then
  git diff --quiet HEAD -- || { echo "Uncommitted changes: commit and push before publishing" >&2; exit 1; }
  COMMIT="$(git rev-parse HEAD)"
fi

IDENTITY="${WINSWITCH_RELEASE_IDENTITY:-}"
[[ -z "$IDENTITY" && -f .release-identity ]] && IDENTITY="$(<.release-identity)"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID identity: set WINSWITCH_RELEASE_IDENTITY or create .release-identity" >&2; exit 1; }

NOTARY_CONFIG="${WINSWITCH_NOTARY_CONFIG:-$HOME/.appstoreconnect/config.json}"
field() { plutil -extract "$1" raw -o - "$NOTARY_CONFIG"; }
KEY_ID="$(field keyId)"; ISSUER="$(field issuerId)"; KEY_PATH="$(field keyPath)"; KEY_PATH="${KEY_PATH/#\~/$HOME}"
notarize() {
  xcrun notarytool submit "$1" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" --wait --timeout 30m
  xcrun stapler staple "$2"
}

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
APPS=(build/WinSwitch.app build/Notepad.app build/Notepad++.app "build/MS Paint.app")
DMG="build/WinSwitch-$VERSION.dmg"

# 1. Build universal apps (Apple silicon and Intel) and sign them with the Developer ID, hardened runtime and a secure
#    timestamp (notarization needs both).
WINSWITCH_UNIVERSAL=1 WINSWITCH_SIGN_TIMESTAMP=1 WINSWITCH_SIGN_IDENTITY="$IDENTITY" ./build.sh
for APP in "${APPS[@]}"; do codesign --verify --strict --deep "$APP"; done

# 2. Notarize the apps in one submission and staple each ticket, so they open offline too.
NOTARIZE_DIR="$(mktemp -d)"
cp -R "${APPS[@]}" "$NOTARIZE_DIR/"
ditto -c -k "$NOTARIZE_DIR" build/WinSwitch-notarize.zip
rm -rf "$NOTARIZE_DIR"
xcrun notarytool submit build/WinSwitch-notarize.zip --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" --wait --timeout 30m
for APP in "${APPS[@]}"; do xcrun stapler staple "$APP"; done
rm build/WinSwitch-notarize.zip

# 3. A drag-to-Applications disk image, signed and notarized as well.
STAGE="$(mktemp -d)"
cp -R "${APPS[@]}" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "WinSwitch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG" "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Built $DMG"

if [[ "${1:-}" == "--publish" ]]; then
  # Release notes: docs/release-notes/<version>.md if it exists, else a short install note.
  NOTES="docs/release-notes/$VERSION.md"
  if [[ -f "$NOTES" ]]; then
    gh release create "v$VERSION" "$DMG" --target "$COMMIT" --title "WinSwitch $VERSION" --notes-file "$NOTES"
  else
    gh release create "v$VERSION" "$DMG" --target "$COMMIT" --title "WinSwitch $VERSION" --notes "Download **WinSwitch-$VERSION.dmg**, open it and drag the apps to Applications. Then allow the permissions described in the [README](https://github.com/kamrat11/WinSwitch#permissions)."
  fi
fi
