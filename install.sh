#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Lid Awake"
APP_PATH="/Applications/${APP_NAME}.app"
HELPER_PATH="/usr/local/libexec/lid-awake-helper"
CLI_PATH="/usr/local/bin/lid-awake"
RESET_PLIST="/Library/LaunchDaemons/su.xyz.LidAwake.reset.plist"
SUDOERS_PATH="/etc/sudoers.d/lid-awake"

swift build -c release

rm -rf build
mkdir -p "build/${APP_NAME}.app/Contents/MacOS"
cp ".build/release/LidAwakeApp" "build/${APP_NAME}.app/Contents/MacOS/LidAwakeApp"

cat > "build/${APP_NAME}.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lid Awake</string>
  <key>CFBundleDisplayName</key><string>Lid Awake</string>
  <key>CFBundleIdentifier</key><string>su.xyz.LidAwake</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>LidAwakeApp</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cat > build/su.xyz.LidAwake.reset.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>su.xyz.LidAwake.reset</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/libexec/lid-awake-helper</string>
    <string>off</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST

sudo install -d -m 755 /usr/local/bin /usr/local/libexec /Library/LaunchDaemons
sudo install -o root -g wheel -m 755 scripts/lid-awake-helper "$HELPER_PATH"
sudo install -o root -g wheel -m 755 .build/release/lid-awake "$CLI_PATH"
sudo install -o root -g wheel -m 644 build/su.xyz.LidAwake.reset.plist "$RESET_PLIST"

cat > build/lid-awake.sudoers <<EOF
%admin ALL=(root) NOPASSWD: ${HELPER_PATH} on, ${HELPER_PATH} off, ${HELPER_PATH} status
EOF
sudo visudo -cf build/lid-awake.sudoers
sudo install -o root -g wheel -m 440 build/lid-awake.sudoers "$SUDOERS_PATH"

sudo launchctl bootout system/su.xyz.LidAwake.reset 2>/dev/null || true
sudo launchctl bootstrap system "$RESET_PLIST"

sudo "$HELPER_PATH" off >/dev/null
sudo rm -rf "$APP_PATH"
sudo ditto "build/${APP_NAME}.app" "$APP_PATH"
sudo chown -R root:wheel "$APP_PATH"

open "$APP_PATH"
printf '\nInstalled Lid Awake 0.1.0. Normal sleep behavior is currently enabled.\n'
