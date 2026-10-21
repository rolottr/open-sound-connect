#!/bin/zsh
# Builds "Open Sound Connect.app" with SwiftPM.
#   scripts/build.sh            release build into build/Open Sound Connect.app
#   CONFIG=debug scripts/build.sh
#   ARCH=x86_64 scripts/build.sh     another architecture (default: this Mac's)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
#                                    Developer ID signature for releases (default: ad-hoc)
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=${CONFIG:-release}
ARCH=${ARCH:-$(uname -m)}
case "$CONFIG" in
  release|debug) ;;
  *) echo "CONFIG must be release or debug" >&2; exit 2 ;;
esac
BUNDLE_ID=dev.rolottr.SoundConnect
APP="$ROOT/build/Open Sound Connect.app"
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
echo "==> swift build ($CONFIG, $ARCH) with SDK ${SDKROOT:-default}"
swift build -c "$CONFIG" --arch "$ARCH" --product SoundConnect
BIN=$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)
# The icon renderer runs here during the build, so it is always built for this Mac.
swift build -c "$CONFIG" --product SoundConnectArtwork
TOOLS=$(swift build -c "$CONFIG" --show-bin-path)

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SoundConnect" "$APP/Contents/MacOS/Open Sound Connect"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
BUILD_NUMBER=$(date +%Y%m%d%H%M)
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Artwork/ATTRIBUTION.md" "$APP/Contents/Resources/ArtworkAttribution.md"
cp "$ROOT"/Resources/Models/*.usdz "$ROOT"/Resources/Models/*.png "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

echo "==> App icon"
"$TOOLS/SoundConnectArtwork" icon "$ROOT/Resources/Artwork/AppIconSource.png" "$ROOT/build/AppIcon.iconset"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Inside-out, without --deep: nested code first, then the app that seals it.
  # The default designated requirement (bundle id + team) is stable across updates and also satisfies the
  # identifier-only requirement of the ad-hoc builds, so the Bluetooth grant carries over.
  # No entitlements: the app isn't sandboxed, loads no third-party code, and Bluetooth needs no Hardened
  # Runtime exception.
  echo "==> Signing with $SIGN_IDENTITY (Hardened Runtime, secure timestamp)"
  SIGN=(codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
  MAIN="$APP/Contents/MacOS/Open Sound Connect"
  # Any other Mach-O in the bundle must carry the same signature.
  find "$APP" -type f -perm +111 ! -path "$MAIN" -print0 |
    while IFS= read -r -d '' file; do
      if file -b "$file" | grep -q Mach-O; then "${SIGN[@]}" "$file"; fi
    done
  "${SIGN[@]}" --identifier "$BUNDLE_ID" "$APP"
else
  echo "==> Ad-hoc signing (identifier-based designated requirement keeps the Bluetooth grant across rebuilds)"
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP"
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

echo "==> Built $APP ($ARCH, $BUILD_NUMBER)"
