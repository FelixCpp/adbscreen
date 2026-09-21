# ADBScreen

A macOS app that mirrors Android device screens (via `adb`/`scrcpy`) and
receives AirPlay streams from iPhone/iPad, all in one place.

## Requirements

- macOS 14+
- Xcode (with command line tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Development

```bash
./run.sh
```

Debug build using Xcode's normal DerivedData (fast incremental builds).
Launches the freshly built app directly, quitting any previously running
instance first.

## Local install

```bash
./build.sh
```

Clean Release build, exported to `./build/ADBScreen.app` and installed
straight into `/Applications/ADBScreen.app` — no manual drag/`mv` needed.

```bash
./reinstall.sh
```

Full reset: revokes every macOS privacy permission ever granted to
ADBScreen (Local Network, Screen Recording, ...), forgets its
preferences (remembered devices, onboarding state, window layout), then
rebuilds and reinstalls via `build.sh`. Use this when you want the app
to behave like a fresh install, e.g. to re-test onboarding.

Both scripts are ad-hoc signed (`CODE_SIGN_IDENTITY: "-"` in
`project.yml`) — fine for your own Mac, but the resulting `.app` will
**not** open on anyone else's Mac (Gatekeeper blocks it as "damaged").
Use `package.sh` for anything you intend to share.

## Distributing to other people

```bash
./package.sh
```

Produces `dist/ADBScreen-<version>.dmg`. Without any environment
variables it builds an ad-hoc DMG, useful only for testing the
packaging flow itself.

To produce a DMG that actually runs on other people's Macs, you need
an [Apple Developer Program](https://developer.apple.com/programs/)
membership and a **Developer ID Application** certificate:

1. Create/download the certificate in Xcode (Settings → Accounts →
   Manage Certificates) or on the
   [Apple Developer portal](https://developer.apple.com/account/resources/certificates/list).
2. Generate an
   [app-specific password](https://support.apple.com/en-us/102654)
   for your Apple ID, used for notarization.
3. Store notarization credentials once:
   ```bash
   xcrun notarytool store-credentials adbscreen-notary \
     --apple-id you@example.com \
     --team-id TEAMID \
     --password <app-specific-password>
   ```
4. Build, sign and notarize:
   ```bash
   DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="adbscreen-notary" \
   ./package.sh
   ```

This signs the app (and the embedded `adbscreen-airplay-helper`
binary) with your Developer ID, enables the Hardened Runtime, submits
the DMG to Apple's notary service, waits for approval, and staples the
notarization ticket to the DMG. That stapled DMG is the artifact to
hand out — recipients can open it without any Gatekeeper warning.

### CI

`.github/workflows/release.yml` runs `package.sh` on pushes to `main`,
on `v*` tags, and on manual dispatch. It builds an (ad-hoc, unless
secrets are configured) DMG on every run and uploads it as a build
artifact; on `v*` tags with notarization secrets configured, it also
attaches the notarized DMG to a GitHub release.

To enable signing/notarization in CI, add these repository secrets
(Settings → Secrets and variables → Actions):

| Secret | Description |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | `base64 -i DeveloperIDApplication.p12 \| pbcopy` of your exported certificate + private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password the `.p12` was exported with |
| `KEYCHAIN_PASSWORD` | Any throwaway password for the temporary CI keychain |
| `APPLE_TEAM_ID` | Your Apple Developer Team ID |
| `NOTARY_APPLE_ID` | Apple ID email used for notarization |
| `NOTARY_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |

Without these secrets the workflow still builds and uploads an ad-hoc
DMG artifact (handy for verifying the packaging flow on every push),
it just won't attach anything to a release.

## Project structure

- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  spec; the source of truth for the Xcode project (`ADBScreen.xcodeproj`
  is generated and gitignored).
- `Sources/ADBScreen` — app sources, `Info.plist`, entitlements, and
  bundled resources (`scrcpy-server`, `adbscreen-airplay-helper`).
- `vendor` — third-party sources used to build the bundled
  `adbscreen-airplay-helper` binary (see `vendor/SHA256SUMS.txt` for
  provenance of the vendored `scrcpy-server` release).
