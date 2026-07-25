# Lid Awake

A macOS menu bar utility that keeps a MacBook working with the lid closed.

## Features

- Enable closed-lid operation for 15 minutes, 1 hour, or 8 hours.
- Automatically stop at the configured maximum duration.
- Optionally work only while connected to external power.
- Automatically disable at a selected battery level.
- Start the menu bar app and policy agent when the user signs in.
- Control everything from the menu bar or CLI.
- Restore normal sleep behavior after reboot and during uninstall.
- Use a root-owned helper restricted to `on`, `off`, and `status`; arbitrary commands are not accepted.

> **Warning:** Never put the MacBook in a bag while Lid Awake is enabled. A closed MacBook can remain active and generate heat.

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

The installer asks for the administrator password. Normal menu bar and CLI use does not require entering it again.

The application icon source is stored as `Assets/AppIcon.png`. During installation, macOS `sips` and `iconutil` generate the required `AppIcon.icns` and bundle it into the application.

## Defaults

- Closed-lid operation: disabled
- External power required: yes
- Battery cutoff: 20%
- Maximum duration: 8 hours
- Launch at login: enabled

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
```

`on` without a duration uses the configured maximum duration. The background agent checks power, battery, and expiry every 30 seconds.

## Architecture

- `LidAwakeApp` — menu bar interface.
- `lid-awake` — command-line interface and settings editor.
- `lid-awake-agent` — unprivileged policy agent running in the user session.
- `lid-awake-helper` — root-owned fixed-command helper controlling `pmset disablesleep`.
- `su.xyz.LidAwake.reset` — boot-time safety reset that restores `disablesleep 0`.

Settings and the latest status are stored locally in:

```text
~/Library/Application Support/Lid Awake/
```

## Manual validation

This repository intentionally has no GitHub Actions workflow. Validate on a Mac:

```bash
swift build -c release
swift test
zsh -n install.sh
zsh -n uninstall.sh
zsh -n scripts/lid-awake-helper
```

## Uninstall

```bash
zsh ./uninstall.sh
```

Uninstalling stops both user agents, restores normal sleep behavior, and removes settings, logs, binaries, and the application.

## License

MIT
