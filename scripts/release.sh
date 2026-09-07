#!/bin/zsh
# Build a Developer ID–signed, notarized, stapled Portkeep DMG.
#
#   ./scripts/release.sh                 # build, sign, notarize, staple
#   ./scripts/release.sh --skip-notarize # local signed DMG only
#
# Notarization uses, in order:
#   1. PORTKEEP_NOTARY_PROFILE (or typeanywhere / AC_PASSWORD)
#   2. App Store Connect API key at ~/.appstoreconnect/private_keys
#      plus PORTKEEP_ASC_ISSUER if the key is a team key.

set -euo pipefail

ROOT="${0:A:h:h}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

SKIP_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

IDENTITY="${PORTKEEP_CODESIGN_IDENTITY:-Developer ID Application: Sajid Palagiri (CTGJJTS5R6)}"
TEAM="CTGJJTS5R6"
ENTITLEMENTS="$ROOT/Portside/Resources/Portkeep.entitlements"
DD="/tmp/portkeep-release"
DIST="$ROOT/dist"
VERSION="1.0.0"
BUILD="1"
APP_NAME="Portkeep"
DMG_NAME="Portkeep-${VERSION}.dmg"

say() { printf '%s\n' "$*"; }

sign_item() {
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"
}

cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate

say "building Release…"
rm -rf "$DD"
xcodebuild \
    -project Portkeep.xcodeproj \
    -scheme Portkeep \
    -configuration Release \
    -derivedDataPath "$DD" \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build

APP_SRC="$DD/Build/Products/Release/Portkeep.app"
rm -rf "$DIST"
mkdir -p "$DIST/app" "$DIST/dmg-stage" "$ROOT/website/downloads"
ditto "$APP_SRC" "$DIST/app/Portkeep.app"

APP_BUNDLE="$DIST/app/Portkeep.app"
SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"

say "signing Sparkle nested tools (inside-out, with timestamp)"
sign_item "$SPARKLE/XPCServices/Downloader.xpc"
sign_item "$SPARKLE/XPCServices/Installer.xpc"
sign_item "$SPARKLE/Updater.app"
sign_item "$SPARKLE/Autoupdate"
sign_item "$SPARKLE/Sparkle"
sign_item "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

HELPER="$APP_BUNDLE/Contents/Helpers/portkeep"
if [[ -x "$HELPER" ]]; then
    say "signing helper"
    sign_item --entitlements "$ENTITLEMENTS" "$HELPER"
fi
say "signing $APP_NAME.app with $IDENTITY"
sign_item --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

say "creating $DMG_NAME"
ditto "$DIST/app/Portkeep.app" "$DIST/dmg-stage/Portkeep.app"
ln -s /Applications "$DIST/dmg-stage/Applications"
hdiutil create \
    -volname "Portkeep" \
    -srcfolder "$DIST/dmg-stage" \
    -ov -format UDZO -imagekey zlib-level=9 \
    "$DIST/$DMG_NAME"
sign_item "$DIST/$DMG_NAME"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    say "skipped notarization"
else
    submit_notary() {
        local artifact="$1"
        if [[ -n "${PORTKEEP_NOTARY_PROFILE:-}" ]]; then
            xcrun notarytool submit "$artifact" --keychain-profile "$PORTKEEP_NOTARY_PROFILE" --wait
            return
        fi
        for profile in typeanywhere AC_PASSWORD portkeep; do
            if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
                xcrun notarytool submit "$artifact" --keychain-profile "$profile" --wait
                return
            fi
        done
        local key=""
        for candidate in \
            "$HOME/.appstoreconnect/private_keys/AuthKey_YKV875Q4HC.p8" \
            "$HOME/private_keys/AuthKey_YKV875Q4HC.p8"
        do
            [[ -f "$candidate" ]] && key="$candidate" && break
        done
        if [[ -n "$key" && -n "${PORTKEEP_ASC_ISSUER:-}" ]]; then
            xcrun notarytool submit "$artifact" \
                --key "$key" --key-id "YKV875Q4HC" \
                --issuer "$PORTKEEP_ASC_ISSUER" --wait
            return
        fi
        if [[ -n "$key" ]]; then
            xcrun notarytool submit "$artifact" \
                --key "$key" --key-id "YKV875Q4HC" --wait
            return
        fi
        echo "error: no notary credentials. Set PORTKEEP_NOTARY_PROFILE or PORTKEEP_ASC_ISSUER." >&2
        exit 1
    }
    say "submitting $DMG_NAME to Apple…"
    submit_notary "$DIST/$DMG_NAME"
    xcrun stapler staple "$DIST/$DMG_NAME"
    xcrun stapler staple "$DIST/app/Portkeep.app"
    xcrun stapler validate "$DIST/$DMG_NAME"
fi

cp -f "$DIST/$DMG_NAME" "$ROOT/website/downloads/$DMG_NAME"
SIZE=$(stat -f%z "$DIST/$DMG_NAME")
SIG=$(swift "$ROOT/scripts/sign-update.swift" "$DIST/$DMG_NAME" "$ROOT/Signing/sparkle_eddsa_private.b64")
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
cat > "$ROOT/website/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Portkeep</title>
    <link>https://portkeep.sajidpalagiri.com/appcast.xml</link>
    <description>Portkeep updates</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <enclosure
        url="https://portkeep.sajidpalagiri.com/downloads/${DMG_NAME}"
        length="${SIZE}"
        type="application/octet-stream"
        sparkle:edSignature="${SIG}"/>
    </item>
  </channel>
</rss>
EOF

CHECKSUM="$(shasum -a 256 "$DIST/$DMG_NAME" | awk '{print $1}')"
{
    echo "artifact: $DIST/$DMG_NAME"
    echo "version:  $VERSION ($BUILD)"
    echo "identity: $IDENTITY"
    echo "sha256:   $CHECKSUM"
    echo "site:     website/ (deploy to portkeep.sajidpalagiri.com)"
} | tee "$DIST/Portkeep-${VERSION}.sha256.txt"

say "done. DMG is at $DIST/$DMG_NAME"
