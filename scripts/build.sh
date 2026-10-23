#!/bin/zsh
# Builds "Open Sound Connect.app" with SwiftPM.
#   scripts/build.sh            release build into build/Open Sound Connect.app
#   CONFIG=debug scripts/build.sh
#   ARCH=x86_64 scripts/build.sh     another architecture (default: this Mac's); ARCH=universal for both
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
#                                    Developer ID signature for releases (default: ad-hoc)
#   CHANNEL=appstore SIGN_IDENTITY="Apple Distribution: …" PROVISIONING_PROFILE=… scripts/build.sh
#                                    Mac App Store build: no update check, profile embedded
#   SANDBOX=0 scripts/build.sh       no App Sandbox, for developer runs (--probe/--replay/--snapshot-dir
#                                    with files outside the container)
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=${CONFIG:-release}
ARCH=${ARCH:-$(uname -m)}
CHANNEL=${CHANNEL:-github}
SANDBOX=${SANDBOX:-1}
case "$CONFIG" in
  release|debug) ;;
  *) echo "CONFIG must be release or debug" >&2; exit 2 ;;
esac
case "$CHANNEL" in
  github) ENTITLEMENTS="$ROOT/Resources/Signing/GitHub.entitlements"; SWIFT_FLAGS=() ;;
  appstore) ENTITLEMENTS="$ROOT/Resources/Signing/AppStore.entitlements"; SWIFT_FLAGS=(-Xswiftc -DAPP_STORE) ;;
  *) echo "CHANNEL must be github or appstore" >&2; exit 2 ;;
esac
[[ "$ARCH" == universal ]] && ARCHS=(arm64 x86_64) || ARCHS=("$ARCH")
BUNDLE_ID=dev.rolottr.SoundConnect
APP="$ROOT/build/Open Sound Connect.app"
cd "$ROOT"
mkdir -p "$ROOT/build"

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
BINARIES=()
for arch in $ARCHS; do
  echo "==> swift build ($CONFIG, $arch, $CHANNEL) with SDK ${SDKROOT:-default}"
  swift build -c "$CONFIG" --arch "$arch" "${SWIFT_FLAGS[@]}" --product SoundConnect
  # Each architecture may land in the same products folder, so keep a copy before building the next.
  cp "$(swift build -c "$CONFIG" --arch "$arch" "${SWIFT_FLAGS[@]}" --show-bin-path)/SoundConnect" "$ROOT/build/SoundConnect-$arch"
  BINARIES+=("$ROOT/build/SoundConnect-$arch")
done
# The icon renderer runs here during the build, so it is always built for this Mac.
swift build -c "$CONFIG" --product SoundConnectArtwork
TOOLS=$(swift build -c "$CONFIG" --show-bin-path)

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Open Sound Connect" "${BINARIES[@]}"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
BUILD_NUMBER=$(date +%Y%m%d%H%M)
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Artwork/ATTRIBUTION.md" "$APP/Contents/Resources/ArtworkAttribution.md"
cp "$ROOT"/Resources/Models/*.usdz "$ROOT"/Resources/Models/*.png "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/"
if (( SANDBOX )); then
  # Moves the data of earlier, unsandboxed versions into the container the first time a sandboxed one runs.
  cp "$ROOT/Resources/container-migration.plist" "$APP/Contents/Resources/"
fi

echo "==> App icon"
"$TOOLS/SoundConnectArtwork" icon "$ROOT/Resources/Artwork/AppIconSource.png" "$ROOT/build/AppIcon.iconset"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Entitlements: the App Sandbox plus what the app needs inside it (see the comments in Resources/Signing).
SIGN_ENTITLEMENTS=()
if (( SANDBOX )); then
  cp "$ENTITLEMENTS" "$ROOT/build/signing.entitlements"
  if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
    # The App Store requires the profile inside the app and its application and team identifiers in the
    # signature; take them from the profile so they always match it.
    security cms -D -i "$PROVISIONING_PROFILE" > "$ROOT/build/profile.plist"
    APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$ROOT/build/profile.plist")
    TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$ROOT/build/profile.plist")
    [[ "$APP_ID" == "$TEAM_ID.$BUNDLE_ID" ]] || { echo "Profile is for $APP_ID, not $TEAM_ID.$BUNDLE_ID" >&2; exit 2; }
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" \
      -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ROOT/build/signing.entitlements"
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  fi
  SIGN_ENTITLEMENTS=(--entitlements "$ROOT/build/signing.entitlements")
elif [[ "$CHANNEL" == appstore || -n "${PROVISIONING_PROFILE:-}" ]]; then
  echo "App Store builds must be sandboxed" >&2; exit 2
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Inside-out, without --deep: nested code first, then the app that seals it.
  # The default designated requirement (bundle id + team) is stable across updates and also satisfies the
  # identifier-only requirement of the ad-hoc builds, so the Bluetooth grant carries over.
  # Hardened Runtime without exceptions: the app loads no third-party code and Bluetooth needs none.
  echo "==> Signing with $SIGN_IDENTITY (Hardened Runtime, secure timestamp, sandbox: $SANDBOX)"
  SIGN=(codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
  MAIN="$APP/Contents/MacOS/Open Sound Connect"
  # Any other Mach-O in the bundle must carry the same signature.
  find "$APP" -type f -perm +111 ! -path "$MAIN" -print0 |
    while IFS= read -r -d '' file; do
      if file -b "$file" | grep -q Mach-O; then "${SIGN[@]}" "$file"; fi
    done
  "${SIGN[@]}" "${SIGN_ENTITLEMENTS[@]}" --identifier "$BUNDLE_ID" "$APP"
else
  echo "==> Ad-hoc signing (identifier-based designated requirement keeps the Bluetooth grant across rebuilds)"
  codesign --force --sign - "${SIGN_ENTITLEMENTS[@]}" --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP"
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

echo "==> Built $APP ($ARCH, $CHANNEL, $BUILD_NUMBER)"
