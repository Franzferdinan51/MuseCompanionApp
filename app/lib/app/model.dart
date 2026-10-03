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

import 'package:muse_companion/src/gadget/commands.dart';
import 'package:muse_companion/src/gadget/service.dart';

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

  CompanionSettings copyWith({
    String? theme,
    bool? keepScreenOn,
    bool? speakReplies,
    bool? allowCalls,
    bool? allowSendSms,
    int? speechVolume,
  }) {
    return CompanionSettings(
      theme: theme ?? this.theme,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      speakReplies: speakReplies ?? this.speakReplies,
      allowCalls: allowCalls ?? this.allowCalls,
      allowSendSms: allowSendSms ?? this.allowSendSms,
      speechVolume: speechVolume ?? this.speechVolume,
    );
  }

  /// The themes the gadget accepts.
  static const List<String> themeOptions = <String>[
    'light',
    'dark',
    'system'
  ];

  Map<String, Object?> toMap() => {
        'theme': theme,
        'keep_screen_on': keepScreenOn,
        'speak_replies': speakReplies,
        'allow_calls': allowCalls,
        'allow_send_sms': allowSendSms,
        'speech_volume': speechVolume.clamp(0, 100),
      };

  static CompanionSettings fromMap(Map<String, Object?> map) {
    final theme = map['theme'];
    return CompanionSettings(
      theme: theme is String && themeOptions.contains(theme)
          ? theme
          : 'system',
      keepScreenOn: map['keep_screen_on'] == true,
      speakReplies: map['speak_replies'] is bool
          ? map['speak_replies']! as bool
          : true,
      allowCalls: map['allow_calls'] == true,
      allowSendSms: map['allow_send_sms'] == true,
      speechVolume: _speechVolume(map['speech_volume']),
    );
  }

  static int _speechVolume(Object? value) {
    final number = value is num ? value.round() : 80;
    if (number < 0) return 0;
    if (number > 100) return 100;
    return number;
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
    for (var start = 0;
        start < rawLine.length && result.length < maxLines;
        start += maxLineLength) {
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
  bool get characterIsModel =>
      _character != null && isGlbModel(_character!);

  /// Clear the character back to the neutral placeholder.
  void applyPlaceholder() {
    _character = null;
    _charWidth = null;
    _charHeight = null;
    notify();
  }

  /// Apply a status caption: clip, then derive the visible lines.
  void applyStatus(String text) {
    final clipped =
        text.length > maxStatusChars ? text.substring(0, maxStatusChars) : text;
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
