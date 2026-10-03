import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/commands.dart';

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
        width: 800, height: 800, bytes: 1234, fromCache: false);
  }

  @override
  Future<void> showPlaceholder() async {
    placeholders += 1;
  }

  @override
  Future<Map<String, Object?>> setDisplay(
      {String? theme, bool? keepScreenOn}) async {
    if (theme != null) this.theme = theme;
    if (keepScreenOn != null) this.keepScreenOn = keepScreenOn;
    return {'theme': this.theme, 'keep_screen_on': this.keepScreenOn};
  }

  @override
  Future<Map<String, Object?>> displayInfo() async =>
      {'theme': theme, 'keep_screen_on': keepScreenOn};
}

class _FakeHealth implements CompanionHealth {
  @override
  Future<Map<String, Object?>> health() async =>
      {'battery_level': 80, 'charging': true};
}

void main() {
  group('command specs', () {
    test('registers the companion command set', () {
      final specs =
          companionCommandSpecs(screenWidth: 1080, screenHeight: 2400);
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
      final result = await executor.run(
          'companion.set_status', {'text': 'héllo 👋'}, null);
      expect(result['ok'], isTrue);
      expect(display.status, 'héllo 👋');
    });

    test('pocket.set_status is a working alias', () async {
      final result =
          await executor.run('pocket.set_status', {'text': 'hi'}, null);
      expect(result['ok'], isTrue);
      expect(display.status, 'hi');
    });

    test('set_status requires text and clips overlong input', () async {
      expect((await executor.run('companion.set_status', {}, null))['ok'],
          isFalse);
      final long = 'x' * (maxStatusChars + 10);
      final result =
          await executor.run('companion.set_status', {'text': long}, null);
      expect(result['ok'], isTrue);
      expect(display.status, hasLength(maxStatusChars));
      expect((result['payload'] as Map)['truncated'], isTrue);
    });

    test('draw_url validates and reports the draw', () async {
      expect((await executor.run('display.draw_url', {}, null))['ok'],
          isFalse);
      expect(
          (await executor
                  .run('display.draw_url', {'url': 'ftp://x/y'}, null))['ok'],
          isFalse);
      final result = await executor.run(
          'display.draw_url', {'url': 'https://example.com/c.png'}, null);
      expect(result['ok'], isTrue);
      expect(display.lastUrl, 'https://example.com/c.png');
      expect((result['payload'] as Map)['width'], 800);
      final failed = await executor.run('display.draw_url',
          {'url': 'https://example.com/fail.png'}, null);
      expect(failed['ok'], isFalse);
    });

    test('show_animation clears to the placeholder', () async {
      final result =
          await executor.run('display.show_animation', {}, null);
      expect(result['ok'], isTrue);
      expect(display.placeholders, 1);
    });

    test('set_display validates and applies preferences', () async {
      expect(
          (await executor.run(
              'companion.set_display', {'theme': 'neon'}, null))['ok'],
          isFalse);
      expect(
          (await executor.run('companion.set_display',
              {'keep_screen_on': 'yes'}, null))['ok'],
          isFalse);
      final result = await executor.run('companion.set_display',
          {'theme': 'dark', 'keep_screen_on': true}, null);
      expect(result['ok'], isTrue);
      expect(display.theme, 'dark');
      expect(display.keepScreenOn, isTrue);
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
