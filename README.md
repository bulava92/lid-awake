# Lid Awake

[Русская версия](README_RU.md)

A macOS menu bar utility that keeps a MacBook working with the lid closed.

> **Warning:** Never put the MacBook in a bag while Lid Awake is enabled. A closed MacBook can remain active and generate heat.

## Features

- Enable closed-lid operation for 15 minutes, 1 hour, or 8 hours.
- Automatically stop at the configured maximum duration.
- Optionally work only while connected to external power.
- Pause automatically at the selected battery level.
- Pause automatically when macOS reports a serious or critical thermal state.
- Resume after safe conditions return, provided the timer has not expired.
- Show remaining time, power source, battery level, and thermal state.
- Notify when the effective state changes.
- Start the menu bar app and policy agent at login.
- Russian and English interface.
- Select Russian on first install when macOS uses Russian; otherwise select English.
- Switch manually between **Русский** and **English** from the menu.
- Diagnostics, event history, and agent logs.
- Manual update checks through GitHub Releases.
- Menu bar and CLI control.
- Root-owned helper restricted to `on`, `off`, and `status`.
- Restore normal sleep behavior after reboot and during uninstall.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools
- An administrator account for installation

## Install

```bash
git clone https://github.com/bulava92/lid-awake.git
cd lid-awake
zsh ./install.sh
```

For an existing clone:

```bash
git pull
zsh ./install.sh
```

The installer asks for the administrator password. Normal menu bar and CLI use does not require entering it again.

The application icon source is stored as `Assets/AppIcon.png`. During installation, `sips` and `iconutil` generate `AppIcon.icns` and bundle it into the application.

## Defaults

- Closed-lid operation: disabled
- External power required: yes
- Battery cutoff: 20%
- Maximum duration: 8 hours
- Thermal protection: enabled
- Notifications: enabled
- Launch at login: enabled
- Language: Russian for Russian macOS, English otherwise

## Language

At first installation, the installer writes one of two language choices based on macOS:

- `russian`
- `english`

The menu contains only **Русский** and **English**. The selected value is retained across upgrades.

```bash
lid-awake language russian
lid-awake language english
```

## CLI

```bash
lid-awake on
lid-awake on 3600
lid-awake for 900
lid-awake off
lid-awake status
lid-awake settings
lid-awake ac-only on
lid-awake ac-only off
lid-awake battery-limit 20
lid-awake max-duration 28800
lid-awake thermal-protection on
lid-awake notifications on
lid-awake launch-at-login on
lid-awake diagnostics
lid-awake log-path
lid-awake version
```

`on` without a duration uses the configured maximum duration. The background agent checks power, battery, thermal state, and expiry every 30 seconds.

## Diagnostics and logs

The menu provides:

- **Open Diagnostics…**
- **Open Logs**
- **Check for Updates…**

Local state and logs are stored in:

```text
~/Library/Application Support/Lid Awake/
~/Library/Logs/Lid Awake/agent.log
```

## Architecture

- `LidAwakeApp` — localized menu bar interface.
- `lid-awake` — CLI and settings editor.
- `lid-awake-agent` — unprivileged policy agent.
- `lid-awake-helper` — root-owned fixed-command helper controlling `pmset disablesleep`.
- `su.xyz.LidAwake.reset` — boot-time safety reset restoring `disablesleep 0`.

## Manual validation

This repository intentionally has no GitHub Actions workflow. Validate on a Mac:

```bash
swift build -c release
swift test
zsh -n install.sh
zsh -n uninstall.sh
zsh -n scripts/lid-awake-helper
zsh -n scripts/notarize-app.sh
```

## Signing and notarization

Unsigned installation remains the default. The repository is prepared for future Developer ID signing and notarization.

```bash
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" zsh ./install.sh
```

After configuring a `notarytool` keychain profile:

```bash
NOTARY_PROFILE="lid-awake-notary" zsh ./scripts/notarize-app.sh
```

See [SIGNING.md](SIGNING.md).

## Uninstall

```bash
zsh ./uninstall.sh
```

Uninstalling stops both user agents, restores normal sleep behavior, and removes settings, logs, binaries, and the application.

## License

MIT
