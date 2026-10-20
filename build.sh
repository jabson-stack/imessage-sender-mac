#!/bin/zsh
# Builds iMessageCollectorMac.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/iMessageCollectorMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -parse-as-library -O -target arm64-apple-macos14 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/iMessageCollectorMac"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>iMessageCollectorMac</string>
  <key>CFBundleIdentifier</key><string>ge.space.iMessageCollectorMac</string>
  <key>CFBundleExecutable</key><string>iMessageCollectorMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Personal team (jaba.od@gmail.com)
TEAM_ID=4WS8VKQEGB
SIGN_IDENTITY="Apple Development: jaba.od@gmail.com (4Y26D8X9PC)"

codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP"
