#!/bin/sh
# Builds, signs and installs /Applications/OpalMini.app.
# Signs with your "Apple Development" (or Developer ID) certificate so macOS keeps camera/menu-bar
# permissions across rebuilds; falls back to ad-hoc if none is installed. Override with SIGN_ID=...
set -e
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}  # macOS 27 SDK + SwiftUI macros
cd "$(dirname "$0")"
APP=OpalMini.app
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 -oE '"(Developer ID Application|Apple Development): [^"]+"' | tr -d '"')}

[ -f AppIcon.icns ] || swift make_icon.swift
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos27.0" OpalMini.swift -o "$APP/Contents/MacOS/OpalMini"
sed "s/BUILD/$(git rev-list --count HEAD 2>/dev/null || echo 1)/" Info.plist > "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --options runtime --timestamp=none --entitlements OpalMini.entitlements -s "${SIGN_ID:--}" "$APP"
codesign --verify --strict "$APP"
echo "signed with: ${SIGN_ID:-ad-hoc}"

pkill -x OpalMini 2>/dev/null || true
rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/
echo "installed /Applications/$APP"
