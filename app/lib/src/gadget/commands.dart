// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// The companion app command set: the full-color successor to the commands
// Muse Pocket registers (see muse-pocket `docs/usage.md` and
// `esp32/main/noise_control.cpp`). Where Pocket dithers to 1-bit 480x480
// and wraps 4 lines of ASCII, the companion shows full-color images at the
// phone's resolution and full Unicode captions, and — like the Linux
// gadget's shell and the phone app's own device pairing — it lets the
// Muse see, hear, and act on this phone.

import 'dart:convert';
import 'dart:typed_data';

import 'chat_events.dart';
import 'phone_actions.dart';
import '../../app/choice_cards.dart';
import '../../app/home_integrations.dart';
import '../../app/lmstudio_client.dart';
import '../../app/media_queue.dart';
import '../../app/vision_analyze.dart';
import '../../app/scenes.dart';
import '../../app/sensors_snapshot.dart';
import '../../app/workspace_files.dart';

/// Longest status caption the app accepts (UTF-16 code units).
const int maxStatusChars = 4000;

/// Timeout the Muse allows an image command, in milliseconds.
const int drawImageTimeoutMs = 60000;

/// Builds the `commands_v2` map registered with `link.register`.
///
/// [screenWidth]/[screenHeight] are the display's pixel dimensions; the
/// Muse prepares character art from this description.
Map<String, Object?> companionCommandSpecs({
  required int screenWidth,
  required int screenHeight,
}) {
  Map<String, Object?> stringParam(String description) => {
    'type': 'string',
    'description': description,
  };

  Map<String, Object?> intParam(
    String description, {
    int? minimum,
    int? maximum,
  }) {
    final param = <String, Object?>{
      'type': 'integer',
      'description': description,
    };
    if (minimum != null) param['minimum'] = minimum;
    if (maximum != null) param['maximum'] = maximum;
    return param;
  }

  final drawUrlDescription =
      'Download a full-color image and draw it on the ${screenWidth}x$screenHeight '
      'companion display inside a fixed round stage. Takes an http:// or https:// URL '
      'of a baseline (not progressive) JPEG, PNG, WebP or GIF. Any '
      'resolution works: the phone cover-crops a square around the subject '
      'and draws it sharply, then animates '
      'idle, listening, thinking, speaking, boot, and shutdown. The portrait '
      'blinks and looks around. A thinking spinner and a listen ring stay on '
      'the bezel. A short tap pets the picture and does not dismiss it. '
      'Prefer a sharp picture of your own Muse, not a tiny pixel icon. '
      'Plain http:// uses the least device memory. Replies when the image '
      'is drawn and cached on the device. The character stays visible until '
      'replaced or cleared with display.show_animation, and survives app '
      'restarts.';

  final statusDescription =
      'Update the caption below the character. The character remains '
      'visible. Send meaningful updates when your activity changes; keep '
      'them short (one or two lines). Full Unicode is supported, including '
      'accented characters and emoji. Up to $maxStatusChars characters.';

  final displayDescription =
      'Adjust the companion display preferences. All parameters are '
      'optional and applied together; omitted ones are left unchanged. '
      'Settings are saved on the device. Speech volume and the spoken '
      'voice are chosen in Settings and cannot be changed here.';

  final healthDescription =
      'Report companion health: battery level (percent), whether it is '
      'charging, device model, OS version and app version.';

  return {
    'display.draw_url': {
      'description': drawUrlDescription,
      'required': {'url': stringParam('http:// or https:// URL of the image.')},
      'optional': {
        'row': intParam(
          'Ignored on the companion; accepted for compatibility with '
          'fixed-layout gadgets.',
        ),
      },
      'timeout_ms': drawImageTimeoutMs,
    },
    'display.show_animation': {
      'description':
          'Clear the character image and bring back the neutral placeholder '
          'and the agent name. The caption is kept.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'companion.set_status': {
      'description': statusDescription,
      'required': {
        'text': stringParam(
          'Current activity or status, up to $maxStatusChars characters.',
        ),
      },
      'optional': <String, Object?>{},
    },
    // Same handler as companion.set_status: Muses that learned the Pocket
    // command names keep working with the companion app.
    'pocket.set_status': {
      'description':
          '$statusDescription (Compatibility alias of '
          'companion.set_status.)',
      'required': {
        'text': stringParam(
          'Current activity or status, up to $maxStatusChars characters.',
        ),
      },
      'optional': <String, Object?>{},
    },
    'companion.set_display': {
      'description': displayDescription,
      'required': <String, Object?>{},
      'optional': {
        'theme': stringParam('Color theme: "light", "dark" or "system".'),
        'keep_screen_on': {
          'type': 'boolean',
          'description':
              'Keep the screen on while the companion screen is visible.',
        },
        'speak_replies': {
          'type': 'boolean',
          'description': 'Speak assistant replies aloud on the phone speaker.',
        },
      },
    },
    'device.health': {
      'description': healthDescription,
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'usb.list_devices': {
      'description':
          'List USB devices plugged into the phone over OTG (flash drives, '
          'etc.): device name, vendor/product id, class, and whether the '
          'app already has permission to open each one.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'usb.request_permission': {
      'description':
          'Show the system USB permission dialog on the phone for one '
          'device, so the app may open it. The user answers on the phone; '
          'call usb.list_devices afterwards to see has_permission.',
      'required': {
        'device': stringParam('Device name from usb.list_devices.'),
      },
      'optional': <String, Object?>{},
    },
    'usb.list_volumes': {
      'description':
          'List mounted removable storage volumes (USB OTG drives, SD '
          'cards): mount path, label, total and free space. Take a path '
          'from here for usb.list_files.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'usb.list_files': {
      'description':
          'List files and folders inside a mounted removable volume. Up '
          'to 500 entries, folders first. Refuses paths outside mounted '
          'removable volumes.',
      'required': {
        'path': stringParam(
          'Directory path from usb.list_volumes, e.g. /storage/1A2B-3C4D.',
        ),
      },
      'optional': <String, Object?>{},
    },
    'usb.read_file': {
      'description':
          'Read a file from a mounted removable volume. Returns the '
          'content base64-encoded, capped at 10MB. Refuses paths outside '
          'mounted removable volumes.',
      'required': {
        'path': stringParam('File path inside a mounted removable volume.'),
      },
      'optional': <String, Object?>{},
    },
    'usb.serial_list': {
      'description':
          'List USB serial devices plugged into the phone over OTG (dev '
          'boards, routers, 3D printers, ham radios, GPS units, industrial '
          'gear, ...): device name, driver/chip (CDC-ACM, FTDI, CP210x, '
          'CH340, PL2303), port number, vendor/product id, and whether the '
          'app already has permission to open each one. Take a device name '
          'from here for usb.serial_open.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'usb.serial_open': {
      'description':
          'Open a USB serial port and get a session id for talking to it. '
          'Defaults to 115200 baud, 8 data bits, 1 stop bit, no parity. '
          'Needs USB permission first: if the result says so, call '
          'usb.request_permission with the device name, then try again.',
      'required': {
        'device': stringParam('Device name from usb.serial_list.'),
      },
      'optional': {
        'baud_rate': intParam('Baud rate, e.g. 9600 or 115200. Default 115200.'),
        'port': intParam(
          'Port index for multi-port adapters. Default 0.',
        ),
      },
    },
    'usb.serial_write': {
      'description':
          'Write bytes to an open serial port. Data is plain text by '
          'default; pass encoding base64 for binary payloads.',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
        'data': stringParam('Text to write, or base64 when encoding is set.'),
      },
      'optional': {
        'encoding': stringParam('"utf8" (default) or "base64".'),
      },
    },
    'usb.serial_write_line': {
      'description':
          'Write a line to an open serial port with a trailing newline '
          'appended. Most firmware consoles expect newline-terminated '
          'commands, so prefer this over usb.serial_write for them.',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
        'data': stringParam('Line to write, without the newline.'),
      },
      'optional': {
        'encoding': stringParam('"utf8" (default) or "base64".'),
      },
    },
    'usb.serial_read': {
      'description':
          'Read available bytes from an open serial port, waiting up to '
          'timeout_ms. Returns the byte count plus the data as base64 and '
          'as a UTF-8 text decode.',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
      },
      'optional': {
        'timeout_ms': intParam(
          'How long to wait, in ms. Default 2000, max 30000.',
          minimum: 100,
          maximum: 30000,
        ),
      },
    },
    'usb.serial_read_lines': {
      'description':
          'Read up to max_lines newline-terminated lines from an open '
          'serial port, waiting until they arrive or the timeout elapses. '
          'Returns the lines as a list, plus any partial (unterminated) '
          'line still buffered.',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
      },
      'optional': {
        'max_lines': intParam('Max lines to collect. Default 50.', minimum: 1),
        'timeout_ms': intParam(
          'How long to wait, in ms. Default 2000, max 30000.',
          minimum: 100,
          maximum: 30000,
        ),
      },
    },
    'usb.serial_drain': {
      'description':
          'Discard all buffered input on an open serial port and report '
          'how many bytes were dropped. Useful before sending a fresh '
          'command so the reply is not polluted by stale output.',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
      },
      'optional': <String, Object?>{},
    },
    'usb.serial_set_baud': {
      'description':
          'Change the baud rate on an already-open serial port (keeps 8 '
          'data bits, 1 stop bit, no parity).',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
        'baud_rate': intParam('New baud rate, e.g. 9600 or 115200.'),
      },
      'optional': <String, Object?>{},
    },
    'usb.serial_set_dtr_rts': {
      'description':
          'Drive the DTR and RTS control lines on an open serial port. '
          'This is generic serial line control: toggling these sequences '
          'is how many devices are reset or put into firmware-download '
          'mode.',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
      },
      'optional': {
        'dtr': {
          'type': 'boolean',
          'description': 'DTR line state. Default false.',
        },
        'rts': {
          'type': 'boolean',
          'description': 'RTS line state. Default false.',
        },
      },
    },
    'usb.serial_port_info': {
      'description':
          'Report an open serial port: driver/chip, baud rate, data bits, '
          'stop bits, parity, and the CTS/DSR line state where the driver '
          'supports it.',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
      },
      'optional': <String, Object?>{},
    },
    'usb.serial_purge': {
      'description':
          'Purge the hardware buffers of an open serial port.',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
      },
      'optional': {
        'direction': stringParam(
          '"rx", "tx", or "both" (default).',
        ),
      },
    },
    'usb.serial_close': {
      'description':
          'Close an open serial port and release its session id.',
      'required': {
        'session': stringParam('Session id from usb.serial_open.'),
      },
      'optional': <String, Object?>{},
    },
    'file.list': {
      'description':
          'List files and folders in the agent workspace (sandboxed app '
          'storage for notes, itineraries, data): name, type, size, '
          'modified time. Folders first, 500-entry cap. Omit path for '
          'the workspace root.',
      'required': <String, Object?>{},
      'optional': {
        'path': stringParam('Folder inside the workspace, e.g. notes.'),
      },
    },
    'file.read': {
      'description':
          'Read a workspace file as text (64k char cap) or base64 '
          '(10MB cap) with encoding base64. Paths stay inside the '
          'workspace; traversal is refused.',
      'required': {
        'path': stringParam('Workspace file path, e.g. notes/todo.txt.'),
      },
      'optional': {
        'encoding': stringParam('"text" (default) or "base64".'),
      },
    },
    'file.write': {
      'description':
          'Write text to a workspace file (5MB cap), creating parent '
          'folders. Atomic: temp file + rename. Pass append true to '
          'append instead of replacing. Pass encoding base64 with '
          'base64-encoded content to store binary files (images for '
          'vision.analyze).',
      'required': {
        'path': stringParam('Workspace file path, e.g. notes/todo.txt.'),
        'content': stringParam('Text to store, or base64 with encoding.'),
      },
      'optional': {
        'append': {
          'type': 'boolean',
          'description': 'Append to the file instead of replacing it.',
        },
        'encoding': stringParam(
          '"text" (default) or "base64" for binary content.',
        ),
      },
    },
    'file.delete': {
      'description':
          'Delete a workspace file or empty folder. Returns whether '
          'anything was removed.',
      'required': {
        'path': stringParam('Workspace file or folder path.'),
      },
      'optional': <String, Object?>{},
    },
    'scene.save': {
      'description':
          'Save a named offline routine: 1-10 command steps run in order '
          'on the phone, stopping at the first failure. Run it later '
          'with scene.run. A scene cannot contain other scene.* steps.',
      'required': {
        'id': stringParam(
          'Scene id: 1-32 chars of a-z, 0-9, _ or -, e.g. movie-night.',
        ),
      },
      'optional': {
        'title': stringParam('Human title shown in the scene list.'),
        'steps_json': stringParam(
          'JSON array of steps, each {"command": "...", "params": {...}}. '
          'Example: [{"command":"phone.speak","params":{"text":"Hi"}}].',
        ),
      },
    },
    'scene.list': {
      'description':
          'List saved offline routines: id, title, step count.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'scene.run': {
      'description':
          'Run a saved offline routine by id, executing its steps in '
          'order on the phone. Reports per-step results and whether the '
          'scene completed.',
      'required': {
        'id': stringParam('Scene id from scene.list.'),
      },
      'optional': <String, Object?>{},
    },
    'scene.delete': {
      'description': 'Delete a saved offline routine. Returns whether '
          'anything was removed.',
      'required': {
        'id': stringParam('Scene id from scene.list.'),
      },
      'optional': <String, Object?>{},
    },
    'sensors.read': {
      'description':
          'Take one-shot motion and magnetic-field readings: '
          'accelerometer (m/s^2 incl. gravity), gyroscope (rad/s), '
          'magnetometer (microtesla), plus per-sensor availability. '
          'Missing hardware reports absent instead of failing.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'media.enqueue': {
      'description':
          'Queue an audio URL for playback on the phone speaker '
          '(http/https only, 50-track cap). Pass next true to play it '
          'right after the current track.',
      'required': {
        'url': stringParam('http(s) audio URL to queue.'),
      },
      'optional': {
        'title': stringParam('Track title for the queue listing.'),
        'mime': stringParam('MIME hint, e.g. audio/mpeg.'),
        'next': {
          'type': 'boolean',
          'description': 'Insert after the current track. Default false.',
        },
      },
    },
    'media.queue': {
      'description':
          'Show the playback queue: player state, current index, and '
          'tracks with titles.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'media.play': {
      'description':
          'Play the queue from the current track (or the given index). '
          'Audio only; video needs a visible surface the agent has not.',
      'required': <String, Object?>{},
      'optional': {
        'index': intParam('Queue index to start from. Default current.'),
      },
    },
    'media.control': {
      'description': 'Control playback: pause, resume, stop, next, previous.',
      'required': {
        'action': stringParam(
          '"pause", "resume", "stop", "next" or "previous".',
        ),
      },
      'optional': <String, Object?>{},
    },
    'media.clear': {
      'description': 'Stop playback and empty the queue.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'display.show_card': {
      'description':
          'Show an interactive card on the phone stage: title, text, '
          'up to 4 buttons. The user taps a button on the phone; the '
          'choice is recorded, not pushed — read it back with '
          'display.card_status. The card auto-dismisses after ttl_s '
          '(default 60, max 3600). Showing a card replaces any current '
          'one.',
      'required': {
        'title': stringParam('Card title.'),
      },
      'optional': {
        'text': stringParam('Card body text.'),
        'image_url': stringParam('http(s) image shown on the card.'),
        'buttons_json': stringParam(
          'JSON array of buttons, each {"id": "...", "label": "..."}. '
          'Example: [{"id":"yes","label":"Yes"}].',
        ),
        'ttl_s': intParam(
          'Seconds before auto-dismiss. Default 60, max 3600.',
          minimum: 1,
          maximum: 3600,
        ),
      },
    },
    'display.card_status': {
      'description':
          'Report the current card (if any) and the last recorded '
          'button choice.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'display.clear_card': {
      'description': 'Dismiss the current card without recording a choice.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'vision.capture': {
      'description':
          'Take one photo with the phone camera and show it to you in this '
          'chat, so you can see what the phone is looking at. The command '
          'returns once the photo has been posted. Optional prompt is the '
          'question to ask about the photo.',
      'required': <String, Object?>{},
      'optional': {
        'prompt': stringParam(
          'Question to ask about the photo. Defaults to asking what you see.',
        ),
        'facing': stringParam(
          'Camera to use: "back" or "front". Defaults to the camera chosen in Companion Settings.',
        ),
      },
      'timeout_ms': drawImageTimeoutMs,
    },
    'home.status': {
      'description':
          'Show smart-home integration status: whether Home Assistant '
          'and MQTT are enabled and configured (base URL, host, topic '
          'prefix). Secrets are never included.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'home.states': {
      'description':
          'Read Home Assistant entity states (capped list), or one '
          'entity with entity_id like light.kitchen. Needs Home '
          'Assistant enabled and set up in Settings.',
      'required': <String, Object?>{},
      'optional': {
        'entity_id': stringParam(
          'Entity id, e.g. light.kitchen. Omit to list states.',
        ),
      },
    },
    'home.call': {
      'description':
          'Call a Home Assistant service, e.g. domain light, service '
          'turn_on with entity_id light.kitchen. Needs Home Assistant '
          'enabled and set up in Settings.',
      'required': {
        'domain': stringParam('Service domain, e.g. light.'),
        'service': stringParam('Service name, e.g. turn_on.'),
      },
      'optional': {
        'entity_id': stringParam('Target entity, e.g. light.kitchen.'),
        'data_json': stringParam(
          'Extra service data as a JSON object, e.g. {"brightness": 128}.',
        ),
      },
    },
    'mqtt.status': {
      'description':
          'Show MQTT status: enabled, broker host/port, topic prefix. '
          'Same payload as home.status.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'mqtt.publish': {
      'description':
          'Publish a message to the MQTT broker under the configured '
          'topic prefix (default muse/). Absolute topics, wildcards and '
          'escapes are refused. Needs MQTT enabled and set up in Settings.',
      'required': {
        'topic': stringParam(
          'Topic under the prefix, e.g. desk/lamp/set.',
        ),
        'message': stringParam('Message payload.'),
      },
      'optional': <String, Object?>{},
    },
    'vision.analyze': {
      'description':
          'Read text (OCR) and barcodes from a workspace image, fully '
          'on-device — the image never leaves the phone. Store image '
          'bytes first with file.write encoding base64. Returns the '
          'recognized text plus decoded barcodes with formats.',
      'required': {
        'path': stringParam('Workspace image path, e.g. scans/receipt.jpg.'),
      },
      'optional': {
        'mode': stringParam(
          '"text", "barcode" or "both" (default).',
        ),
      },
    },
    'voice.stop': {
      'description': 'Stop any in-progress speech immediately.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
      'timeout_ms': drawImageTimeoutMs,
    },
    'local_ai.run_task': {
      'description':
          'Run a task through the on-phone local AI (LM Studio). The local '
          'model receives phone tools and acts on the device. Works only when '
          '"Enable local AI" is on in Companion Settings.',
      'required': {
        'instruction': stringParam('What the local model should do.'),
      },
      'optional': <String, Object?>{},
    },
    'voice.listen': {
      'description':
          'Record the phone microphone and send the clip to you as a voice '
          'note. seconds is 1 to 20, default 5. Optional prompt is text sent '
          'with the note.',
      'required': <String, Object?>{},
      'optional': {
        'seconds': intParam(
          'How long to listen, 1 to 20.',
          minimum: 1,
          maximum: 20,
        ),
        'prompt': stringParam('Text sent with the voice note.'),
      },
      'timeout_ms': drawImageTimeoutMs,
    },
    'phone.open_url': {
      'description': 'Open an http(s) URL on the phone.',
      'required': {'url': stringParam('http:// or https:// URL.')},
      'optional': <String, Object?>{},
    },
    'phone.launch_app': {
      'description':
          'Open an installed app by exact package name or app name '
          '(for example "maps" or "com.google.android.apps.maps"). '
          'A weak name that matches several apps returns those names '
          'instead of opening one. Turn on Screen control so this still '
          'works while Muse Companion is in the background.',
      'required': {'name': stringParam('Package name or app name.')},
      'optional': <String, Object?>{},
    },
    'phone.list_apps': {
      'description':
          'List launchable apps as name and package. Without a query, '
          'returns up to 200 and sets truncated when more exist. With a '
          'query, returns up to 40 matches.',
      'required': <String, Object?>{},
      'optional': {
        'query': stringParam('Name or package fragment. Omit to list apps.'),
      },
    },
    'phone.clipboard': {
      'description': 'Read or replace the phone clipboard.',
      'required': {'action': stringParam('"get" or "set".')},
      'optional': {'text': stringParam('Text to copy when action is set.')},
    },
    'phone.flashlight': {
      'description': 'Turn the phone flashlight on or off.',
      'required': {
        'on': {'type': 'boolean', 'description': 'True to turn the torch on.'},
      },
      'optional': <String, Object?>{},
    },
    'phone.volume': {
      'description':
          'Set a volume stream as a percent from 0 to 100. stream is '
          'music (the default), ring, alarm, notification, or voice.',
      'required': {
        'level': intParam('Volume percent.', minimum: 0, maximum: 100),
      },
      'optional': {
        'stream': stringParam(
          'music, ring, alarm, notification, or voice. Defaults to music.',
        ),
      },
    },
    'phone.brightness': {
      'description':
          'Set the screen brightness as a percent from 0 to 100, or switch '
          'auto brightness on. Needs the system "modify settings" grant; if '
          'it is missing the settings page opens and the result says so.',
      'required': {
        'level': intParam('Brightness percent.', minimum: 0, maximum: 100),
      },
      'optional': {
        'mode': stringParam(
          '"manual" (default) applies level. "auto" turns automatic brightness on.',
        ),
      },
    },
    'phone.location': {
      'description':
          'Report the phone\'s last known location (latitude, longitude, '
          'accuracy in meters) when the user has granted location.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'phone.notify': {
      'description': 'Show a notification on the phone.',
      'required': {
        'title': stringParam('Notification title.'),
        'text': stringParam('Notification body.'),
      },
      'optional': <String, Object?>{},
    },
    'phone.alarm': {
      'description': 'Set an alarm on the phone clock.',
      'required': {
        'hour': intParam('Hour 0-23.', minimum: 0, maximum: 23),
        'minute': intParam('Minute 0-59.', minimum: 0, maximum: 59),
      },
      'optional': {'message': stringParam('Alarm label.')},
    },
    'phone.dial': {
      'description':
          'Open the phone dialer with a number filled in. The user places '
          'the call.',
      'required': {'number': stringParam('Phone number.')},
      'optional': <String, Object?>{},
    },
    'phone.call': {
      'description':
          'Place a phone call. Works only after the user turns on '
          '"Allow Muse to place calls" in Companion Settings.',
      'required': {'number': stringParam('Phone number.')},
      'optional': <String, Object?>{},
    },
    'phone.sms': {
      'description':
          'Open a text message addressed to number with the body filled in. '
          'Pass send=true to send it directly, which works only after the '
          'user turns on "Allow Muse to send texts".',
      'required': {
        'number': stringParam('Destination phone number.'),
        'text': stringParam('Message body.'),
      },
      'optional': {
        'send': {
          'type': 'boolean',
          'description':
              'Send immediately when the user has allowed it. Otherwise the composer opens.',
        },
      },
    },
    'phone.messages': {
      'description':
          'Read the latest text messages in the inbox (sender, body, time). '
          'Requires the SMS permission.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'phone.notifications': {
      'description':
          'Read the notifications currently posted on the phone. The user '
          'must enable notification access for Muse Companion.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'phone.contacts': {
      'description': 'Search contacts by name or number. Returns up to 20.',
      'required': {'query': stringParam('Name or number fragment.')},
      'optional': <String, Object?>{},
    },
    'phone.events': {
      'description': 'List upcoming calendar events, up to 15.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'phone.share': {
      'description': 'Open the system share sheet with text.',
      'required': {'text': stringParam('Text to share.')},
      'optional': <String, Object?>{},
    },
    'phone.speak': {
      'description':
          'Speak text aloud on the phone speaker, using the voice chosen '
          'in Companion Settings.',
      'required': {'text': stringParam('What to say.')},
      'optional': <String, Object?>{},
    },
    'phone.media': {
      'description':
          'Send a media key: play, pause, play_pause, next, previous, stop.',
      'required': {
        'action': stringParam(
          'play, pause, play_pause, next, previous, or stop.',
        ),
      },
      'optional': <String, Object?>{},
    },
    'phone.capabilities': {
      'description':
          'Report which phone controls are available and which permissions '
          'are granted right now.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'phone.ringer': {
      'description':
          'Read or set the ringer: normal, vibrate, or silent. action is '
          '"get" or "set". Silent mode may ask the user for Do Not Disturb access.',
      'required': <String, Object?>{},
      'optional': {
        'action': stringParam('"get" (default) or "set".'),
        'mode': stringParam('When setting: normal, vibrate, or silent.'),
      },
    },
    'phone.vibrate': {
      'description': 'Vibrate the phone for a short time.',
      'required': <String, Object?>{},
      'optional': {
        'ms': intParam(
          'Duration in milliseconds, 1 to 5000. Default 200.',
          minimum: 1,
          maximum: 5000,
        ),
      },
    },
    'phone.dnd': {
      'description':
          'Read or set Do Not Disturb. mode is all, priority, alarms, or '
          'none. If the user has not allowed notification policy access, '
          'the system page opens instead of changing the mode.',
      'required': <String, Object?>{},
      'optional': {
        'action': stringParam('"get" (default) or "set".'),
        'mode': stringParam('all, priority, alarms, or none.'),
      },
    },
    'phone.rotation': {
      'description':
          'Read or set screen rotation: auto, portrait, landscape, or '
          'locked. Needs the system "modify settings" grant.',
      'required': <String, Object?>{},
      'optional': {
        'action': stringParam('"get" (default) or "set".'),
        'mode': stringParam('auto, portrait, landscape, or locked.'),
      },
    },
    'phone.radio': {
      'description':
          'Report Wi-Fi, Bluetooth, NFC, mobile data, or airplane mode, or '
          'open the system panel for that radio. Android does not let an '
          'app flip these radios by itself. kind is wifi, bluetooth, nfc, '
          'airplane, or mobile. action is "status" (default) or "open".',
      'required': {
        'kind': stringParam('wifi, bluetooth, nfc, airplane, or mobile.'),
      },
      'optional': {'action': stringParam('"status" or "open".')},
    },
    'phone.settings': {
      'description':
          'Open a system settings page: wifi, bluetooth, nfc, display, '
          'sound, apps, battery, location, notifications, wireless, date, '
          'accessibility, storage, about, dnd, airplane, data, security, '
          'write, or app. page "app" opens an app\'s details; pass package '
          'or it opens this companion.',
      'required': {'page': stringParam('Which settings page to open.')},
      'optional': {'package': stringParam('Package name when page is app.')},
    },
    'phone.timer': {
      'description': 'Start a countdown timer on the phone clock.',
      'required': {
        'seconds': intParam(
          'Length in seconds, 1 to 86400.',
          minimum: 1,
          maximum: 86400,
        ),
      },
      'optional': {'message': stringParam('Timer label.')},
    },
    'phone.device': {
      'description':
          'Report this phone: model, Android version, battery, storage, '
          'screen, ringer, and whether Wi-Fi, Bluetooth, NFC, and airplane '
          'mode are on. Does not include accounts or hardware identifiers.',
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
    'phone.screen': {
      'description':
          'Report whether the screen is on. action "wake" turns the screen '
          'on and brings Muse Companion forward.',
      'required': <String, Object?>{},
      'optional': {'action': stringParam('"status" (default) or "wake".')},
    },
    'phone.screenshot': {
      'description':
          'Take a screenshot of the phone and post it in this chat so you '
          'can see the screen. Requires Screen control, which the user turns '
          'on in Companion Settings. The command returns once the picture '
          'has been posted. Optional prompt is the question to ask about it.',
      'required': <String, Object?>{},
      'optional': {
        'prompt': stringParam(
          'Question to ask about the screenshot. Defaults to asking what is on screen.',
        ),
      },
      'timeout_ms': drawImageTimeoutMs,
    },
    'phone.ui': {
      'description':
          'Read what is on the phone screen: text, bounds as '
          'left,top,right,bottom, and whether each control is clickable, '
          'editable, or focused. Up to 60 controls. Optional query keeps '
          'only matching text. Requires Screen control.',
      'required': <String, Object?>{},
      'optional': {
        'query': stringParam('Text, description, or id fragment to keep.'),
      },
    },
    'phone.tap': {
      'description':
          'Tap the phone screen, like a mouse click. Pass text to tap a '
          'visible label, or x and y in pixels, or x_percent and y_percent '
          'from 0 to 100. long=true holds the tap. Requires Screen control.',
      'required': <String, Object?>{},
      'optional': {
        'text': stringParam('Visible label or content description to tap.'),
        'x': intParam('Horizontal pixel.'),
        'y': intParam('Vertical pixel.'),
        'x_percent': intParam(
          'Horizontal position, 0 to 100. Overrides x.',
          minimum: 0,
          maximum: 100,
        ),
        'y_percent': intParam(
          'Vertical position, 0 to 100. Overrides y.',
          minimum: 0,
          maximum: 100,
        ),
        'long': {
          'type': 'boolean',
          'description': 'Hold the tap instead of a short tap.',
        },
      },
    },
    'phone.swipe': {
      'description':
          'Swipe on the phone screen. Give x,y and x2,y2 in pixels, or '
          'x_percent, y_percent, x2_percent, and y2_percent from 0 to 100. '
          'duration is milliseconds from 80 to 2000, default 300. '
          'Requires Screen control.',
      'required': <String, Object?>{},
      'optional': {
        'x': intParam('Start horizontal pixel.'),
        'y': intParam('Start vertical pixel.'),
        'x2': intParam('End horizontal pixel.'),
        'y2': intParam('End vertical pixel.'),
        'x_percent': intParam(
          'Start horizontal percent, 0 to 100.',
          minimum: 0,
          maximum: 100,
        ),
        'y_percent': intParam(
          'Start vertical percent, 0 to 100.',
          minimum: 0,
          maximum: 100,
        ),
        'x2_percent': intParam(
          'End horizontal percent, 0 to 100.',
          minimum: 0,
          maximum: 100,
        ),
        'y2_percent': intParam(
          'End vertical percent, 0 to 100.',
          minimum: 0,
          maximum: 100,
        ),
        'duration': intParam(
          'Swipe length in milliseconds, 80 to 2000. Default 300.',
          minimum: 80,
          maximum: 2000,
        ),
      },
    },
    'phone.type': {
      'description':
          'Replace the text in the focused field. Optional target is a '
          'hint or current value that picks the field. Requires Screen control.',
      'required': {'text': stringParam('Text to put in the field.')},
      'optional': {
        'target': stringParam('Hint or current text of the field to fill.'),
      },
    },
    'phone.press': {
      'description':
          'Press a system key: back, home, recents, notifications, '
          'quick_settings, lock, or power. Requires Screen control.',
      'required': {
        'key': stringParam(
          'back, home, recents, notifications, quick_settings, lock, or power.',
        ),
      },
      'optional': <String, Object?>{},
    },
    'phone.screen_control': {
      'description':
          'Report whether Screen control is on, or open its system page so '
          'the user can turn it on. action is "status" (default) or "open". '
          'You cannot turn it on yourself.',
      'required': <String, Object?>{},
      'optional': {'action': stringParam('"status" or "open".')},
    },
  };
}

