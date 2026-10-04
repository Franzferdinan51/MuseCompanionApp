import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/chat_events.dart';
import 'package:muse_companion/src/gadget/commands.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';

class _FakeDisplay implements CompanionDisplay {
  String status = '';
  String? lastUrl;
  int placeholders = 0;
  String theme = 'system';
  bool keepScreenOn = false;

  @override
  Future<String> setStatus(String text) async {
    status = text;
    return status;
  }

  @override
  Future<ImageDrawResult> drawImageFromUrl(String url) async {
    lastUrl = url;
    if (url.contains('fail')) {
      return const ImageDrawResult.failed('boom');
    }
    return const ImageDrawResult.ok(
      width: 800,
      height: 800,
      bytes: 1234,
      fromCache: false,
    );
  }

  @override
  Future<void> showPlaceholder() async {
    placeholders += 1;
  }

  @override
  Future<Map<String, Object?>> setDisplay({
    String? theme,
    bool? keepScreenOn,
    bool? speakReplies,
  }) async {
    if (theme != null) this.theme = theme;
    if (keepScreenOn != null) this.keepScreenOn = keepScreenOn;
    return {'theme': this.theme, 'keep_screen_on': this.keepScreenOn};
  }

  @override
  Future<Map<String, Object?>> displayInfo() async => {
    'theme': theme,
    'keep_screen_on': keepScreenOn,
  };
}

class _FakeHealth implements CompanionHealth {
  @override
  Future<Map<String, Object?>> health() async => {
    'battery_level': 80,
    'charging': true,
  };
}

class _FakePhone implements PhoneActions {
  final List<(String, Map<String, Object?>)> calls = [];

  String? lastFacing;

