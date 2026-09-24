#!/bin/bash
# Builds WinEx and packages it into build/WinEx.app
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/WinEx.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/WinEx" "$APP/Contents/MacOS/WinEx"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Dock icon (regenerate with: swift Resources/make-icon.swift)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

# Register with LaunchServices so WinEx can become the folder handler
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "Built $APP"
