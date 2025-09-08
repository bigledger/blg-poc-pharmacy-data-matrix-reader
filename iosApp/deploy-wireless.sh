#!/bin/bash

# Wireless deployment script for BigLedgerPharmacyScanner
# Builds and deploys the app wirelessly to an iPhone using Xcode 15+ devicectl.
# Usage:
#   ./deploy-wireless.sh <DEVICE_ID>
# If DEVICE_ID is omitted, a default is used (update it for your device).

DEVICE_ID=${1:-00008130-001651943EF8001C}
PROJECT=BigLedgerPharmacyScanner.xcodeproj
SCHEME=BigLedgerPharmacyScanner
CONFIG=Debug

set -e

echo "🚀 Building $SCHEME for wireless deployment..."

xcodebuild -project "$PROJECT" \
           -scheme "$SCHEME" \
           -destination "platform=iOS,id=$DEVICE_ID" \
           -configuration "$CONFIG" \
           build

echo "✅ Build completed successfully"

# Attempt to locate the built .app automatically (typical DerivedData path pattern)
DERIVED_BASE="$HOME/Library/Developer/Xcode/DerivedData"
APP_PATH=$(find "$DERIVED_BASE" -type d -name "${SCHEME}.app" -path "*/Build/Products/${CONFIG}-iphoneos/${SCHEME}.app" 2>/dev/null | head -n 1)

if [ -z "$APP_PATH" ]; then
  echo "⚠️ Could not automatically locate .app. Falling back to previous hardcoded path."
  APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/BigLedgerPharmacyScanner-ffrpuzakxgevowdtolmtutxlfezp/Build/Products/${CONFIG}-iphoneos/${SCHEME}.app"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "❌ .app not found at: $APP_PATH"
  echo "➡️ Open Xcode, build the scheme for a physical device once, then re-run with your DEVICE_ID."
  exit 1
fi

# Try to discover bundle identifier from Info.plist in the built .app
PLIST="$APP_PATH/Info.plist"
BUNDLE_ID=""
if [ -f "$PLIST" ]; then
  BUNDLE_ID=$(defaults read "${PLIST%.*}" CFBundleIdentifier 2>/dev/null || true)
fi

if [ -z "$BUNDLE_ID" ]; then
  echo "⚠️ Could not read CFBundleIdentifier from Info.plist. If reinstall fails, specify manually."
else
  echo "🧹 Attempting uninstall of existing app ($BUNDLE_ID) from device $DEVICE_ID (ignore errors if not installed)"
  set +e
  xcrun devicectl device uninstall app --device "$DEVICE_ID" "$BUNDLE_ID"
  set -e
fi

echo "📱 Installing app wirelessly to device $DEVICE_ID ..."
# devicectl typically accepts plain UDID; .coredevice.local is optional when using CoreDevice daemon
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "🎉 App deployed wirelessly successfully!"
echo "📱 Check your iPhone - $SCHEME should be installed"