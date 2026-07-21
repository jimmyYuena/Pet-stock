#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/.dev/持仓宠物.app"
EXTENDED_SKINS=(labubu chiikawa usagi hachiware capy shuitunlulu deskotter nai gugugaga crybaby beretbear woolbell bubu jokebear obear)
SWIFT_FLAGS=()

if [[ -f "$ROOT/native/Resources/OpenPets/skin_labubu_idle_0.png" ]]; then
  SWIFT_FLAGS+=(-D LOCAL_EXTENDED_SKINS)
fi

pkill -x StockPet 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library \
  "${SWIFT_FLAGS[@]}" \
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
if (( ${#SWIFT_FLAGS[@]} > 0 )); then
  for prefix in "${EXTENDED_SKINS[@]}"; do
    cp "$ROOT/native/Resources/OpenPets/skin_${prefix}_"*.png "$APP/Contents/Resources/"
  done
fi
cp "$ROOT/native/Resources/OpenPets/"skin_mech_*.png "$APP/Contents/Resources/"
cp "$ROOT/native/Resources/OpenPets/"skin_polar_*.png "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP" >/dev/null
# 让 LaunchServices 重新登记这个 app 的图标，通知左侧才会显示新图标。
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP" 2>/dev/null || true
open "$APP"

echo "持仓宠物开发版已启动"
