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
// Pure presentation state for the companion screen.
//
// This layer knows only what to render; it performs no I/O. The app wires it
// to the real gadget `service` (connection state, agent name) and to the
// `CompanionDisplay` platform side (character image, caption) so the UI can
// react without a running device. Keeping it framework-free makes the display
// derivation unit-testable in isolation.

import 'dart:async';
import 'dart:typed_data';

import 'package:muse_companion/app/avatar_motion.dart';
import 'package:muse_companion/src/gadget/commands.dart';
import 'package:muse_companion/src/gadget/service.dart';

/// Short link label shared by the home bar, the dashboard, and Settings.
///
/// Chat banners stay full sentences. Diagnostics keep the raw enum name.
String connectionStatusLabel(ConnectionState state) {
  switch (state) {
    case ConnectionState.connected:
      return 'Connected';
    case ConnectionState.connecting:
      return 'Connecting…';
    case ConnectionState.waiting:
      return 'Waiting to retry';
    case ConnectionState.unpaired:
      return 'Not paired';
    case ConnectionState.stopped:
      return 'Stopped';
  }
}

/// Maximum number of status lines drawn below the character.
const int kMaxStatusLines = 4;

/// Longest a single wrapped status line may be before it is re-wrapped.
const int kMaxStatusLineLength = 80;

/// GLB magic bytes: every binary glTF file starts with `glTF`.
const List<int> _glbMagic = <int>[0x67, 0x6C, 0x54, 0x46];

/// Whether [bytes] are a 3D model (GLB) rather than a 2D image.
///
/// Detection is by magic bytes only so the bytes-in pipeline stays
/// format-agnostic: anything starting with `glTF` renders in the 3D viewer,
/// everything else keeps the existing image path.
bool isGlbModel(Uint8List bytes) {
  if (bytes.length < _glbMagic.length) return false;
  for (var i = 0; i < _glbMagic.length; i++) {
    if (bytes[i] != _glbMagic[i]) return false;
  }
  return true;
}

/// GIF or animated WebP. Still images and GLB models return false.
///
/// GIF is the `GIF87a` / `GIF89a` header. Animated WebP is a RIFF/WEBP
/// file whose first bytes include an `ANIM` chunk. A still WebP has no
/// ANIM chunk and stays a normal image.
bool isAnimatedImage(Uint8List bytes) {
  if (bytes.length >= 6) {
    final head = String.fromCharCodes(bytes.sublist(0, 6));
    if (head == 'GIF87a' || head == 'GIF89a') return true;
  }
  if (bytes.length < 12) return false;
  final riff = String.fromCharCodes(bytes.sublist(0, 4));
  final webp = String.fromCharCodes(bytes.sublist(8, 12));
  if (riff != 'RIFF' || webp != 'WEBP') return false;
  final window = bytes.length < 256 ? bytes.length : 256;
  return String.fromCharCodes(bytes.sublist(0, window)).contains('ANIM');
}

/// Companion display preferences, matching `companion.set_display`.
///
/// The full-color app has no use for the e-paper controls (frontlight
/// brightness/warmth, refresh interval, orientation flip): the Muse and the
/// user instead choose a color theme and whether the companion screen keeps
/// the display awake.
class CompanionSettings {
  const CompanionSettings({
    this.theme = 'system',
    this.keepScreenOn = false,
    this.speakReplies = true,
    this.allowCalls = false,
    this.allowSendSms = false,
    this.speechVolume = 80,
    this.speechVoice = '',
    this.cameraFacing = 'back',
    this.autoCaptureEnabled = false,
    this.autoCaptureIntervalMinutes = 60,
    this.adbInfoSharingEnabled = false,
    this.usbStorageEnabled = true,
    this.usbSerialEnabled = true,
    this.lmStudioEnabled = false,
    this.lmStudioUrl = 'http://100.68.208.113:1234',
    this.lmStudioModel = '',
    this.lmStudioChatModel = '',
    this.lmStudioAgentModel = '',
    this.systemOneEnabled = false,
    this.systemOneUrl = 'http://100.68.208.113:8765',
    this.voiceProvider = 'android',
    this.openRouterModel = 'fish-audio/s2.1-pro-free:free',
    this.openRouterVoice = '',
  });

