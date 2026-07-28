#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/持仓宠物.app"
VERSION="0.4.3"
DMG="$BUILD/持仓宠物.dmg"

rm -rf "$APP" "$BUILD/dmg-root"
find "$BUILD" -maxdepth 1 -type f -name '持仓宠物*.dmg' -exec rm -f {} + 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/dmg-root"

swiftc -parse-as-library \
  -D PUBLIC_CREATOR_SKINS \
  -target arm64-apple-macos15.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework UserNotifications \
  "$ROOT/native/StockPet.swift" \
  -o "$APP/Contents/MacOS/StockPet"

cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns "$ROOT/native/Resources/StockPet.iconset" -o "$APP/Contents/Resources/StockPet.icns"
else
  cp "$ROOT/native/Resources/StockPet.icns" "$APP/Contents/Resources/StockPet.icns"
fi
cp "$ROOT/native/Resources/OpenPets/"skin_{gptniang,pikachu,gian,suneo,shizuka,shinchan,maruko,atom,sailormoon,kagome,kaitokid,heimerdinger,yantianzong,cubaibai,sakiko,nimbus,yamada,maidlet,mikan,ricklet,totoro,trump,white_muse_realistic}_*.png \
  "$APP/Contents/Resources/"
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
