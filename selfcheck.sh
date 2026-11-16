#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${QUICKTOGGLE_BUILD_DIR:-$DIR/build/checks}"
if [ "${QUICKTOGGLE_PREVIEW:-0}" = "1" ] && [ -z "${QUICKTOGGLE_BUILD_DIR:-}" ]; then
  BUILD_DIR="$DIR/build/checks-preview"
fi
APP="$BUILD_DIR/AiGoodChange.app"
BIN="$APP/Contents/MacOS/QuickToggle"

VERSION="$(tr -d '[:space:]' < "$DIR/VERSION")"

echo "=== AiGoodChange $VERSION 自检 ==="
QUICKTOGGLE_BUILD_DIR="$BUILD_DIR" bash "$DIR/build.sh"
/usr/bin/codesign --verify --deep --strict "$APP"

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"
if [ "$PLIST_VERSION" != "$VERSION" ]; then
  echo "版本不一致：VERSION=$VERSION，Info.plist=$PLIST_VERSION" >&2
  exit 1
fi
echo "版本一致性: $VERSION ✓"
"$BIN" --self-test
"$BIN" --smoke-test
"$BIN" --ui-smoke-test

"$BIN" --idle-measure
echo "AiGoodChange 自检全部通过"