  /// One of `light`, `dark` or `system`.
  final String theme;
  final bool keepScreenOn;

  /// Speak assistant chat replies on the phone speaker.
  final bool speakReplies;

  /// Let Muse place calls with `phone.call`. Off until the user opts in.
  final bool allowCalls;

  /// Let Muse send texts directly with `phone.sms`. Off until the user opts in.
  final bool allowSendSms;

  /// Media volume used when a reply is spoken, 0–100.
  ///
  /// The Home Assistant Voice gadget keeps a speaker dial. This is that
  /// dial for the phone speaker. Muse cannot change it.
  final int speechVolume;

  /// Installed speech-engine voice name. Empty means the clearest voice
  /// for this phone's language. Muse cannot change it.
  final String speechVoice;

  /// `back` or `front`. Used by the camera button and by vision.capture
  /// when Muse does not name a camera. Muse cannot change the saved choice.
  final String cameraFacing;

  /// Automatically capture and post photos on a schedule. When enabled,
  /// the app takes a photo with the selected camera every
  /// [autoCaptureIntervalMinutes] and posts it to the Muse chat.
  final bool autoCaptureEnabled;

  /// Minutes between automatic captures. 15, 30, 60, 120, or 240.
  final int autoCaptureIntervalMinutes;

  /// Share ADB/wireless-ADB connection info with Muse via chat so remote
  /// troubleshooting is possible. Includes pairing status and port.
  final bool adbInfoSharingEnabled;

  /// Let Muse use USB mass-storage commands (usb.list_devices,
  /// usb.list_volumes, usb.list_files, usb.read_file). On until the user
  /// opts out.
  final bool usbStorageEnabled;

  /// Let Muse use USB serial commands (all usb.serial_*). On until the
  /// user opts out.
  final bool usbSerialEnabled;

  /// Let a local AI model (via LM Studio) control the phone. Off until the
  /// user opts in.
  final bool lmStudioEnabled;

  /// Base URL of the LM Studio server, e.g. http://100.68.208.113:1234.
  final String lmStudioUrl;

  /// Model id to request, or '' to use the server default. Never
  /// hard-code a model id here; the user picks it in Settings.
  final String lmStudioModel;

  /// Model id for general chat via LM Studio, or '' for server default.
  /// Never hard-code a model id here; the user picks it in Settings.
  final String lmStudioChatModel;

  /// Model id for the local-AI agent loop (tool calling), or '' for
  /// server default. Never hard-code a model id here.
  final String lmStudioAgentModel;

  /// Ask SystemOne to narrow the phone tool list per task before sending
  /// it to the local model. Opt-in; off by default.
  final bool systemOneEnabled;

  /// Base URL of the SystemOne router, e.g. http://100.68.208.113:8765.
  final String systemOneUrl;

  /// Voice provider: 'android' (native on-device TTS, the default) or
  /// 'openrouter' (OpenRouter cloud TTS). Opt-in only; the Android path
  /// is untouched and stays the default.
  final String voiceProvider;

  /// OpenRouter TTS model id, user-editable in Settings (OpenRouter rotates
  /// free models, so this is never hard-coded). Defaults to the free
  /// Fish Audio model.
  final String openRouterModel;

  /// OpenRouter TTS voice id (a Fish Audio reference/voice id), or ''
  /// for the model's default voice.
  final String openRouterVoice;

