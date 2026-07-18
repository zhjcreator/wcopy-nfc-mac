#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="wCopy NFC"
DIST="$ROOT/dist"
BUNDLE="$DIST/$APP_NAME.app"
CLI="$DIST/wcopy-nfc"
STAGING="$DIST/.build-app.$$"
STAGED_BUNDLE="$STAGING/$APP_NAME.app"
STAGED_CLI="$STAGING/wcopy-nfc"
trap 'rm -rf "$STAGING"' EXIT
rm -rf "$STAGING"
mkdir -p "$STAGING"
MACOS="$STAGED_BUNDLE/Contents/MacOS"
RESOURCES="$STAGED_BUNDLE/Contents/Resources"
ARCHS_VALUE="${ARCHS:-$(uname -m)}"

mkdir -p "$MACOS" "$RESOURCES"

BINARIES=()
for ARCH in $ARCHS_VALUE; do
    swift build --package-path "$ROOT" -c release --arch "$ARCH"
    BINARIES+=("$ROOT/.build/$ARCH-apple-macosx/release/WCopyNFCMac")
done

if [[ ${#BINARIES[@]} -eq 1 ]]; then
    cp "${BINARIES[0]}" "$MACOS/WCopyNFCMac"
else
    lipo -create "${BINARIES[@]}" -output "$MACOS/WCopyNFCMac"
fi
cp "$MACOS/WCopyNFCMac" "$STAGED_CLI"

cp "$ROOT/LICENSE" "$RESOURCES/LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"

ICONSET="$STAGING/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -s format png "$ROOT/Resources/AppIcon.svg" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$STAGED_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>wCopy NFC</string>
    <key>CFBundleExecutable</key>
    <string>WCopyNFCMac</string>
    <key>CFBundleIdentifier</key>
    <string>app.wcopy.nfc.mac</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>wCopy NFC</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License · Based on wcopy-nfc-linux</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$STAGED_BUNDLE"
codesign --force --sign - "$STAGED_CLI"
codesign --verify --deep --strict "$STAGED_BUNDLE"
codesign --verify --strict "$STAGED_CLI"

rm -rf "$BUNDLE"
rm -f "$CLI"
mv "$STAGED_BUNDLE" "$BUNDLE"
mv "$STAGED_CLI" "$CLI"
echo "Built: $BUNDLE"
echo "Built: $CLI"
