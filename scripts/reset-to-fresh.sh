#!/bin/bash
# Puts this Mac back to "WinEx was never here", to go through the first launch from scratch:
#   • quits WinEx and gives the desktop and "Show in Finder" back to Finder;
#   • removes WinEx from the login items;
#   • resets every privacy permission WinEx asked for (Full Disk Access, Desktop, Documents,
#     Downloads, network volumes, removable volumes…) — macOS asks again;
#   • deletes every WinEx setting (views, sidebar, tags list, apps, desktop layout, window places…),
#     its caches and saved window state.
# Left alone: your files (tags, folder colours and symbols are Finder data), Finder's own settings
# (favourite tags), the signing certificate in ~/.winex-signing.
#
# Usage: scripts/reset-to-fresh.sh [--dry-run] [--install-release] [--yes]
#   --dry-run          only print what would be done
#   --install-release  then put the latest GitHub release into /Applications, marked as downloaded
#                      from the internet — the first launch then meets Gatekeeper like a new user's
#   --yes              don't ask for confirmation
set -uo pipefail
ID="dev.winex.WinEx"
DRY=0; INSTALL=0; YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;; --install-release) INSTALL=1 ;; --yes) YES=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done
run() { echo "  \$ $*"; [ $DRY = 1 ] || "$@"; }

echo "WinEx → as if never installed. This resets its permissions and deletes all its settings."
if [ $YES = 0 ] && [ $DRY = 0 ]; then
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^[yYдД] ]] || { echo "Cancelled."; exit 1; }
fi

echo "1. Quit WinEx"
if pgrep -xq WinEx; then
  run osascript -e "quit app id \"$ID\""
  for _ in $(seq 1 20); do pgrep -xq WinEx || break; [ $DRY = 1 ] && break; sleep 0.5; done
  # Still running (a stuck scenario, a crash dialog): only processes of this bundle
  if [ $DRY = 0 ] && pgrep -xq WinEx; then
    for pid in $(pgrep -x WinEx); do
      ps -o command= -p "$pid" | grep -q "WinEx.app/Contents/MacOS/WinEx" && kill "$pid"
    done
  fi
fi

echo "2. Desktop and \"Show in Finder\" back to Finder"
if [ "$(defaults read -g NSFileViewer 2>/dev/null)" = "$ID" ]; then run defaults delete -g NSFileViewer; fi
if [ "$(defaults read com.apple.finder CreateDesktop 2>/dev/null)" = "0" ]; then
  run defaults delete com.apple.finder CreateDesktop
  run killall Finder
fi

echo "3. Login item"
# Only the app itself can take itself out; a copy new enough to know how (an older one would just start)
APP=""
for candidate in "$(cd "$(dirname "$0")/.." && pwd)/build/WinEx.app" /Applications/WinEx.app \
                 $(mdfind "kMDItemCFBundleIdentifier == '$ID'" 2>/dev/null | tr '\n' ' '); do
  if [ -x "$candidate/Contents/MacOS/WinEx" ] && grep -q -- "--unregister-login-item" "$candidate/Contents/MacOS/WinEx"; then
    APP="$candidate"; break
  fi
done
if [ -n "$APP" ]; then
  run "$APP/Contents/MacOS/WinEx" --unregister-login-item
else
  echo "  (no WinEx new enough — remove it in System Settings ▸ General ▸ Login Items)"
fi

echo "4. Privacy permissions"
run tccutil reset All "$ID"

echo "5. Settings, caches, saved state"
for domain in "$ID" "$ID.scenario"; do
  defaults read "$domain" >/dev/null 2>&1 && run defaults delete "$domain"
done
for path in "$HOME/Library/Preferences/$ID.plist" "$HOME/Library/Preferences/$ID.scenario.plist" \
            "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
            "$HOME/Library/Saved Application State/$ID.savedState" "$HOME/Library/WebKit/$ID"; do
  [ -e "$path" ] && run rm -rf "$path"
done
run killall cfprefsd   # forget cached settings (macOS restarts it at once)

if [ $INSTALL = 1 ]; then
  echo "6. The latest release into /Applications, as a download"
  URL=$(curl -fsSL https://api.github.com/repos/dancheskus/WinEx/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*WinEx[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  if [ -z "$URL" ]; then echo "  (couldn't find the release)"; else
    TMP=$(mktemp -d)
    run curl -fsSL -o "$TMP/WinEx.zip" "$URL"
    run ditto -x -k "$TMP/WinEx.zip" "$TMP"
    [ -d /Applications/WinEx.app ] && run rm -rf /Applications/WinEx.app
    run mv "$TMP/WinEx.app" /Applications/WinEx.app
    # What a browser does to a download: Gatekeeper checks it on the first launch
    run xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" /Applications/WinEx.app
  fi
fi

echo
echo "Done. WinEx will start like on a new Mac: no settings, macOS asks for every permission again."
if [ $INSTALL = 1 ]; then echo "Open /Applications/WinEx.app — macOS will first refuse it, as for any unsigned download."; fi