  CompanionSettings copyWith({
    String? theme,
    bool? keepScreenOn,
    bool? speakReplies,
    bool? allowCalls,
    bool? allowSendSms,
    int? speechVolume,
    String? speechVoice,
    String? cameraFacing,
    bool? autoCaptureEnabled,
    int? autoCaptureIntervalMinutes,
    bool? adbInfoSharingEnabled,
    bool? usbStorageEnabled,
    bool? usbSerialEnabled,
    bool? lmStudioEnabled,
    String? lmStudioUrl,
    String? lmStudioModel,
    String? lmStudioChatModel,
    String? lmStudioAgentModel,
    bool? systemOneEnabled,
    String? systemOneUrl,
    String? voiceProvider,
    String? openRouterModel,
    String? openRouterVoice,
  }) {
    return CompanionSettings(
      theme: theme ?? this.theme,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      speakReplies: speakReplies ?? this.speakReplies,
      allowCalls: allowCalls ?? this.allowCalls,
      allowSendSms: allowSendSms ?? this.allowSendSms,
      speechVolume: speechVolume ?? this.speechVolume,
      speechVoice: speechVoice ?? this.speechVoice,
      cameraFacing: cameraFacing ?? this.cameraFacing,
      autoCaptureEnabled: autoCaptureEnabled ?? this.autoCaptureEnabled,
      autoCaptureIntervalMinutes:
          autoCaptureIntervalMinutes ?? this.autoCaptureIntervalMinutes,
      adbInfoSharingEnabled:
          adbInfoSharingEnabled ?? this.adbInfoSharingEnabled,
      usbStorageEnabled: usbStorageEnabled ?? this.usbStorageEnabled,
      usbSerialEnabled: usbSerialEnabled ?? this.usbSerialEnabled,
      lmStudioEnabled: lmStudioEnabled ?? this.lmStudioEnabled,
      lmStudioUrl: lmStudioUrl ?? this.lmStudioUrl,
      lmStudioModel: lmStudioModel ?? this.lmStudioModel,
      lmStudioChatModel: lmStudioChatModel ?? this.lmStudioChatModel,
      lmStudioAgentModel: lmStudioAgentModel ?? this.lmStudioAgentModel,
      systemOneEnabled: systemOneEnabled ?? this.systemOneEnabled,
      systemOneUrl: systemOneUrl ?? this.systemOneUrl,
      voiceProvider: voiceProvider ?? this.voiceProvider,
      openRouterModel: openRouterModel ?? this.openRouterModel,
      openRouterVoice: openRouterVoice ?? this.openRouterVoice,
    );
  }

  /// The themes the gadget accepts.
  static const List<String> themeOptions = <String>['light', 'dark', 'system'];

  static const List<String> cameraFacings = <String>['back', 'front'];

  Map<String, Object?> toMap() => {
    'theme': theme,
    'keep_screen_on': keepScreenOn,
    'speak_replies': speakReplies,
    'allow_calls': allowCalls,
    'allow_send_sms': allowSendSms,
    'speech_volume': speechVolume.clamp(0, 100),
    'speech_voice': speechVoice,
    'camera_facing': cameraFacing,
    'auto_capture_enabled': autoCaptureEnabled,
    'auto_capture_interval_minutes': autoCaptureIntervalMinutes,
    'adb_info_sharing_enabled': adbInfoSharingEnabled,
  };

  static CompanionSettings fromMap(Map<String, Object?> map) {
    final theme = map['theme'];
    return CompanionSettings(
      theme: theme is String && themeOptions.contains(theme) ? theme : 'system',
      keepScreenOn: map['keep_screen_on'] == true,
      speakReplies: map['speak_replies'] is bool
          ? map['speak_replies']! as bool
          : true,
      allowCalls: map['allow_calls'] == true,
      allowSendSms: map['allow_send_sms'] == true,
      speechVolume: _speechVolume(map['speech_volume']),
      speechVoice: _speechVoice(map['speech_voice']),
      cameraFacing: _cameraFacing(map['camera_facing']),
      autoCaptureEnabled: map['auto_capture_enabled'] == true,
      autoCaptureIntervalMinutes:
          _captureInterval(map['auto_capture_interval_minutes']),
      adbInfoSharingEnabled: map['adb_info_sharing_enabled'] == true,
      usbStorageEnabled: map['usb_storage_enabled'] is bool
          ? map['usb_storage_enabled']! as bool
          : true,
      usbSerialEnabled: map['usb_serial_enabled'] is bool
          ? map['usb_serial_enabled']! as bool
          : true,
      lmStudioEnabled: map['lm_studio_enabled'] == true,
      lmStudioUrl: _lmStudioUrl(map['lm_studio_url']),
      lmStudioModel: _lmStudioModel(map['lm_studio_model']),
      lmStudioChatModel: _migratedModel(
        map['lm_studio_chat_model'],
        map['lm_studio_model'],
      ),
      lmStudioAgentModel: _migratedModel(
        map['lm_studio_agent_model'],
        map['lm_studio_model'],
      ),
      systemOneEnabled: map['system_one_enabled'] == true,
      systemOneUrl: _systemOneUrl(map['system_one_url']),
      voiceProvider: _voiceProvider(map['voice_provider']),
      openRouterModel: _openRouterModel(map['openrouter_model']),
      openRouterVoice: _openRouterVoice(map['openrouter_voice']),
    );
  }

