# Muse Companion App

A full-color **Muse gadget** that runs on your phone. Where
[muse-pocket](https://github.com/viticci/muse-pocket) puts your Muse's
character on a small e-ink panel, this app puts that same character on the
phone: your Muse's own art, live captions, hold-to-talk, and the phone
commands a gadget is allowed to use.

Android is the build that ships. The gadget protocol is pure Dart, so the
same session code is what a later iOS or desktop port would use.

## What it does

- **Pairs like a gadget.** The app advertises over Bluetooth LE. Add it from
  the Muse app the same way as any other gadget (Settings → Devices → Add
  gadget). Pairing is encrypted (protocol v5). After that the app keeps a
  Noise session with your Muse and can hold it in a foreground service.
- **Shows your Muse's character.** `display.draw_url` accepts a full-color
  JPEG, PNG, or WebP, an animated GIF or animated WebP, or a GLB. The last
  image is cached on the phone. The portrait moves through idle, listening,
  thinking, and speaking with the same timing as the Waveshare gadget
  screen. The art is yours; the app does not substitute a stock character.
- **Hold the character to talk.** Press and hold the portrait to record a
  voice note, then release to post it. The chat screen's mic does the same
  thing. This is a voice note in the Muse chat, not a phone call.
- **Captions and a speaker.** A reply is drawn under the character while it
  streams, then spoken. Settings has a speech-volume dial. Say it again
  repeats the last reply. A voice-note transcript replaces the "Voice note"
  bubble when one arrives.
- **Dashboard.** The heart icon in the header, and Dashboard in Settings,
  show the character, the caption, link state, and the command channel:
  invokes seen, results sent, the last command, and the recent link log.
- **Phone commands.** Your Muse can open links and apps, set an alarm, read
  notifications after you grant access, and use the camera and microphone.
  The dialer and the message composer open without extra toggles. Placing a
  call or sending a text directly stays off until you turn it on in Settings.
  Muse cannot grant itself those toggles, and it cannot change the speech
  volume.

## Status

Version 0.2.2. The app pairs, keeps the link up, answers `link.invoke` and
Hatch `device.invoke` (including a command that arrives on another stream or
as bare JSON) with `link.result`, streams chat replies, draws and moves the
character, and exposes voice, vision, and phone commands.

## Getting started

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install)
(stable), an Android SDK, and the [Muse app](https://muse.ai).

```bash
cd app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Pairing:

1. Create an SDK token at
   [gadgets.muse.ai/settings/sdk-tokens](https://gadgets.muse.ai/settings/sdk-tokens).
2. In this app, open Pair and enter the token. The phone starts advertising.
3. In the Muse app: Settings → Devices → Add gadget → pick
   `MuseGadgetXXXXXX`.
4. Approve pairing. The app checks the credentials and connects. Your Muse
   is asked for a character image and a status caption.

If commands from Muse time out, open Dashboard. Invokes staying at 0 means
the phone did not receive the command. Invokes climbing while results stay
behind means the reply did not leave the phone. Logcat lines are prefixed
with `[muse]`.

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
      link_client.dart   # link.register / invoke / result + send_chat
      invoke.dart        # link.invoke and device.invoke shapes
      muse_api.dart      # device API: fetch_vms + token refresh
      identity.dart      # stable device identity
      service.dart       # connection loop, backoff, token rotation
      commands.dart      # companion command set + executor
    app/                 # storage, presentation, captions, avatar motion
    ui/                  # companion, dashboard, settings, pairing, chat
  test/
    gadget/              # protocol unit tests + pairing vectors
    testdata/            # official link_pairing_v5 vectors
```

## Protocol notes

The Dart stack follows the
[muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk)
Linux gadget (`musegadget`) and the ESP32 session: the same Noise handshake,
the same service envelopes, the same pairing transcript, and the same BLE
service and characteristic UUIDs. The Muse app pairs with it as a gadget.

Control messages are length-prefixed JSON on the `POST /link-control`
stream. The phone also accepts a Hatch invoke that shows up as bare JSON,
as NDJSON, or as a body chunk on another stream, and it answers on the
control stream with `link.result`. `device_family` stays `companion`.

Chat posts go to `POST /chat/stream` and only acknowledge the post. Replies
arrive as NDJSON on `POST /chat/subscribe`.

Commands registered with `link.register`:

| Command | Purpose |
|---|---|
| `display.draw_url` | Character image or model from a URL |
| `display.show_animation` | Back to the neutral placeholder |
| `companion.set_status` | Unicode status caption |
| `pocket.set_status` | Alias for Muses that learned Pocket |
| `companion.set_display` | Theme (`light`/`dark`/`system`), keep-screen-on, speak replies |
| `device.health` | Battery, charging, model, OS, app version |
| `vision.capture` | Take a photo and post it into chat so the Muse can see it |
| `voice.listen` | Record a short voice note and post it into chat |
| `phone.open_url`, `phone.launch_app`, `phone.list_apps` | Open a link or an installed app, or list launchable apps |
| `phone.clipboard`, `phone.flashlight`, `phone.volume`, `phone.brightness` | Clipboard, torch, media volume, screen brightness |
| `phone.location` | Last known location, then one fresh update |
| `phone.notify`, `phone.alarm` | Show a notification, or open the alarm clock |
| `phone.dial`, `phone.call` | Open the dialer. `phone.call` places the call only if Settings allows it |
| `phone.sms`, `phone.messages` | Open the composer, or send directly if Settings allows it; read recent inbox texts |
| `phone.notifications`, `phone.contacts`, `phone.events` | Recent notifications, contact search, upcoming calendar events |
| `phone.share`, `phone.speak`, `phone.media`, `phone.capabilities` | Share sheet, speak text, media keys, report what this phone can do |

There is no shell command. The phone is controlled through this list.

## Roadmap

- Signed release APK/AAB on GitHub Releases
- iOS (CoreBluetooth peripheral), then macOS and Windows

## Contributing

Issues and pull requests are welcome. Protocol changes should keep the
Dart port compatible with the reference SDK — add a vector or golden test
when behavior changes.

## Acknowledgments

- [muse-pocket](https://github.com/viticci/muse-pocket) — the e-ink
  Muse gadget this app is modeled on.
- [muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk)
  by Meta Platforms, Inc. — the reference gadget SDK and the docs at
  [gadgets.muse.ai](https://gadgets.muse.ai/). The Waveshare board's avatar
  timing and the reTerminal status screen are the references for motion and
  the dashboard. The phone does not copy the SDK's default pixel character.
- The Meta Muse team for the Muse platform itself.

## License

Apache License 2.0. Protocol code is derived from the Muse Gadget SDK,
Copyright (c) Meta Platforms, Inc. and affiliates; see `LICENSE` and the
per-file headers.