/// Result of drawing a downloaded character image.
class ImageDrawResult {
  const ImageDrawResult.ok({
    required this.width,
    required this.height,
    required this.bytes,
    required this.fromCache,
  }) : error = null;

  const ImageDrawResult.failed(this.error)
    : width = 0,
      height = 0,
      bytes = 0,
      fromCache = false;

  bool get isOk => error == null;
  final String? error;
  final int width;
  final int height;
  final int bytes;
  final bool fromCache;
}

/// Platform side of the display commands (implemented by the app layer).
abstract class CompanionDisplay {
  /// Show a status caption; returns the stored text.
  Future<String> setStatus(String text);

  /// Download [url], cache it, decode it and show it as the character.
  Future<ImageDrawResult> drawImageFromUrl(String url);

  /// Clear the character back to the neutral placeholder.
  Future<void> showPlaceholder();

  /// Apply display preferences; nulls leave the current value unchanged.
  Future<Map<String, Object?>> setDisplay({
    String? theme,
    bool? keepScreenOn,
    bool? speakReplies,
  });

  /// Current display preferences (theme, keep_screen_on, ...).
  Future<Map<String, Object?>> displayInfo();
}

/// Platform side of `device.health` (implemented by the app layer).
abstract class CompanionHealth {
  Future<Map<String, Object?>> health();
}

