#!/bin/zsh
# Build the apps, sign them and (with --install) install them to ~/Applications.
#
#   ./build.sh                      # all apps: WinSwitch, WinPad (Notepad), WinCode (Notepad++), WinPaint (MS Paint)
#   ./build.sh --install            # build, install and relaunch WinSwitch
#   ./build.sh --install WinPaint   # only the apps named (by target name)
set -euo pipefail
cd "${0:A:h}"

INSTALL=
[[ "${1:-}" == "--install" ]] && { INSTALL=1; shift; }
APPS=("$@")
(( ${#APPS} )) || APPS=(WinSwitch WinPad WinCode WinPaint)

# WINSWITCH_UNIVERSAL=1 (set by tools/release.sh) builds for Apple silicon and Intel; day-to-day builds are native only.
ARCHS=()
[[ -n "${WINSWITCH_UNIVERSAL:-}" ]] && ARCHS=(--arch arm64 --arch x86_64)
for NAME in "${APPS[@]}"; do swift build -c release "${ARCHS[@]}" --product "$NAME"; done
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

# Signing with a real certificate keeps the Accessibility, Input Monitoring and Screen Recording approvals across
# rebuilds. Name it in WINSWITCH_SIGN_IDENTITY or in an untracked .sign-identity file, e.g.
# "Apple Development: you@example.com (ABCDE12345)". Without one the app is signed ad hoc, and macOS asks for the
# permissions again after each build. WINSWITCH_SIGN_TIMESTAMP=1 (set by tools/release.sh) adds the secure timestamp
# notarization needs.
IDENTITY="${WINSWITCH_SIGN_IDENTITY:-}"
[[ -z "$IDENTITY" && -f .sign-identity ]] && IDENTITY="$(<.sign-identity)"
IDENTITY="${IDENTITY:--}"

# The app names people see; the targets keep short code names (a Swift target can't be called "Notepad++").
bundle_name() {
  case "$1" in
    WinPad) echo "Notepad" ;;
    WinCode) echo "Notepad++" ;;
    WinPaint) echo "MS Paint" ;;
    *) echo "$1" ;;
  esac
}

for NAME in "${APPS[@]}"; do
  APP="build/$(bundle_name "$NAME").app"
  RES=Resources
  [[ "$NAME" != WinSwitch ]] && RES="Resources/$NAME"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"
  cp "$RES/Info.plist" "$APP/Contents/Info.plist"
  find "$RES" -maxdepth 1 -type f ! -name Info.plist ! -name '*.entitlements' -exec cp {} "$APP/Contents/Resources/" \;
  ENTITLEMENTS=()
  [[ -f "$RES/$NAME.entitlements" ]] && ENTITLEMENTS=(--entitlements "$RES/$NAME.entitlements")
  codesign --force --options runtime ${WINSWITCH_SIGN_TIMESTAMP:+--timestamp} "${ENTITLEMENTS[@]}" --sign "$IDENTITY" "$APP"
done

if [[ -n "$INSTALL" ]]; then
  mkdir -p ~/Applications
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  for NAME in "${APPS[@]}"; do
    BUNDLE="$(bundle_name "$NAME").app"
    osascript -e "quit app id \"com.kamrat.$NAME\"" 2>/dev/null || true
    sleep 1
    pkill -x "$NAME" 2>/dev/null || true
    # Builds before the rename installed the app under its code name.
    if [[ "$BUNDLE" != "$NAME.app" && -d ~/Applications/"$NAME.app" ]]; then
      $LSREGISTER -u ~/Applications/"$NAME.app" 2>/dev/null || true
      rm -rf ~/Applications/"$NAME.app"
    fi
    rm -rf ~/Applications/"$BUNDLE"
    cp -R "build/$BUNDLE" ~/Applications/"$BUNDLE"
    # Register the document types so the app shows in Finder's Open With.
    $LSREGISTER -f ~/Applications/"$BUNDLE"
    echo "Installed ~/Applications/$BUNDLE"
  done
  [[ " ${APPS[*]} " == *" WinSwitch "* ]] && open ~/Applications/WinSwitch.app
fi
true
