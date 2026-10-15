#!/bin/zsh
# Type-checks the app against the iOS UIKit/SwiftUI SDK that ships for Mac
# Catalyst inside the macOS SDK. Useful without Xcode; Xcode builds are the
# real check.
set -euo pipefail
ROOT="${0:A:h:h}"
SDK=${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}
SWIFTC=${SWIFTC:-/Library/Developer/CommandLineTools/usr/bin/swiftc}
TARGET=arm64-apple-ios17.0-macabi
FW="$SDK/System/iOSSupport/System/Library/Frameworks"
OUT="${TMPDIR:-/tmp}/teleprompter-typecheck"
mkdir -p "$OUT"
"$SWIFTC" -emit-module -module-name TeleprompterCore -target $TARGET -sdk "$SDK" -F "$FW" \
  -parse-as-library -swift-version 5 \
  "$ROOT"/Packages/TeleprompterCore/Sources/TeleprompterCore/*.swift \
  -emit-module-path "$OUT/TeleprompterCore.swiftmodule"
"$SWIFTC" -typecheck -target $TARGET -sdk "$SDK" -F "$FW" -I "$OUT" -swift-version 5 \
  -parse-as-library "$ROOT"/Teleprompter/**/*.swift
echo "Type check passed."