  static String _cameraFacing(Object? value) =>
      value == 'front' ? 'front' : 'back';

  static int _captureInterval(Object? value) {
    const allowed = [60, 360, 720, 1440];
    if (value is int && allowed.contains(value)) return value;
    return 60;
  }

  /// Voice names are engine ids such as `en-us-x-iog-network`. Anything
  /// else is treated as automatic so a bad stored value cannot be applied.
  static String _speechVoice(Object? value) {
    if (value is! String) return '';
    final name = value.trim();
    if (name.isEmpty || name.length > 160) return '';
    for (final unit in name.codeUnits) {
      final printable = unit >= 0x21 && unit <= 0x7e;
      final forbidden =
          unit == 0x22 || unit == 0x27 || unit == 0x2f || unit == 0x5c;
      if (!printable || forbidden) return '';
    }
    return name;
  }

  static int _speechVolume(Object? value) {
    final number = value is num ? value.round() : 80;
    if (number < 0) return 0;
    if (number > 100) return 100;
    return number;
  }

  /// LM Studio URL: must be http(s). Falls back to the Mac mini default.
  static String _lmStudioUrl(Object? value) {
    if (value is String) {
      final url = value.trim();
      if ((url.startsWith('http://') || url.startsWith('https://')) &&
          url.length <= 256) {
        return url;
      }
    }
    return 'http://100.68.208.113:1234';
  }

  /// Model id: free text, empty means server default. Capped in length so
  /// a bad stored value cannot blow up requests.
  static String _lmStudioModel(Object? value) {
    if (value is! String) return '';
    final name = value.trim();
    if (name.length > 160) return '';
    return name;
  }

  /// New split keys (`lm_studio_chat_model`, `lm_studio_agent_model`) fall
  /// back to the legacy `lm_studio_model` value on first run after upgrade,
  /// so an existing config keeps working without user action.
  static String _migratedModel(Object? value, Object? legacy) {
    final current = _lmStudioModel(value);
    if (current.isNotEmpty) return current;
    return _lmStudioModel(legacy);
  }

  /// SystemOne URL: must be http(s). Falls back to the Mac mini default.
  static String _systemOneUrl(Object? value) {
    if (value is String) {
      final url = value.trim();
      if ((url.startsWith('http://') || url.startsWith('https://')) &&
          url.length <= 256) {
        return url;
      }
    }
    return 'http://100.68.208.113:8765';
  }

  /// Voice provider: 'openrouter' only when explicitly stored; anything
  /// else (including missing) means the Android TTS default.
  static String _voiceProvider(Object? value) =>
      value == 'openrouter' ? 'openrouter' : 'android';

  /// OpenRouter model id: printable ASCII, capped in length. Empty or bad
  /// values fall back to the free Fish Audio default.
  static String _openRouterModel(Object? value) {
    if (value is! String) return 'fish-audio/s2.1-pro-free:free';
    final id = value.trim();
    if (id.isEmpty || id.length > 160) return 'fish-audio/s2.1-pro-free:free';
    for (final unit in id.codeUnits) {
      if (unit < 0x21 || unit > 0x7e) return 'fish-audio/s2.1-pro-free:free';
    }
    return id;
  }

  /// OpenRouter voice id: same shape as a model id; empty means the
  /// model's default voice.
  static String _openRouterVoice(Object? value) {
    if (value is! String) return '';
    final id = value.trim();
    if (id.length > 160) return '';
    for (final unit in id.codeUnits) {
      if (unit < 0x21 || unit > 0x7e) return '';
    }
    return id;
  }
}

