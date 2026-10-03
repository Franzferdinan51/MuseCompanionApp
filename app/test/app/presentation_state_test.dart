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
// Tests for the pure presentation-state model: how a caption becomes the up to
// four visible lines, clipping at maxStatusChars, name/connection/battery
// transitions, and settings round-tripping. No device or Flutter UI involved.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/avatar_motion.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/src/gadget/commands.dart';
import 'package:muse_companion/src/gadget/service.dart';

void main() {
  test('connection labels match the home bar', () {
    expect(connectionStatusLabel(ConnectionState.connected), 'Connected');
    expect(connectionStatusLabel(ConnectionState.connecting), 'Connecting…');
    expect(connectionStatusLabel(ConnectionState.waiting), 'Waiting to retry');
    expect(connectionStatusLabel(ConnectionState.unpaired), 'Not paired');
    expect(connectionStatusLabel(ConnectionState.stopped), 'Stopped');
  });

  group('deriveStatusLines', () {
    test('a single short line returns one line', () {
      expect(deriveStatusLines('Hello'), <String>['Hello']);
    });

    test('newlines are preserved and capped at four lines', () {
      final lines = deriveStatusLines('A\nB\nC\nD\nE');
      expect(lines, <String>['A', 'B', 'C', 'D']);
    });

    test('a long line is hard-wrapped without exceeding the limit', () {
      final longLine = 'x' * 100;
      final lines = deriveStatusLines(longLine, maxLineLength: 80);
      expect(lines, <String>['x' * 80, 'x' * 20]);
    });

    test('wrapping respects the overall four-line cap', () {
      final longLine = 'y' * 400; // would be five 80-char lines
      final lines = deriveStatusLines(longLine, maxLineLength: 80);
      expect(lines.length, kMaxStatusLines);
    });

    test('empty caption yields a single empty line', () {
      expect(deriveStatusLines(''), <String>['']);
    });
  });

  group('PresentationState.applyStatus', () {
    test('derives visible lines from a multi-line caption', () {
      final state = PresentationState();
      state.applyStatus('Reading your notes.\nNext: drafting a reply.');
      expect(state.lines, <String>[
        'Reading your notes.',
        'Next: drafting a reply.',
      ]);
    });

    test('clips to maxStatusChars and stores the clipped text', () {
      final state = PresentationState();
      final longText = 'z' * (maxStatusChars + 500);
      state.applyStatus(longText);
      expect(state.statusText, 'z' * maxStatusChars);
      expect(state.statusText.length, maxStatusChars);
    });

    test('does not notify when the caption is unchanged', () {
      final state = PresentationState();
      state.applyStatus('same');
      var changes = 0;
      state.onChange = () => changes++;
      state.applyStatus('same'); // no-op
      expect(changes, 0);
    });

    test('notifies and updates when the caption changes', () {
      final state = PresentationState();
      var changes = 0;
      state.onChange = () => changes++;
      state.applyStatus('first');
      state.applyStatus('second');
      expect(changes, 2);
      expect(state.lines, <String>['second']);
    });
  });

  group('PresentationState identity transitions', () {
    test('applyConnection records state and detail', () {
      final state = PresentationState();
      state.applyConnection(ConnectionState.connected, detail: 'registered');
      expect(state.connection, ConnectionState.connected);
      expect(state.statusDetail, 'registered');
      expect(state.isDisconnected, isFalse);
    });

    test('applyName updates the agent name', () {
      final state = PresentationState();
      state.applyName('Ada');
      expect(state.name, 'Ada');
    });

    test('applyCharacter and applyPlaceholder toggle the image', () {
      final state = PresentationState();
      final bytes = Uint8List.fromList(utf8.encode('img'));
      state.applyCharacter(bytes, width: 10, height: 20);
      expect(state.character, isNotNull);
      expect(state.charWidth, 10);
      state.applyPlaceholder();
      expect(state.character, isNull);
    });

    test('applyBattery clamps and reports unknown as null', () {
      final state = PresentationState();
      state.applyBattery(150);
      expect(state.battery, 100);
      state.applyBattery(null);
      expect(state.battery, isNull);
    });
  });

  group('CompanionSettings', () {
    test('defaults follow the system theme', () {
      const settings = CompanionSettings();
      expect(settings.theme, 'system');
      expect(settings.keepScreenOn, isFalse);
      expect(settings.cameraFacing, 'back');
      expect(settings.allowCalls, isFalse);
      expect(settings.allowSendSms, isFalse);
      expect(CompanionSettings.themeOptions, <String>[
        'light',
        'dark',
        'system',
      ]);
    });

    test('fromMap/toMap round-trips', () {
      final restored = CompanionSettings.fromMap({
        'theme': 'dark',
        'keep_screen_on': true,
      });
      expect(restored.theme, 'dark');
      expect(restored.keepScreenOn, isTrue);

      final round = CompanionSettings.fromMap(restored.toMap());
      expect(round.theme, 'dark');
      expect(round.keepScreenOn, isTrue);
    });

    test('an unknown theme falls back to the default', () {
      final restored = CompanionSettings.fromMap({'theme': 'neon'});
      expect(restored.theme, 'system');
      expect(
        CompanionSettings.fromMap({'camera_facing': 'nope'}).cameraFacing,
        'back',
      );
      expect(
        CompanionSettings.fromMap({'camera_facing': 'front'}).cameraFacing,
        'front',
      );
    });

    test('copyWith changes only the supplied field', () {
      const base = CompanionSettings(theme: 'light', keepScreenOn: true);
      final next = base.copyWith(theme: 'dark');
      expect(next.theme, 'dark');
      expect(next.keepScreenOn, isTrue);
    });
  });

  group('3D avatar (GLB) detection', () {
    test('glTF magic bytes detect a model', () {
      final glb = Uint8List.fromList([
        0x67,
        0x6C,
        0x54,
        0x46,
        0x02,
        0x00,
        0x00,
        0x00,
      ]);
      expect(isGlbModel(glb), isTrue);
    });

    test('image bytes are not a model', () {
      // PNG signature.
      final png = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      expect(isGlbModel(png), isFalse);
    });

    test('short buffers are not a model', () {
      expect(isGlbModel(Uint8List(0)), isFalse);
      expect(isGlbModel(Uint8List.fromList([0x67, 0x6C])), isFalse);
    });

    test('characterIsModel follows the stored bytes', () {
      final state = PresentationState();
      expect(state.characterIsModel, isFalse);
      state.applyCharacter(
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      );
      expect(state.characterIsModel, isFalse);
      state.applyCharacter(
        Uint8List.fromList([0x67, 0x6C, 0x54, 0x46, 0x02, 0x00, 0x00, 0x00]),
      );
      expect(state.characterIsModel, isTrue);
      state.applyPlaceholder();
      expect(state.characterIsModel, isFalse);
      state.close();
    });
  });

  group('animated image detection', () {
    test('GIF headers count as animated', () {
      expect(isAnimatedImage(Uint8List.fromList('GIF89a'.codeUnits)), isTrue);
      expect(isAnimatedImage(Uint8List.fromList('GIF87a'.codeUnits)), isTrue);
    });

    test('a PNG is not animated', () {
      final png = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      expect(isAnimatedImage(png), isFalse);
    });

    test('WebP is animated only with an ANIM chunk', () {
      final still = Uint8List.fromList('RIFF....WEBPVP8 '.codeUnits);
      expect(isAnimatedImage(still), isFalse);
      final anim = Uint8List.fromList('RIFF....WEBPANIM'.codeUnits);
      expect(isAnimatedImage(anim), isTrue);
    });
  });

  group('avatar pose', () {
    test('applyPose notifies once and ignores the same pose', () {
      final state = PresentationState();
      var notices = 0;
      state.onChange = () => notices += 1;
      expect(state.pose, AvatarPose.idle);
      state.applyPose(AvatarPose.listening);
      expect(state.pose, AvatarPose.listening);
      state.applyPose(AvatarPose.listening);
      expect(notices, 1);
      state.close();
    });
  });
}
