#!/bin/bash
# Build Axe.app from source.
#
# Usage:
#   bash build.sh               — build + ad-hoc sign (local dev / testing)
#   bash build.sh --sign        — build + Developer ID sign + notarize + staple
#
# For --sign, set these env vars (or store them in a .env file beside this script):
#   TEAM_ID        Your 10-character Apple Developer Team ID
#                  (visible at developer.apple.com → Membership)
#   APPLE_ID       Your Apple ID email
#   APP_PASSWORD   App-specific password from appleid.apple.com
#                  → Security → App-Specific Passwords → Generate
#
# Example:
#   TEAM_ID=AB12CD34EF APPLE_ID=you@example.com APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
#     bash build.sh --sign
#
# Tip: store credentials in Keychain once so you never have to pass them again:
#   xcrun notarytool store-credentials "axe" \
#     --apple-id "you@example.com" --team-id "AB12CD34EF" --password "xxxx-xxxx-xxxx-xxxx"
# Then set NOTARYTOOL_PROFILE=axe instead of APPLE_ID / APP_PASSWORD.

set -euo pipefail

SIGN=false
while [[ $# -gt 0 ]]; do
    case $1 in --sign) SIGN=true; shift ;; *) shift ;; esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/Axe.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

# ── Read optional .env beside the script ─────────────────────────────────────
[[ -f "$HERE/.env" ]] && set -a && source "$HERE/.env" && set +a

TEAM_ID="${TEAM_ID:-}"
APPLE_ID="${APPLE_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"   # keychain profile (alternative to env vars)

# Pull version from main.swift so the bundle plist stays in sync
VERSION=$(grep '^let appVersion' "$HERE/main.swift" | sed 's/.*"\(.*\)".*/\1/')

# ── Build ─────────────────────────────────────────────────────────────────────
swiftc -O "$HERE/makeicon.swift" -o "$HERE/makeicon" 2>/dev/null
"$HERE/makeicon"
rm -f "$HERE/makeicon"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

swiftc -O "$HERE/main.swift" -o "$MACOS/Axe"
cp "$HERE/AppIcon.icns" "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Axe</string>
    <key>CFBundleDisplayName</key><string>Axe</string>
    <key>CFBundleIdentifier</key><string>com.emerytech.axe</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Axe</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# ── Sign ──────────────────────────────────────────────────────────────────────
if $SIGN; then
    if [[ -z "$TEAM_ID" ]]; then
        echo "✗ TEAM_ID is not set. See usage at the top of this script." >&2; exit 1
    fi

    SIGN_IDENTITY="Developer ID Application: Taylor Emery ($TEAM_ID)"

    echo "→ Signing with Developer ID..."
    codesign --force --deep \
             --options runtime \
             --entitlements "$HERE/entitlements.plist" \
             --sign "$SIGN_IDENTITY" \
             "$APP"
    codesign --verify --deep --strict "$APP"
    echo "   Signature OK"

    echo "→ Notarizing (takes ~1 minute)..."
    TMPZIP=$(mktemp /tmp/axe-notarize-XXXX.zip)
    ditto -c -k --keepParent "$APP" "$TMPZIP"

    if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
        xcrun notarytool submit "$TMPZIP" \
            --keychain-profile "$NOTARYTOOL_PROFILE" \
            --wait
    else
        if [[ -z "$APPLE_ID" || -z "$APP_PASSWORD" ]]; then
            echo "✗ Set APPLE_ID + APP_PASSWORD (or NOTARYTOOL_PROFILE) to notarize." >&2
            rm -f "$TMPZIP"; exit 1
        fi
        xcrun notarytool submit "$TMPZIP" \
            --apple-id  "$APPLE_ID" \
            --team-id   "$TEAM_ID" \
            --password  "$APP_PASSWORD" \
            --wait
    fi
    rm -f "$TMPZIP"

    echo "→ Stapling ticket..."
    xcrun stapler staple "$APP"

    echo "→ Creating release artifacts..."
    # Homebrew zip
    ditto -c -k --keepParent "$APP" "$HERE/../Axe.zip"
    echo "   Axe.zip  $(du -sh "$HERE/../Axe.zip" | cut -f1)"

    # DMG with Applications symlink (for direct download)
    DMGTMP=$(mktemp -d)
    cp -r "$APP" "$DMGTMP/"
    ln -s /Applications "$DMGTMP/Applications"
    hdiutil create -volname "Axe" -srcfolder "$DMGTMP" -ov -format UDZO \
        "$HERE/../Axe.dmg" 2>/dev/null
    rm -rf "$DMGTMP"
    echo "   Axe.dmg  $(du -sh "$HERE/../Axe.dmg" | cut -f1)"

    echo ""
    echo "✓ Built, signed, notarized, and stapled: $APP"
    echo "  Release artifacts ready: Axe.zip  Axe.dmg"
else
    # Ad-hoc sign for local dev
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "Built: $APP  (ad-hoc signed — for release use --sign)"
fi

echo "Launch with:  open \"$APP\""
