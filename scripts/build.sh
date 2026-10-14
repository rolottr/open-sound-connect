#!/bin/zsh
# Builds "Sound Connect.app" with SwiftPM.
#   scripts/build.sh            release build into build/Sound Connect.app
#   CONFIG=debug scripts/build.sh
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=${CONFIG:-release}
case "$CONFIG" in
  release|debug) ;;
  *) echo "CONFIG must be release or debug" >&2; exit 2 ;;
esac
BUNDLE_ID=dev.rolottr.SoundConnect
APP="$ROOT/build/Sound Connect.app"
cd "$ROOT"

# Use the selected toolchain without changing global developer settings.
# The macOS 27 SDK declares SwiftUI's @State as a compiler macro whose plugin ships only inside Xcode, so the
# Command Line Tools cannot expand it. Build against the newest CLT macOS 26 SDK (plain property wrappers);
# the app still targets macOS 15+ and runs natively on macOS 27. Override with SDKROOT=... if needed.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools ]]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    if [[ -d "$candidate" ]]; then export SDKROOT="$candidate"; break; fi
  done
fi
export SDKROOT=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
echo "==> swift build ($CONFIG) with SDK ${SDKROOT:-default}"
swift build -c "$CONFIG" --product SoundConnect
swift build -c "$CONFIG" --product SoundConnectArtwork
BIN=$(swift build -c "$CONFIG" --show-bin-path)
echo "==> Local Now Playing helper"
"$ROOT/scripts/build-mediaremote.sh"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SoundConnect" "$APP/Contents/MacOS/Sound Connect"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
BUILD_NUMBER=$(date +%Y%m%d%H%M)
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Artwork/ATTRIBUTION.md" "$APP/Contents/Resources/ArtworkAttribution.md"
cp "$ROOT/Resources/Models/WH-1000XM4.usdz" "$APP/Contents/Resources/"
cp "$ROOT/Resources/Models/WH-1000XM4.png" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
mkdir -p "$APP/Contents/Frameworks"
ditto "$ROOT/build/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$ROOT/Vendor/MediaRemoteAdapter/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp "$ROOT/Vendor/MediaRemoteAdapter/LICENSE" "$APP/Contents/Resources/MediaRemoteAdapter-LICENSE"

echo "==> App icon"
"$BIN/SoundConnectArtwork" icon "$ROOT/Resources/Artwork/AppIconSource.png" "$ROOT/build/AppIcon.iconset"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing (identifier-based designated requirement keeps the Bluetooth grant across rebuilds)"
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP"
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

echo "==> Built $APP ($BUILD_NUMBER)"
