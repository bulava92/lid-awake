#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.2.0"
APP_NAME="Lid Awake"
APP_PATH="/Applications/${APP_NAME}.app"
HELPER_PATH="/usr/local/libexec/lid-awake-helper"
AGENT_PATH="/usr/local/libexec/lid-awake-agent"
CLI_PATH="/usr/local/bin/lid-awake"
RESET_PLIST="/Library/LaunchDaemons/su.xyz.LidAwake.reset.plist"
USER_AGENT_DIR="$HOME/Library/LaunchAgents"
POLICY_LABEL="su.xyz.LidAwake.agent"
APP_LABEL="su.xyz.LidAwake.app"
USER_ID="$(id -u)"
ICON_SOURCE="Assets/AppIcon.png"
ICONSET_PATH="build/AppIcon.iconset"
ICON_PATH="build/AppIcon.icns"
APP_CONTENTS="build/${APP_NAME}.app/Contents"
ENTITLEMENTS="Resources/LidAwake.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SUPPORT_DIR="$HOME/Library/Application Support/Lid Awake"
LANGUAGE_FILE="$SUPPORT_DIR/language.txt"

[[ -f "$ICON_SOURCE" ]] || { print -u2 "Missing app icon: $ICON_SOURCE"; exit 66; }
[[ -f "$ENTITLEMENTS" ]] || { print -u2 "Missing entitlements: $ENTITLEMENTS"; exit 66; }

swift build -c release
rm -rf build
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$ICONSET_PATH"
cp ".build/release/LidAwakeApp" "$APP_CONTENTS/MacOS/LidAwakeApp"

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
cp "$ICON_PATH" "$APP_CONTENTS/Resources/AppIcon.icns"

cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Lid Awake</string>
<key>CFBundleDisplayName</key><string>Lid Awake</string>
<key>CFBundleIdentifier</key><string>su.xyz.LidAwake</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleExecutable</key><string>LidAwakeApp</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" ".build/release/lid-awake"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" ".build/release/lid-awake-agent"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "build/${APP_NAME}.app"
  codesign --verify --deep --strict --verbose=2 "build/${APP_NAME}.app"
else
  print "SIGN_IDENTITY is not set; installing unsigned build."
fi

cat > build/reset.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>su.xyz.LidAwake.reset</string>
<key>ProgramArguments</key><array><string>/usr/local/libexec/lid-awake-helper</string><string>off</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST

sudo install -d -m 755 /usr/local/bin /usr/local/libexec /Library/LaunchDaemons
sudo install -o root -g wheel -m 755 scripts/lid-awake-helper "$HELPER_PATH"
sudo install -o root -g wheel -m 755 .build/release/lid-awake-agent "$AGENT_PATH"
sudo install -o root -g wheel -m 755 .build/release/lid-awake "$CLI_PATH"
sudo install -o root -g wheel -m 644 build/reset.plist "$RESET_PLIST"

cat > build/lid-awake.sudoers <<EOF
%admin ALL=(root) NOPASSWD: ${HELPER_PATH} on, ${HELPER_PATH} off, ${HELPER_PATH} status
EOF
sudo visudo -cf build/lid-awake.sudoers
sudo install -o root -g wheel -m 440 build/lid-awake.sudoers /etc/sudoers.d/lid-awake

sudo launchctl bootout system/su.xyz.LidAwake.reset 2>/dev/null || true
sudo launchctl bootstrap system "$RESET_PLIST"
sudo "$HELPER_PATH" off >/dev/null
sudo rm -rf "$APP_PATH"
sudo ditto "build/${APP_NAME}.app" "$APP_PATH"
sudo chown -R root:wheel "$APP_PATH"

mkdir -p "$USER_AGENT_DIR" "$HOME/Library/Logs/Lid Awake" "$SUPPORT_DIR"
if [[ ! -f "$LANGUAGE_FILE" ]]; then
  if defaults read -g AppleLanguages 2>/dev/null | grep -Eiq '(^|[^a-z])ru([^a-z]|$)'; then
    print -r -- "russian" > "$LANGUAGE_FILE"
  else
    print -r -- "english" > "$LANGUAGE_FILE"
  fi
fi

cat > "$USER_AGENT_DIR/${POLICY_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${POLICY_LABEL}</string>
<key>ProgramArguments</key><array><string>${AGENT_PATH}</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>${HOME}/Library/Logs/Lid Awake/agent.log</string>
<key>StandardErrorPath</key><string>${HOME}/Library/Logs/Lid Awake/agent.log</string>
</dict></plist>
PLIST
cat > "$USER_AGENT_DIR/${APP_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${APP_LABEL}</string>
<key>ProgramArguments</key><array><string>${APP_PATH}/Contents/MacOS/LidAwakeApp</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST

launchctl bootout "gui/${USER_ID}/${POLICY_LABEL}" 2>/dev/null || true
launchctl bootout "gui/${USER_ID}/${APP_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${USER_ID}" "$USER_AGENT_DIR/${POLICY_LABEL}.plist"
launchctl bootstrap "gui/${USER_ID}" "$USER_AGENT_DIR/${APP_LABEL}.plist"
launchctl kickstart -k "gui/${USER_ID}/${POLICY_LABEL}"
launchctl kickstart -k "gui/${USER_ID}/${APP_LABEL}"

printf '\nInstalled Lid Awake %s. Closed-lid mode is disabled by default.\n' "$VERSION"
