#!/bin/bash
# Build Axe.app from source.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/Axe.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

# Generate the app icon
swiftc -O "$HERE/makeicon.swift" -o "$HERE/makeicon" 2>/dev/null
"$HERE/makeicon"
rm -f "$HERE/makeicon"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

swiftc -O "$HERE/main.swift" -o "$MACOS/Axe"
cp "$HERE/AppIcon.icns" "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Axe</string>
    <key>CFBundleDisplayName</key><string>Axe</string>
    <key>CFBundleIdentifier</key><string>com.temery.axe</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Axe</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS is happy to run it
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Launch with:  open \"$APP\""
