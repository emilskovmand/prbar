#!/usr/bin/env bash
# Builds PRBar.app into ./build. Pass --install to copy it to ~/Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/PRBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/PRBar" "$APP/Contents/MacOS/PRBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp the version from git (e.g. 0.1.4, or 0.1.4-2-gabc123 between releases) for the update check.
VERSION=$(git describe --tags --always 2>/dev/null | sed 's/^v//')
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION:-0.0.0-dev}" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/PRBar.app"
  pkill -x PRBar 2>/dev/null || true
  # Wait for the old copy to exit, or `open` fails with -600.
  for _ in {1..50}; do pgrep -x PRBar >/dev/null || break; sleep 0.1; done
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
