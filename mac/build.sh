#!/bin/zsh
# Builds Orbit.app, the native Mac app, into mac/build/Orbit.app.
# It shows what the Orbit server on this Mac records, so the server needs to be running
# (scripts/service.sh status).  Usage:  mac/build.sh [--install]
# --install then moves it into /Applications (or ~/Applications if this account can't write there).
set -euo pipefail
cd "${0:A:h}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Orbit"

APP=build/Orbit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Orbit"
cp Info.plist "$APP/Contents/Info.plist"

# The app icon: draw it once, then make every size macOS wants.
if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift tools/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null  # signed for this Mac only
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST=/Applications
  [[ -w $DEST ]] || { DEST=$HOME/Applications; mkdir -p "$DEST"; }
  # A running copy would keep the old version open: quit it now and reopen it after.
  RUNNING=$(osascript -e 'application id "local.orbit.app" is running' 2>/dev/null || echo false)
  if [[ $RUNNING == true ]]; then
    osascript -e 'tell application id "local.orbit.app" to quit'
    for _ in {1..50}; do pgrep -qx Orbit || break; sleep 0.1; done
  fi
  rm -rf "$DEST/Orbit.app"
  mv "$APP" "$DEST/Orbit.app"  # moved, not copied, so Spotlight finds only one Orbit
  echo "Installed to $DEST/Orbit.app"
  if [[ $RUNNING == true ]]; then open "$DEST/Orbit.app"; fi
fi
