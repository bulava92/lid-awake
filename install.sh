#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(print -r -- "$VERSION" | tr -cd '0-9')"
APP_NAME="Lid Awake"
APP_PATH="/Applications/${APP_NAME}.app"
HELPER_PATH="/usr/local/libexec/lid-awake-helper"
CLI_PATH="/usr/local/bin/lid-awake"
RESET_PLIST="/Library/LaunchDaemons/su.xyz.LidAwake.reset.plist"
USER_AGENT_DIR="$HOME/Library/LaunchAgents"
POLICY_LABEL="su.xyz.LidAwake.agent"
APP_LABEL="su.xyz.LidAwake.app"
SCHEDULE_LABEL="su.xyz.LidAwake.scheduler"
SCHEDULER_PATH="/usr/local/libexec/lid-awake-scheduler"
SCHEDULE_EDITOR_PATH="/usr/local/libexec/lid-awake-schedule-editor"
USER_ID="$(id -u)"
ICON_SOURCE="Assets/AppIcon.png"
ICONSET_PATH="build/AppIcon.iconset"
ICON_PATH="build/AppIcon.icns"
ENTITLEMENTS="Resources/LidAwake.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SUPPORT_DIR="$HOME/Library/Application Support/Lid Awake"
LANGUAGE_FILE="$SUPPORT_DIR/language.txt"
AGENT_APP_NAME="Lid Awake Agent"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lid-awake-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_BUILD_PATH="$STAGING_DIR/${APP_NAME}.app"
APP_CONTENTS="$APP_BUILD_PATH/Contents"
AGENT_BUILD_PATH="$STAGING_DIR/${AGENT_APP_NAME}.app"
AGENT_CONTENTS="$AGENT_BUILD_PATH/Contents"
AGENT_APP_PATH="$SUPPORT_DIR/${AGENT_APP_NAME}.app"
AGENT_EXECUTABLE="$AGENT_APP_PATH/Contents/MacOS/lid-awake-agent"
OLD_AGENT_PATH="/usr/local/libexec/lid-awake-agent"

[[ -f "$ICON_SOURCE" ]] || { print -u2 "Missing app icon: $ICON_SOURCE"; exit 66; }
[[ -f "$ENTITLEMENTS" ]] || { print -u2 "Missing entitlements: $ENTITLEMENTS"; exit 66; }
[[ -n "$VERSION" ]] || { print -u2 "VERSION is empty"; exit 66; }

cat > Sources/LidAwakeCore/BuildVersion.swift <<EOF
public enum BuildVersion {
    public static let current = "${VERSION}"
}
EOF

swift build -c release
.build/release/lid-awake-self-test
rm -rf build
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$AGENT_CONTENTS/MacOS" "$AGENT_CONTENTS/Resources" "$ICONSET_PATH"
cp ".build/release/LidAwakeApp" "$APP_CONTENTS/MacOS/LidAwakeApp"
cp ".build/release/lid-awake-agent" "$AGENT_CONTENTS/MacOS/lid-awake-agent"

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
cp "$ICON_PATH" "$AGENT_CONTENTS/Resources/AppIcon.icns"

cat > "$APP_CONTENTS/Info.plist" <<PLIST
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

cat > "$AGENT_CONTENTS/Info.plist" <<PLIST
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

# Finder metadata and resource forks can be inherited from downloaded assets.
# They make codesign reject the otherwise valid app bundle.
xattr -cr "$APP_BUILD_PATH" "$AGENT_BUILD_PATH"
for bundle in "$APP_BUILD_PATH" "$AGENT_BUILD_PATH"; do
  xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
done

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" ".build/release/lid-awake"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUILD_PATH"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$AGENT_BUILD_PATH"
else
  codesign --force --deep --sign - "$APP_BUILD_PATH"
  codesign --force --deep --sign - "$AGENT_BUILD_PATH"
  print "Developer ID is not set; using local ad-hoc signatures."
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUILD_PATH"
codesign --verify --deep --strict --verbose=2 "$AGENT_BUILD_PATH"

cat > build/reset.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>su.xyz.LidAwake.reset</string>
<key>ProgramArguments</key><array><string>/usr/local/libexec/lid-awake-helper</string><string>off</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST

# Stop and remove every known previous installation layout.
launchctl bootout "gui/${USER_ID}/${POLICY_LABEL}" 2>/dev/null || true
launchctl bootout "gui/${USER_ID}/${APP_LABEL}" 2>/dev/null || true
launchctl bootout "gui/${USER_ID}/${SCHEDULE_LABEL}" 2>/dev/null || true
launchctl bootout "gui/${USER_ID}/su.xyz.LidAwakeAgent" 2>/dev/null || true
pkill -x LidAwakeApp 2>/dev/null || true
pkill -x lid-awake-agent 2>/dev/null || true
pkill -x lid-awake-scheduler 2>/dev/null || true
pkill -x lid-awake-schedule-editor 2>/dev/null || true
rm -f "$USER_AGENT_DIR/su.xyz.LidAwakeAgent.plist"
sudo rm -f "$OLD_AGENT_PATH" /usr/local/libexec/LidAwakeAgent
rm -rf "$SUPPORT_DIR/LidAwakeAgent.app" "$SUPPORT_DIR/Lid Awake Agent.app"
# Accessibility is no longer required; remove the old bundle permission record.
tccutil reset Accessibility su.xyz.LidAwake.Agent >/dev/null 2>&1 || true

