#!/bin/bash
set -e

APP="ProxyMenubar"
BUNDLE="${APP}.app"

echo "Compiling..."
swiftc ProxyMenubar.swift -framework AppKit -o "${APP}"

echo "Building icon..."
ICONSET="AppIcon.iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE database-network.png --out "${ICONSET}/icon_${SIZE}x${SIZE}.png" > /dev/null
    sips -z $((SIZE*2)) $((SIZE*2)) database-network.png --out "${ICONSET}/icon_${SIZE}x${SIZE}@2x.png" > /dev/null
done
iconutil -c icns "${ICONSET}" -o AppIcon.icns
rm -rf "${ICONSET}"

echo "Building app bundle..."
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${APP}" "${BUNDLE}/Contents/MacOS/"
cp AppIcon.icns "${BUNDLE}/Contents/Resources/"

cat > "${BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ProxyMenubar</string>
    <key>CFBundleIdentifier</key>
    <string>com.proxy-menubar</string>
    <key>CFBundleName</key>
    <string>Proxy Menubar</string>
    <key>CFBundleDisplayName</key>
    <string>Proxy Menubar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS doesn't block the unsigned binary
codesign --sign - --force "${BUNDLE}"

echo ""
echo "Done! ${BUNDLE} is ready."
echo "Run:  open ${BUNDLE}"
echo "Or drag to /Applications for permanent install."
