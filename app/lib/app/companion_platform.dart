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
// App-layer implementation of the `CompanionDisplay` / `CompanionHealth`
// platform sides from commands.dart. This is where the Muse's display commands
// touch the real device: downloading+caching character images, persisting the
// caption, applying display preferences and reporting health. It performs no
// presentation logic itself — decoded images and captions are handed back to
// the PresentationState via [CompanionDisplayListener].

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:battery_plus/battery_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:muse_companion/src/gadget/commands.dart';
import 'package:path_provider/path_provider.dart';

import 'model.dart';
import 'storage.dart';

/// Largest character image accepted, in bytes (20 MiB).
const int maxCharacterBytes = 20 * 1024 * 1024;

/// Receives the side effects of a display command so the UI can update.
abstract class CompanionDisplayListener {
  void onCharacter(Uint8List bytes, int width, int height);
  void onStatus(String text);
  void onPlaceholder();
  void onSettings(CompanionSettings settings);
}

class AppCompanionDisplay implements CompanionDisplay {
  AppCompanionDisplay({
    required this.listener,
    required SettingsStore settings,
    http.Client? client,
  })  : _settings = settings,
        _client = client;

  final SettingsStore _settings;
  final CompanionDisplayListener listener;
  final http.Client? _client;

  @override
  Future<String> setStatus(String text) async {
    await _settings.saveStatus(text);
    listener.onStatus(text);
    return text;
  }

  @override
  Future<ImageDrawResult> drawImageFromUrl(String url) async {
    if (url.startsWith('data:')) {
      return _drawBytes(_decodeDataUrl(url), fromCache: false);
    }
    final client = _client ?? http.Client();
    final owned = _client == null;
    try {
      final cachedPath = await _cachePath(url);
      Uint8List bytes;
      bool fromCache;
      if (await File(cachedPath).exists()) {
        bytes = await File(cachedPath).readAsBytes();
        fromCache = true;
      } else {
        final response = await client.get(Uri.parse(url));
        if (response.statusCode != 200) {
          return ImageDrawResult.failed(
              'download failed: ${response.statusCode}');
        }
        bytes = response.bodyBytes;
        if (bytes.length > maxCharacterBytes) {
          return ImageDrawResult.failed(
              'image too large (${bytes.length} bytes)');
        }
        fromCache = false;
        try {
          await File(cachedPath).writeAsBytes(bytes);
        } on IOException {
          // A writable cache is a convenience, not a requirement.
        }
      }
      // GLB 3D models are not images: pass them through to the 3D
      // viewer instead of decoding them. Same bytes-in pipeline, no
      // format restriction — .glb URLs work like image URLs.
      return _drawBytes(bytes, fromCache: fromCache);
    } finally {
      if (owned) client.close();
    }
  }

  Future<ImageDrawResult> _drawBytes(Uint8List? bytes,
      {required bool fromCache}) async {
    if (bytes == null || bytes.isEmpty) {
      return const ImageDrawResult.failed('image could not be decoded');
    }
    if (bytes.length > maxCharacterBytes) {
      return ImageDrawResult.failed('image too large (${bytes.length} bytes)');
    }
    if (isGlbModel(bytes)) {
      listener.onCharacter(bytes, 0, 0);
      await _rememberCharacter(bytes);
      return ImageDrawResult.ok(
          width: 0, height: 0, bytes: bytes.length, fromCache: fromCache);
    }
    int width;
    int height;
    try {
      final image = await _decode(bytes).timeout(const Duration(seconds: 15));
      width = image.width;
      height = image.height;
      image.dispose();
    } on TimeoutException {
      return const ImageDrawResult.failed('image decode timed out');
    } catch (_) {
      return const ImageDrawResult.failed('image could not be decoded');
    }
    listener.onCharacter(bytes, width, height);
    await _rememberCharacter(bytes);
    return ImageDrawResult.ok(
        width: width,
        height: height,
        bytes: bytes.length,
        fromCache: fromCache);
  }

  @override
  Future<void> showPlaceholder() async {
    listener.onPlaceholder();
    try {
      final file = File(await _lastCharacterPath());
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The placeholder still shows if the cache file cannot be removed.
    }
  }

  /// Last character the Muse sent, so a restart does not sit on the
  /// placeholder until the next draw.
  static Future<Uint8List?> loadCachedCharacter() async {
    try {
      final file = File(await _lastCharacterPath());
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > maxCharacterBytes) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, Object?>> setDisplay({
    String? theme,
    bool? keepScreenOn,
    bool? speakReplies,
  }) async {
    final next = _settings.loadSettings().copyWith(
          theme: theme,
          keepScreenOn: keepScreenOn,
          speakReplies: speakReplies,
        );
    await _settings.saveSettings(next);
    listener.onSettings(next);
    return {
      'theme': next.theme,
      'keep_screen_on': next.keepScreenOn,
      'speak_replies': next.speakReplies,
    };
  }

  @override
  Future<Map<String, Object?>> displayInfo() async {
    final current = _settings.loadSettings();
    return {
      'theme': current.theme,
      'keep_screen_on': current.keepScreenOn,
      'speak_replies': current.speakReplies,
    };
  }

  Uint8List? _decodeDataUrl(String url) {
    final comma = url.indexOf(',');
    if (comma < 0 || !url.substring(0, comma).contains(';base64')) {
      return null;
    }
    try {
      return base64Decode(url.substring(comma + 1));
    } on FormatException {
      return null;
    }
  }

  Future<void> _rememberCharacter(Uint8List bytes) async {
    try {
      final file = File(await _lastCharacterPath());
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // A missing cache must not fail the draw the user is already seeing.
    }
  }

  static Future<String> _lastCharacterPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/muse_character_last';
  }

  Future<String> _cachePath(String url) async {
    final digest = sha256.convert(utf8.encode(url));
    final dir = await getApplicationCacheDirectory();
    return '${dir.path}/muse_character_${digest.toString()}';
  }

  Future<ui.Image> _decode(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }
}

class AppCompanionHealth implements CompanionHealth {
  AppCompanionHealth({required this.appVersion});

  final String appVersion;

  @override
  Future<Map<String, Object?>> health() async {
    return {
      'battery_level': await _batteryLevel(),
      'charging': await _charging(),
      'model': await _model(),
      'os': _os(),
      'app_version': appVersion,
    };
  }

  Future<int?> _batteryLevel() async {
    try {
      return await Battery().batteryLevel;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _charging() async {
    try {
      final state = await Battery().batteryState;
      return state == BatteryState.charging ||
          state == BatteryState.full;
    } catch (_) {
      return false;
    }
  }

  Future<String> _model() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        return (await info.androidInfo).model;
      }
      if (Platform.isIOS) {
        return (await info.iosInfo).utsname.machine;
      }
      if (Platform.isMacOS) {
        return (await info.macOsInfo).model;
      }
      if (Platform.isWindows) {
        return (await info.windowsInfo).computerName;
      }
      if (Platform.isLinux) {
        return (await info.linuxInfo).prettyName;
      }
    } catch (_) {
      // Fall through to the generic answer.
    }
    return Platform.operatingSystem;
  }

  String _os() {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return Platform.operatingSystem;
    }
  }
}