Map<String, Object?> okResult(Map<String, Object?> payload) => {
  'ok': true,
  'payload': payload,
};

Map<String, Object?> errorResult(String message) => {
  'ok': false,
  'error': message,
};

/// Posts a chat turn, including camera frames and voice notes.
typedef PostToMuse =
    Future<Map<String, Object?>> Function(
      String message,
      List<ChatAttachment> attachments,
    );

/// Dispatches the Muse's `link.invoke` calls to the app.
class CompanionExecutor {
  CompanionExecutor({
    required this.display,
    required this.health,
    this.phone,
    this.postToMuse,
    this.allowCalls,
    this.allowSendSms,
    this.cameraFacing,
    this.usbStorageEnabled,
    this.usbSerialEnabled,
    this.lmStudioEnabled,
    this.lmStudioUrl,
    this.lmStudioAgentModel,
    this.systemOneEnabled,
    this.systemOneUrl,
    this.speakReplies,
    this.workspace,
    this.scenes,
    this.sensors,
    this.mediaQueue,
    this.cards,
    this.visionAnalyzer,
    this.homeConfig,
    this.mqttPublisher,
  });

  final CompanionDisplay display;
  final CompanionHealth health;
  final PhoneActions? phone;
  final PostToMuse? postToMuse;

  /// User toggles. Calls and direct texts stay off until these return true.
  final bool Function()? allowCalls;
  final bool Function()? allowSendSms;

