#!/bin/sh
# Builds OpalMini.app next to this script. Usage: ./build.sh && open OpalMini.app
set -e
cd "$(dirname "$0")"
APP=OpalMini.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library OpalMini.swift -o "$APP/Contents/MacOS/OpalMini"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.opalmini</string>
<key>CFBundleName</key><string>OpalMini</string>
<key>CFBundleExecutable</key><string>OpalMini</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>Live preview of the Opal C1.</string>
</dict></plist>
EOF
codesign -s - --force "$APP"
rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/ && echo "installed /Applications/$APP"
