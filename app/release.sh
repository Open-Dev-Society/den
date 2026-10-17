#!/bin/sh
# Build Den.app and package it for a GitHub pre-release:  ./release.sh  → dist/Den-<version>.dmg and .zip
# The DMG window's look: Release/dmg.py (layout) and Release/background.swift (picture).
set -e
cd "$(dirname "$0")"
./bundle.sh
v=$(defaults read "$PWD/Den.app/Contents/Info.plist" CFBundleShortVersionString)
rm -rf dist && mkdir dist
uvx --quiet --from dmgbuild==1.6.7 dmgbuild -s Release/dmg.py -D app=Den.app -D icon=Icon/Den.icns \
    -D background=Release/background.png "Den $v" "dist/Den-$v.dmg"
ditto -c -k --sequesterRsrc --keepParent Den.app "dist/Den-$v.zip"
shasum -a 256 dist/*