  /// User toggles. USB storage and USB serial commands are refused while
  /// these return false.
  final bool Function()? usbStorageEnabled;
  final bool Function()? usbSerialEnabled;

  /// Local AI (LM Studio) settings. local_ai.run_task is refused while
  /// [lmStudioEnabled] returns false.
  final bool Function()? lmStudioEnabled;
  final String Function()? lmStudioUrl;
  final String Function()? lmStudioAgentModel;

  /// Voice output. phone.speak is refused while [speakReplies] returns
  /// false (2026-10-04: voice doomloop fix).
  final bool Function()? speakReplies;

  /// SystemOne tool routing. When [systemOneEnabled] returns true, the
  /// phone tool list is narrowed per task via [systemOneUrl] before
  /// sending it to the local model.
  final bool Function()? systemOneEnabled;
  final String Function()? systemOneUrl;

  /// Camera chosen in Companion Settings when vision.capture omits facing.
  final String Function()? cameraFacing;

  /// Sandboxed workspace file store. Null uses the default documents
  /// location; tests inject a temp dir.
  final WorkspaceFiles? workspace;

  /// Saved offline routines. Null uses the default documents location;
  /// tests inject a temp dir.
  final SceneStore? scenes;

  /// One-shot sensor reader. Null reads real hardware; tests inject a
  /// fake sampler.
  final SensorReader? sensors;

