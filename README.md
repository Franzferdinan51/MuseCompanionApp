# Muse Companion App

Your phone, as a Muse gadget. Pair it with the [Muse app](https://muse.ai) and your phone becomes your Muse's eyes, ears, mouth, and hands: a live character on screen, hold-to-talk voice, spoken replies, camera vision, and a command channel that lets your Muse actually *do things* on the phone — open apps, set alarms, read notifications, take photos, and now talk to USB devices you plug in.

Android is the build that ships. The gadget protocol is pure Dart, so the same session code is what a later iOS or desktop port would use. There is also a [desktop companion](https://github.com/Franzferdinan51/MuseDesktopCompanion) if you want the same idea on a Mac.

## What it does

- **Pairs like a gadget.** The app advertises over Bluetooth LE. Add it from the Muse app the same way as any other gadget (Settings → Devices → Add gadget). Pairing is encrypted (protocol v5). After that the app holds a Noise session with your Muse in a foreground service.
- **Shows your Muse's character.** `display.draw_url` accepts a full-color JPEG, PNG, WebP, animated GIF, or GLB. The phone renders it on a pixel-avatar stage (Waveshare-style 64×64 aesthetic) with idle, listening, thinking, and speaking poses, plus rings, waveform, and a thinking spinner. Captions sit under the stage. A finished chat reply containing an image link is drawn the same way without needing `display.draw_url`. The art is yours — the app never substitutes a stock character. Until a picture arrives, the stage shows the generic Muse logo (each install uses its own user's avatar, never someone else's).
- **Tap to pet, hold to talk.** Short tap pets the portrait. Hold for ~220 ms to record a voice note; release posts it as a voice turn (`audio/wav`, `output_modality: voice`). The chat screen has a hold-to-record mic too, and `voice.listen` records a timed note. Typed messages and camera photos stay `output_modality: text`.
- **Captions and a speaker.** Replies stream as live captions under the character, then get spoken aloud. Settings has a speech-volume dial and voice picker. "Say it again" repeats the last reply.
- **Phone commands.** Your Muse can open links and apps, set alarms and timers, read notifications (with access granted), take photos, record voice notes, control ringer/DND/vibration/rotation, post notifications, read contacts and calendar, send texts and place calls (only if you enable those in Settings), take screenshots and read the screen (needs the Screen control accessibility service), and more. There is no shell — the phone is controlled through the command list below.
- **Dashboard, chat, activity.** The app has a dashboard (character, caption, link state, command channel stats), a chat view, an activity/diagnostics view (link log, invokes seen, results sent), pairing, and settings.

## USB OTG — plug things in

The newest addition. Plug USB devices into the phone and your Muse can see and use them.

**USB storage (flash drives, etc.):**

| Command | What it does |
|---|---|
| `usb.list_devices` | List USB devices plugged in: name, vendor/product ID, class, permission state |
| `usb.request_permission` | Ask the user for permission to open a USB device |
| `usb.list_volumes` | List mounted removable storage (USB drives and SD cards): path, label, free space |
| `usb.list_files` | Browse a directory on mounted USB storage (folders first, 500-entry cap) |
| `usb.read_file` | Read a file off USB storage (base64, 10 MB cap) |

Plug in a flash drive → Android mounts it → `usb.list_volumes` gives the path → browse and read from there. Reads are confined to the USB volume (canonical-path checked, no escaping).

**USB serial (any serial device — not just one board):**

Full serial console over OTG. Routers, 3D printers, GPS units, industrial gear, dev boards — anything with a USB serial chip. Supported drivers: CDC-ACM, FTDI, CP210x, CH340, PL2303.

| Command | What it does |
|---|---|
| `usb.serial_list` | List available serial ports: device, driver, VID/PID, permission state |
| `usb.serial_open` | Open a port (default 115200 8N1); returns a session ID |
| `usb.serial_write` | Write raw bytes (UTF-8 or base64) |
| `usb.serial_write_line` | Write with `\n` appended (for firmware consoles) |
| `usb.serial_read` | Read with timeout; returns base64 + decoded text |
| `usb.serial_read_lines` | Read up to N newline-terminated lines |
| `usb.serial_drain` | Discard buffered input |
| `usb.serial_purge` | Purge hardware buffers (rx/tx/both) |
| `usb.serial_set_baud` | Change baud rate on an open port |
| `usb.serial_set_dtr_rts` | Drive DTR/RTS lines (reset / bootloader sequences) |
| `usb.serial_port_info` | Driver, baud, data/stop/parity, CTS/DSR state |
| `usb.serial_close` | Close the port, release the session |

Uses [usb-serial-for-android](https://github.com/mik3y/usb-serial-for-android) for driver probing. Permission uses Android's standard USB permission dialog — `usb.serial_open` on a device without permission tells your Muse to call `usb.request_permission` first.

## Command reference

Commands registered with `link.register`. This is the complete list — there is no shell command, the phone is controlled through this list.

| Command | Purpose |
|---|---|
| `display.draw_url` | Character image or model from a URL |
| `display.show_animation` | Back to the neutral placeholder (caption kept) |
| `companion.set_status` | Unicode status caption |
| `pocket.set_status` | Alias for Muses that learned Pocket |
| `companion.set_display` | Theme (`light`/`dark`/`system`), keep-screen-on, speak replies |
| `device.health` | Battery, charging, model, OS, app version |
| `vision.capture` | Take a photo and post it into chat |
| `voice.listen` | Record a short voice note and post it as a voice turn |
| `phone.open_url`, `phone.launch_app`, `phone.list_apps` | Open a link or installed app, or list launchable apps |
| `phone.clipboard`, `phone.flashlight`, `phone.volume`, `phone.brightness` | Clipboard, torch, volume (music/ring/alarm/notification/voice), screen brightness |
| `phone.location` | Last known location, then one fresh update |
| `phone.notify`, `phone.alarm`, `phone.timer` | Show a notification, set an alarm, start a timer |
| `phone.dial`, `phone.call` | Open the dialer. `phone.call` places the call only if Settings allows it |
| `phone.sms`, `phone.messages` | Open the composer, or send directly if Settings allows it; read recent inbox texts |
| `phone.notifications`, `phone.contacts`, `phone.events` | Recent notifications, contact search, upcoming calendar events |
| `phone.share`, `phone.speak`, `phone.media`, `phone.capabilities` | Share sheet, speak text, media keys, report what this phone can do |
| `phone.ringer`, `phone.dnd`, `phone.vibrate`, `phone.rotation` | Ringer mode, Do Not Disturb, vibration, screen rotation |
| `phone.radio`, `phone.settings` | Radio status, or open a system panel/settings page. No silent radio toggle |
| `phone.device`, `phone.screen` | Device status (no IMEI or serial), wake the screen |
| `phone.screenshot`, `phone.ui` | Post a screenshot into chat, or read on-screen text and buttons. Needs Screen control |
| `phone.tap`, `phone.swipe`, `phone.type`, `phone.press` | Tap, swipe, type, press back/home/recents/notifications/quick settings/lock/power. Needs Screen control |
| `phone.screen_control` | Report whether Screen control is on, or open its system page |
| `usb.*` | USB storage and serial — see the USB OTG section above |
| `file.list`, `file.read`, `file.write`, `file.delete` | Sandboxed workspace files for notes, data, images (text or base64) |
| `scene.save`, `scene.list`, `scene.run`, `scene.delete` | Named offline routines: 1–10 steps run on the phone |
| `sensors.read` | Accelerometer, gyroscope, magnetometer + availability |
| `media.enqueue`, `media.queue`, `media.play`, `media.control`, `media.clear` | Audio playback queue on the phone speaker |
| `display.show_card`, `display.card_status`, `display.clear_card` | Interactive card with buttons on the stage; choice read back |
| `vision.analyze` | On-device OCR + barcodes from a workspace image |
| `home.status`, `home.states`, `home.call` | Home Assistant states and services (opt-in, Settings) |
| `mqtt.status`, `mqtt.publish` | MQTT under one topic prefix (opt-in, Settings) |

## Getting started

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install) (stable), an Android SDK, and the [Muse app](https://muse.ai).

```bash
cd app
flutter pub get
flutter analyze
flutter test
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Pairing:

1. Create an SDK token at [gadgets.muse.ai/settings/sdk-tokens](https://gadgets.muse.ai/settings/sdk-tokens).
2. In this app, open Pair and enter the token. The phone starts advertising over BLE.
3. In the Muse app: Settings → Devices → Add gadget → pick `MuseGadgetXXXXXX`.
4. Approve pairing. The app checks credentials and connects. Your Muse is asked for a character image and a status caption.

Troubleshooting the link: open Dashboard in the app. If "Invokes seen" stays at 0 while your Muse says it's sending commands, the phone isn't receiving `device.invoke` — this is a known platform-side issue (see below). Logcat lines are prefixed with `[muse]`.

## Permissions

The app asks for a lot because it's a gadget your Muse drives. Grouped by why:

- **Gadget link:** Bluetooth (advertise/connect), foreground service, notifications, ignore-battery-optimizations, internet. Keeps the encrypted session alive.
- **Eyes and ears:** Camera, microphone. `vision.capture` and voice notes.
- **Mouth:** Audio settings. Spoken replies through the speaker.
- **Phone control:** Contacts, calendar, SMS (read/send), phone calls, location, notifications access, Do Not Disturb access, write settings, alarm. Each maps to a `phone.*` command. Placing calls and sending texts stay off until you explicitly enable them in Settings — your Muse cannot grant itself those toggles.
- **Screen control:** Accessibility service (opt-in). Screenshots, reading the screen, taps/swipes. Your Muse cannot turn this on — you do it in system settings.
- **USB:** USB host. Storage and serial device access.

## Protocol notes

The Dart stack follows the [muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk) Linux gadget (`musegadget`): the same Noise handshake, service envelopes, pairing transcript, and BLE service/characteristic UUIDs. The Muse app pairs with it as a gadget.

Control messages are length-prefixed JSON on the `POST /link-control` stream. The phone also accepts a Hatch invoke as bare JSON, NDJSON, or a body chunk on another stream, and answers on the control stream with `link.result`. `device_family` stays `companion`.

Chat posts go to `POST /chat/stream` and only acknowledge the post. Replies arrive as NDJSON on `POST /chat/subscribe`.

## Known issues

- **`device.invoke` often never reaches the phone.** Commands your Muse sends can time out while Dashboard sits at "Invokes seen: 0". Chat messages arrive fine — it's the invoke path that's broken platform-side. Workarounds (the on-phone camera button, voice notes) don't use that path. Being tracked with the Muse team.
- **Avatar URL pickup on fresh installs** doesn't auto-load reliably; may need a re-pair or manual set.

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
      phone_actions.dart # phone.* command implementations (Dart side)
    app/                 # storage, presentation, captions, avatar motion and life
    ui/                  # companion, pixel stage, theme, dashboard, settings, pairing, chat, diagnostics
  android/app/src/main/kotlin/dev/musecompanion/muse_companion/
    PhoneBridge.kt         # MethodChannel bridge: phone.* command implementations
    UsbOtgManager.kt       # USB device discovery, permission, mass-storage access
    UsbSerialManager.kt    # USB serial ports via usb-serial-for-android
    GadgetBlePeripheral.kt # BLE advertising for pairing
    MuseNotificationListener.kt  # notification access
    ScreenControl.kt       # accessibility service for screen control
  test/
    gadget/              # protocol unit tests + pairing vectors
    testdata/            # official link_pairing_v5 vectors
```

## Roadmap

- Play-signed release APK/AAB
- iOS (CoreBluetooth peripheral), then macOS and Windows

## Contributing

Issues and pull requests are welcome. Protocol changes should keep the Dart port compatible with the reference SDK — add a vector or golden test when behavior changes.

## Acknowledgments

- [muse-pocket](https://github.com/viticci/muse-pocket) — the e-ink Muse gadget this app is modeled on.
- [muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk) by Meta Platforms, Inc. — the reference gadget SDK and the docs at [gadgets.muse.ai](https://gadgets.muse.ai/).
- [usb-serial-for-android](https://github.com/mik3y/usb-serial-for-android) — USB serial drivers.
- The Meta Muse team for the Muse platform itself.

## License

Apache License 2.0. Protocol code is derived from the Muse Gadget SDK, Copyright (c) Meta Platforms, Inc. and affiliates; see `LICENSE` and the per-file headers.
