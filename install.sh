#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

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

swift build -c release
rm -rf build
mkdir -p "build/${APP_NAME}.app/Contents/MacOS"
cp ".build/release/LidAwakeApp" "build/${APP_NAME}.app/Contents/MacOS/LidAwakeApp"

cat > "build/${APP_NAME}.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Lid Awake</string>
<key>CFBundleDisplayName</key><string>Lid Awake</string>
<key>CFBundleIdentifier</key><string>su.xyz.LidAwake</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleExecutable</key><string>LidAwakeApp</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

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

mkdir -p "$USER_AGENT_DIR" "$HOME/Library/Logs/Lid Awake"
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

printf '\nInstalled Lid Awake 1.0.0. It starts at login; closed-lid mode is disabled by default.\n'
