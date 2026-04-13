#!/usr/bin/env bash
#
# build-dmg.sh — Build the wg0 macOS app and package it as a .dmg.
#
# Usage:
#   cd native-clients/macos
#   bash build-dmg.sh
#
# Produces:
#   build/wg0.dmg          — the distributable disk image
#   build/wg0.app/         — the unsigned .app bundle
#
# Requirements:
#   - macOS 14+ with Xcode Command Line Tools installed
#   - swift 5.10+
#
# The .app is UNSIGNED. Users must right-click → Open to bypass
# Gatekeeper on first launch. Once we have an Apple Developer ID
# ($99/year), this script gains a codesign + notarize step.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_NAME="wg0"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
DMG_VOLUME_NAME="wg0 Installer"

echo "=== Building wg0 macOS app ==="
echo "Source: ${SCRIPT_DIR}"
echo "Output: ${BUILD_DIR}"
echo ""

# 1. Clean previous build.
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# 2. Build the Swift package in release mode.
echo "Step 1: swift build --configuration release"
cd "${SCRIPT_DIR}"
swift build --configuration release 2>&1

# Find the built executable.
EXEC_PATH=$(swift build --configuration release --show-bin-path)/Wg0MacApp
if [[ ! -f "$EXEC_PATH" ]]; then
    echo "ERROR: Built executable not found at $EXEC_PATH"
    exit 1
fi
echo "Executable: ${EXEC_PATH}"

# 3. Assemble the .app bundle structure.
echo ""
echo "Step 2: Assembling ${APP_NAME}.app bundle"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy the executable.
cp "${EXEC_PATH}" "${MACOS_DIR}/Wg0MacApp"
chmod +x "${MACOS_DIR}/Wg0MacApp"

# Copy Info.plist.
cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS}/Info.plist"

# Create a minimal PkgInfo.
echo -n "APPL????" > "${CONTENTS}/PkgInfo"

# Create an icon placeholder (a simple colored square).
# A real .icns file can be added later from a designer.
# For now, macOS will use the generic app icon.
echo "  (No custom icon yet — using macOS default app icon)"

echo "  Bundle created at: ${APP_BUNDLE}"

# 4. Verify the bundle structure.
echo ""
echo "Step 3: Verifying bundle"
ls -la "${CONTENTS}/"
ls -la "${MACOS_DIR}/"

# 5. Create the .dmg.
echo ""
echo "Step 4: Creating ${APP_NAME}.dmg"

# Create a temporary directory for the DMG contents.
DMG_STAGE="${BUILD_DIR}/dmg-stage"
mkdir -p "${DMG_STAGE}"
cp -R "${APP_BUNDLE}" "${DMG_STAGE}/"

# Create a symlink to /Applications for drag-to-install.
ln -s /Applications "${DMG_STAGE}/Applications"

# Create the .dmg using hdiutil.
hdiutil create \
    -volname "${DMG_VOLUME_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov -format UDZO \
    "${DMG_PATH}"

# Clean up staging.
rm -rf "${DMG_STAGE}"

echo ""
echo "=== Build complete ==="
echo "  .app: ${APP_BUNDLE}"
echo "  .dmg: ${DMG_PATH}"
echo ""
echo "To install:"
echo "  1. Open ${DMG_PATH}"
echo "  2. Drag wg0.app to Applications"
echo "  3. Right-click wg0.app → Open (first time only, to bypass Gatekeeper)"
echo ""
echo "Size:"
du -sh "${APP_BUNDLE}" "${DMG_PATH}"
