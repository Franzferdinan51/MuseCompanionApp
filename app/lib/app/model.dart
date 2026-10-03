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
  });

  /// One of `light`, `dark` or `system`.
  final String theme;
  final bool keepScreenOn;

  CompanionSettings copyWith({String? theme, bool? keepScreenOn}) {
    return CompanionSettings(
      theme: theme ?? this.theme,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
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
      };

  static CompanionSettings fromMap(Map<String, Object?> map) {
    final theme = map['theme'];
    return CompanionSettings(
      theme: theme is String && themeOptions.contains(theme)
          ? theme
          : 'system',
      keepScreenOn: map['keep_screen_on'] == true,
    );
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

  /// Apply a downloaded/decoded character image.
  void applyCharacter(Uint8List bytes, {int? width, int? height}) {
    _character = bytes;
    _charWidth = width;
    _charHeight = height;
    notify();
  }

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
