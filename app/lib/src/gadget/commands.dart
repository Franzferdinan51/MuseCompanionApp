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
// phone's resolution and full Unicode captions.

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

  Map<String, Object?> intParam(String description,
      {int? minimum, int? maximum}) {
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
      'companion display. Takes an http:// or https:// URL of a JPEG, PNG, '
      'WebP or GIF; any resolution works and the device scales and crops it '
      'to fill the character canvas while keeping the subject centered. '
      'Plain http:// uses the least device memory. Replies when the image '
      'is drawn and cached on the device. The character stays visible until '
      'replaced or cleared with display.show_animation, and survives app '
      'restarts. Prefer a square portrait of the character on a clean '
      'background; photographic detail and color are fully supported.';

  final statusDescription =
      'Update the caption below the character. The character remains '
      'visible. Send meaningful updates when your activity changes; keep '
      'them short (one or two lines). Full Unicode is supported, including '
      'accented characters and emoji. Up to $maxStatusChars characters.';

  final displayDescription =
      'Adjust the companion display preferences. All parameters are '
      'optional and applied together; omitted ones are left unchanged. '
      'Settings are saved on the device.';

  final healthDescription =
      'Report companion health: battery level (percent), whether it is '
      'charging, device model, OS version and app version.';

  return {
    'display.draw_url': {
      'description': drawUrlDescription,
      'required': {
        'url': stringParam('http:// or https:// URL of the image.'),
      },
      'optional': {
        'row': intParam(
            'Ignored on the companion; accepted for compatibility with '
            'fixed-layout gadgets.'),
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
            'Current activity or status, up to $maxStatusChars characters.'),
      },
      'optional': <String, Object?>{},
    },
    // Same handler as companion.set_status: Muses that learned the Pocket
    // command names keep working with the companion app.
    'pocket.set_status': {
      'description': '$statusDescription (Compatibility alias of '
          'companion.set_status.)',
      'required': {
        'text': stringParam(
            'Current activity or status, up to $maxStatusChars characters.'),
      },
      'optional': <String, Object?>{},
    },
    'companion.set_display': {
      'description': displayDescription,
      'required': <String, Object?>{},
      'optional': {
        'theme': stringParam(
            'Color theme: "light", "dark" or "system".'),
        'keep_screen_on': {
          'type': 'boolean',
          'description':
              'Keep the screen on while the companion screen is visible.',
        },
      },
    },
    'device.health': {
      'description': healthDescription,
      'required': <String, Object?>{},
      'optional': <String, Object?>{},
    },
  };
}

/// Result of drawing a downloaded character image.
class ImageDrawResult {
  const ImageDrawResult.ok(
      {required this.width,
      required this.height,
      required this.bytes,
      required this.fromCache})
      : error = null;

  const ImageDrawResult.failed(this.error)
      : width = 0,
        height = 0,
        bytes = 0,
        fromCache = false;

  final bool get isOk => error == null;
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
  Future<Map<String, Object?>> setDisplay({String? theme, bool? keepScreenOn});

  /// Current display preferences (theme, keep_screen_on, ...).
  Future<Map<String, Object?>> displayInfo();
}

/// Platform side of `device.health` (implemented by the app layer).
abstract class CompanionHealth {
  Future<Map<String, Object?>> health();
}

Map<String, Object?> okResult(Map<String, Object?> payload) =>
    {'ok': true, 'payload': payload};

Map<String, Object?> errorResult(String message) =>
    {'ok': false, 'error': message};

/// Dispatches the Muse's `link.invoke` calls to the app.
class CompanionExecutor {
  CompanionExecutor({required this.display, required this.health});

  final CompanionDisplay display;
  final CompanionHealth health;

  Future<Map<String, Object?>> run(String command,
      Map<String, Object?> params, int? timeoutMs) async {
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
      }
    } catch (e) {
      return errorResult('$e');
    }
    return errorResult('unsupported command: $command');
  }

  Future<Map<String, Object?>> _setStatus(
      Map<String, Object?> params) async {
    final text = params['text'];
    if (text is! String || text.isEmpty) {
      return errorResult('text is required');
    }
    final clipped =
        text.length > maxStatusChars ? text.substring(0, maxStatusChars) : text;
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
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
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

  Future<Map<String, Object?>> _setDisplay(
      Map<String, Object?> params) async {
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
    final applied = await display.setDisplay(
      theme: theme as String?,
      keepScreenOn: keepScreenOn as bool?,
    );
    return okResult({'status': 'ok', ...applied});
  }
}

/// The first message the companion sends its Muse after pairing.
///
/// Mirrors the Pocket intro (`pocket_intro_request` in
// `esp32/main/noise_control.cpp`), adapted to the full-color display.
String companionIntroMessage() {
  return 'Initialize Muse Companion as my companion display. Send your own '
      'character image using display.draw_url, as a full-color JPEG, PNG or '
      'WebP at any resolution; photographic detail is fully supported. Keep '
      'the character visible and set the caption with companion.set_status '
      'to your current activity. Use short plain text with Unicode and '
      'emoji where they help. Keep the caption current on meaningful '
      'activity changes. If already set up, refresh the character and '
      'current status. Tell me if a command fails.';
}
