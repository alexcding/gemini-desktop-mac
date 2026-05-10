#!/bin/bash

# Create DMG for Gemini Desktop
# Usage: ./scripts/create-dmg.sh [path/to/Gemini Desktop.app] [output_dir]
# Defaults: ~/Downloads/GeminiDesktop/

set -e

APP_NAME="Gemini Desktop"
DEFAULT_DIR="$HOME/Downloads/GeminiDesktop"
if [ -n "$1" ]; then
  APP_PATH="$1"
else
  APP_PATH="${DEFAULT_DIR}/${APP_NAME}.app"
fi
if [ -n "$2" ]; then
  OUTPUT_DIR="$2"
else
  OUTPUT_DIR="$DEFAULT_DIR"
fi
mkdir -p "$OUTPUT_DIR"
DMG_FINAL="${OUTPUT_DIR}/GeminiDesktop.dmg"
VOLUME_NAME="Gemini Desktop"

echo "Creating DMG for ${APP_NAME}..."

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at ${APP_PATH}"
    exit 1
fi

# Create staging directory in the same location
STAGING_DIR="${OUTPUT_DIR}/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app to staging
echo "Copying app..."
cp -R "$APP_PATH" "$STAGING_DIR/"

# Create Applications symlink
ln -s /Applications "$STAGING_DIR/Applications"

# Remove old DMG if exists
rm -f "$DMG_FINAL"

# Create DMG directly (no mount needed)
echo "Creating DMG..."
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_FINAL"

# Cleanup staging
rm -rf "$STAGING_DIR"

echo ""
echo "DMG created successfully: ${DMG_FINAL}"
echo "Size: $(du -h "$DMG_FINAL" | cut -f1)"
