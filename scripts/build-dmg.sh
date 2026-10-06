#!/bin/bash
# Builds MacFanPilot (Release, arm64), signs it and packs dist/MacFanPilot-<version>.dmg.
#
#   scripts/build-dmg.sh
#
# Signing: uses "Developer ID Application" for the team if that certificate is in the keychain,
# otherwise "Apple Development". Only a Developer ID build can be notarized; to notarize, store
# credentials once with `xcrun notarytool store-credentials <profile>` and run:
#
#   NOTARY_PROFILE=<profile> scripts/build-dmg.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MacFanPilot"
TEAM_ID="6MD59J7ZW5"
APP_ID="uz.stiv.macfanpilot"
HELPER_ID="uz.stiv.macfanpilot.helper"
BUILD_DIR="build"
DIST_DIR="dist"

# First valid signing identity of the given kind whose certificate belongs to the team.
find_identity() {
    local kind="$1" hash
    while read -r hash; do
        if security find-certificate -a -Z -p | awk -v h="$hash" '/^SHA-1 hash:/{p=($3==h)} p' \
            | openssl x509 -noout -subject 2>/dev/null | grep -q "OU=$TEAM_ID"; then
            echo "$hash"; return 0
        fi
    done < <(security find-identity -v -p codesigning | awk -v k="$kind" 'index($0, "\"" k ":") {print $2}')
    return 1
}

if IDENTITY=$(find_identity "Developer ID Application"); then
    KIND="Developer ID"
elif IDENTITY=$(find_identity "Apple Development"); then
    KIND="Apple Development"
else
    echo "error: no signing certificate for team $TEAM_ID in the keychain" >&2
    exit 1
fi
echo "==> Signing with $KIND ($IDENTITY)"

echo "==> Building"
mkdir -p "$BUILD_DIR"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" build > "$BUILD_DIR/xcodebuild.log" 2>&1 \
    || { tail -40 "$BUILD_DIR/xcodebuild.log"; echo "error: build failed, see $BUILD_DIR/xcodebuild.log" >&2; exit 1; }

STAGE="$BUILD_DIR/dmg"
APP="$STAGE/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST_DIR"
ditto "$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app" "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# Xcode signs builds without a timestamp. Re-sign inside out with a secure one, so the signature
# (and the XPC checks that depend on it) stays valid after the certificate expires.
echo "==> Re-signing with a secure timestamp"
sign() { codesign --force --options runtime --sign "$IDENTITY" "$@"; }
TIMESTAMP=(--timestamp)
if ! sign "${TIMESTAMP[@]}" --identifier "$HELPER_ID" "$APP/Contents/MacOS/${APP_NAME}Helper" 2>/dev/null; then
    [ "$KIND" = "Developer ID" ] && { echo "error: Apple's timestamp server is unreachable" >&2; exit 1; }
    echo "warning: timestamp server unreachable; signing without a timestamp" >&2
    TIMESTAMP=(--timestamp=none)
    sign "${TIMESTAMP[@]}" --identifier "$HELPER_ID" "$APP/Contents/MacOS/${APP_NAME}Helper"
fi
sign "${TIMESTAMP[@]}" --entitlements "App/$APP_NAME.entitlements" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict "$APP"
codesign --verify -R="anchor apple generic and identifier \"$APP_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$APP"
codesign --verify -R="anchor apple generic and identifier \"$HELPER_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
    "$APP/Contents/MacOS/${APP_NAME}Helper"
[ "$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")" = "arm64" ] || { echo "error: app is not arm64-only" >&2; exit 1; }

echo "==> Packing"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
codesign --force --sign "$IDENTITY" "${TIMESTAMP[@]}" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    [ "$KIND" = "Developer ID" ] || { echo "error: notarization needs a Developer ID certificate" >&2; exit 1; }
    echo "==> Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "==> $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '), $KIND$([ -n "${NOTARY_PROFILE:-}" ] && echo ", notarized"))"
