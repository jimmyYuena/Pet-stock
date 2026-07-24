#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
# 用可见目录（不要用隐藏的 .dev）：macOS 不索引 dot 目录里的 app，
# 会导致通知/图标服务取不到 app 图标（通知左侧空白）。
APP="$ROOT/dev-build/持仓宠物.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
source "$ROOT/packaging/public-pet-skins.zsh"
SWIFT_FLAGS=(-D PUBLIC_CREATOR_SKINS)
HAS_LOCAL_EXTENDED_SKINS=false

if [[ -f "$ROOT/native/Resources/OpenPets/skin_labubu_idle_0.png" ]]; then
  SWIFT_FLAGS=(-D LOCAL_EXTENDED_SKINS)
  HAS_LOCAL_EXTENDED_SKINS=true
fi

pkill -x StockPet 2>/dev/null || true
# 注销并删除旧的隐藏目录构建，清掉它遗留的空白图标登记
if [[ -d "$ROOT/.dev/持仓宠物.app" ]]; then
  "$LSREGISTER" -u "$ROOT/.dev/持仓宠物.app" 2>/dev/null || true
fi
rm -rf "$ROOT/.dev"
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
if [[ "$HAS_LOCAL_EXTENDED_SKINS" == true ]]; then
  cp "$ROOT/native/Resources/OpenPets/"skin_*.png "$APP/Contents/Resources/"
else
  copy_public_pet_skins \
    "$ROOT/native/Resources/OpenPets" \
    "$APP/Contents/Resources"
fi
codesign --force --deep --sign - "$APP" >/dev/null
# 让 LaunchServices 重新登记这个 app 的图标，并刷新 Dock / 通知守护进程的图标缓存，
# 否则通知左侧会一直沿用早期构建缓存下来的空白图标。
"$LSREGISTER" -f "$APP" 2>/dev/null || true
killall Dock 2>/dev/null || true
killall usernoted 2>/dev/null || true
open "$APP"

echo "持仓宠物开发版已启动"
