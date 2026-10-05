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
// Drives the real CompanionExecutor's device-control commands
// (device.vibrate, device.clipboard.*, device.notify, device.get_location)
// against the CompanionDeviceStub — validating dispatch and parameter
// checks, not the platform plugins themselves.

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/commands.dart';

import '_stubs.dart';

void main() {
  late CompanionExecutor executor;
  late CompanionDeviceStub device;

  setUp(() {
    device = CompanionDeviceStub();
    executor = CompanionExecutor(
      display: CompanionDisplayStub(),
      health: CompanionHealthStub(),
      device: device,
    );
  });

  group('device.vibrate', () {
    test('buzzes with the requested duration', () async {
      final result =
          await executor.run('device.vibrate', {'duration_ms': 500}, null);
      expect(result['ok'], isTrue);
      expect(device.vibratedMs, 500);
    });

    test('omitted duration uses the platform default', () async {
      final result = await executor.run('device.vibrate', {}, null);
      expect(result['ok'], isTrue);
      expect(device.vibratedMs, isNull);
    });

    test('rejects a non-integer duration', () async {
      final result =
          await executor.run('device.vibrate', {'duration_ms': 'long'}, null);
      expect(result['ok'], isFalse);
      expect(device.vibratedMs, isNull);
    });

    test('plugin failure becomes an error result', () async {
      device.failNext = true;
      final result =
          await executor.run('device.vibrate', {'duration_ms': 100}, null);
      expect(result['ok'], isFalse);
      expect((result['error'] as String), contains('no vibrator'));
    });
  });

  group('device.clipboard', () {
    test('get returns the stubbed text', () async {
      device.clipboard = 'hello from the phone';
      final result = await executor.run('device.clipboard.get', {}, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['text'], 'hello from the phone');
    });

    test('get reports null when the clipboard is empty', () async {
      final result = await executor.run('device.clipboard.get', {}, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['text'], isNull);
    });

    test('set stores the text and reports its length', () async {
      final result = await executor
          .run('device.clipboard.set', {'text': 'copy me'}, null);
      expect(result['ok'], isTrue);
      expect(device.clipboard, 'copy me');
      expect((result['payload'] as Map)['characters'], 7);
    });

    test('set rejects a missing text param', () async {
      final result = await executor.run('device.clipboard.set', {}, null);
      expect(result['ok'], isFalse);
    });
  });

  group('device.notify', () {
    test('shows the notification with title and body', () async {
      final result = await executor.run('device.notify',
          {'title': 'Juno', 'body': 'Fresh roast is ready.'}, null);
      expect(result['ok'], isTrue);
      expect(device.notifiedTitle, 'Juno');
      expect(device.notifiedBody, 'Fresh roast is ready.');
    });

    test('rejects missing title or body', () async {
      expect(
          (await executor.run('device.notify', {'body': 'x'}, null))['ok'],
          isFalse);
      expect(
          (await executor.run('device.notify', {'title': 'x'}, null))['ok'],
          isFalse);
      expect(device.notifiedTitle, isNull);
    });
  });

  group('device.get_location', () {
    test('returns the stubbed position payload', () async {
      final result = await executor.run('device.get_location', {}, null);
      expect(result['ok'], isTrue);
      final payload = result['payload'] as Map;
      expect(payload['latitude'], 39.8644);
      expect(payload['longitude'], -84.1324);
    });
  });

  test('unknown device commands still report unsupported', () async {
    final result = await executor.run('device.self_destruct', {}, null);
    expect(result['ok'], isFalse);
    expect(result['error'], contains('unsupported command'));
  });
}
