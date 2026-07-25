# Signing and notarization

Lid Awake currently installs unsigned by default. The repository already contains the files and scripts required to add Developer ID signing later without changing the application architecture.

## Prerequisites

- Apple Developer Program membership
- A `Developer ID Application` certificate installed in Keychain
- Xcode Command Line Tools
- Apple ID or App Store Connect API credentials for `notarytool`

## Signed local installation

List available identities:

```bash
security find-identity -v -p codesigning
```

Build, sign, verify, and install:

```bash
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" zsh ./install.sh
```

The installer signs:

- `Lid Awake.app`
- `lid-awake`
- `lid-awake-agent`

The app uses `Resources/LidAwake.entitlements` and the hardened runtime. The shell helper is installed as a root-owned fixed-command script and is not embedded inside the app bundle.

## Configure notarytool

Example with Apple ID credentials:

```bash
xcrun notarytool store-credentials lid-awake-notary \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

An App Store Connect API key can be used instead.

## Notarize

First build a signed app without deleting the `build` directory:

```bash
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" zsh ./install.sh
```

Then submit, wait, staple, and validate:

```bash
NOTARY_PROFILE="lid-awake-notary" zsh ./scripts/notarize-app.sh
```

The script runs:

- `codesign --verify`
- `ditto` to create a ZIP archive
- `xcrun notarytool submit --wait`
- `xcrun stapler staple`
- `xcrun stapler validate`
- `spctl --assess`

## Future release packaging

For a public signed release, package the stapled application as a DMG or ZIP after notarization. Do not notarize an unsigned build and do not modify the application bundle after stapling.