sudo install -d -m 755 /usr/local/bin /usr/local/libexec /Library/LaunchDaemons
sudo install -o root -g wheel -m 755 scripts/lid-awake-helper "$HELPER_PATH"
sudo install -o root -g wheel -m 755 .build/release/lid-awake "$CLI_PATH"
sudo install -o root -g wheel -m 755 .build/release/lid-awake-scheduler "$SCHEDULER_PATH"
sudo install -o root -g wheel -m 755 .build/release/lid-awake-schedule-editor "$SCHEDULE_EDITOR_PATH"
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
sudo ditto "$APP_BUILD_PATH" "$APP_PATH"
sudo chown -R root:wheel "$APP_PATH"
sudo xattr -cr "$APP_PATH"
sudo xattr -d com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
sudo xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_PATH" 2>/dev/null || true

mkdir -p "$USER_AGENT_DIR" "$HOME/Library/Logs/Lid Awake" "$SUPPORT_DIR"
ditto "$AGENT_BUILD_PATH" "$AGENT_APP_PATH"
chmod -R u+rwX,go+rX "$AGENT_APP_PATH"
xattr -cr "$AGENT_APP_PATH"
xattr -d com.apple.FinderInfo "$AGENT_APP_PATH" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$AGENT_APP_PATH" 2>/dev/null || true

if [[ ! -f "$LANGUAGE_FILE" ]]; then
  if defaults read -g AppleLanguages 2>/dev/null | grep -Eiq '(^|[^a-z])ru([^a-z]|$)'; then print -r -- "russian" > "$LANGUAGE_FILE"; else print -r -- "english" > "$LANGUAGE_FILE"; fi
fi

cat > "$USER_AGENT_DIR/${POLICY_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${POLICY_LABEL}</string>
<key>ProgramArguments</key><array><string>${AGENT_EXECUTABLE}</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
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
cat > "$USER_AGENT_DIR/${SCHEDULE_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${SCHEDULE_LABEL}</string>
<key>ProgramArguments</key><array><string>${SCHEDULER_PATH}</string><string>run</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>${HOME}/Library/Logs/Lid Awake/scheduler.log</string>
<key>StandardErrorPath</key><string>${HOME}/Library/Logs/Lid Awake/scheduler.log</string>
</dict></plist>
PLIST

launchctl bootstrap "gui/${USER_ID}" "$USER_AGENT_DIR/${POLICY_LABEL}.plist"
launchctl bootstrap "gui/${USER_ID}" "$USER_AGENT_DIR/${APP_LABEL}.plist"
launchctl bootstrap "gui/${USER_ID}" "$USER_AGENT_DIR/${SCHEDULE_LABEL}.plist"
launchctl enable "gui/${USER_ID}/${POLICY_LABEL}"
launchctl enable "gui/${USER_ID}/${APP_LABEL}"
launchctl enable "gui/${USER_ID}/${SCHEDULE_LABEL}"
launchctl kickstart -k "gui/${USER_ID}/${POLICY_LABEL}"
launchctl kickstart -k "gui/${USER_ID}/${APP_LABEL}"
launchctl kickstart -k "gui/${USER_ID}/${SCHEDULE_LABEL}"
"$SCHEDULER_PATH" init-default >/dev/null
sleep 1

# Installation self-checks.
[[ -x "$HELPER_PATH" ]] || { print -u2 "Helper verification failed"; exit 70; }
[[ -x "$CLI_PATH" ]] || { print -u2 "CLI verification failed"; exit 70; }
[[ -x "$SCHEDULER_PATH" ]] || { print -u2 "Scheduler verification failed"; exit 70; }
[[ -x "$SCHEDULE_EDITOR_PATH" ]] || { print -u2 "Schedule editor verification failed"; exit 70; }
[[ -x "$AGENT_EXECUTABLE" ]] || { print -u2 "Agent verification failed"; exit 70; }
[[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]] || { print -u2 "App icon verification failed"; exit 70; }
[[ -f "$AGENT_APP_PATH/Contents/Resources/AppIcon.icns" ]] || { print -u2 "Agent icon verification failed"; exit 70; }
codesign --verify --deep --strict "$APP_PATH"
codesign --verify --deep --strict "$AGENT_APP_PATH"
launchctl print "gui/${USER_ID}/${POLICY_LABEL}" >/dev/null
launchctl print "gui/${USER_ID}/${APP_LABEL}" >/dev/null
launchctl print "gui/${USER_ID}/${SCHEDULE_LABEL}" >/dev/null
POLICY_STATE="$("$CLI_PATH" status | /usr/bin/awk -F': ' 'NR == 1 { print $2 }')"
EXPECTED_HELPER_STATE="$([[ "$POLICY_STATE" == "enabled" ]] && print enabled || print disabled)"
[[ "$(sudo "$HELPER_PATH" status)" == "$EXPECTED_HELPER_STATE" ]] || {
  print -u2 "Helper state does not match policy state: policy=${POLICY_STATE}, helper=$(sudo "$HELPER_PATH" status)"
  exit 70
}

printf '\nInstalled and verified Lid Awake %s. Policy state: %s.\n' "$VERSION" "$POLICY_STATE"
