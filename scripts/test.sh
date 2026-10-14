#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools ]]; then
  if [[ -z "${SDKROOT:-}" ]]; then
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
      if [[ -d "$candidate" ]]; then export SDKROOT="$candidate"; break; fi
    done
  fi
  export SDKROOT=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
  FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
  # CLT's test framework and macro plugin are outside SwiftPM's default native search paths.
  swift test --build-system native \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
else
  swift test "$@"
fi
