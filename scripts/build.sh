#!/bin/bash
# Build the SPM targets and assemble an ad-hoc-signed aisland.app bundle.
# A stable bundle identifier + signature keeps TCC grants (Accessibility,
# Apple Events) sticky across rebuilds.
#
# Usage: scripts/build.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/aisland.app"

swift build -c "$CONFIG"
BIN=".build/$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/aisland" "$APP/Contents/MacOS/aisland"
cp "$BIN/island-shim" "$APP/Contents/Helpers/island-shim"
cp "$BIN/islandctl" "$APP/Contents/Helpers/islandctl"
cp App/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - "$APP/Contents/Helpers/island-shim"
codesign --force --sign - "$APP/Contents/Helpers/islandctl"
codesign --force --sign - --identifier com.aisland.app "$APP"

echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
    # Relaunch cleanly if already running.
    pkill -x aisland 2>/dev/null || true
    sleep 0.3
    open "$APP"
fi
