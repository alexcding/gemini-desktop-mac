#!/bin/bash

# Create DMG for Gemini Desktop
# Usage: ./scripts/create-dmg.sh

set -e

APP_NAME="Gemini Desktop"
APP_PATH="$HOME/Downloads/GeminiDesktop/${APP_NAME}.app"
DMG_NAME="GeminiDesktop"
OUTPUT_DIR="$HOME/Downloads"
VOLUME_NAME="Gemini Desktop"

# Temp directory for DMG contents
TMP_DIR=$(mktemp -d)
DMG_TMP="${TMP_DIR}/${DMG_NAME}-tmp.dmg"
DMG_FINAL="${OUTPUT_DIR}/${DMG_NAME}.dmg"

echo "Creating DMG for ${APP_NAME}..."

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at ${APP_PATH}"
    exit 1
fi

# Create staging directory
STAGING_DIR="${TMP_DIR}/staging"
mkdir -p "$STAGING_DIR"

# Copy app to staging
echo "Copying app..."
cp -R "$APP_PATH" "$STAGING_DIR/"

# Create Applications symlink
ln -s /Applications "$STAGING_DIR/Applications"

# Calculate size (app size + 10MB buffer)
SIZE=$(du -sm "$STAGING_DIR" | cut -f1)
SIZE=$((SIZE + 10))

# Create temporary DMG
echo "Creating DMG..."
hdiutil create -srcfolder "$STAGING_DIR" -volname "$VOLUME_NAME" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW -size ${SIZE}m "$DMG_TMP"

# Mount the temporary DMG
echo "Mounting DMG..."
MOUNT_DIR="/Volumes/${VOLUME_NAME}"
hdiutil attach "$DMG_TMP" -mountpoint "$MOUNT_DIR"

# Set window properties using AppleScript
echo "Setting DMG appearance..."
osascript <<EOF
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 100, 900, 400}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set position of item "${APP_NAME}.app" of container window to {125, 150}
        set position of item "Applications" of container window to {375, 150}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

# Unmount
echo "Finalizing..."
sync
hdiutil detach "$MOUNT_DIR"

# Convert to compressed DMG
rm -f "$DMG_FINAL"
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL"

# Cleanup
rm -rf "$TMP_DIR"

echo ""
echo "DMG created successfully: ${DMG_FINAL}"
echo "Size: $(du -h "$DMG_FINAL" | cut -f1)"
