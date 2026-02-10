#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ToWebP"
APP_PATH="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.keiver.towebp"

echo "Building ${APP_NAME} (release)..."
cd "$SCRIPT_DIR"
swift build -c release

BINARY="$SCRIPT_DIR/.build/release/${APP_NAME}"
if [ ! -f "$BINARY" ]; then
    echo "Error: Release binary not found at $BINARY" >&2
    exit 1
fi

echo "Creating app bundle at ${APP_PATH}..."
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

cp "$BINARY" "${APP_PATH}/Contents/MacOS/${APP_NAME}"

cat > "${APP_PATH}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>ToWebP</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

# Copy install script into the bundle for the "Install to Applications" menu item to find
cp "$SCRIPT_DIR/install-app.sh" "${APP_PATH}/Contents/Resources/install-app.sh"

echo "Signing app bundle..."
codesign --force --sign - "${APP_PATH}"

echo ""
echo "Done! ${APP_NAME} installed to ${APP_PATH}"
echo "You can now launch it from Applications or Spotlight."
