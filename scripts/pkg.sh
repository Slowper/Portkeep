#!/bin/zsh
# Build an MDM installer: /Applications/Portkeep.app + /usr/local/bin/portkeep.
#
#   ./scripts/pkg.sh --dev     package the Debug build (local test)
#   ./scripts/pkg.sh           package dist/app/Portkeep.app, or a Release build
#   ./scripts/pkg.sh /path/to/Portkeep.app
#
# Does not notarize. Does not install.

set -euo pipefail

ROOT="${0:A:h:h}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

VERSION="1.0.0"
IDENTIFIER="com.sajidpalagiri.portkeep"
INSTALLER_IDENTITY="${PORTKEEP_INSTALLER_IDENTITY:-Developer ID Installer: Sajid Palagiri (CTGJJTS5R6)}"
DEV=0
APP=""

for arg in "$@"; do
    case "$arg" in
        --dev) DEV=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) APP="$arg" ;;
    esac
done

if [[ -z "$APP" ]]; then
    if [[ "$DEV" -eq 1 ]]; then
        APP="/tmp/portkeep-dd/Build/Products/Debug/Portkeep.app"
        if [[ ! -d "$APP" ]]; then
            xcodegen generate
            xcodebuild -project "$ROOT/Portkeep.xcodeproj" -scheme Portkeep \
                -configuration Debug -derivedDataPath /tmp/portkeep-dd build
        fi
    elif [[ -d "$ROOT/dist/app/Portkeep.app" ]]; then
        APP="$ROOT/dist/app/Portkeep.app"
    else
        echo "error: no app. Pass --dev, a path to Portkeep.app, or build a Release first." >&2
        exit 2
    fi
fi

APP="${APP:A}"
if [[ ! -d "$APP" ]]; then
    echo "error: missing $APP" >&2
    exit 2
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/root/Applications" "$STAGING/scripts" "$ROOT/dist/mdm"

ditto "$APP" "$STAGING/root/Applications/Portkeep.app"
cp -f "$ROOT/mdm/scripts/preinstall" "$STAGING/scripts/preinstall"
cp -f "$ROOT/mdm/scripts/postinstall" "$STAGING/scripts/postinstall"
chmod 755 "$STAGING/scripts/preinstall" "$STAGING/scripts/postinstall"

COMPONENT="$STAGING/Portkeep-component.pkg"
pkgbuild \
    --root "$STAGING/root" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location / \
    --scripts "$STAGING/scripts" \
    "$COMPONENT"

OUT="$ROOT/dist/Portkeep-${VERSION}.pkg"
if security find-identity -v | grep -q "Developer ID Installer: Sajid Palagiri"; then
    productbuild --package "$COMPONENT" --sign "$INSTALLER_IDENTITY" "$OUT"
    echo "signed with $INSTALLER_IDENTITY"
else
    productbuild --package "$COMPONENT" "$OUT"
    echo "unsigned pkg (no Developer ID Installer cert). Jamf/Kandji can still deploy it."
fi

cp -f "$ROOT/mdm/com.sajidpalagiri.portkeep.plist" "$ROOT/dist/mdm/"
cp -f "$ROOT/mdm/Portkeep.mobileconfig" "$ROOT/dist/mdm/"
cp -f "$ROOT/mdm/IT.txt" "$ROOT/dist/mdm/"

pkgutil --payload-files "$OUT" | head
echo "pkg: $OUT"
echo "it:  $ROOT/dist/mdm/"
