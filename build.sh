#!/bin/bash
# Builds a release binary and wraps it into build/KurBar.app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/KurBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/KurBar" "$APP/Contents/MacOS/KurBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
