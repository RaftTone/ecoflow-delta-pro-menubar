#!/bin/bash
# Build EcoFlowBar.app into ~/Applications and (re)start it via its LaunchAgent.
# Usage: ./build.sh            build + install + restart
#        ./build.sh --no-run   build + install only
set -euo pipefail

cd "$(dirname "$0")"
APP="$HOME/Applications/EcoFlowBar.app"
LABEL="ua.rafttone.ecoflow-bar"
BUNDLE_ID="ua.rafttone.ecoflowbar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p build
swiftc -O -swift-version 5 -framework AppKit -framework SwiftUI main.swift Model.swift Card.swift Look.swift L10n.swift -o build/EcoFlowBar

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build/EcoFlowBar "$APP/Contents/MacOS/EcoFlowBar"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>EcoFlowBar</string>
  <key>CFBundleExecutable</key><string>EcoFlowBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PL
codesign --force --sign - "$APP" >/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/EcoFlowBar</string></array>
  <key>RunAtLoad</key><true/>
  <!-- Restart after a crash, but stay quit after "Вийти" (clean exit). -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PL

echo "built: $APP"
[[ "${1:-}" == "--no-run" ]] && exit 0

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the service is gone; bootstrapping too early fails with "5: Input/output error".
for _ in {1..50}; do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.1
done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "started: $LABEL"
