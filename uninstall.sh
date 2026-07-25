#!/bin/zsh
set -euo pipefail

APP_PATH="/Applications/Lid Awake.app"
HELPER_PATH="/usr/local/libexec/lid-awake-helper"
CLI_PATH="/usr/local/bin/lid-awake"
RESET_PLIST="/Library/LaunchDaemons/su.xyz.LidAwake.reset.plist"
SUDOERS_PATH="/etc/sudoers.d/lid-awake"

pkill -x LidAwakeApp 2>/dev/null || true

if [[ -x "$HELPER_PATH" ]]; then
  sudo "$HELPER_PATH" off || true
else
  sudo /usr/bin/pmset -a disablesleep 0 || true
fi

sudo launchctl bootout system/su.xyz.LidAwake.reset 2>/dev/null || true
sudo rm -f "$RESET_PLIST" "$SUDOERS_PATH" "$HELPER_PATH" "$CLI_PATH"
sudo rm -rf "$APP_PATH"
rm -rf "$HOME/Library/Application Support/Lid Awake"

printf 'Lid Awake removed. Normal sleep behavior restored.\n'
