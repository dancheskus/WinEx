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
# Releases (GitHub Actions) pass the version from the tag; local builds are marked "dev" and
# don't look for updates on their own
PLIST="$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
else
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion dev" "$PLIST"
fi
# Dock icon (regenerate with: swift Resources/make-icon.swift)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The languages (texts are in the code, see Sources/WinEx/Localization): the folders tell macOS
# which languages the app speaks, so its own buttons and units follow the chosen one
for lang in en ru; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  printf '"CFBundleName" = "WinEx";\n' > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
# A stable signature keeps privacy permissions (Full Disk Access, Desktop, Documents, network
# volumes) across rebuilds; ad-hoc signatures change every build. See scripts/setup-signing.sh.
IDENTITY="WinEx Signing"
SIGNING_KEYCHAIN="$HOME/.winex-signing/signing.keychain-db"
if [ -f "$SIGNING_KEYCHAIN" ]; then
  # Its own keychain with a known password: no login-password prompts (scripts/setup-signing.sh)
  security unlock-keychain -p "$(cat "$HOME/.winex-signing/keychain-password")" "$SIGNING_KEYCHAIN"
  codesign --force --sign "$IDENTITY" --keychain "$SIGNING_KEYCHAIN" "$APP" >/dev/null
elif security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  # CI: the workflow's temporary keychain
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null
else
  echo "(ad-hoc signature: run scripts/setup-signing.sh once to keep permissions across builds)"
  codesign --force --sign - "$APP" >/dev/null
fi

# Register with LaunchServices so WinEx can become the folder handler
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "Built $APP"
