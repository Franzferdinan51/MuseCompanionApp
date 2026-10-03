# Muse Companion App

A full-color **Muse gadget companion** for your phone — the app version of
[muse-pocket](https://github.com/Franzferdinan51/muse-pocket). Where Pocket
shows your Muse's character on a small e-ink display, this app shows it on
your phone in full color and detail: character art, live status captions,
chat, and settings.

Android first; iOS, macOS and Windows follow from the same Flutter codebase.

## What it does

- **Pairs like a real gadget** — the app advertises over Bluetooth LE and is
  added from the Muse app exactly like any Muse gadget (Settings → Devices).
  Encrypted pairing (protocol v5), then a persistent Noise-encrypted session
  with your Muse.
- **Shows your Muse's character** — full-color JPEG/PNG/WebP art at your
  screen's resolution, cached on-device and kept across restarts.
- **3D avatar** — when your Muse sends a GLB model instead of an image,
  the character view renders it as an auto-rotating 3D avatar; 2D art and
  the neutral placeholder behave exactly as before.
- **Live status captions** — short Unicode updates under the character
  whenever your Muse's activity changes.
- **Chat from the device** — send messages to your Muse as coming from the
  companion (main chat or a side chat).
- **Muse-driven display** — your Muse can update the caption, swap the
  character, clear back to the placeholder, and adjust theme preferences
  through gadget commands; a health command reports battery and device info.

## Status

Under active development. The gadget protocol core (Noise XX session,
BLE pairing v5, link client, connection loop with token rotation) is
implemented in pure Dart with 160+ tests, including a byte-for-byte replay
of the official pairing vectors and a Noise handshake transcript verified
against the reference Python SDK. The Android BLE peripheral, pairing
wizard, and release builds are being finished next.

## Getting started

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install)
(stable), an Android SDK for device builds, and the
[Muse app](https://muse.ai) with a paired Muse.

```bash
cd app
flutter pub get
flutter analyze
flutter test
flutter run -d <your-android-device>
```

Pairing (once the pairing wizard lands):

1. Create an SDK token at
   [gadgets.muse.ai/settings/sdk-tokens](https://gadgets.muse.ai/settings/sdk-tokens).
2. Enter it in the app's pairing screen — the app starts advertising.
3. In the Muse app: Settings → Devices → Add gadget → pick
   `MuseGadgetXXXXXX`.
4. Approve pairing; the app verifies the provisioned credentials and
   connects. Your Muse introduces itself with character art and a status.

## Project layout

```text
app/
  lib/
    main.dart            # wiring: identity, service, executor, UI
    src/gadget/          # pure-Dart gadget protocol (no platform code)
      proto.dart         # protobuf wire codec
      envelope.dart      # Noise service envelopes
      framing.dart       # transport chunk framing
      noise_xx.dart      # Noise_XX_25519_AESGCM_SHA256 + test responder
      transport.dart     # NoiseTransport (requests/responses)
      p256.dart          # pure-Dart P-256 ECDH for BLE pairing
      pairing.dart       # BLE pairing v5 device side
      ble_framing.dart   # BLE chunked notifications
      ble_setup.dart     # GATT setup controller (SetupController)
      link_client.dart   # link.register/invoke/result + send_chat
      muse_api.dart      # device API: fetch_vms + token refresh
      identity.dart      # stable device identity
      service.dart       # connection loop, backoff, token rotation
      commands.dart      # companion command set + executor
    app/                 # storage, presentation state, platform display/health
    ui/                  # companion screen, settings, pairing, chat
    ble/                 # platform BLE peripheral (Android GATT server first)
  test/
    gadget/              # protocol unit tests + pairing vectors
    testdata/            # official link_pairing_v5 vectors
```

## Protocol notes

The Dart stack is a faithful port of the
[muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk)
Linux gadget (`musegadget` package): same Noise handshake, same service
envelopes, same pairing transcript and key schedule, same BLE service and
characteristic UUIDs — so the existing Muse apps pair with it unchanged.

Commands registered with `link.register`:

| Command | Purpose |
|---|---|
| `display.draw_url` | Full-color character image from a URL |
| `display.show_animation` | Back to the neutral placeholder |
| `companion.set_status` | Unicode status caption |
| `pocket.set_status` | Alias for Muses that learned Pocket |
| `companion.set_display` | Theme (`light`/`dark`/`system`), keep-screen-on |
| `device.health` | Battery, charging, model, OS, app version |

## Roadmap

- Android BLE peripheral (advertising + GATT server) and pairing wizard
- Chat UI, status history, diagnostics screen
- Foreground service for a persistent connection
- Signed release APK/AAB on GitHub Releases
- iOS (CoreBluetooth peripheral), then macOS and Windows

## Contributing

Issues and pull requests are welcome. Protocol changes should keep the
Dart port byte-compatible with the reference SDK — add a vector or golden
test when behavior changes.

## Acknowledgments

- [muse-pocket](https://github.com/Franzferdinan51/muse-pocket) — the
  e-ink Muse gadget this app is modeled on; display layout, pairing flow
  and firmware behavior reference.
- [muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk)
  by Meta Platforms, Inc. — the reference gadget SDK and docs at
  [gadgets.muse.ai](https://gadgets.muse.ai/); protocol, pairing and
  voice designs followed from it.
- The Meta Muse team for the Muse platform itself.

## License

Apache License 2.0. Protocol code is derived from the Muse Gadget SDK,
Copyright (c) Meta Platforms, Inc. and affiliates; see `LICENSE` and the
per-file headers.
