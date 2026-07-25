#!/bin/zsh
set -euo pipefail

APP_PATH="/Applications/Lid Awake.app"
HELPER_PATH="/usr/local/libexec/lid-awake-helper"
OLD_AGENT_PATH="/usr/local/libexec/lid-awake-agent"
CLI_PATH="/usr/local/bin/lid-awake"
RESET_PLIST="/Library/LaunchDaemons/su.xyz.LidAwake.reset.plist"
USER_AGENT_DIR="$HOME/Library/LaunchAgents"
POLICY_LABEL="su.xyz.LidAwake.agent"
APP_LABEL="su.xyz.LidAwake.app"
USER_ID="$(id -u)"
SUPPORT_DIR="$HOME/Library/Application Support/Lid Awake"
AGENT_APP_PATH="$SUPPORT_DIR/Lid Awake Agent.app"

for label in "$POLICY_LABEL" "$APP_LABEL" "su.xyz.LidAwakeAgent"; do
  launchctl bootout "gui/${USER_ID}/${label}" 2>/dev/null || true
done
pkill -x LidAwakeApp 2>/dev/null || true
pkill -x lid-awake-agent 2>/dev/null || true

if [[ -x "$HELPER_PATH" ]]; then sudo "$HELPER_PATH" off || true; else sudo /usr/bin/pmset -a disablesleep 0 || true; fi

sudo launchctl bootout system/su.xyz.LidAwake.reset 2>/dev/null || true
sudo rm -f "$RESET_PLIST" /etc/sudoers.d/lid-awake "$HELPER_PATH" "$OLD_AGENT_PATH" /usr/local/libexec/LidAwakeAgent "$CLI_PATH"
sudo rm -rf "$APP_PATH"
rm -f "$USER_AGENT_DIR/${POLICY_LABEL}.plist" "$USER_AGENT_DIR/${APP_LABEL}.plist" "$USER_AGENT_DIR/su.xyz.LidAwakeAgent.plist"
rm -rf "$AGENT_APP_PATH" "$SUPPORT_DIR/LidAwakeAgent.app" "$SUPPORT_DIR" "$HOME/Library/Logs/Lid Awake"
tccutil reset Accessibility su.xyz.LidAwake.Agent >/dev/null 2>&1 || true
tccutil reset Notifications su.xyz.LidAwake.Agent >/dev/null 2>&1 || true

printf 'Lid Awake removed. Normal sleep behavior restored.\n'
