#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  echo "用法: ./build-app-store.sh <版本号> <构建号>"
  echo "示例: ./build-app-store.sh 0.4.3 12"
  exit 64
fi

VERSION="$1"
BUILD_NUMBER="$2"
ROOT="${0:A:h}"
OUTPUT="$ROOT/app-store-export"
APP="$OUTPUT/持仓宠物.app"
PKG="$OUTPUT/StockPet-v${VERSION}-build${BUILD_NUMBER}.pkg"
PROFILE_PLIST="$OUTPUT/profile.plist"
BUNDLE_ID="com.stockpet.desktop"

: "${APP_STORE_APP_IDENTITY:?请设置 APP_STORE_APP_IDENTITY（Mac App Distribution/Apple Distribution 证书名称）}"
: "${APP_STORE_INSTALLER_IDENTITY:?请设置 APP_STORE_INSTALLER_IDENTITY（Mac Installer Distribution 证书名称）}"
: "${APP_STORE_PROVISIONING_PROFILE:?请设置 APP_STORE_PROVISIONING_PROFILE（.provisionprofile 绝对路径）}"

if [[ ! -f "$APP_STORE_PROVISIONING_PROFILE" ]]; then
  echo "找不到描述文件: $APP_STORE_PROVISIONING_PROFILE"
  exit 66
fi

rm -rf "$OUTPUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

typeset -a binaries
for arch in arm64 x86_64; do
  binary="$OUTPUT/StockPet-$arch"
  xcrun swiftc -parse-as-library \
    -D PUBLIC_CREATOR_SKINS \
    -target "${arch}-apple-macos15.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework UserNotifications \
    -framework Security \
    -framework Vision \
    -framework UniformTypeIdentifiers \
    "$ROOT/native/StockPet.swift" \
    -o "$binary"
  binaries+=("$binary")
done
xcrun lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/StockPet"

cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"

cp "$ROOT/native/Resources/StockPet.icns" "$APP/Contents/Resources/StockPet.icns"
cp "$ROOT/native/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$ROOT/native/Resources/OpenPets/"skin_{gptniang,pikachu,gian,suneo,shizuka,shinchan,maruko,atom,sailormoon,kagome,kaitokid,heimerdinger,yantianzong,cubaibai,sakiko,nimbus,yamada,maidlet,mikan,ricklet,totoro,trump,white_muse_realistic}_*.png \
  "$APP/Contents/Resources/"

cp "$APP_STORE_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
security cms -D -i "$APP_STORE_PROVISIONING_PROFILE" > "$PROFILE_PLIST"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
if [[ "$profile_app_id" != *".$BUNDLE_ID" ]]; then
  echo "描述文件的 Application Identifier 与 $BUNDLE_ID 不匹配"
  exit 65
fi

codesign --force \
  --timestamp \
  --options runtime \
  --entitlements "$ROOT/native/StockPet.entitlements" \
  --sign "$APP_STORE_APP_IDENTITY" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
productbuild \
  --component "$APP" /Applications \
  --sign "$APP_STORE_INSTALLER_IDENTITY" \
  "$PKG"
pkgutil --check-signature "$PKG"

rm -f "${binaries[@]}" "$PROFILE_PLIST"
echo "$PKG"
