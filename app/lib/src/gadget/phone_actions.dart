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
// What the companion can do on the phone itself. The Android bridge
// implements this; tests use a fake. Capture and recording return bytes
// so the executor can post them into the Muse chat, which is how the
// model actually sees and hears.

import 'dart:typed_data';

class PhoneActionException implements Exception {
  const PhoneActionException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class PhoneActions {
  /// One JPEG from the [facing] camera (`back` or `front`).
  Future<Uint8List> captureJpeg({String facing = 'back'});

  /// A mono 16-bit PCM WAV recorded for [seconds] (already capped).
  Future<Uint8List> recordWav(int seconds);

  /// Speak [text] on the phone speaker.
  Future<void> speak(String text);

  /// Open the system screen where notification access is granted.
  Future<void> openNotificationAccess();

  /// Every other `phone.*` command. Throws [PhoneActionException] on failure.
  Future<Map<String, Object?>> run(String command, Map<String, Object?> params);
}
