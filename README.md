# Lid Awake

[Русская версия](README_RU.md)

<p align="center">
  <a href="https://boosty.to/smd.monster/donate">
    <img src="https://img.shields.io/badge/Support_the_project-Boosty-f15f2c?style=for-the-badge" alt="Support the project on Boosty">
  </a>
</p>

Lid Awake is a macOS menu bar utility that keeps a MacBook running with the lid closed.

> Never place the MacBook in a bag while Lid Awake is enabled. The computer may remain active and generate heat.

## Features

- Permanent and temporary modes.
- Optional AC-only operation.
- Automatic low-battery suspension.
- Thermal protection.
- Immediate charger updates through IOKit.
- Independent lid-close actions: turn off the display, lock the session, and play a sound.
- The lid-close sound plays immediately; screen actions run only after the lid remains closed for a short debounce interval.
- Native notifications, diagnostics, rotating logs, CLI, and update checks.
- `.pkg` building, ad-hoc signing, Developer ID signing, and notarization support.

## Menu structure

The main menu contains the current mode, Enable, Disable, Temporary mode, Settings, Diagnostics, Open log, Check for updates, and Quit.

Inside **Settings**:

- Only while connected to power
- When the lid closes…
  - Turn off display
  - Lock screen
  - Play sound
  - Sound volume
- Thermal protection
- Notifications
- Launch at login
- Disable at battery level
- Maximum temporary duration
- Language

## How the mode works

Selecting Enable means Lid Awake should keep the Mac active until the user disables it. Temporary mode does the same until its timer expires.

Safety constraints do not cancel the user's request. Missing external power, low battery, or thermal pressure changes the state to Paused. When the constraint disappears, the mode resumes automatically.

## Power and battery handling

Lid Awake subscribes to native IOKit power-source notifications. Connecting or disconnecting the charger triggers immediate policy reconciliation, followed by another reconciliation after a short delay as a safeguard. A periodic timer remains as a fallback.

When **Only while connected to power** is enabled, battery operation moves the app into a waiting state. Connecting the charger automatically restores the requested mode.

**Disable at battery level** pauses the mode when battery charge is equal to or below the selected threshold. Connecting power or charging above the threshold allows automatic recovery.

## Thermal protection

Lid Awake does not measure a temperature in degrees. It uses macOS `ProcessInfo.processInfo.thermalState`:

- `nominal` — normal thermal state;
- `fair` — elevated load, no shutdown required;
- `serious` — serious thermal pressure;
- `critical` — critical thermal pressure.

At `serious` or `critical`, Lid Awake stops keeping the Mac active, changes the state to Paused, and records the reason in the event log. It automatically resumes after the state returns to `nominal` or `fair`, provided the mode is still requested.

## Lid-close actions

The actions are independent:

- **Turn off display** — turns off the display without issuing a separate lock command.
- **Lock screen** — locks the user session.
- **Play sound** — plays a short system sound.
- **Sound volume** — controls the signal volume relative to the current macOS system volume.

With system volume at 50%, 100% in Lid Awake means the loudest signal the app can produce without changing the system volume. It does not bypass the system output level.

macOS may require a password or Touch ID after display sleep according to **System Settings → Lock Screen**. Display sleep may therefore look like an explicit lock even when Lock screen is disabled in Lid Awake.

On macOS versions where the legacy `CGSession` utility is unavailable, Lid Awake requests immediate display sleep instead. This fallback is used only when **System Settings → Lock Screen** is configured to require a password immediately; otherwise Lid Awake reports that locking failed rather than claiming the session is secure.

## VPN clients and lid-close events

Lid Awake prevents the Mac from entering sleep, but third-party applications may still react to the lid-close event itself.

For example, Pritunl Client may restart the VPN connection when the lid is closed or opened, even while the Mac remains active.

To disable this behavior:

1. Open **Pritunl Client → Settings → Advanced Settings**.
2. Enable **Disable device wake watch**.
3. Restart Pritunl Client.

The VPN connection should then remain active while using Lid Awake.

> Important: this setting applies only to Pritunl Client. Lid Awake does not modify VPN-client settings or the configuration of other third-party applications.

## Notifications

Notifications are sent for meaningful state transitions, such as waiting for power, a safety suspension, or automatic recovery. Disabling notifications does not affect the keep-awake behavior.

## Menu bar icons

- open lock — permanent active mode;
- timer — temporary active mode;
- power plug — waiting for external power;
- battery — battery threshold restriction;
- thermometer — thermal restriction;
- moon — disabled.

## Installation

### Installer package

```bash
zsh ./build-pkg.sh
open build
```

The package is written to `build/LidAwake-<version>-unsigned.pkg`.

### Installation from source

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

The installer builds and tests the project, installs the application and required background components, and then verifies the result.

## Permissions

Screen locking does not require Accessibility permission.

The background agent may request notification permission.

## Temporary mode

The submenu provides standard durations, a custom duration, and timer cancellation. Cancelling temporary mode fully disables Lid Awake. A requested duration cannot exceed the configured maximum.

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

## Diagnostics and logs

Diagnostics include version, architecture, component state, active settings, power source, battery level, thermal state, lid state, and agent path.

- Agent log: `~/Library/Logs/Lid Awake/agent.log`
- Previous agent log: `~/Library/Logs/Lid Awake/agent.log.1`
- Event log: `~/Library/Application Support/Lid Awake/events.log`
- Previous event log: `~/Library/Application Support/Lid Awake/events.log.1`
- Last lid close: `~/Library/Application Support/Lid Awake/last-lid-close.txt`

Logs rotate at approximately 1 MB.

## Updates

**Check for updates…** reads the latest GitHub release. Automatic installer opening requires a matching `.pkg.sha256` asset, a matching SHA-256 checksum, and a package accepted by macOS as signed, trusted, and notarized.

## Versioning, signing, and notarization

`VERSION` is the source of truth. `install.sh` and `build-pkg.sh` generate `Sources/LidAwakeCore/BuildVersion.swift` and write the same version into the bundles.

Without `SIGN_IDENTITY`, local ad-hoc signatures are used. Developer ID signing and notarization are documented in [SIGNING.md](SIGNING.md).

## Uninstall

```bash
zsh ./uninstall.sh
```

The script restores normal sleep behavior and removes the application, background components, CLI, settings, and logs.

## License

[MIT](LICENSE)
