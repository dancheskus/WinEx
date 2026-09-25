#!/bin/bash
# Photographs the windows a scenario presents: the scenario writes <out>/tab-N (a window number)
# and waits for <out>/shot-N. Pictures go to build/scenario-<name>/. Needs Screen Recording
# permission for the terminal. Usage: scripts/capture-window.sh <scenario> [shots]
set -uo pipefail
cd "$(dirname "$0")/.."
NAME="${1:?scenario}"; SHOTS="${2:-1}"
./build.sh debug >/dev/null 2>&1 || { echo "build failed"; exit 1; }
OUT=$(mktemp -d /tmp/winex-scenario.XXXXXX)
WINEX_SCENARIO="$NAME" WINEX_SCENARIO_OUT="$OUT" WINEX_MENU_TEST="${WINEX_MENU_TEST:-}" build/WinEx.app/Contents/MacOS/WinEx >/dev/null 2>&1 &
PID=$!
rm -rf "build/scenario-$NAME"; mkdir -p "build/scenario-$NAME"
for i in $(seq 0 $((SHOTS - 1))); do
  for _ in $(seq 1 60); do [ -f "$OUT/tab-$i" ] && break; sleep 0.25; done
  [ -f "$OUT/tab-$i" ] || break
  screencapture -x -o -l"$(cat "$OUT/tab-$i")" "build/scenario-$NAME/shot-$i.png"
  touch "$OUT/shot-$i"
done
for _ in $(seq 1 20); do kill -0 $PID 2>/dev/null || break; sleep 0.5; done
kill -0 $PID 2>/dev/null && kill $PID
cat "$OUT/log.txt" 2>/dev/null; rm -rf "$OUT"
echo "pictures: build/scenario-$NAME/"
