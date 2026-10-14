#!/bin/zsh
# Installs build/Sound Connect.app into ~/Applications and launches it (Dock + menu bar).
#   scripts/install.sh                      install the existing build (builds if missing)
#   scripts/install.sh --build              build first
#   scripts/install.sh --pin-dock           also keep it in the Dock (one entry, never duplicated)
set -euo pipefail

ROOT=${0:A:h:h}
SOURCE="$ROOT/build/Sound Connect.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Sound Connect.app"
BUILD=0
PIN=0
for arg in "$@"; do
  case "$arg" in
    --build) BUILD=1 ;;
    --pin-dock) PIN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if (( BUILD )) || [[ ! -d "$SOURCE" ]]; then
  "$ROOT/scripts/build.sh"
fi

mkdir -p "$DEST_DIR"
# Stop only the installed copy (other copies, e.g. a replay session from build/, are left alone).
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then
  echo "==> Quitting the running installed copy"
  pkill -TERM -f "$DEST/Contents/MacOS/" || true
  for _ in {1..20}; do pgrep -f "$DEST/Contents/MacOS/" >/dev/null || break; sleep 0.25; done
fi

echo "==> Installing to $DEST"
rm -rf "$DEST"
ditto "$SOURCE" "$DEST"
codesign --verify --strict "$DEST"
# Make Launch Services (Dock, Spotlight, Open With) pick up the new copy and its icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

if (( PIN )); then
  ENCODED="file://${DEST// /%20}/"
  if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "Applications/Sound%20Connect.app"; then
    echo "==> Already in the Dock"
  else
    echo "==> Adding to the Dock"
    defaults write com.apple.dock persistent-apps -array-add \
      "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$ENCODED</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
    killall Dock
  fi
fi

echo "==> Launching"
open "$DEST"
