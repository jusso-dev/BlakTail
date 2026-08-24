# macOS desktop app

SwiftUI menu bar + status window that signs in through the onshore console (Better Auth),
stores the session token in Keychain, and starts/stops local `blaktaild` without using the
terminal.

**Choice:** native SwiftUI (not Tauri). The Mac agent is already a LaunchDaemon
(`com.blaktail.agent`); a Swift shell talks to it with `launchctl` and the `blaktaild`
CLI.

**Minimum macOS:** macOS 14 Sonoma (`LSMinimumSystemVersion` / Package.swift `macOS(.v14)`).

## Layout

| Path | Role |
| --- | --- |
| `apps/macos/Sources/BlakTailCore` | Auth, Keychain, agent driver, tagline |
| `apps/macos/Sources/BlakTail` | Menu bar + windows |
| `apps/console/src/app/desktop` | Browser sign-in page for ASWebAuthenticationSession |
| `apps/console/src/app/api/desktop` | `/me` and `/join-key` for the Mac app |
| `apps/console/src/lib/desktop-auth.ts` | Bearer session → console context |

Console bridge files merge with the Next.js console from the Better Auth work. They call the
same onshore coordinator; no offshore IdP.

## Build (on a Mac)

```sh
cd apps/macos
swift test
swift build -c release
```

To produce a signed `.app` for distribution, open the package in Xcode (or create an App
target that links `BlakTailCore`), set the bundle ID to `au.org.blaktail.desktop`, and use
`Resources/Info.plist` so the `blaktail://` URL scheme is registered. `LSUIElement` keeps
the app menu-bar-first.

## Sign in and connect

1. Set the onshore console URL in the status window (Australian-hosted HTTPS only).
2. **Sign in…** opens ASWebAuthenticationSession against `/desktop/auth`.
3. After sign-in, the console redirects to `blaktail://auth/callback#token=…`. The token is
   stored in Keychain (`au.org.blaktail.desktop` / `better-auth.session_token`).
4. The desktop `/me` response lists every live accessible organisation without
   replacing the Better Auth session. **Connect** supplies the selected organisation ID
   when it asks the console to mint a short-lived join key, then runs `blaktaild up`
   with the key on **stdin only** (never `--join-key`, never process env that persists).
   The LaunchDaemon is bootstrapped afterward.
5. Status shows connection state, device name, tailnet IP, and the last error.
6. **Disconnect** boots out the daemon and runs `blaktaild down`.
7. **Quit** clears transient UI state. It does not leave the join key in argv, environment,
   or UserDefaults. The session token may remain in Keychain until **Sign out**.

About BlakTail shows the shared project mission:

> Built by Indigenous Australians for Indigenous Australian organisations. Data stays onshore, Indigenous Australian organisations stay in control, and the code stays public.

## Australian English

UI copy uses Australian English (organisation, cancelled, unauthorised, notarisation).

## Notarisation (do not buy certificates in CI)

Developer ID Application signing and Apple notarisation are **manual operator steps**, not
CI jobs. CI must not purchase, renew, or upload payment-backed signing
certificates.

Suggested local release flow on a Mac with your organisation’s Developer ID:

```sh
# After building BlakTail.app
codesign --force --options runtime --sign "Developer ID Application: YOUR ORG" BlakTail.app
ditto -c -k --keepParent BlakTail.app BlakTail.zip
xcrun notarytool submit BlakTail.zip --keychain-profile "notary" --wait
xcrun stapler staple BlakTail.app
```

Store Notary credentials in the local Keychain profile (`notarytool store-credentials`), not
in the git repository. GitHub Actions for this repo run on hosted runners (`ubuntu-latest`, `macos-latest`)
runners and only build or test; they do not buy certs.

## Manual validation

On a current Mac (14+), with `blaktaild` installed and an onshore console + coordinator:

1. Launch BlakTail from the menu bar.
2. Sign in, confirm account details in the status window.
3. Connect; confirm status shows Connected and a tailnet IP.
4. Ping a peer on the tailnet.
5. Disconnect; confirm status returns to Disconnected.
6. Quit. Confirm Activity Monitor / `ps` shows no child command line containing the join key.

## CI

`.github/workflows/macos-desktop.yml` runs `swift test` on `macos-latest`. `scripts/validate-macos-desktop.sh` checks structure and the locked
tagline on any host.
