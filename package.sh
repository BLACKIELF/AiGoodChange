#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
BUILD_DIR="${QUICKTOGGLE_BUILD_DIR:-$SCRIPT_DIR/build/package}"
APP="$BUILD_DIR/AiGoodChange.app"
ZIP="$BUILD_DIR/AiGoodChange-$VERSION-macOS-arm64.zip"

if [ "${QUICKTOGGLE_PREVIEW:-0}" = "1" ]; then
    echo "预览包不能作为发行包；请关闭 QUICKTOGGLE_PREVIEW 后重试。" >&2
    exit 2
fi

QUICKTOGGLE_BUILD_DIR="$BUILD_DIR" bash "$SCRIPT_DIR/build.sh" --release
/usr/bin/codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "✓ 打包完成: $ZIP"
