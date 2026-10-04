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

import 'dart:typed_data';

import 'chat_events.dart';
import 'phone_actions.dart';

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
  });

  final CompanionDisplay display;
  final CompanionHealth health;
  final PhoneActions? phone;
  final PostToMuse? postToMuse;

  /// User toggles. Calls and direct texts stay off until these return true.
  final bool Function()? allowCalls;
  final bool Function()? allowSendSms;

  /// Camera chosen in Companion Settings when vision.capture omits facing.
  final String Function()? cameraFacing;

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
          return await _phone(command, params);
        case 'vision.capture':
          return await _capture(params);
        case 'phone.screenshot':
          return await _screenshot(params);
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

  Future<Map<String, Object?>> _speak(Map<String, Object?> params) async {
    final phone = _requirePhone();
    if (phone is Map<String, Object?>) return phone;
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
      'Once Screen control is on, phone.screenshot shows you the screen, '
      'phone.ui reads it, and phone.tap, phone.swipe, phone.type, and '
      'phone.press use it. '
      'Wi-Fi, Bluetooth, NFC, and airplane mode open the system panel. '
      'Each reply you write is shown as the caption under the '
      'character, the way a Muse screen does, and spoken when the phone is '
      'set to. If already set up, refresh the character and current status. '
      'Tell me if a command fails.';
}
