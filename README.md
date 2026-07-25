# Lid Awake

A macOS menu bar utility that keeps your MacBook running with the lid closed.

## Features

- Enable or disable closed-lid operation from the menu bar.
- CLI control: `on`, `off`, `status`.
- Temporary mode with an automatic timeout.
- Fixed-command privileged helper; no arbitrary shell execution.
- Automatically restores normal sleep behavior after reboot and during uninstall.

> **Warning:** A closed MacBook can continue running and generating heat. Never place it in a bag while Lid Awake is enabled.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools

## Install

```bash
 git clone https://github.com/bulava92/lid-awake.git
 cd lid-awake
 zsh ./install.sh
```

The installer asks for an administrator password once. Normal use does not require entering it again.

Installed components:

```text
/Applications/Lid Awake.app
/usr/local/bin/lid-awake
/usr/local/libexec/lid-awake-helper
/Library/LaunchDaemons/su.xyz.LidAwake.reset.plist
/etc/sudoers.d/lid-awake
```

## CLI

```bash
lid-awake on
lid-awake off
lid-awake status
lid-awake for 900
lid-awake cancel-timer
```

`lid-awake for 900` enables the mode for 15 minutes and then restores normal sleep behavior.

## How it works

The application calls a root-owned helper that accepts only three commands: `on`, `off`, and `status`. The helper controls the macOS `pmset disablesleep` setting. A one-shot LaunchDaemon restores `disablesleep 0` during every boot.

## Uninstall

```bash
zsh ./uninstall.sh
```

Uninstalling always restores normal sleep behavior first.

## License

MIT
