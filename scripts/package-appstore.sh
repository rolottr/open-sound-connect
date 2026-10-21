#!/bin/zsh
# Build the Mac App Store version (universal, sandboxed, no update check) and wrap it in a signed installer
# package for App Store Connect.
#   PROVISIONING_PROFILE=<Mac App Store profile> scripts/package-appstore.sh
#   SIGN_IDENTITY / INSTALLER_IDENTITY override the "Apple Distribution" and
#     "3rd Party Mac Developer Installer" certificates found in the keychain.
#   UPLOAD=1 ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> scripts/package-appstore.sh
#     also validates and uploads the package with altool. The API key file stays where altool looks for it
#     (~/.appstoreconnect/private_keys/AuthKey_<key id>.p8); it is never passed on the command line.
set -euo pipefail

ROOT=${0:A:h:h}
[[ -n "${PROVISIONING_PROFILE:-}" ]] || { echo "Set PROVISIONING_PROFILE to the Mac App Store provisioning profile" >&2; exit 2; }
PROVISIONING_PROFILE=${PROVISIONING_PROFILE:A}
SIGN_IDENTITY=${SIGN_IDENTITY:-Apple Distribution}
INSTALLER_IDENTITY=${INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}

# A distribution profile provisions no individual Macs; a development profile would be rejected on upload.
if security cms -D -i "$PROVISIONING_PROFILE" | plutil -extract ProvisionedDevices raw - >/dev/null 2>&1; then
  echo "$PROVISIONING_PROFILE is a development profile; use a Mac App Store distribution profile" >&2; exit 2
fi

CHANNEL=appstore ARCH=universal CONFIG=release SIGN_IDENTITY="$SIGN_IDENTITY" PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
  "$ROOT/scripts/build.sh"
APP="$ROOT/build/Open Sound Connect.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
PACKAGE="$ROOT/build/Open-Sound-Connect-$VERSION-AppStore.pkg"

echo "==> Installer package"
rm -f "$PACKAGE"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PACKAGE"
pkgutil --check-signature "$PACKAGE"
lipo -archs "$APP/Contents/MacOS/Open Sound Connect"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -E "key|true|string" || true

if [[ "${UPLOAD:-0}" == 1 ]]; then
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || { echo "UPLOAD needs ASC_KEY_ID and ASC_ISSUER_ID" >&2; exit 2; }
  # altool ships with Xcode, not the Command Line Tools; use it without changing xcode-select.
  export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
  echo "==> Validating with App Store Connect"
  xcrun altool --validate-app -f "$PACKAGE" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "==> Uploading"
  xcrun altool --upload-app -f "$PACKAGE" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
fi
echo "==> Packaged $PACKAGE"