  /// Audio playback queue. Null plays through a real audio backend;
  /// tests inject a fake backend.
  final MediaQueuePlayer? mediaQueue;

  /// Interactive display cards. Null uses the process-wide store the
  /// companion screen observes; tests inject an isolated store.
  final ChoiceCardStore? cards;

  /// On-device image analysis backend. Null uses real ML Kit models;
  /// tests inject a fake.
  final VisionAnalyzerBackend? visionAnalyzer;

  /// Loads the smart-home config (Settings plus secrets). Null means
  /// unconfigured; tests inject a fixed config.
  final Future<HomeIntegrationConfig?> Function()? homeConfig;

  /// MQTT publish seam. Null connects to the real broker per publish;
  /// tests inject a recording fake.
  final MqttPublisher? mqttPublisher;

  Future<Map<String, Object?>> run(
    String command,
    Map<String, Object?> params,
    int? timeoutMs,
  ) async {
    try {
      switch (command) {
        case 'display.draw_url':
          return await _drawUrl(params);
        case 'display.show_animation':
          await display.showPlaceholder();
          return okResult({'status': 'placeholder'});
        case 'companion.set_status':
        case 'pocket.set_status':
          return await _setStatus(params);
        case 'companion.set_display':
          return await _setDisplay(params);
        case 'device.health':
          return okResult(await health.health());
        case 'usb.list_devices':
        case 'usb.request_permission':
        case 'usb.list_volumes':
        case 'usb.list_files':
        case 'usb.read_file':
          return await _usbStorage(command, params);
        case 'usb.serial_list':
        case 'usb.serial_open':
        case 'usb.serial_write':
        case 'usb.serial_write_line':
        case 'usb.serial_read':
        case 'usb.serial_read_lines':
        case 'usb.serial_drain':
        case 'usb.serial_set_baud':
        case 'usb.serial_set_dtr_rts':
        case 'usb.serial_port_info':
        case 'usb.serial_purge':
        case 'usb.serial_close':
          return await _usbSerial(command, params);
        case 'file.list':
        case 'file.read':
        case 'file.write':
        case 'file.delete':
          return await _workspaceFiles(command, params);
        case 'scene.save':
        case 'scene.list':
        case 'scene.run':
        case 'scene.delete':
          return await _scenes(command, params, timeoutMs);
        case 'sensors.read':
          return okResult(await (sensors ?? SensorReader()).read());
        case 'media.enqueue':
        case 'media.queue':
        case 'media.play':
        case 'media.control':
        case 'media.clear':
          return await _mediaQueue(command, params);
        case 'display.show_card':
        case 'display.card_status':
        case 'display.clear_card':
          return _displayCard(command, params);
        case 'vision.capture':
          return await _capture(params);
        case 'vision.analyze':
          return await _visionAnalyze(command, params);
        case 'home.status':
        case 'home.states':
        case 'home.call':
        case 'mqtt.status':
        case 'mqtt.publish':
          return await _home(command, params);
        case 'phone.screenshot':
          return await _screenshot(params);
        case 'voice.stop':
          return await _stopSpeak();
        case 'local_ai.run_task':
          return await _localAiRunTask(params);
        case 'voice.listen':
          return await _listen(params);
        case 'phone.speak':
          return await _speak(params);
        case 'phone.call':
          return await _call(params);
        case 'phone.sms':
          return await _sms(params);
        default:
          if (command.startsWith('phone.')) {
            return await _phone(command, params);
          }
      }
    } on PhoneActionException catch (e) {
      return errorResult(e.message);
    } catch (e) {
      return errorResult('$e');
    }
    return errorResult('unsupported command: $command');
  }

