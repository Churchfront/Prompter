#!/bin/zsh
# Builds the app's code for Mac Catalyst (same UIKit/SwiftUI stack as iOS) with
# the runtime harness instead of the app entry point, runs it, and writes
# screenshots to $HARNESS_OUT (default: Tools/Harness/Screenshots).
# Needs only the Command Line Tools. A window appears briefly while it runs.
set -euo pipefail
ROOT="${0:A:h:h}"
SDK=${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}
SWIFTC=${SWIFTC:-/Library/Developer/CommandLineTools/usr/bin/swiftc}
TARGET=arm64-apple-ios17.0-macabi
FW="$SDK/System/iOSSupport/System/Library/Frameworks"
LIBS=(-L "$SDK/System/iOSSupport/usr/lib" -L "$SDK/System/iOSSupport/usr/lib/swift")
BUILD="${TMPDIR:-/tmp}/teleprompter-harness"
export HARNESS_OUT="${HARNESS_OUT:-$ROOT/Tools/Harness/Screenshots}"
mkdir -p "$BUILD" "$HARNESS_OUT"

"$SWIFTC" -target $TARGET -sdk "$SDK" -F "$FW" -parse-as-library -swift-version 5 -O \
  -emit-library -static -module-name TeleprompterCore \
  -emit-module -emit-module-path "$BUILD/TeleprompterCore.swiftmodule" \
  "$ROOT"/Packages/TeleprompterCore/Sources/TeleprompterCore/*.swift -o "$BUILD/libTeleprompterCore.a"

APP_SOURCES=("${(@f)$(find "$ROOT/Teleprompter" -name '*.swift' ! -path '*/App/TeleprompterApp.swift')}")
"$SWIFTC" -target $TARGET -sdk "$SDK" -F "$FW" -Fsystem "$FW" $LIBS -I "$BUILD" -L "$BUILD" -lTeleprompterCore \
  -swift-version 5 -Onone -module-name Prompter \
  $APP_SOURCES "$ROOT"/Tools/Harness/*.swift -o "$BUILD/Harness"

APP="$BUILD/Harness.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Harness" "$APP/Contents/MacOS/Harness"
cp "$ROOT/Teleprompter/Resources/Fonts/"*.ttf "$ROOT/Teleprompter/Resources/SampleScript.txt" "$APP/Contents/Resources/"
cp "$ROOT/Teleprompter/Resources/Web/"* "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.churchfront.prompter.harness</string>
<key>CFBundleExecutable</key><string>Harness</string>
<key>CFBundleName</key><string>Prompter Harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign -s - --force "$APP" >/dev/null 2>&1
"$APP/Contents/MacOS/Harness" "$@"
