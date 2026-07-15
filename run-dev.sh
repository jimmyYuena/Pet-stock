#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/.dev/持仓宠物.app"

pkill -x StockPet 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library \
  -target arm64-apple-macos14.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework UserNotifications \
  "$ROOT/native/StockPet.swift" \
  -o "$APP/Contents/MacOS/StockPet"

cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null
open "$APP"

echo "持仓宠物开发版已启动"
