#!/bin/bash
set -euo pipefail

# Build a repair bundle without stopping the installed app or touching its settings.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ARCH="${1:-$(uname -m)}"
APP_DIR="$ROOT_DIR/dist/SideScreen.app"
SCRATCH_DIR="$ROOT_DIR/MacHost/.build-boox"
MODULE_CACHE="$SCRATCH_DIR/module-cache"

mkdir -p "$MODULE_CACHE"
cd "$ROOT_DIR/MacHost"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
    swift build --disable-sandbox -c release --arch "$BUILD_ARCH" --scratch-path "$SCRATCH_DIR"
BIN_DIR="$(swift build --disable-sandbox -c release --arch "$BUILD_ARCH" --scratch-path "$SCRATCH_DIR" --show-bin-path)"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/SideScreen" "$APP_DIR/Contents/MacOS/SideScreen"
cp "$ROOT_DIR/MacHost/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
python3 - "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib, sys
info = {
    'CFBundleExecutable': 'SideScreen',
    'CFBundleIdentifier': 'com.sidescreen.app',
    'CFBundleName': 'Side Screen',
    'CFBundleDisplayName': 'Side Screen BOOX Touch',
    'CFBundleIconFile': 'AppIcon',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0.2',
    'CFBundleVersion': '10003',
    'SideScreenRepairVersion': '1.0.2-booxfix.4-touch',
    'LSMinimumSystemVersion': '13.0',
    'LSUIElement': False,
    'NSHighResolutionCapable': True,
    'NSSupportsAutomaticGraphicsSwitching': True,
    'NSScreenCaptureUsageDescription': 'Side Screen captures the virtual display and streams it to your tablet.',
    'NSLocalNetworkUsageDescription': 'Side Screen connects to your tablet over your local network.',
    'NSBonjourServices': ['_sidescreen._tcp'],
}
with open(sys.argv[1], 'wb') as output:
    plistlib.dump(info, output)
PY
codesign --force --deep --sign - --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "App: $APP_DIR ($BUILD_ARCH, 1.0.2-booxfix.4-touch)"
