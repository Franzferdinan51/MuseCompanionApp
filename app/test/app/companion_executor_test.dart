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
// Drives the real CompanionExecutor command dispatch (commands.dart) end to end.
// The platform side is provided by a small fake implementing the same
// CompanionDisplay / CompanionHealth interfaces the app uses — this exercises
// the shipped validation/dispatch code, not a re-implementation of it.

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/commands.dart';

import '_stubs.dart';

void main() {
  late CompanionExecutor executor;
  late CompanionDisplayStub display;
  late CompanionHealthStub health;

  setUp(() {
    display = CompanionDisplayStub();
    health = CompanionHealthStub();
    executor = CompanionExecutor(display: display, health: health);
  });

  test('companionCommandSpecs registers the full-color command set', () {
    final specs = companionCommandSpecs(screenWidth: 480, screenHeight: 480);
    for (final command in [
      'display.draw_url',
      'display.show_animation',
      'companion.set_status',
      'pocket.set_status',
      'companion.set_display',
      'device.health',
    ]) {
      expect(specs.containsKey(command), isTrue, reason: command);
    }
  });

  test('draw_url rejects non-http(s) URLs without touching the display', () async {
    final result = await executor.run(
        'display.draw_url', {'url': 'javascript:alert(1)'}, null);
    expect(result['ok'], isFalse);
    expect(display.drawnUrl, isNull);
  });

  test('draw_url with a valid URL draws and reports the result', () async {
    final result = await executor.run('display.draw_url',
        {'url': 'https://example.com/char.jpg'}, null);
    expect(result['ok'], isTrue);
    expect((result['payload'] as Map)['status'], 'drawn');
    expect(display.drawnUrl, 'https://example.com/char.jpg');
  });

  test('set_status requires text', () async {
    final result =
        await executor.run('companion.set_status', <String, Object?>{}, null);
    expect(result['ok'], isFalse);
    expect(display.setStatusText, isNull);
  });

  test('set_status clips to maxStatusChars and returns the character count',
      () async {
    final longText = 'z' * (maxStatusChars + 500);
    final result = await executor.run(
        'companion.set_status', {'text': longText}, null);
    expect(result['ok'], isTrue);
    expect((result['payload'] as Map)['characters'], maxStatusChars);
    expect(display.setStatusText?.length, maxStatusChars);
  });

  test('pocket.set_status is an alias for companion.set_status', () async {
    final result = await executor.run(
        'pocket.set_status', {'text': 'hi'}, null);
    expect(result['ok'], isTrue);
    expect(display.setStatusText, 'hi');
  });

  test('show_animation clears the character to the placeholder', () async {
    final result =
        await executor.run('display.show_animation', <String, Object?>{}, null);
    expect(result['ok'], isTrue);
    expect((result['payload'] as Map)['status'], 'placeholder');
    expect(display.placeholderShown, isTrue);
  });

  test('device.health reports the health payload', () async {
    final result =
        await executor.run('device.health', <String, Object?>{}, null);
    expect(result['ok'], isTrue);
    expect(health.called, isTrue);
    expect((result['payload'] as Map)['battery_percent'], 42);
  });

  test('an unsupported command returns an error result', () async {
    final result = await executor.run('nope.command', <String, Object?>{}, null);
    expect(result['ok'], isFalse);
    expect(result['error'], 'unsupported command: nope.command');
  });
}
