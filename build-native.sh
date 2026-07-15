#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/持仓宠物.app"
VERSION="0.3.2"
DMG="$BUILD/持仓宠物.dmg"

rm -rf "$APP" "$BUILD/dmg-root"
find "$BUILD" -maxdepth 1 -type f -name '持仓宠物*.dmg' -exec rm -f {} + 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/dmg-root"

swiftc -parse-as-library \
  -target arm64-apple-macos15.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework UserNotifications \
  "$ROOT/native/StockPet.swift" \
  -o "$APP/Contents/MacOS/StockPet"

cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/native/Resources/StockPet.icns" "$APP/Contents/Resources/StockPet.icns"
cp "$ROOT/native/Resources/OpenPets/"skin_rbull_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_gbear_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_pbull_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_ox_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_minicow_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_bubu_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_jokebear_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_obear_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_mech_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_polar_*.png "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"

cp -R "$APP" "$BUILD/dmg-root/"
ln -s /Applications "$BUILD/dmg-root/Applications"

hdiutil create \
  -volname "持仓宠物 $VERSION" \
  -srcfolder "$BUILD/dmg-root" \
  -ov -format UDZO \
  "$DMG"

rm -rf "$APP" "$BUILD/dmg-root"

echo "$DMG"
