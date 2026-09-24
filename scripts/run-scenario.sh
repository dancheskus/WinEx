#!/bin/bash
# Runs an in-app scenario (debug build) and prints its log.
#   scripts/run-scenario.sh <name>        names: see Sources/WinEx/Debug/Scenarios.swift
# The scenario uses its own settings store, drives the app with in-process events only and quits
# by itself; only the process started here is ever killed (on timeout).
set -uo pipefail
cd "$(dirname "$0")/.."
NAME="${1:?scenario name}"
TIMEOUT="${2:-90}"
OUT=$(mktemp -d /tmp/winex-scenario.XXXXXX)
./build.sh debug >/dev/null 2>&1 || { echo "build failed"; ./build.sh debug 2>&1 | grep error: | head; exit 1; }
CRASHES_BEFORE=$(ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -c -i winex)
WINEX_SCENARIO="$NAME" WINEX_SCENARIO_OUT="$OUT" build/WinEx.app/Contents/MacOS/WinEx >"$OUT/stdout.txt" 2>&1 &
PID=$!
for _ in $(seq 1 "$TIMEOUT"); do sleep 1; kill -0 $PID 2>/dev/null || break; done
if kill -0 $PID 2>/dev/null; then echo "!! timeout — stopping pid $PID"; kill $PID; fi
cat "$OUT/log.txt" 2>/dev/null || echo "(no log)"
CRASHES_AFTER=$(ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -c -i winex)
[ "$CRASHES_AFTER" -gt "$CRASHES_BEFORE" ] && echo "!! the scenario crashed — see ~/Library/Logs/DiagnosticReports"
rm -rf "$OUT"
