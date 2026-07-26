#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_VERSION="$(tr -d '[:space:]' < VERSION)"
VERSION="${1:-$PROJECT_VERSION}"
APP_NAME="Lid Awake"
AGENT_NAME="Lid Awake Agent"
BUILD_NUMBER="$(print -r -- "$VERSION" | tr -cd '0-9')"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lid-awake-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_PATH="$STAGING_DIR/${APP_NAME}.app"
AGENT_PATH="$STAGING_DIR/${AGENT_NAME}.app"
PKG_ROOT="$STAGING_DIR/pkg-root"
PKG_SCRIPTS="$STAGING_DIR/pkg-scripts"
PKG_PATH="build/LidAwake-${VERSION}-unsigned.pkg"
ICON_SOURCE="Assets/AppIcon.png"
ICONSET_PATH="$STAGING_DIR/AppIcon.iconset"
ICON_PATH="$STAGING_DIR/AppIcon.icns"
ENTITLEMENTS="Resources/LidAwake.entitlements"
APP_IDENTITY="${LID_AWAKE_APP_SIGN_IDENTITY:-}"

[[ "$VERSION" == "$PROJECT_VERSION" ]] || { print -u2 "Requested package version $VERSION does not match VERSION file $PROJECT_VERSION"; exit 64; }
[[ -f "$ICON_SOURCE" ]] || { print -u2 "Missing app icon: $ICON_SOURCE"; exit 66; }
[[ -f "$ENTITLEMENTS" ]] || { print -u2 "Missing entitlements: $ENTITLEMENTS"; exit 66; }

cat > Sources/LidAwakeCore/BuildVersion.swift <<EOF
public enum BuildVersion {
    public static let current = "${VERSION}"
}
EOF

swift build -c release
.build/release/lid-awake-self-test

rm -rf "$APP_PATH" "$AGENT_PATH" "$PKG_ROOT" "$PKG_SCRIPTS" "$ICONSET_PATH" "$ICON_PATH" "$PKG_PATH" "$PKG_PATH.sha256"
mkdir -p \
  "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" \
  "$AGENT_PATH/Contents/MacOS" "$AGENT_PATH/Contents/Resources" \
  "$ICONSET_PATH" "$PKG_ROOT/Applications" \
  "$PKG_ROOT/Library/Application Support/Lid Awake" \
  "$PKG_ROOT/Library/LaunchDaemons" \
  "$PKG_ROOT/usr/local/bin" "$PKG_ROOT/usr/local/libexec" \
  "$PKG_ROOT/etc/sudoers.d" "$PKG_SCRIPTS"

cp .build/release/LidAwakeApp "$APP_PATH/Contents/MacOS/LidAwakeApp"
cp .build/release/lid-awake-agent "$AGENT_PATH/Contents/MacOS/lid-awake-agent"

sips -z 16 16     "$ICON_SOURCE" --out "$ICONSET_PATH/icon_16x16.png" >/dev/null
sips -z 32 32     "$ICON_SOURCE" --out "$ICONSET_PATH/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ICON_SOURCE" --out "$ICONSET_PATH/icon_32x32.png" >/dev/null
sips -z 64 64     "$ICON_SOURCE" --out "$ICONSET_PATH/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ICON_SOURCE" --out "$ICONSET_PATH/icon_128x128.png" >/dev/null
sips -z 256 256   "$ICON_SOURCE" --out "$ICONSET_PATH/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_SOURCE" --out "$ICONSET_PATH/icon_256x256.png" >/dev/null
sips -z 512 512   "$ICON_SOURCE" --out "$ICONSET_PATH/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_SOURCE" --out "$ICONSET_PATH/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_PATH" -o "$ICON_PATH"
cp "$ICON_PATH" "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$ICON_PATH" "$AGENT_PATH/Contents/Resources/AppIcon.icns"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Lid Awake</string>
<key>CFBundleDisplayName</key><string>Lid Awake</string>
<key>CFBundleIdentifier</key><string>su.xyz.LidAwake</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleExecutable</key><string>LidAwakeApp</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

cat > "$AGENT_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Lid Awake Agent</string>
<key>CFBundleDisplayName</key><string>Lid Awake Agent</string>
<key>CFBundleIdentifier</key><string>su.xyz.LidAwake.Agent</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleExecutable</key><string>lid-awake-agent</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST

xattr -cr "$APP_PATH" "$AGENT_PATH"
for bundle in "$APP_PATH" "$AGENT_PATH"; do
  xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
done

