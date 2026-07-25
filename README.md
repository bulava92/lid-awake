# Lid Awake

[Русская версия](README_RU.md)

Lid Awake is a macOS menu bar utility that keeps a MacBook running with the lid closed.

> Never place the MacBook in a bag while Lid Awake is enabled. The computer may remain active and generate heat.

## Features

- Permanent mode until manually disabled.
- Temporary mode with 15-minute, 1-hour, 8-hour, and custom durations.
- Configurable maximum temporary duration; unavailable presets are disabled.
- Optional AC-only operation, battery cutoff, and thermal protection.
- Optional screen lock and display blanking when the lid closes.
- Optional lid-close sound with separate volume control.
- Native macOS notifications.
- Russian and English interface.
- Event-driven lid monitoring through IOKit, with a low-frequency fallback check.
- Menu bar icons for enabled, temporary, power-waiting, low-battery, thermal, and disabled states.
- Diagnostics, rotating logs, CLI, update checks, ad-hoc signing, and future Developer ID support.

## Menu structure

The main menu contains the current mode, Enable, Disable, Temporary mode, Settings, Diagnostics, Open log, Check for updates, and Quit.

All preferences are inside **Settings**:

- Only while connected to power
- Lock screen when lid closes
- Play sound when lid closes
- Sound volume
- Thermal protection
- Notifications
- Launch at login
- Disable at battery level
- Maximum temporary duration
- Language

## Installation

```bash
mkdir -p ~/Projects
cd ~/Projects
git clone https://github.com/bulava92/lid-awake.git
cd lid-awake
zsh ./install.sh
```

For an existing checkout:

```bash
cd ~/Projects/lid-awake
git pull
zsh ./install.sh
```

The installer builds and tests the project, migrates old layouts, creates the application and agent bundles, applies ad-hoc signatures when no Developer ID is supplied, installs LaunchAgents, resets `disablesleep` to the safe default, and verifies the installation.

## Permissions

Current versions use `CGSession` for screen locking and do **not** require Accessibility permission. Older builds used keyboard emulation as a fallback. If an old `lid-awake-agent` entry remains in **System Settings → Privacy & Security → Accessibility**, it can be removed.

The background agent may request notification permission when notifications are enabled.

## CLI

```bash
lid-awake on
lid-awake off
lid-awake for 3600
lid-awake cancel-timer
lid-awake status
lid-awake settings
lid-awake diagnostics
lid-awake version
```

The requested temporary duration must not exceed the configured maximum.

## Logs and diagnostics

- Agent log: `~/Library/Logs/Lid Awake/agent.log`
- Previous agent log: `~/Library/Logs/Lid Awake/agent.log.1`
- Event log: `~/Library/Application Support/Lid Awake/events.log`
- Previous event log: `~/Library/Application Support/Lid Awake/events.log.1`
- Last detected lid close: `~/Library/Application Support/Lid Awake/last-lid-close.txt`

Logs rotate at approximately 1 MB.

## Updates

**Check for updates…** reads the latest GitHub release. When a newer release exists, the dialog can open its release page.

## Versioning

`VERSION` is the source of truth. `install.sh` generates `Sources/LidAwakeCore/BuildVersion.swift` before building and writes the same version into both application bundles.

## Signing

Without `SIGN_IDENTITY`, both bundles receive local ad-hoc signatures. Developer ID signing and notarization are documented in [SIGNING.md](SIGNING.md).

## Uninstall

```bash
zsh ./uninstall.sh
```

The uninstaller restores normal sleep behavior and removes the app, agent, LaunchAgents, helper, CLI, settings, and logs.
