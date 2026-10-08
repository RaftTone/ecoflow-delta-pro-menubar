#!/bin/bash
# Build a universal (arm64 + x86_64) EcoFlowBar.app and zip it for a GitHub release.
# Usage: ./release.sh [version]     -> dist/EcoFlowBar-<version>-macos.zip
# The app is ad-hoc signed (no Apple Developer ID), so macOS Gatekeeper asks the user to allow it once, see README.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"
SRC="main.swift Model.swift Card.swift Look.swift L10n.swift"
OUT="dist"
APP="$OUT/EcoFlowBar.app"

rm -rf "$OUT" && mkdir -p "$OUT/build"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" -framework AppKit -framework SwiftUI $SRC -o "$OUT/build/EcoFlowBar-$ARCH"
done
lipo -create "$OUT/build/EcoFlowBar-arm64" "$OUT/build/EcoFlowBar-x86_64" -output "$OUT/build/EcoFlowBar"

mkdir -p "$APP/Contents/MacOS"
cp "$OUT/build/EcoFlowBar" "$APP/Contents/MacOS/EcoFlowBar"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>ua.rafttone.ecoflowbar</string>
  <key>CFBundleName</key><string>EcoFlowBar</string>
  <key>CFBundleExecutable</key><string>EcoFlowBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PL
codesign --force --sign - "$APP" >/dev/null
ditto -c -k --keepParent "$APP" "$OUT/EcoFlowBar-$VERSION-macos.zip"
lipo -archs "$APP/Contents/MacOS/EcoFlowBar"
ls -la "$OUT/EcoFlowBar-$VERSION-macos.zip"