if [[ -n "$APP_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP_PATH"
  codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$AGENT_PATH"
else
  codesign --force --deep --sign - "$APP_PATH"
  codesign --force --deep --sign - "$AGENT_PATH"
  print "Developer ID is not set; using local ad-hoc signatures."
fi
codesign --verify --deep --strict "$APP_PATH"
codesign --verify --deep --strict "$AGENT_PATH"

ditto "$APP_PATH" "$PKG_ROOT/Applications/${APP_NAME}.app"
ditto "$AGENT_PATH" "$PKG_ROOT/Library/Application Support/Lid Awake/${AGENT_NAME}.app"
xattr -cr "$PKG_ROOT/Applications/${APP_NAME}.app" "$PKG_ROOT/Library/Application Support/Lid Awake/${AGENT_NAME}.app"
install -m 755 .build/release/lid-awake "$PKG_ROOT/usr/local/bin/lid-awake"
install -m 755 scripts/lid-awake-helper "$PKG_ROOT/usr/local/libexec/lid-awake-helper"

cat > "$PKG_ROOT/Library/LaunchDaemons/su.xyz.LidAwake.reset.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>su.xyz.LidAwake.reset</string>
<key>ProgramArguments</key><array><string>/usr/local/libexec/lid-awake-helper</string><string>off</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
chmod 644 "$PKG_ROOT/Library/LaunchDaemons/su.xyz.LidAwake.reset.plist"

cat > "$PKG_ROOT/etc/sudoers.d/lid-awake" <<'SUDOERS'
%admin ALL=(root) NOPASSWD: /usr/local/libexec/lid-awake-helper on, /usr/local/libexec/lid-awake-helper off, /usr/local/libexec/lid-awake-helper status
SUDOERS
chmod 440 "$PKG_ROOT/etc/sudoers.d/lid-awake"
visudo -cf "$PKG_ROOT/etc/sudoers.d/lid-awake"

cat > "$PKG_SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/zsh
set -euo pipefail

APP_PATH="/Applications/Lid Awake.app"
SYSTEM_AGENT="/Library/Application Support/Lid Awake/Lid Awake Agent.app"
HELPER="/usr/local/libexec/lid-awake-helper"
RESET_LABEL="su.xyz.LidAwake.reset"
RESET_PLIST="/Library/LaunchDaemons/${RESET_LABEL}.plist"
POLICY_LABEL="su.xyz.LidAwake.agent"
APP_LABEL="su.xyz.LidAwake.app"

/usr/sbin/chown -R root:wheel "$APP_PATH" "/Library/Application Support/Lid Awake"
/bin/chmod 755 /usr/local/bin/lid-awake "$HELPER"
/bin/chmod 644 "$RESET_PLIST"
/bin/chmod 440 /etc/sudoers.d/lid-awake
/usr/sbin/visudo -cf /etc/sudoers.d/lid-awake

/bin/launchctl bootout system/$RESET_LABEL 2>/dev/null || true
/bin/launchctl bootstrap system "$RESET_PLIST"
"$HELPER" off >/dev/null

CONSOLE_USER=$(/usr/bin/stat -f '%Su' /dev/console)
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != root && "$CONSOLE_USER" != loginwindow ]]; then
  USER_ID=$(/usr/bin/id -u "$CONSOLE_USER")
  USER_HOME=$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | /usr/bin/awk '{print $2}')
  SUPPORT_DIR="$USER_HOME/Library/Application Support/Lid Awake"
  AGENT_PATH="$SUPPORT_DIR/Lid Awake Agent.app"
  AGENT_EXECUTABLE="$AGENT_PATH/Contents/MacOS/lid-awake-agent"
  LAUNCH_AGENTS="$USER_HOME/Library/LaunchAgents"
  LOG_DIR="$USER_HOME/Library/Logs/Lid Awake"
  LANGUAGE_FILE="$SUPPORT_DIR/language.txt"

  /bin/launchctl bootout "gui/${USER_ID}/${POLICY_LABEL}" 2>/dev/null || true
  /bin/launchctl bootout "gui/${USER_ID}/${APP_LABEL}" 2>/dev/null || true
  /usr/bin/pkill -x LidAwakeApp 2>/dev/null || true
  /usr/bin/pkill -x lid-awake-agent 2>/dev/null || true

  /bin/mkdir -p "$SUPPORT_DIR" "$LAUNCH_AGENTS" "$LOG_DIR"
  /bin/rm -rf "$AGENT_PATH"
  /usr/bin/ditto "$SYSTEM_AGENT" "$AGENT_PATH"

  if [[ ! -f "$LANGUAGE_FILE" ]]; then
    if /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/defaults read -g AppleLanguages 2>/dev/null | /usr/bin/grep -Eiq '(^|[^a-z])ru([^a-z]|$)'; then
      print -r -- "russian" > "$LANGUAGE_FILE"
    else
      print -r -- "english" > "$LANGUAGE_FILE"
    fi
  fi

  cat > "$LAUNCH_AGENTS/${POLICY_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${POLICY_LABEL}</string>
<key>ProgramArguments</key><array><string>${AGENT_EXECUTABLE}</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>${USER_HOME}/Library/Logs/Lid Awake/agent.log</string>
<key>StandardErrorPath</key><string>${USER_HOME}/Library/Logs/Lid Awake/agent.log</string>
</dict></plist>
PLIST

  cat > "$LAUNCH_AGENTS/${APP_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${APP_LABEL}</string>
<key>ProgramArguments</key><array><string>${APP_PATH}/Contents/MacOS/LidAwakeApp</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST

  /usr/sbin/chown -R "$CONSOLE_USER":staff "$SUPPORT_DIR" "$LAUNCH_AGENTS" "$LOG_DIR"
  /bin/chmod 644 "$LAUNCH_AGENTS/${POLICY_LABEL}.plist" "$LAUNCH_AGENTS/${APP_LABEL}.plist"
  /bin/launchctl bootstrap "gui/${USER_ID}" "$LAUNCH_AGENTS/${POLICY_LABEL}.plist"
  /bin/launchctl bootstrap "gui/${USER_ID}" "$LAUNCH_AGENTS/${APP_LABEL}.plist"
  /bin/launchctl enable "gui/${USER_ID}/${POLICY_LABEL}"
  /bin/launchctl enable "gui/${USER_ID}/${APP_LABEL}"
  /bin/launchctl kickstart -k "gui/${USER_ID}/${POLICY_LABEL}"
  /bin/launchctl kickstart -k "gui/${USER_ID}/${APP_LABEL}"
fi
POSTINSTALL
chmod 755 "$PKG_SCRIPTS/postinstall"

pkgbuild \
  --root "$PKG_ROOT" \
  --scripts "$PKG_SCRIPTS" \
  --identifier su.xyz.LidAwake \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  "$PKG_PATH"

shasum -a 256 "$PKG_PATH" > "$PKG_PATH.sha256"
printf '\nBuilt package: %s/%s\n' "$PWD" "$PKG_PATH"
