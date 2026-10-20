#!/bin/zsh
# Build and package the app for one architecture (default: this Mac's).
#   ARCH=x86_64 scripts/package.sh
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profile> scripts/package.sh
#     signs, notarizes and staples the app before zipping it. The profile is a
#     notarytool keychain profile (xcrun notarytool store-credentials).
set -euo pipefail

ROOT=${0:A:h:h}
ARCH=${ARCH:-$(uname -m)}
CONFIG=release ARCH="$ARCH" "$ROOT/scripts/build.sh"
ARCHIVE="Sound-Connect-macos-$ARCH.zip"
APP="Open Sound Connect.app"
cd "$ROOT/build"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "NOTARY_PROFILE needs SIGN_IDENTITY" >&2; exit 2; }
  echo "==> Notarizing"
  ditto -c -k --sequesterRsrc --keepParent "$APP" notarize.zip
  xcrun notarytool submit notarize.zip --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "notarize-$ARCH.json" || true
  rm -f notarize.zip
  ID=$(plutil -extract id raw "notarize-$ARCH.json")
  STATUS=$(plutil -extract status raw "notarize-$ARCH.json")
  xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" "notarize-$ARCH-log.json" || true
  echo "    submission $ID: $STATUS (log: build/notarize-$ARCH-log.json)"
  [[ "$STATUS" == Accepted ]] || exit 1
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "==> Packaged $ROOT/build/$ARCHIVE"
