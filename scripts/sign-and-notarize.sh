#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION_VALUE="$(tr -d '[:space:]' < VERSION)"
APP_IDENTITY="${LID_AWAKE_APP_SIGN_IDENTITY:?Set LID_AWAKE_APP_SIGN_IDENTITY to a Developer ID Application identity}"
PKG_IDENTITY="${LID_AWAKE_PKG_SIGN_IDENTITY:?Set LID_AWAKE_PKG_SIGN_IDENTITY to a Developer ID Installer identity}"
NOTARY_PROFILE="${LID_AWAKE_NOTARY_PROFILE:?Set LID_AWAKE_NOTARY_PROFILE to a notarytool keychain profile}"
UNSIGNED_PKG="build/LidAwake-${VERSION_VALUE}-unsigned.pkg"
SIGNED_PKG="build/LidAwake-${VERSION_VALUE}.pkg"

LID_AWAKE_APP_SIGN_IDENTITY="$APP_IDENTITY" zsh ./build-pkg.sh "$VERSION_VALUE"
productsign --sign "$PKG_IDENTITY" "$UNSIGNED_PKG" "$SIGNED_PKG"
pkgutil --check-signature "$SIGNED_PKG"
xcrun notarytool submit "$SIGNED_PKG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$SIGNED_PKG"
xcrun stapler validate "$SIGNED_PKG"
spctl --assess --type install --verbose=4 "$SIGNED_PKG"
shasum -a 256 "$SIGNED_PKG" > "$SIGNED_PKG.sha256"

print "Signed and notarized package: $SIGNED_PKG"
print "Checksum: $SIGNED_PKG.sha256"