  Future<Map<String, Object?>> _setStatus(Map<String, Object?> params) async {
    final text = params['text'];
    if (text is! String || text.isEmpty) {
      return errorResult('text is required');
    }
    final clipped = text.length > maxStatusChars
        ? text.substring(0, maxStatusChars)
        : text;
    final stored = await display.setStatus(clipped);
    return okResult({
      'status': 'ok',
      'characters': stored.length,
      if (text.length > maxStatusChars) 'truncated': true,
    });
  }

  Future<Map<String, Object?>> _drawUrl(Map<String, Object?> params) async {
    final url = params['url'];
    if (url is! String || url.isEmpty) {
      return errorResult('url is required');
    }
    final dataImage =
        url.startsWith('data:image/') ||
        url.startsWith('data:model/') ||
        url.startsWith('data:application/octet-stream');
    final uri = Uri.tryParse(url);
    final httpUrl =
        uri != null && (uri.isScheme('http') || uri.isScheme('https'));
    if (!dataImage && !httpUrl) {
      return errorResult('url must be http:// or https://');
    }
    final result = await display.drawImageFromUrl(url);
    if (!result.isOk) {
      return errorResult(result.error ?? 'download failed');
    }
    return okResult({
      'status': 'drawn',
      'width': result.width,
      'height': result.height,
      'bytes': result.bytes,
      'cached': result.fromCache,
    });
  }

  Future<Map<String, Object?>> _setDisplay(Map<String, Object?> params) async {
    final theme = params['theme'];
    if (theme != null &&
        theme != 'light' &&
        theme != 'dark' &&
        theme != 'system') {
      return errorResult('theme must be light, dark or system');
    }
    final keepScreenOn = params['keep_screen_on'];
    if (keepScreenOn != null && keepScreenOn is! bool) {
      return errorResult('keep_screen_on must be a boolean');
    }
    final speakReplies = params['speak_replies'];
    if (speakReplies != null && speakReplies is! bool) {
      return errorResult('speak_replies must be a boolean');
    }
    final applied = await display.setDisplay(
      theme: theme as String?,
      keepScreenOn: keepScreenOn as bool?,
      speakReplies: speakReplies as bool?,
    );
    return okResult({'status': 'ok', ...applied});
  }

  Future<Map<String, Object?>> _capture(Map<String, Object?> params) async {
    final phone = _requirePhone();
    if (phone is Map<String, Object?>) return phone;
    final prompt = params['prompt'];
    final question = prompt is String && prompt.trim().isNotEmpty
        ? prompt.trim()
        : 'Look at this photo from the phone camera and describe what you see.';
    final facing = _cameraFacing(params);
    await display.setStatus('Looking through the camera');
    final jpeg = await (phone as PhoneActions).captureJpeg(facing: facing);
    return _postSeen(
      question,
      ChatAttachment(
        mimeType: 'image/jpeg',
        filename: 'camera.jpg',
        bytes: jpeg,
      ),
      'photo',
    );
  }

  Future<Map<String, Object?>> _screenshot(Map<String, Object?> params) async {
    final phone = _requirePhone();
    if (phone is Map<String, Object?>) return phone;
    final prompt = params['prompt'];
    final question = prompt is String && prompt.trim().isNotEmpty
        ? prompt.trim()
        : 'Look at this screenshot of the phone and describe what is on the screen.';
    await display.setStatus('Looking at the screen');
    final result = await (phone as PhoneActions).run('phone.screenshot', params);
    final bytes = _jpegBytes(result['jpeg']);
    if (bytes == null || bytes.isEmpty) {
      return errorResult('the phone returned an empty screenshot');
    }
    final posted = await _postSeen(
      question,
      ChatAttachment(
        mimeType: 'image/jpeg',
        filename: 'screen.jpg',
        bytes: bytes,
      ),
      'screenshot',
    );
    if (posted['ok'] != true) return posted;
    final payload = Map<String, Object?>.from(posted['payload']! as Map);
    final width = _asInt(result['width']);
    final height = _asInt(result['height']);
    if (width != null) payload['width'] = width;
    if (height != null) payload['height'] = height;
    return okResult(payload);
  }