  @override
  Future<Uint8List> captureJpeg({String facing = 'back'}) async {
    lastFacing = facing;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<Uint8List> recordWav(int seconds) async => Uint8List.fromList([4, 5]);

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stopSpeak() async {}

  @override
  Future<void> openNotificationAccess() async {}

  @override
  Future<Map<String, Object?>> run(
    String command,
    Map<String, Object?> params,
  ) async {
    calls.add((command, params));
    if (command == 'phone.screenshot') {
      return {
        'jpeg': Uint8List.fromList([9, 8, 7]),
        'width': 100,
        'height': 200,
        'status': 'Looking at the screen',
      };
    }
    return {...params, 'command': command};
  }
}

void main() {
  group('command specs', () {
    test('registers the companion command set', () {
      final specs = companionCommandSpecs(
        screenWidth: 1080,
        screenHeight: 2400,
      );
      for (final name in [
        'display.draw_url',
        'display.show_animation',
        'companion.set_status',
        'pocket.set_status',
        'companion.set_display',
        'device.health',
      ]) {
        expect(specs, contains(name));
      }
      final draw = specs['display.draw_url'] as Map;
      expect(draw['timeout_ms'], drawImageTimeoutMs);
      expect((draw['description'] as String), contains('1080x2400'));
      expect((draw['description'] as String), contains('full-color'));
    });
  });

  group('executor', () {
    late _FakeDisplay display;
    late CompanionExecutor executor;

    setUp(() {
      display = _FakeDisplay();
      executor = CompanionExecutor(display: display, health: _FakeHealth());
    });

    test('set_status stores unicode captions', () async {
      final result = await executor.run('companion.set_status', {
        'text': 'héllo 👋',
      }, null);
      expect(result['ok'], isTrue);
      expect(display.status, 'héllo 👋');
    });

    test('pocket.set_status is a working alias', () async {
      final result = await executor.run('pocket.set_status', {
        'text': 'hi',
      }, null);
      expect(result['ok'], isTrue);
      expect(display.status, 'hi');
    });

    test('set_status requires text and clips overlong input', () async {
      expect(
        (await executor.run('companion.set_status', {}, null))['ok'],
        isFalse,
      );
      final long = 'x' * (maxStatusChars + 10);
      final result = await executor.run('companion.set_status', {
        'text': long,
      }, null);
      expect(result['ok'], isTrue);
      expect(display.status, hasLength(maxStatusChars));
      expect((result['payload'] as Map)['truncated'], isTrue);
    });

    test('draw_url validates and reports the draw', () async {
      expect((await executor.run('display.draw_url', {}, null))['ok'], isFalse);
      expect(
        (await executor.run('display.draw_url', {
          'url': 'ftp://x/y',
        }, null))['ok'],
        isFalse,
      );
      final result = await executor.run('display.draw_url', {
        'url': 'https://example.com/c.png',
      }, null);
      expect(result['ok'], isTrue);
      expect(display.lastUrl, 'https://example.com/c.png');
      expect((result['payload'] as Map)['width'], 800);
      final failed = await executor.run('display.draw_url', {
        'url': 'https://example.com/fail.png',
      }, null);
      expect(failed['ok'], isFalse);
    });

    test('show_animation clears to the placeholder', () async {
      final result = await executor.run('display.show_animation', {}, null);
      expect(result['ok'], isTrue);
      expect(display.placeholders, 1);
    });

    test('set_display validates and applies preferences', () async {
      expect(
        (await executor.run('companion.set_display', {
          'theme': 'neon',
        }, null))['ok'],
        isFalse,
      );
      expect(
        (await executor.run('companion.set_display', {
          'keep_screen_on': 'yes',
        }, null))['ok'],
        isFalse,
      );
      final result = await executor.run('companion.set_display', {
        'theme': 'dark',
        'keep_screen_on': true,
      }, null);
      expect(result['ok'], isTrue);
      expect(display.theme, 'dark');
      expect(display.keepScreenOn, isTrue);

      final ignored = await executor.run('companion.set_display', {
        'speech_voice': 'en-us-x-iog-network',
        'speech_volume': 10,
      }, null);
      expect(ignored['ok'], isTrue);
      final payload = ignored['payload'] as Map;
      expect(payload.containsKey('speech_voice'), isFalse);
      expect(payload.containsKey('speech_volume'), isFalse);
    });

    test('health reports the platform payload', () async {
      final result = await executor.run('device.health', {}, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['battery_level'], 80);
    });

    test('unknown commands fail cleanly', () async {
      final result = await executor.run('nope.nope', {}, null);
      expect(result['ok'], isFalse);
    });

    test('calls and texts stay off until the user allows them', () async {
      final phone = _FakePhone();
      var allowCalls = false;
      var allowSms = false;
      final gated = CompanionExecutor(
        display: display,
        health: _FakeHealth(),
        phone: phone,
        allowCalls: () => allowCalls,
        allowSendSms: () => allowSms,
      );
      final blocked = await gated.run('phone.call', {'number': '555'}, null);
      expect(blocked['ok'], isFalse);
      expect(phone.calls, isEmpty);

      allowCalls = true;
      final placed = await gated.run('phone.call', {'number': '555'}, null);
      expect(placed['ok'], isTrue);
      expect(phone.calls.single.$1, 'phone.call');

      final composer = await gated.run('phone.sms', {
        'to': '555',
        'body': 'hi',
        'send': true,
      }, null);
      expect((composer['payload'] as Map)['send'], isFalse);

      allowSms = true;
      final sent = await gated.run('phone.sms', {
        'to': '555',
        'body': 'hi',
        'send': true,
      }, null);
      expect((sent['payload'] as Map)['send'], isTrue);
    });

    test('local_ai.run_task is refused while local AI is disabled', () async {
      final phone = _FakePhone();
      var enabled = false;
      final gated = CompanionExecutor(
        display: display,
        health: _FakeHealth(),
        phone: phone,
        lmStudioEnabled: () => enabled,
        lmStudioUrl: () => 'http://127.0.0.1:1234',
        lmStudioModel: () => '',
      );
      final blocked = await gated.run(
        'local_ai.run_task',
        {'instruction': 'take a photo'},
        null,
      );
      expect(blocked['ok'], isFalse);
      expect(blocked['error'], contains('disabled'));

      enabled = true;
      final missing = await gated.run('local_ai.run_task', {}, null);
      expect(missing['ok'], isFalse);
      expect(missing['error'], contains('instruction'));
    });

    test('local_ai.run_task is registered in the command specs', () {
      final specs = companionCommandSpecs(screenWidth: 1080, screenHeight: 2400);
      final spec = specs['local_ai.run_task'] as Map<String, Object?>;
      final required = spec['required'] as Map<String, Object?>;
      expect(required.containsKey('instruction'), isTrue);
    });

    test('vision posts the camera bytes into chat', () async {
      final phone = _FakePhone();
      String? posted;
      List<ChatAttachment>? items;
      final seeing = CompanionExecutor(
        display: display,
        health: _FakeHealth(),
        phone: phone,
        postToMuse: (message, attachments) async {
          posted = message;
          items = attachments;
          return {'ok': true};
        },
      );
      final result = await seeing.run('vision.capture', {}, null);
      expect(result['ok'], isTrue);
      expect(display.status, 'Looking through the camera');
      expect(posted, contains('photo'));
      expect(items, hasLength(1));
      expect(items!.single.mimeType, 'image/jpeg');
      expect(items!.single.filename, 'camera.jpg');
      expect(items!.single.bytes, [1, 2, 3]);
      expect(phone.lastFacing, 'back');
    });

    test('screenshot posts the screen and leaves the jpeg out of the result', () async {
      final phone = _FakePhone();
      String? posted;
      List<ChatAttachment>? items;
      final seeing = CompanionExecutor(
        display: display,
        health: _FakeHealth(),
        phone: phone,
        postToMuse: (message, attachments) async {
          posted = message;
          items = attachments;
          return {'ok': true};
        },
      );
      final result = await seeing.run('phone.screenshot', {
        'prompt': 'What is open?',
      }, null);
      expect(result['ok'], isTrue);
      expect(display.status, 'Looking at the screen');
      expect(posted, 'What is open?');
      expect(items, hasLength(1));
      expect(items!.single.filename, 'screen.jpg');
      expect(items!.single.bytes, [9, 8, 7]);
      final payload = result['payload'] as Map;
      expect(payload['kind'], 'screenshot');
      expect(payload['width'], 100);
      expect(payload['height'], 200);
      expect(payload.containsKey('jpeg'), isFalse);
      expect(phone.calls.single.$1, 'phone.screenshot');
    });

    test('vision uses the saved camera unless facing is set', () async {
      final phone = _FakePhone();
      final seeing = CompanionExecutor(
        display: display,
        health: _FakeHealth(),
        phone: phone,
        cameraFacing: () => 'front',
        postToMuse: (message, attachments) async => {'ok': true},
      );
      await seeing.run('vision.capture', {}, null);
      expect(phone.lastFacing, 'front');
      await seeing.run('vision.capture', {'facing': 'back'}, null);
      expect(phone.lastFacing, 'back');
      final bad = await seeing.run('vision.capture', {'facing': 'side'}, null);
      expect(bad['ok'], isFalse);
    });

    test('device commands are registered for the phone', () {
      final specs = companionCommandSpecs(
        screenWidth: 1080,
        screenHeight: 2400,
      );
      for (final name in [
        'vision.capture',
        'phone.ringer',
        'phone.vibrate',
        'phone.dnd',
        'phone.rotation',
        'phone.radio',
        'phone.settings',
        'phone.timer',
        'phone.device',
        'phone.screen',
        'phone.screenshot',
        'phone.ui',
        'phone.tap',
        'phone.swipe',
        'phone.type',
        'phone.press',
        'phone.screen_control',
      ]) {
        expect(specs.containsKey(name), isTrue, reason: name);
      }
    });
  });

  group('intro message', () {
    test('asks for character art and status upkeep', () {
      final intro = companionIntroMessage();
      expect(intro, contains('display.draw_url'));
      expect(intro, contains('companion.set_status'));
      expect(intro, contains('full-color'));
    });
  });
}
