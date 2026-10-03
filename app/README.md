# Muse Companion

A full-color companion app for the **Muse Pocket** gadget — an open-source,
on-device replacement for the proprietary phone app that drives the device. It
speaks the Muse gadget protocol end to end: BLE pairing and session setup, the
device command set, live status/character rendering, chat, and diagnostics.

This is a Flutter app targeting **Android**, **iOS**, and **macOS**.

---

## What it does

Muse Pocket shows a small full-color e-ink display and runs "characters" (animated
avatars). This app lets you:

- **Pair and connect** to a Muse over Bluetooth Low Energy using the encrypted
  gadget protocol (Noise framing, X25519 + P‑256 key exchange).
- **Set the Muse's status text** — the short line of activity shown on the
  device (up to 4000 characters).
- **Draw art and animations** onto the display via `display.draw_url` and
  `display.show_animation`.
- **Chat** with the Muse, with history persisted locally.
- **View diagnostics** — session lease info, token state, connection health.
- **Tune settings** — light/dark/system theme and other non‑secret display prefs.

### Companion command set

The app registers a command set sized to the real display (`companionCommandSpecs`).
The commands it drives:

| Command | Purpose |
| --- | --- |
| `companion.set_status` / `pocket.set_status` | Set the Muse's status text (≤ 4000 chars). |
| `companion.set_display` | Theme, keep-screen-on, and whether replies are spoken. |
| `display.draw_url` | Draw an image fetched from a URL onto the display. |
| `display.show_animation` | Return to the neutral placeholder. |
| `device.health` | Read the device's battery level. |
| `vision.capture` / `voice.listen` | Post a camera photo or a voice note into chat. |
| `phone.*` | Open links and apps, dial, message, notifications, location, and the rest of the phone command set. Direct calls and texts require the Settings toggles. |

---

## Architecture

The code is organized in three layers, from "pure" at the bottom to UI at the top:

```
lib/
├── main.dart                 # Entry point: wires service + executor + presentation
├── app/                      # App-level concerns (framework-agnostic where possible)
│   ├── model.dart            # PresentationState (pure state) + CompanionSettings
│   ├── storage.dart          # SecurePairingStore, PersistentIdentity, SettingsStore
│   ├── ble_peripheral.dart   # BlePeripheralManager: BLE stack <-> pairing bridge
│   ├── chat.dart             # ChatHistory (persisted chat)
│   ├── companion_platform.dart
│   └── foreground.dart       # Foreground service / notification helpers
├── ui/                       # Flutter widgets
│   ├── scope.dart            # AppScope InheritedWidget: shared app context
│   ├── companion_screen.dart # Home screen (character art, status, header)
│   ├── settings_screen.dart  # Theme + display prefs, diagnostics, chat entry points
│   ├── chat_screen.dart
│   ├── diagnostics_screen.dart
│   └── pairing_screen.dart
└── src/gadget/               # The gadget protocol stack (pure Dart, no Flutter)
    ├── service.dart          # Connection loop: pairing → session → health polling
    ├── commands.dart         # Command specs + CompanionExecutor (command handlers)
    ├── pairing.dart          # Noise handshake / session establishment
    ├── ble_framing.dart      # BLE packet framing
    ├── ble_setup.dart
    ├── identity.dart         # Device identity (public key material)
    ├── proto.dart / envelope.dart / framing.dart
    ├── p256.dart / noise_xx.dart   # X25519, AES‑GCM, SHA‑256/HMAC/HKDF, ECDH P‑256
    ├── muse_api.dart         # REST calls to the Muse API (VMS lease, token refresh)
    ├── link_client.dart / transport.dart
    └── ...
```

### Key design points

- **`PresentationState` (`app/model.dart`)** is a pure state object that the UI
  observes through a stream. It derives the multi‑line status text from raw input,
  clamps it to `maxStatusChars`, and tracks connection/battery/agent state. The
  screen stays decoupled from how that state is produced.

- **`AppScope` (`ui/scope.dart`)** is an `InheritedWidget` that exposes the gadget
  service, presentation state, settings store, BLE manager, and chat history to
  descendant widgets. It wraps the whole `MaterialApp`, so every pushed route can
  resolve it — including Settings, Chat, and Diagnostics screens navigated via the
  Navigator.

- **`GadgetService` (`src/gadget/service.dart`)** runs a single connection loop:
  load saved pairing → report *unpaired* or fetch a VM lease → establish an
  encrypted session → poll health (battery) → back off and retry on failure. A
  real `Timer` backs each backoff/poll sleep so an early `stop()`/`wake()` cancels
  it instead of leaving a dangling timer pending.

- **The protocol stack (`src/gadget/`)** is pure Dart with no Flutter dependency,
  which keeps the crypto, framing, and networking fully unit-testable without a
  device or emulator.

---

## Getting started

### Prerequisites

- The [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart SDK `^3.11.1`).
- For Android: the Android SDK + a device or emulator.
- For iOS/macOS: Xcode and a macOS build machine.
- Bluetooth on the host/device for real pairing (the protocol stack is tested with
  fakes, so no hardware is needed to run the test suite).

### Install dependencies

```bash
cd app
flutter pub get
```

### Run

```bash
# Android
flutter run

# macOS desktop
flutter run -d macos

# iOS (macOS host)
flutter run -d ios
```

Pair from this app once it's running; the saved pairing is stored in encrypted
device storage (`SecurePairingStore`) and reused on subsequent launches.

---

## Testing

The suite covers the protocol stack (crypto, framing, pairing, proto), the app
layer (presentation state, executor, chat, BLE peripheral, foreground), and a
widget smoke test for the companion screen + settings navigation.

```bash
# Everything
flutter test

# A single area
flutter test test/gadget
flutter test test/app
flutter test test/ui
flutter test test/widget_test.dart
```

The gadget tests use in‑memory fakes (`MemoryPairingStore`, stubbed HTTP/ble) so
they run deterministically off-device. The widget smoke test drives the real
`GadgetService` connection loop and asserts that navigating to Settings resolves
the shared `AppScope`.

---

## Project layout (top level)

```
muse-pocket/
├── app/                    # This Flutter application
│   ├── lib/                # Source (see Architecture above)
│   ├── test/               # Unit + widget tests
│   ├── android/ ios/ macos/# Platform embeds
│   └── pubspec.yaml
└── README.md
```

---

## License

Apache‑2.0. See the repository root for details.