/// Splits a caption into the up to [kMaxStatusLines] lines drawn below the
/// character.
///
/// The caption may already contain newlines (as muse-pocket sends); each line
/// longer than [kMaxStatusLineLength] is hard-wrapped. This mirrors the Pocket "up to four lines" rule, relaxed for the full-color
/// display's wider canvas and full Unicode. Pure so it can be asserted directly.
List<String> deriveStatusLines(
  String text, {
  int maxLines = kMaxStatusLines,
  int maxLineLength = kMaxStatusLineLength,
}) {
  final result = <String>[];
  for (final rawLine in text.split('\n')) {
    if (result.length >= maxLines) break;
    if (rawLine.isEmpty) {
      result.add('');
      continue;
    }
    if (rawLine.length <= maxLineLength) {
      result.add(rawLine);
      continue;
    }
    for (
      var start = 0;
      start < rawLine.length && result.length < maxLines;
      start += maxLineLength
    ) {
      final end = (start + maxLineLength).clamp(0, rawLine.length);
      result.add(rawLine.substring(start, end));
    }
  }
  return result;
}

/// Observable snapshot of what the companion screen renders.
class PresentationState {
  PresentationState({CompanionSettings? settings})
    : _settings = settings ?? const CompanionSettings(),
      _controller = StreamController<void>.broadcast();

  ConnectionState? _connection;
  String _statusDetail = '';
  String? _name;
  Uint8List? _character;
  int? _charWidth;
  int? _charHeight;
  String _statusText = '';
  List<String> _lines = const [];
  CompanionSettings _settings;
  int? _battery;
  AvatarPose _pose = AvatarPose.idle;

  void Function()? onChange;
  final StreamController<void> _controller;

  /// Fires whenever any rendered field changes.
  Stream<void> get stream => _controller.stream;

  ConnectionState? get connection => _connection;
  String get statusDetail => _statusDetail;
  String? get name => _name;
  Uint8List? get character => _character;
  int? get charWidth => _charWidth;
  int? get charHeight => _charHeight;
  String get statusText => _statusText;
  List<String> get lines => List.unmodifiable(_lines);
  CompanionSettings get settings => _settings;

  bool get isDisconnected =>
      _connection == null ||
      _connection == ConnectionState.unpaired ||
      _connection == ConnectionState.stopped;

  int? get battery => _battery;

  /// What the portrait is doing. Idle until a listen, a reply, or an error.
  AvatarPose get pose => _pose;

  /// Whether the current character is a GIF or an animated WebP.
  bool get characterIsAnimated =>
      _character != null && isAnimatedImage(_character!);

  /// Change the portrait pose. No-op when it is already [pose].
  void applyPose(AvatarPose pose) {
    if (_pose == pose) return;
    _pose = pose;
    notify();
  }

  /// Apply a battery percentage (0–100) or null when unknown.
  void applyBattery(int? percent) {
    final clamped = percent?.clamp(0, 100).toInt();
    if (_battery == clamped) return;
    _battery = clamped;
    notify();
  }

  /// Apply a connection-state emission from the service.
  void applyConnection(ConnectionState? state, {String detail = ''}) {
    if (_connection == state && _statusDetail == detail) return;
    _connection = state;
    _statusDetail = detail;
    notify();
  }

  /// Apply the agent (Muse) display name.
  void applyName(String? name) {
    if (_name == name) return;
    _name = name;
    notify();
  }

  /// Apply downloaded character bytes (2D image or GLB 3D model).
  void applyCharacter(Uint8List bytes, {int? width, int? height}) {
    _character = bytes;
    _charWidth = width;
    _charHeight = height;
    notify();
  }

  /// Whether the current character bytes are a 3D model (GLB).
  bool get characterIsModel => _character != null && isGlbModel(_character!);

  /// Clear the character back to the neutral placeholder.
  void applyPlaceholder() {
    _character = null;
    _charWidth = null;
    _charHeight = null;
    notify();
  }

  /// Apply a status caption: clip, then derive the visible lines.
  void applyStatus(String text) {
    final clipped = text.length > maxStatusChars
        ? text.substring(0, maxStatusChars)
        : text;
    if (_statusText == clipped &&
        _lines.join('\n') == deriveStatusLines(clipped).join('\n')) {
      return;
    }
    _statusText = clipped;
    _lines = deriveStatusLines(clipped);
    notify();
  }

  void applySettings(CompanionSettings settings) {
    _settings = settings;
    notify();
  }

  void notify() {
    onChange?.call();
    if (!_controller.isClosed) _controller.add(null);
  }

  void close() {
    if (!_controller.isClosed) _controller.close();
  }
}