  Uint8List? _jpegBytes(Object? raw) {
    if (raw is Uint8List) return raw;
    if (raw is List) {
      final bytes = Uint8List(raw.length);
      for (var i = 0; i < raw.length; i++) {
        final value = raw[i];
        if (value is! int) return null;
        bytes[i] = value;
      }
      return bytes;
    }
    return null;
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  Future<Map<String, Object?>> _listen(Map<String, Object?> params) async {
    final phone = _requirePhone();
    if (phone is Map<String, Object?>) return phone;
    final rawSeconds = params['seconds'];
    var seconds = rawSeconds is int ? rawSeconds : 5;
    if (seconds < 1) seconds = 1;
    if (seconds > 20) seconds = 20;
    final prompt = params['prompt'];
    final question = prompt is String ? prompt : '';
    await display.setStatus('Listening');
    final wav = await (phone as PhoneActions).recordWav(seconds);
    return _postSeen(
      question,
      ChatAttachment(
        mimeType: 'audio/wav',
        filename: 'voice_note.wav',
        bytes: wav,
      ),
      'voice note',
    );
  }

  Future<Map<String, Object?>> _stopSpeak() async {
    final phone = _requirePhone();
    if (phone is Map<String, Object?>) return phone;
    await (phone as PhoneActions).stopSpeak();
    return okResult({'status': 'stopped'});
  }

  Future<Map<String, Object?>> _speak(Map<String, Object?> params) async {
    final phone = _requirePhone();
    if (phone is Map<String, Object?>) return phone;
    if (speakReplies?.call() == false) {
      return errorResult('voice output is off (Speak replies disabled)');
    }
    final text = params['text'];
    if (text is! String || text.trim().isEmpty) {
      return errorResult('text is required');
    }
    await (phone as PhoneActions).speak(text);
    return okResult({'status': 'speaking', 'characters': text.length});
  }

  Future<Map<String, Object?>> _call(Map<String, Object?> params) async {
    if (allowCalls?.call() != true) {
      return errorResult('placing calls is off in Companion Settings');
    }
    return _phone('phone.call', params);
  }

  Future<Map<String, Object?>> _sms(Map<String, Object?> params) async {
    final send = params['send'] == true && allowSendSms?.call() == true;
    return _phone('phone.sms', {...params, 'send': send});
  }

  Future<Map<String, Object?>> _localAiRunTask(
    Map<String, Object?> params,
  ) async {
    if (lmStudioEnabled?.call() != true) {
      return errorResult('Local AI is disabled in Companion Settings');
    }
    final instruction = params['instruction'];
    if (instruction is! String || instruction.trim().isEmpty) {
      return errorResult('instruction is required');
    }
    final phoneResult = _requirePhone();
    if (phoneResult is Map<String, Object?>) return phoneResult;
    final service = LocalAiService(
      baseUrl: lmStudioUrl?.call() ?? '',
      model: lmStudioAgentModel?.call() ?? '',
      phone: phoneResult as PhoneActions,
      usbStorageEnabled: usbStorageEnabled?.call() == true,
      usbSerialEnabled: usbSerialEnabled?.call() == true,
      cameraFacing: cameraFacing?.call() ?? 'back',
      systemOneEnabled: systemOneEnabled?.call() == true,
      systemOneUrl: systemOneUrl?.call() ?? 'http://100.68.208.113:8765',
      speakAllowed: speakReplies?.call() ?? true,
    );
    final result = await service.runTask(instruction.trim());
    if (!result.ok) return errorResult(result.error);
    return okResult({
      'text': result.text,
      'tool_calls': result.toolCalls,
    });
  }

  Future<Map<String, Object?>> _usbStorage(
    String command,
    Map<String, Object?> params,
  ) async {
    if (usbStorageEnabled?.call() != true) {
      return errorResult('USB storage is disabled in Companion Settings');
    }
    return _phone(command, params);
  }

  Future<Map<String, Object?>> _usbSerial(
    String command,
    Map<String, Object?> params,
  ) async {
    if (usbSerialEnabled?.call() != true) {
      return errorResult('USB serial is disabled in Companion Settings');
    }
    return _phone(command, params);
  }

  Future<Map<String, Object?>> _workspaceFiles(
    String command,
    Map<String, Object?> params,
  ) async {
    final files = workspace ?? WorkspaceFiles();
    try {
      switch (command) {
        case 'file.list': {
          final entries = await files.list(
            params['path']?.toString() ?? '',
          );
          return okResult({
            'entries': [for (final e in entries) e.toJson()],
          });
        }
        case 'file.read': {
          final path = params['path'];
          if (path is! String || path.isEmpty) {
            return errorResult('path is required');
          }
          if (params['encoding']?.toString() == 'base64') {
            final (payload, size) = await files.readBytes(path);
            return okResult({
              'path': path,
              'encoding': 'base64',
              'content': payload,
              'size_bytes': size,
            });
          }
          return okResult({
            'path': path,
            'encoding': 'text',
            'content': await files.readText(path),
          });
        }
        case 'file.write': {
          final path = params['path'];
          final content = params['content'];
          if (path is! String || path.isEmpty) {
            return errorResult('path is required');
          }
          if (content is! String) {
            return errorResult('content is required');
          }
          if (params['encoding']?.toString() == 'base64') {
            List<int> bytes;
            try {
              bytes = base64Decode(content);
            } catch (_) {
              return errorResult('content is not valid base64');
            }
            final size = await files.writeBytes(path, bytes);
            return okResult({'path': path, 'size_bytes': size});
          }
          final size = await files.writeText(
            path,
            content,
            append: params['append'] == true,
          );
          return okResult({'path': path, 'size_bytes': size});
        }
        case 'file.delete': {
          final path = params['path'];
          if (path is! String || path.isEmpty) {
            return errorResult('path is required');
          }
          return okResult({'path': path, 'deleted': await files.delete(path)});
        }
      }
    } on WorkspaceException catch (e) {
      return errorResult(e.message);
    }
    return errorResult('unsupported command: $command');
  }

  Future<Map<String, Object?>> _scenes(
    String command,
    Map<String, Object?> params,
    int? timeoutMs,
  ) async {
    final store = scenes ?? SceneStore();
    try {
      switch (command) {
        case 'scene.save': {
          final id = params['id'];
          if (id is! String || id.isEmpty) {
            return errorResult('id is required');
          }
          final steps = _parseSceneSteps(params['steps_json']);
          if (steps == null) {
            return errorResult(
              'steps_json must be a JSON array of '
              '{"command": ..., "params": {...}} steps',
            );
          }
          for (final step in steps) {
            if (step.command.startsWith('scene.')) {
              return errorResult('scenes cannot contain scene.* steps');
            }
          }
          final title = params['title']?.toString().trim();
          final stored = await store.save(
            Scene(
              id: id,
              title: title == null || title.isEmpty ? id : title,
              steps: steps,
            ),
          );
          return okResult({'id': stored, 'steps': steps.length});
        }
        case 'scene.list': {
          final list = await store.list();
          return okResult({
            'scenes': [
              for (final s in list)
                {'id': s.id, 'title': s.title, 'steps': s.steps.length},
            ],
          });
        }
        case 'scene.run': {
          final id = params['id'];
          if (id is! String || id.isEmpty) {
            return errorResult('id is required');
          }
          final outcome = await store.runScene(
            id,
            (c, p) => run(c, p, timeoutMs),
          );
          return okResult(outcome.toJson());
        }
        case 'scene.delete': {
          final id = params['id'];
          if (id is! String || id.isEmpty) {
            return errorResult('id is required');
          }
          return okResult({'id': id, 'deleted': await store.delete(id)});
        }
      }
    } on SceneException catch (e) {
      return errorResult(e.message);
    }
    return errorResult('unsupported command: $command');
  }

  /// Parse the scene.save steps_json array, or null when malformed.
  List<SceneStep>? _parseSceneSteps(Object? raw) {
    if (raw == null) return const [];
    if (raw is! String || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return [
        for (final item in decoded)
          if (item is Map<String, Object?>)
            SceneStep.fromJson(item)
          else if (item is Map)
            SceneStep.fromJson(item.cast<String, Object?>()),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>> _mediaQueue(
    String command,
    Map<String, Object?> params,
  ) async {
    final player = mediaQueue ?? MediaQueuePlayer();
    try {
      switch (command) {
        case 'media.enqueue': {
          final url = params['url'];
          if (url is! String || url.isEmpty) {
            return errorResult('url is required');
          }
          player.queue.add(
            MediaTrack(
              url: url,
              title: params['title']?.toString() ?? '',
              mime: params['mime']?.toString() ?? '',
            ),
            next: params['next'] == true,
          );
          return okResult({
            'queue_length': player.queue.length,
            ...player.status(),
          });
        }
        case 'media.queue':
          return okResult({
            'queue_length': player.queue.length,
            ...player.status(),
            'tracks': [
              for (var i = 0; i < player.queue.tracks.length; i++)
                {'index': i, ...player.queue.tracks[i].toJson()},
            ],
          });
        case 'media.play': {
          final rawIndex = params['index'];
          final index = rawIndex is num ? rawIndex.toInt() : null;
          if (await player.play(index)) return okResult(player.status());
          return errorResult(
            player.lastError.isEmpty ? 'nothing to play' : player.lastError,
          );
        }
        case 'media.control': {
          final action = params['action']?.toString();
          switch (action) {
            case 'pause':
              if (await player.pause()) return okResult(player.status());
              return errorResult('nothing playing');
            case 'resume':
              if (await player.resume()) return okResult(player.status());
              return errorResult('nothing paused');
            case 'stop':
              await player.stop();
              return okResult(player.status());
            case 'next':
              await player.next();
              return okResult(player.status());
            case 'previous':
              await player.previous();
              return okResult(player.status());
          }
          return errorResult(
            'action must be pause, resume, stop, next or previous',
          );
        }
        case 'media.clear':
          player.queue.clear();
          await player.stop();
          return okResult(player.status());
      }
    } on MediaQueueException catch (e) {
      return errorResult(e.message);
    }
    return errorResult('unsupported command: $command');
  }

  Map<String, Object?> _displayCard(
    String command,
    Map<String, Object?> params,
  ) {
    final store = cards ?? ChoiceCardStore.instance;
    try {
      switch (command) {
        case 'display.show_card': {
          final title = params['title'];
          if (title is! String || title.trim().isEmpty) {
            return errorResult('title is required');
          }
          final buttons = _parseCardButtons(params['buttons_json']);
          if (buttons == null) {
            return errorResult(
              'buttons_json must be a JSON array of '
              '{"id": ..., "label": ...} buttons',
            );
          }
          final rawTtl = params['ttl_s'];
          final card = store.show(
            title: title,
            text: params['text']?.toString() ?? '',
            imageUrl: params['image_url']?.toString() ?? '',
            buttons: buttons,
            ttlSeconds: rawTtl is num ? rawTtl.toInt() : 60,
          );
          return okResult(card.toJson());
        }
        case 'display.card_status':
          return okResult(store.status());
        case 'display.clear_card':
          store.clear();
          return okResult({'cleared': true});
      }
    } on ChoiceCardException catch (e) {
      return errorResult(e.message);
    }
    return errorResult('unsupported command: $command');
  }

  /// Parse the display.show_card buttons_json array, or null when malformed.
  List<CardButton>? _parseCardButtons(Object? raw) {
    if (raw == null) return const [];
    if (raw is! String || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return [
        for (final item in decoded)
          if (item is Map<String, Object?>)
            CardButton.fromJson(item)
          else if (item is Map)
            CardButton.fromJson(item.cast<String, Object?>()),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>> _visionAnalyze(
    String command,
    Map<String, Object?> params,
  ) async {
    assert(command == 'vision.analyze');
    final path = params['path'];
    if (path is! String || path.isEmpty) {
      return errorResult('path is required');
    }
    try {
      final analysis = await analyzeWorkspaceImage(
        files: workspace ?? WorkspaceFiles(),
        relPath: path,
        mode: params['mode']?.toString() ?? 'both',
        backend: visionAnalyzer,
      );
      return okResult({'path': path, ...analysis.toJson()});
    } on VisionException catch (e) {
      return errorResult(e.message);
    } on WorkspaceException catch (e) {
      return errorResult(e.message);
    }
  }

  Future<Map<String, Object?>> _home(
    String command,
    Map<String, Object?> params,
  ) async {
    final config = await homeConfig?.call() ?? const HomeIntegrationConfig();
    try {
      switch (command) {
        case 'home.status':
        case 'mqtt.status':
          return okResult(config.status());
        case 'home.states':
        case 'home.call': {
          final api = _requireHomeAssistant(config);
          if (api is Map<String, Object?>) return api;
          final assistant = api as HomeAssistant;
          if (command == 'home.states') {
            final entity = params['entity_id']?.toString();
            return okResult({
              'states': await assistant.states(
                entity == null || entity.isEmpty ? null : entity,
              ),
            });
          }
          final domain = params['domain'];
          final service = params['service'];
          if (domain is! String || domain.isEmpty) {
            return errorResult('domain is required');
          }
          if (service is! String || service.isEmpty) {
            return errorResult('service is required');
          }
          final data = _parseServiceData(params['data_json']);
          if (data == null) {
            return errorResult('data_json must be a JSON object');
          }
          final changed = await assistant.callService(
            domain,
            service,
            entityId: params['entity_id']?.toString(),
            data: data,
          );
          return okResult({'changed': changed});
        }
        case 'mqtt.publish': {
          if (!config.mqttEnabled) {
            return errorResult('MQTT is disabled in Companion Settings');
          }
          if (config.mqttHost.isEmpty) {
            return errorResult(
              'MQTT is not set up: enter the broker host in Settings',
            );
          }
          final topic = params['topic'];
          final message = params['message'];
          if (topic is! String || topic.isEmpty) {
            return errorResult('topic is required');
          }
          if (message is! String) {
            return errorResult('message is required');
          }
          final full = resolveMqttTopic(config.mqttTopicPrefix, topic);
          await (mqttPublisher ?? RealMqttPublisher()).publish(
            host: config.mqttHost,
            port: config.mqttPort,
            username: config.mqttUsername,
            password: config.mqttPassword,
            topic: full,
            message: message,
          );
          return okResult({'topic': full, 'published': true});
        }
      }
    } on HomeIntegrationException catch (e) {
      return errorResult(e.message);
    }
    return errorResult('unsupported command: $command');
  }

  /// A configured [HomeAssistant], or an error result map when the
  /// integration is off or missing its URL/token.
  Object _requireHomeAssistant(HomeIntegrationConfig config) {
    if (!config.homeEnabled) {
      return errorResult('Home Assistant is disabled in Companion Settings');
    }
    if (config.homeBaseUrl.isEmpty || config.homeToken.isEmpty) {
      return errorResult(
        'Home Assistant is not set up: enter the base URL and token '
        'in Settings',
      );
    }
    return HomeAssistant(baseUrl: config.homeBaseUrl, token: config.homeToken);
  }

  /// Parse the home.call data_json object. Null means malformed;
  /// absent means no extra data.
  Map<String, Object?>? _parseServiceData(Object? raw) {
    if (raw == null) return const {};
    if (raw is! String || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>> _phone(
    String command,
    Map<String, Object?> params,
  ) async {
    final phone = _requirePhone();
    if (phone is Map<String, Object?>) return phone;
    final result = await (phone as PhoneActions).run(command, params);
    return okResult(result);
  }

  String _cameraFacing(Map<String, Object?> params) {
    final requested = params['facing'];
    if (requested != null) {
      if (requested is! String) {
        throw const PhoneActionException('facing must be back or front');
      }
      final value = requested.trim().toLowerCase();
      if (value == 'back' || value == 'front') return value;
      throw const PhoneActionException('facing must be back or front');
    }
    return cameraFacing?.call() == 'front' ? 'front' : 'back';
  }

  /// A [PhoneActions], or an error result map when the phone is unavailable.
  Object _requirePhone() {
    final phone = this.phone;
    if (phone == null) {
      return errorResult('phone controls are not available on this device');
    }
    return phone;
  }

  Future<Map<String, Object?>> _postSeen(
    String message,
    ChatAttachment attachment,
    String kind,
  ) async {
    final post = postToMuse;
    if (post == null) {
      return errorResult('chat is not connected');
    }
    if (attachment.bytes.isEmpty) {
      return errorResult('the phone returned an empty $kind');
    }
    if (attachment.bytes.length > 2 * 1024 * 1024) {
      return errorResult('$kind is too large to send');
    }
    final posted = await post(message, [attachment]);
    if (posted['ok'] != true) {
      final error = posted['error'];
      return errorResult(error is String ? error : 'could not post the $kind');
    }
    return okResult({
      'status': 'posted',
      'kind': kind,
      'bytes': attachment.bytes.length,
    });
  }
}

/// The first message the companion sends its Muse after pairing.
///
/// Mirrors the Pocket intro (`pocket_intro_request` in
// `esp32/main/noise_control.cpp`), adapted to the full-color display.
String companionIntroMessage() {
  return 'Initialize Muse Companion as my companion display and phone. '
      'Redraw your own Muse avatar and send it with '
      'display.draw_url: a full-color PNG, JPEG, WebP or GIF, as sharp as '
      'you can make it. The phone fits that picture inside a fixed round '
      'stage. It blinks, looks around, '
      'and moves through idle, listening, thinking, speaking, boot, and '
      'shutdown, the way a full-UI Muse board does. A short tap pets the '
      'portrait. Holding it sends you a voice note, and the bezel fills for '
      'that hold. Do not send the '
      'default gadget character. A GLB URL still displays, but the pixel '
      'portrait is the one to send. '
      'Keep the character visible and set the caption with companion.set_status '
      'to your current activity. Use short plain text with Unicode and emoji '
      'where they help. You can see through the phone camera with vision.capture, listen '
      'with voice.listen, and use the phone.* commands registered on this '
      'device (open links, launch apps, notifications, messages, contacts, '
      'calendar, location, alarms, timers, clipboard, flashlight, volume, '
      'ringer, brightness, rotation, vibration, and spoken replies). '
      'A USB drive plugged in over OTG shows up in usb.list_volumes; '
      'browse it with usb.list_files and read files with usb.read_file. '
      'USB serial devices (dev boards, routers, 3D printers, radios, ...) '
      'show up in usb.serial_list; open one with usb.serial_open and talk '
      'to it with usb.serial_write_line and usb.serial_read_lines. '
      'Once Screen control is on, phone.screenshot shows you the screen, '
      'phone.ui reads it, and phone.tap, phone.swipe, phone.type, and '
      'phone.press use it. '
      'Wi-Fi, Bluetooth, NFC, and airplane mode open the system panel. '
      'Each reply you write is shown as the caption under the '
      'character, the way a Muse screen does, and spoken when the phone is '
      'set to. If already set up, refresh the character and current status. '
      'Tell me if a command fails.';
}
