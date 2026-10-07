import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/choice_cards.dart';
import 'package:muse_companion/app/home_integrations.dart';
import 'package:muse_companion/app/media_queue.dart';
import 'package:muse_companion/app/scenes.dart';
import 'package:muse_companion/app/sensors_snapshot.dart';
import 'package:muse_companion/app/vision_analyze.dart';
import 'package:muse_companion/app/workspace_files.dart';
import 'package:muse_companion/src/gadget/chat_events.dart';
import 'package:muse_companion/src/gadget/commands.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';

class _FakeMqttPublisher implements MqttPublisher {
  final List<Map<String, String>> published = [];

  @override
  Future<void> publish({
    required String host,
    required int port,
    required String username,
    required String password,
    required String topic,
    required String message,
  }) async {
    published.add({'host': host, 'topic': topic, 'message': message});
  }
}

class _FakeQueueBackend implements QueueAudioBackend {
  final List<String> played = [];

  @override
  Future<void> playUrl(String url) async {
    played.add(url);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  void onComplete(void Function() cb) {}

  @override
  Future<void> dispose() async {}
}

class _FakeVisionAnalyzer implements VisionAnalyzerBackend {
  @override
  Future<String> recognizeText(String absolutePath) async => 'TOTAL 42.00';

  @override
  Future<List<BarcodeHit>> scanBarcodes(String absolutePath) async =>
      const [BarcodeHit(format: 'qrCode', value: 'https://example.com')];

  @override
  Future<void> dispose() async {}
}

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
        'file.list',
        'file.read',
        'file.write',
        'file.delete',
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
        lmStudioAgentModel: () => '',
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

