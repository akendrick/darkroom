# Darkroom

An iPhone and Apple Watch companion for alternative-process printing — carbon
transfer, gum, salt, cyanotype, silver gelatine and the like. It walks you
through a print one step at a time with big, safelight-friendly timers, and
records what you actually did so a good print can be repeated.

## What it does

- **Walk-throughs.** Each process is a list of steps (pour, wait, add, rinse,
  dry …) with default times, temperatures and amounts. Change any of them on the
  day; the print keeps what you used, the recipe stays as it was.
- **Timers that keep going.** Step timers ring with the phone locked or on
  silent (AlarmKit), show on the Lock Screen as a Live Activity, and appear on
  the Watch so you never touch the phone with wet hands.
- **Darkroom mode.** Red on black, for use under the safelight.
- **Processes.** Reference notes for each process, in sections, with a PDF to
  print and pin on the darkroom wall.
- **Multi-print.** Two prints side by side, the phone turned sideways.
- **Works offline.** Everything is kept on the phone and sent when there is a
  connection.
- **Gallery** of finished prints with their photos.

## The server

The app is the client half. It talks to a small PHP/MySQL web app (the
Darkroom server) that stores prints, materials, chemistry, processes and walk-throughs and
offers the same walk-throughs in a browser. **The server is not part of this
repository.**

The app signs in once with the server's password and keeps a per-device key in
the Keychain; every request sends it as `Authorization: Bearer …`. The server
address is set at build time (see below).

## Building

Requires Xcode 26 or later; the app targets iOS 26 and watchOS 26.

1. Open `Darkroom.xcodeproj`.
2. Signing and the server address live in `Config/Signing.xcconfig`:

   | Setting | Meaning |
   |---|---|
   | `DEVELOPMENT_TEAM` | Your Apple developer team ID. Leave empty to build for the Simulator only. |
   | `APP_BUNDLE_ID` | The app's bundle ID. The Watch app and Live Activity extension derive theirs from it. |
   | `DARKROOM_SERVER` | The server the app talks to. |

   Rather than editing that file, put your own values in
   `Config/Signing.local.xcconfig` (ignored by git), for example:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   ```

3. Choose the **Darkroom** scheme and run.

Debug builds show a switch on the sign-in screen for a local test server at
`http://localhost:8642`.

## Layout

| Folder | What's in it |
|---|---|
| `Darkroom/` | The iPhone app (SwiftUI) |
| `DarkroomWatch/` | The Watch app |
| `DarkroomLive/` | Lock Screen Live Activity |
| `LiveShared/`, `Shared/` | Code shared between the targets: timers, durations, phone–Watch messages |
| `Config/` | Info.plists and signing settings |

## Licence

MIT — see [LICENSE](LICENSE).
