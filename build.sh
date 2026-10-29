#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AiGoodChange"
# Keep the executable, bundle ID, and signing identity for existing installations.
EXECUTABLE_NAME="QuickToggle"
BUILD_DIR="${QUICKTOGGLE_BUILD_DIR:-$SCRIPT_DIR/build}"
if [ "${QUICKTOGGLE_PREVIEW:-0}" = "1" ] && [ -z "${QUICKTOGGLE_BUILD_DIR:-}" ]; then
    BUILD_DIR="$SCRIPT_DIR/build/preview"
fi
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
APP="$BUILD_DIR/$APP_NAME.app"
BIN="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
BUILD_NUMBER="$(git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
SOURCE_REVISION="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$SOURCE_REVISION" != "unknown" ] && ! git -C "$SCRIPT_DIR" diff --quiet HEAD -- QuickToggle.swift VERSION build.sh Assets; then
    SOURCE_REVISION="$SOURCE_REVISION-dirty"
fi

CONFIG="debug"
case "${1:-}" in
  --release) CONFIG="release" ;;
  "") ;;
  *) echo "用法: build.sh [--release]" >&2; exit 2 ;;
esac

rm -rf "$APP"
mkdir -p "$BIN" "$RES" "$MODULE_CACHE_DIR"

SWIFT_FLAGS=(
  -warnings-as-errors
  -framework AppKit -framework Carbon -framework ApplicationServices -framework ServiceManagement
  -target "arm64-apple-macosx13.0"
)
case "$CONFIG" in
  debug)   SWIFT_FLAGS+=(-Onone -g) ;;
  release) SWIFT_FLAGS+=(-O -whole-module-optimization) ;;
esac

BUNDLE_ID="com.quicktoggle.app"
DISPLAY_NAME="AiGoodChange"
if [ "${QUICKTOGGLE_PREVIEW:-0}" = "1" ]; then
    SWIFT_FLAGS+=(-D QUICKTOGGLE_PREVIEW)
    BUNDLE_ID="com.quicktoggle.preview"
    DISPLAY_NAME="AiGoodChange 预览"
fi

echo "→ 编译中（$CONFIG，版本 $VERSION build $BUILD_NUMBER）..."
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR" \
/usr/bin/swiftc "$SCRIPT_DIR/QuickToggle.swift" "${SWIFT_FLAGS[@]}" \
  -o "$BIN/$EXECUTABLE_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>QuickToggleSourceRevision</key><string>${SOURCE_REVISION}</string>
  <key>CFBundleGetInfoString</key><string>AiGoodChange ${VERSION}</string>
  <key>CFBundleExecutable</key><string>QuickToggle</string>
  <key>CFBundleIconFile</key><string>QuickToggleIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp "$SCRIPT_DIR/Assets/QuickToggleIcon-0817v2.icns" "$RES/QuickToggleIcon.icns"
cp "$SCRIPT_DIR/Assets/AiGoodBroThemes.json" "$RES/AiGoodBroThemes.json"
cp "$SCRIPT_DIR/Assets/AiGoodBro-Themes-LICENSE.txt" "$RES/AiGoodBro-Themes-LICENSE.txt"

SIGN_IDENTITY="QuickToggle Local Development"
if /usr/bin/security find-certificate -c "$SIGN_IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    echo "→ 代码签名（$SIGN_IDENTITY，稳定身份，辅助功能授权跨构建保留）..."
    /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
    echo "→ 代码签名（ad-hoc；注意：每次重建后辅助功能授权会失效）..."
    /usr/bin/codesign --force --deep --sign - "$APP"
fi
/usr/bin/codesign --verify --deep --strict "$APP"

echo "✓ 构建完成: $APP"
echo "  运行: open \"$APP\""