  group('workspace file commands', () {
    late Directory root;
    late CompanionExecutor executor;

    setUp(() {
      root = Directory.systemTemp.createTempSync('cmd_ws_test');
      executor = CompanionExecutor(
        display: _FakeDisplay(),
        health: _FakeHealth(),
        workspace: WorkspaceFiles(root: root),
      );
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('write, read, list and delete round-trip', () async {
      var result = await executor.run('file.write', {
        'path': 'notes/todo.txt',
        'content': 'buy milk',
      }, null);
      expect(result['ok'], isTrue);

      result = await executor.run('file.read', {
        'path': 'notes/todo.txt',
      }, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['content'], 'buy milk');

      result = await executor.run('file.list', {'path': 'notes'}, null);
      expect(result['ok'], isTrue);
      final entries = (result['payload'] as Map)['entries'] as List;
      expect(entries.map((e) => (e as Map)['name']), ['todo.txt']);

      result = await executor.run('file.delete', {
        'path': 'notes/todo.txt',
      }, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['deleted'], isTrue);
    });

    test('traversal is refused and params validated', () async {
      final refused = await executor.run('file.read', {
        'path': '../escape.txt',
      }, null);
      expect(refused['ok'], isFalse);

      expect((await executor.run('file.read', {}, null))['ok'], isFalse);
      expect(
        (await executor.run('file.write', {'path': 'x.txt'}, null))['ok'],
        isFalse,
      );
      expect((await executor.run('file.delete', {}, null))['ok'], isFalse);
    });
  });

  group('offline scene commands', () {
    late Directory root;
    late _FakeDisplay display;
    late CompanionExecutor executor;

    setUp(() {
      root = Directory.systemTemp.createTempSync('cmd_scene_test');
      display = _FakeDisplay();
      executor = CompanionExecutor(
        display: display,
        health: _FakeHealth(),
        scenes: SceneStore(dir: root),
      );
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<Map<String, Object?>> saveScene() => executor.run('scene.save', {
      'id': 'greet',
      'title': 'Greet',
      'steps_json':
          '[{"command":"companion.set_status","params":{"text":"hi"}}]',
    }, null);

    test('save, list and run round-trip', () async {
      final saved = await saveScene();
      expect(saved['ok'], isTrue);

      final listed = await executor.run('scene.list', {}, null);
      expect(listed['ok'], isTrue);
      final scenes = (listed['payload'] as Map)['scenes'] as List;
      expect(scenes.length, 1);
      expect((scenes.single as Map)['id'], 'greet');

      final ran = await executor.run('scene.run', {'id': 'greet'}, null);
      expect(ran['ok'], isTrue);
      final outcome = (ran['payload'] as Map);
      expect(outcome['completed'], isTrue);
      expect(display.status, 'hi');
    });

    test('save validates id, steps and nesting', () async {
      expect((await executor.run('scene.save', {}, null))['ok'], isFalse);
      expect(
        (await executor.run('scene.save', {
          'id': 'bad id!',
          'steps_json': '[{"command":"companion.set_status"}]',
        }, null))['ok'],
        isFalse,
      );
      expect(
        (await executor.run('scene.save', {
          'id': 'bad-json',
          'steps_json': 'not json',
        }, null))['ok'],
        isFalse,
      );
      expect(
        (await executor.run('scene.save', {
          'id': 'nested',
          'steps_json': '[{"command":"scene.run","params":{"id":"greet"}}]',
        }, null))['ok'],
        isFalse,
      );
    });

    test('run of unknown scene and delete report cleanly', () async {
      expect(
        (await executor.run('scene.run', {'id': 'nope'}, null))['ok'],
        isFalse,
      );
      final deleted = await executor.run('scene.delete', {'id': 'nope'}, null);
      expect(deleted['ok'], isTrue);
      expect((deleted['payload'] as Map)['deleted'], isFalse);
    });
  });

  group('media queue commands', () {
    late CompanionExecutor executor;

    setUp(() {
      executor = CompanionExecutor(
        display: _FakeDisplay(),
        health: _FakeHealth(),
        mediaQueue: MediaQueuePlayer(backend: _FakeQueueBackend()),
      );
    });

    test('enqueue, queue, play, control and clear', () async {
      var result = await executor.run('media.enqueue', {
        'url': 'https://example.com/a.mp3',
        'title': 'A',
      }, null);
      expect(result['ok'], isTrue);

      result = await executor.run('media.queue', {}, null);
      expect(result['ok'], isTrue);
      expect(((result['payload'] as Map)['tracks'] as List).length, 1);

      result = await executor.run('media.play', {}, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['state'], 'playing');

      result = await executor.run('media.control', {'action': 'pause'}, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['state'], 'paused');

      result = await executor.run('media.clear', {}, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['queue_length'], 0);
    });

    test('invalid url, action and empty play are refused', () async {
      expect(
        (await executor.run('media.enqueue', {'url': 'ftp://x/y'}, null))['ok'],
        isFalse,
      );
      expect((await executor.run('media.enqueue', {}, null))['ok'], isFalse);
      expect(
        (await executor.run('media.control', {'action': 'dance'}, null))['ok'],
        isFalse,
      );
      expect((await executor.run('media.play', {}, null))['ok'], isFalse);
    });
  });

  group('display card commands', () {
    late ChoiceCardStore cards;
    late CompanionExecutor executor;

    setUp(() {
      cards = ChoiceCardStore();
      executor = CompanionExecutor(
        display: _FakeDisplay(),
        health: _FakeHealth(),
        cards: cards,
      );
    });

    tearDown(() {
      cards.dispose();
    });

    test('show, status, choose and clear', () async {
      var result = await executor.run('display.show_card', {
        'title': 'Dinner?',
        'text': 'Pick a place',
        'buttons_json': '[{"id":"a","label":"A"},{"id":"b","label":"B"}]',
      }, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['title'], 'Dinner?');

      expect(cards.choose('b'), isTrue);
      result = await executor.run('display.card_status', {}, null);
      expect(result['ok'], isTrue);
      final payload = result['payload'] as Map;
      expect(payload['card'], isNull);
      expect(
        (payload['last_choice'] as Map)['button_id'],
        'b',
      );

      result = await executor.run('display.clear_card', {}, null);
      expect(result['ok'], isTrue);
    });

    test('show validates title and buttons', () async {
      expect((await executor.run('display.show_card', {}, null))['ok'], isFalse);
      expect(
        (await executor.run('display.show_card', {
          'title': 'T',
          'buttons_json': 'nope',
        }, null))['ok'],
        isFalse,
      );
    });
  });

  group('vision analyze', () {
    test('vision.analyze reports text and barcodes', () async {
      final root = Directory.systemTemp.createTempSync('cmd_vision_test');
      try {
        final files = WorkspaceFiles(root: root);
        await files.writeBytes('scan/r.jpg', [1, 2, 3]);
        final executor = CompanionExecutor(
          display: _FakeDisplay(),
          health: _FakeHealth(),
          workspace: files,
          visionAnalyzer: _FakeVisionAnalyzer(),
        );
        final result = await executor.run('vision.analyze', {
          'path': 'scan/r.jpg',
          'mode': 'both',
        }, null);
        expect(result['ok'], isTrue);
        final payload = result['payload'] as Map;
        expect(payload['text'], 'TOTAL 42.00');
        expect(
          ((payload['barcodes'] as List).single as Map)['value'],
          'https://example.com',
        );

        expect(
          (await executor.run('vision.analyze', {}, null))['ok'],
          isFalse,
        );
        expect(
          (await executor.run('vision.analyze', {
            'path': 'scan/r.jpg',
            'mode': 'smell',
          }, null))['ok'],
          isFalse,
        );
      } finally {
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });
  });

  group('smart home commands', () {
    CompanionExecutor executor({
      HomeIntegrationConfig config = const HomeIntegrationConfig(),
    }) => CompanionExecutor(
      display: _FakeDisplay(),
      health: _FakeHealth(),
      homeConfig: () async => config,
      mqttPublisher: _FakeMqttPublisher(),
    );

    test('status reports without secrets or setup', () async {
      final result = await executor().run('home.status', {}, null);
      expect(result['ok'], isTrue);
      final payload = result['payload'] as Map;
      expect((payload['home_assistant'] as Map)['enabled'], isFalse);
      expect('$payload', isNot(contains('sekret')));
    });

    test('home calls refuse when disabled or unconfigured', () async {
      expect(
        (await executor().run('home.states', {}, null))['ok'],
        isFalse,
      );
      const partial = HomeIntegrationConfig(
        homeEnabled: true,
        homeBaseUrl: '',
        homeToken: '',
      );
      expect(
        (await executor().run('home.call', {
          'domain': 'light',
          'service': 'turn_on',
        }, null))['ok'],
        isFalse,
      );
      expect(
        (await executor(
          config: partial,
        ).run('home.states', {}, null))['ok'],
        isFalse,
      );
    });

    test('mqtt publish stays under the prefix', () async {
      const config = HomeIntegrationConfig(
        mqttEnabled: true,
        mqttHost: 'broker.local',
        mqttTopicPrefix: 'muse/',
      );
      final ex = executor(config: config);
      final result = await ex.run('mqtt.publish', {
        'topic': 'desk/lamp/set',
        'message': 'on',
      }, null);
      expect(result['ok'], isTrue);
      expect((result['payload'] as Map)['topic'], 'muse/desk/lamp/set');

      expect(
        (await ex.run('mqtt.publish', {
          'topic': '../escape',
          'message': 'x',
        }, null))['ok'],
        isFalse,
      );
      expect(
        (await executor().run('mqtt.publish', {
          'topic': 'a/b',
          'message': 'x',
        }, null))['ok'],
        isFalse,
      );
    });
  });

  group('sensor readings', () {
    test('sensors.read reports the injected sample', () async {
      final executor = CompanionExecutor(
        display: _FakeDisplay(),
        health: _FakeHealth(),
        sensors: SensorReader(
          sampler: (_) async => const SensorSample(
            accelerometer: [0.0, 9.81, 0.0],
          ),
        ),
      );
      final result = await executor.run('sensors.read', {}, null);
      expect(result['ok'], isTrue);
      final payload = result['payload'] as Map;
      expect(payload['accelerometer'], [0.0, 9.81, 0.0]);
      expect(payload['gyroscope'], isNull);
      final available = payload['available'] as Map;
      expect(available['accelerometer'], isTrue);
      expect(available['gyroscope'], isFalse);
    });
  });
}
