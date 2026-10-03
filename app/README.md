# Muse Companion

Version 0.2.4 (versionCode 6). Android package
`dev.musecompanion.muse_companion`.

The phone is the Muse gadget. It pairs over Bluetooth LE, keeps a Noise
session with your Muse, and shows your Muse's own picture on a 64×64 pixel
stage with live captions. Chat replies arrive on the phone. Gadget commands
are answered with `link.result` when they arrive.

The app registers as `device_family` `companion`, `model_id` `companion-app`,
`platform` `android`. Android is the build that ships.

## What it does

- **Pairs** with protocol v5. The phone advertises as `MuseGadget` plus six
  hex digits. Add it from the Muse app: Settings → Devices → Add gadget.
- **Shows a pixel avatar** on the home screen. See [Avatar](#avatar).
- **Tap the portrait to pet it. Hold it to talk.** A press shorter than
  about 220 ms is a pet. A longer hold starts listening and, on release,
  posts a voice note. The chat screen's mic is hold-to-record only.
- **Captions and speech.** A reply is drawn under the character while it
  streams, then spoken. Speech is on by default. Settings has the volume
  dial (default 80). Say it again repeats the last reply.
- **Dashboard.** The heart icon shows whether commands are reaching the
  phone. See [Dashboard](#dashboard).
- **Phone commands.** Links, apps, alarms, timers, camera, microphone,
  clipboard, flashlight, notifications, contacts, calendar, location, and
  the dialer. Ringer, Do Not Disturb, rotation, brightness, vibration, and
  a short screen wake are included. Wi-Fi, Bluetooth, NFC, mobile data, and
  airplane mode open the system panel. Placing a call or sending a text
  directly stays off until you turn that on in Settings. Muse cannot grant
  itself those toggles, and it cannot change the speech volume. There is
  no shell.

## Avatar

The home screen uses the glossy backdrop. The avatar sits in a black round
stage that stays still. A picture is cover-cropped onto a 64×64 grid and
drawn inside that disc, with hard pixels, the way the
full-UI boards on [gadgets.muse.ai](https://gadgets.muse.ai/) scale a pixel
avatar. A flat backdrop fills the circle, and the character, head to feet,
sits inside the ring. Rings, sparkles, thought dots, and sound waves orbit
the fixed disc. On a picture, the body bobs and the feet stay
put, the way the board's pixel avatar moves. The whole image does not
slide. Animated GIF and
WebP frames keep their timing. A GLB plays in the same circle. Captions sit
under the stage. The last picture is cached and shown again after a restart.
A tap does not dismiss it.

Until a picture arrives, the stage shows an original round face (not the
SDK's default character) and the line "Waiting for character" or "Asking
your Muse for a character…".

| State | Label | Motion |
| --- | --- | --- |
| Boot | BOOT | One short squash when the screen opens on an idle portrait, then idle. |
| Idle | READY | Slow bob. While the link is connecting the word is CONNECTING; while it is waiting to retry, RECONNECTING. Not paired stays on the bottom bar. |
| Listening | LISTENING | Faster bob, expanding rings, centred meter. The bezel fills from the top across 15 seconds of a hold. The mic beside the word lights only in this state. |
| Thinking | THINKING | Lean, three thought dots, and a 60° spinner on the bezel (300°/s, starting at the top). |
| Speaking | SPEAKING | Scale pulse and rings. The bezel stays empty. |
| Error | ERROR | A short shake, then a still error face. |
| Off | OFF | The link was stopped. Fade. This is not the sleep button. |

The header moon covers the screen locally. Tap the cover or the moon to
wake. That does not change the link pose.

Tap the portrait to pet it. Hold it (about 220 ms) to start listening, then
release to send. The hint on the home screen is "Tap to pet, hold to talk".

### How the picture is set

Both paths use the same downloader and the same stage.

1. **`display.draw_url`.** Muse invokes the command with an `http` or `https`
   image URL. The phone downloads it, caches it, and draws it. JPEG, PNG,
   WebP, animated GIF, animated WebP, and GLB are accepted.
   `display.show_animation` clears the picture and brings the round face
   back. The caption stays.
2. **An image URL in a finished chat reply.** When the reply text contains
   an `https` URL whose path ends in `.png`, `.jpg`, `.jpeg`, `.webp`, or
   `.gif`, the phone downloads that URL. A query string is kept. The first
   matching link in the reply is the one used. `http` links and pages
   without those extensions are ignored. This path does not use
   `device.invoke`.

After pairing, the app asks Muse once for a pixel portrait and a caption.
That message is not sent again until you unpair. A picture already on disk
counts as that ask having been sent.

## Dashboard

The heart icon to the left of the name opens the dashboard. Settings →
Dashboard opens the same page.

It shows the pixel stage, the caption, link state, detail, battery, pose,
speech volume, invokes seen, results sent, the last command, the last
result, and the recent link log (newest first, up to 12 lines).

Read the command channel this way:

- **Invokes seen 0** while Muse reports a timeout: the phone did not receive
  `device.invoke`.
- **Invokes climbing, results behind:** a command arrived and the
  `link.result` reply has not left the phone.
- **Invokes and results together:** commands are arriving and the phone is
  answering.

## Known platform issue

Chat reaches the phone. Assistant text arrives as NDJSON on
`POST /chat/subscribe`. `POST /chat/stream` only acknowledges what the phone
sends.

`device.invoke` from the Muse platform often does not arrive. Muse then
reports a timeout, and the dashboard stays at **Invokes seen 0**. That
covers `display.draw_url`, `companion.set_status`, and `device.health` the
same way. The app answers with `link.result` when a command does arrive, as
`link.invoke`, `device.invoke`, a bare command name, bare JSON, or a body
chunk on another stream.

Until those frames are delivered, set the portrait by putting an `https`
image URL in a chat reply. The stage redraws continuously, so logcat's main
buffer fills with `BLASTBufferQueue` lines and a `[muse]` line may not
survive. The dashboard counters are the record that stays.

## Commands

`companionCommandSpecs` registers this set, sized to the phone's display.

| Command | What the phone does |
| --- | --- |
| `display.draw_url` | Download an image URL and draw it on the pixel stage. |
| `display.show_animation` | Clear the picture and show the round face again. |
| `companion.set_status`, `pocket.set_status` | Set the caption. Up to 4000 characters. The stage shows a shorter wrap. |
| `companion.set_display` | Theme, keep-screen-on, and whether replies are spoken. |
| `device.health` | Battery percent, charging, model, OS version, and app version. |
| `vision.capture` | Take a camera photo and post it to chat. Facing follows Settings (Back or Front) unless the command sets `facing`. |
| `voice.listen` | Record 1–20 seconds (default 5) and post a voice note. |
| `phone.open_url` | Open an `http` or `https` URL. |
| `phone.launch_app`, `phone.list_apps` | Open an app by package or name, or list launchable apps. |
| `phone.clipboard` | Read or set the clipboard. |
| `phone.flashlight` | Torch on or off. |
| `phone.volume`, `phone.brightness` | Volume on music, ring, alarm, notification, or voice (default music). Brightness level or auto/manual, when the system grant exists. |
| `phone.location` | Last known location, after the user grants it. |
| `phone.notify` | Show a notification. |
| `phone.alarm`, `phone.timer` | Set a clock alarm, or start a timer. |
| `phone.dial` | Open the dialer with a number filled in. The user places the call. |
| `phone.call` | Place a call. Requires "Allow Muse to place calls" in Settings. |
| `phone.sms` | Open the message composer. `send=true` sends only after "Allow Muse to send texts". |
| `phone.messages`, `phone.notifications` | Read the SMS inbox, or posted notifications, after those grants. |
| `phone.contacts`, `phone.events` | Search contacts, or list upcoming calendar events. |
| `phone.share`, `phone.speak`, `phone.media` | Share sheet, speak text, or a media key. |
| `phone.capabilities` | Which controls and permissions are available now, including camera facing and the grants below. |
| `phone.ringer`, `phone.dnd`, `phone.vibrate` | Ringer mode, Do Not Disturb (opens the system page if needed), or a short vibration. |
| `phone.rotation` | Auto, portrait, landscape, or locked, when write-settings is granted. |
| `phone.radio` | Report Wi-Fi, Bluetooth, NFC, mobile data, or airplane mode, or open that system panel. It does not toggle them silently. |
| `phone.settings` | Open one whitelisted system page (display, sound, apps, battery, and the radio pages). |
| `phone.device` | Manufacturer, model, Android release, battery, storage, ringer, and radio status. No accounts, IMEI, or serial. |
| `phone.screen` | Whether the screen is on, or wake it for a few seconds. |

## Architecture

```
lib/
├── main.dart                      # Wires identity, service, executor, and UI
├── app/
│   ├── model.dart                 # PresentationState and CompanionSettings
│   ├── pixel_avatar.dart          # 64×64 scale map, accents, blink, meter, bezel arcs
│   ├── avatar_life.dart           # Palette, gaze, blink shapes, sparkles, pet
│   ├── avatar_motion.dart         # Idle, listening, thinking, speaking, boot, error, off
│   ├── captions.dart              # Caption and spoken-reply clipping
│   ├── chat.dart                  # In-memory chat history for this launch
│   ├── companion_platform.dart    # Image download, cache, and display bridge
│   ├── storage.dart               # Pairing, identity, and settings storage
│   ├── ble_peripheral.dart        # BLE advertiser for pairing
│   ├── phone_bridge.dart          # Android method channel for phone commands
│   └── foreground.dart            # Link foreground service and notification
├── ui/
│   ├── companion_screen.dart      # Home: stage, captions, pet, hold-to-talk, sleep
│   ├── pixel_stage.dart           # Fixed disc; the portrait moves inside it
│   ├── muse_theme.dart            # Glossy backdrop, logo, ink and mist colours
│   ├── dashboard_screen.dart      # Heart-icon diagnostics
│   ├── chat_screen.dart
│   ├── settings_screen.dart
│   ├── pairing_screen.dart
│   ├── diagnostics_screen.dart
│   └── scope.dart                 # AppScope for every route
└── src/gadget/                    # Pure Dart. No Flutter.
    ├── service.dart               # Connect loop, register, subscribe, intro
    ├── link_client.dart           # Noise session, invoke, link.result
    ├── commands.dart              # Command specs and CompanionExecutor
    ├── chat_events.dart           # /chat/subscribe events and reply image URLs
    ├── invoke.dart                # Invoke parsing
    ├── transport.dart             # HTTP over Noise
    ├── noise_xx.dart              # Noise XX
    ├── pairing.dart               # BLE pairing, protocol v5
    ├── ble_setup.dart, ble_framing.dart
    ├── identity.dart              # Stable homelink- id and MuseGadget name
    ├── muse_api.dart              # fetch_vms and device-token refresh
    ├── proto.dart, envelope.dart, framing.dart, p256.dart
    └── phone_actions.dart
```

`PresentationState` is what the screens render. `AppScope` hands the
service, presentation, settings, BLE manager, chat, and phone bridge to
every route.

`GadgetService` loads the saved pairing, leases a VM, opens the Noise
session, sends `link.register`, and opens `POST /chat/subscribe`. The setup
chat goes out once from that subscribe. The local battery reading refreshes
about once a minute for the header. It is separate from the `device.health`
command.

The device id is a random MAC-shaped value stored on the phone. The node id
is `homelink-` plus the last six hex digits. The BLE name uses those same
digits. It is not a hardware address.

Chat history lives in memory for the session, up to 100 messages. The
pairing, the SDK token, settings, and the last character image are stored
on the device.

## Build and test

Requirements: [Flutter](https://docs.flutter.dev/get-started/install)
stable (Dart `^3.11.1`), an Android SDK, and the Muse app.

```bash
cd app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Install the debug APK with `adb install -r`. Check the phone with
`adb shell dumpsys package dev.musecompanion.muse_companion` and expect
`versionName=0.2.4` and `versionCode=6`.

Narrower test runs:

```bash
flutter test test/gadget
flutter test test/app
flutter test test/ui
flutter test test/widget_test.dart
```

Gadget tests use in-memory fakes, so they do not need a phone. The widget
smoke test expects the unpaired home screen: "Muse", "Waiting for
character", "Not paired", and the Settings tooltip.

### Pair

1. Create an SDK token at
   [gadgets.muse.ai/settings/sdk-tokens](https://gadgets.muse.ai/settings/sdk-tokens).
2. In this app, open Pair and enter the token. The phone starts advertising.
3. In the Muse app: Settings → Devices → Add gadget → pick
   `MuseGadget` plus the six digits.
4. Approve pairing. The app connects and asks once for a character and a
   caption.

## Project layout

```
MuseCompanionApp/
├── app/                 # This Flutter application
│   ├── lib/
│   ├── test/
│   ├── android/
│   └── pubspec.yaml     # version 0.2.4+6
├── README.md
└── LICENSE              # Apache-2.0
```

## License

Apache-2.0. See the repository root.
