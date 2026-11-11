# GatePass

A dead-simple, open-source sideloader for macOS. Drop an `.ipa`, it lands on your iPhone or Apple TV — over USB or Wi-Fi — and GatePass quietly re-signs it before the 7-day free-account limit runs out, whenever the device shows up.

## Features

- Sign in once with your own (free) Apple ID
- Drag & drop or pick an `.ipa` / `.tipa`
- iPhone, iPad and Apple TV, USB or Wi-Fi
- **Auto-refresh**: lives in the menu bar; when a device with apps due for renewal appears, it renews them and notifies you
- "My apps" with days-left countdown, one-click refresh
- Recent IPAs and a browsable IPA folder

## Layout

| Path | What |
|---|---|
| `app/` | SwiftUI macOS app (Swift Package) |
| `engine/` | `gatepass-engine`: Rust CLI speaking JSON lines; does Apple auth, signing, device I/O |
| `upstream/impactor/` | Vendored [Impactor](https://github.com/claration/Impactor) — the engine's libraries. Our changes are marked `[GatePass]` |
| `scripts/build-app.sh` | Builds everything into `build/GatePass.app` (`--dmg` for a disk image) |

## Build

Requirements: Xcode (Swift 6), Rust (`rustup`).

```bash
scripts/build-app.sh
open build/GatePass.app
```

## Engine protocol

Each command prints one JSON object per line on stdout. `{"type":"progress",...}` while working, `{"type":"prompt",...}` when it needs an answer (the app writes one line to stdin), and a final `done` / `devices` / `apps` / `error` event.

```bash
engine/target/release/gatepass-engine devices
engine/target/release/gatepass-engine install --ipa App.ipa --udid <UDID>
```

Data lives in `~/Library/Application Support/GatePass`.

## Notes

- Free Apple IDs: apps last 7 days, max 3 active sideloaded apps, 10 new App IDs per week. These are Apple's limits.
- Apple ID login uses Apple's private APIs (same as every sideloader). On macOS, anisette data is generated locally by the system's AOSKit, so Apple sees your real Mac; set `GATEPASS_REMOTE_ANISETTE=1` to use a public anisette server instead. Your password is only sent to Apple.
- Use it for apps you have the right to install.
