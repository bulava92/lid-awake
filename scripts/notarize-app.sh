#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${1:-build/Lid Awake.app}"
PROFILE="${NOTARY_PROFILE:-}"
ARCHIVE="build/Lid-Awake-notarization.zip"

[[ -d "$APP_PATH" ]] || { print -u2 "App not found: $APP_PATH"; exit 66; }
[[ -n "$PROFILE" ]] || {
  print -u2 "Set NOTARY_PROFILE to an xcrun notarytool keychain profile."
  print -u2 "Example: xcrun notarytool store-credentials lid-awake-notary --apple-id ... --team-id ..."
  exit 64
}

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

printf 'Notarized and stapled: %s\n' "$APP_PATH"
