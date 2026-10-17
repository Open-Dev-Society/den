#!/bin/sh
# Build Den.app from this package:  ./bundle.sh && open Den.app
set -e
cd "$(dirname "$0")"
# the SwiftUI macros ship with Xcode, not the Command Line Tools
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build -c release
rm -rf Den.app
mkdir -p Den.app/Contents/MacOS Den.app/Contents/Resources
cp .build/release/Den Den.app/Contents/MacOS/
cp Icon/Den.icns Den.app/Contents/Resources/ # from Icon/Den.svg: cd Icon && swift render.swift
cat > Den.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Den</string>
  <key>CFBundleIdentifier</key><string>local.den.app</string>
  <key>CFBundleName</key><string>Den</string>
  <key>CFBundleIconFile</key><string>Den</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0-alpha</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Den asks System Events to switch between light and dark mode when you run that command.</string>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>local.den.dockitem</string>
    <key>UTTypeDescription</key><string>Den Dock item</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
  <key>NSRemindersFullAccessUsageDescription</key><string>Den's Reminders widget shows what's still to do. Read on this Mac; nothing is sent anywhere.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Den reads your calendar on this Mac so meetings can join your journal, people pages and answers. Nothing is copied or sent anywhere.</string>
</dict>
</plist>
PLIST
codesign --force --sign - Den.app
echo "built $(pwd)/Den.app"
