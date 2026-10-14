#!/bin/zsh
# Build the pinned, vendored MediaRemote helper; no download or CMake is required.
set -euo pipefail
ROOT=${0:A:h:h}
SOURCE="$ROOT/Vendor/MediaRemoteAdapter"
FRAMEWORK="$ROOT/build/MediaRemoteAdapter.framework"
SDKROOT=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK/Versions/A/Resources"
xcrun clang -isysroot "$SDKROOT" -mmacosx-version-min=15.0 \
  -dynamiclib -fobjc-arc -fvisibility=default -O2 \
  -I"$SOURCE/include" -I"$SOURCE/src" \
  "$SOURCE"/src/adapter/*.m "$SOURCE"/src/private/*.m "$SOURCE"/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name '@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter' \
  -o "$FRAMEWORK/Versions/A/MediaRemoteAdapter"
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
codesign --force --sign - "$FRAMEWORK"
