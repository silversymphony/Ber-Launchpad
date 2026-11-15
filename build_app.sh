#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Ber Launchpad"
EXEC_NAME="BerLaunchpad"
BUNDLE_ID="com.ber.launchpad"
APP_BUNDLE="$PROJECT_DIR/${APP_NAME}.app"
BUILD_TMP="$PROJECT_DIR/.build_icon_tmp"

echo "1. Compiling Swift release binary..."
cd "$PROJECT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${EXEC_NAME}"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Error: compiled binary not found at $BIN_PATH"
    exit 1
fi

echo "2. Generating AppIcon.icns..."
rm -rf "$BUILD_TMP"
mkdir -p "$BUILD_TMP"
ICONSET_DIR="$BUILD_TMP/AppIcon.iconset"
swift "$PROJECT_DIR/Scripts/generate_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$BUILD_TMP/AppIcon.icns"

echo "3. Assembling ${APP_NAME}.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/${EXEC_NAME}"
chmod +x "$APP_BUNDLE/Contents/MacOS/${EXEC_NAME}"
cp "$BUILD_TMP/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Ber Launchpad</string>
    <key>CFBundleExecutable</key>
    <string>BerLaunchpad</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.ber.launchpad</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Ber Launchpad</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

rm -rf "$BUILD_TMP"

echo "4. Ad-hoc signing ${APP_NAME}.app..."
codesign --force --deep --sign - "$APP_BUNDLE"

if [[ -w "/Applications" ]]; then
    echo "5. Installing copy to /Applications/${APP_NAME}.app..."
    rm -rf "/Applications/${APP_NAME}.app"
    ditto "$APP_BUNDLE" "/Applications/${APP_NAME}.app"
    codesign --force --deep --sign - "/Applications/${APP_NAME}.app"
else
    echo "5. Skipping /Applications copy (/Applications not writable without elevated privileges)."
fi

echo "Done: $APP_BUNDLE"
