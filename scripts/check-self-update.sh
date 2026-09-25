#!/bin/bash
# End-to-end check of the updater on a copy of WinEx in a temporary folder (never the real app):
# the copy (launched with `open`, like a normal app) finds "version 99" in a local feed, installs
# it, quits and must come back as 99. Separate settings store; nothing touches the user's WinEx.
set -uo pipefail
cd "$(dirname "$0")/.."
./build.sh debug >/dev/null 2>&1 || { echo "build failed"; exit 1; }
WORK=$(mktemp -d /tmp/winex-selfupdate.XXXXXX)
OUT="$WORK/out"; mkdir -p "$OUT" "$WORK/old" "$WORK/new"
cp -R build/WinEx.app "$WORK/old/WinEx.app"
cp -R build/WinEx.app "$WORK/new/WinEx.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0" -c "Set :CFBundleVersion 1.0" "$WORK/old/WinEx.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 99.0.0" -c "Set :CFBundleVersion 99.0.0" "$WORK/new/WinEx.app/Contents/Info.plist"
security unlock-keychain -p "$(cat ~/.winex-signing/keychain-password)" ~/.winex-signing/signing.keychain-db
for app in "$WORK/old/WinEx.app" "$WORK/new/WinEx.app"; do
  codesign --force --sign "WinEx Signing" --keychain ~/.winex-signing/signing.keychain-db "$app" >/dev/null 2>&1
done
(cd "$WORK/new" && ditto -c -k --keepParent WinEx.app ../WinEx-99.0.0.zip)
cat > "$WORK/feed.json" <<JSON
{"tag_name": "v99.0.0", "body": "test", "assets": [{"name": "WinEx-99.0.0.zip", "browser_download_url": "file://$WORK/WinEx-99.0.0.zip"}]}
JSON
open -n "$WORK/old/WinEx.app" --env WINEX_SCENARIO=selfupdate --env WINEX_SCENARIO_OUT="$OUT" \
  --env WINEX_UPDATE_FEED="$WORK/feed.json" --env WINEX_AUTO_UPDATE=1
for _ in $(seq 1 40); do grep -q "after the update\|still running" "$OUT/log.txt" 2>/dev/null && break; sleep 1; done
sleep 2
cat "$OUT/log.txt" 2>/dev/null || echo "(no log)"
echo "bundle now: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORK/old/WinEx.app/Contents/Info.plist" 2>/dev/null)"
# Stop only copies started from this temporary folder
pgrep -f "$WORK/old/WinEx.app/Contents/MacOS/WinEx" | xargs -r kill 2>/dev/null
rm -rf "$WORK"
