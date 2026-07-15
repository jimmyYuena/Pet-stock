#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/.dev/持仓宠物.app"

pkill -x StockPet 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

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
codesign --force --deep --sign - "$APP" >/dev/null
open "$APP"

echo "持仓宠物开发版已启动"
