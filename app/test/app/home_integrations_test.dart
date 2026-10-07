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

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse_companion/app/home_integrations.dart';
import 'package:muse_companion/app/lmstudio_tools.dart';
import 'package:muse_companion/src/gadget/phone_actions.dart';

class _FakePhone implements PhoneActions {
  @override
  Future<Uint8List> captureJpeg({String facing = 'back'}) async =>
      Uint8List(0);

  @override
  Future<Uint8List> recordWav(int seconds) async => Uint8List(0);

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
  ) async => {};
}

class _FakeMqttPublisher implements MqttPublisher {
  final List<String> topics = [];

  @override
  Future<void> publish({
    required String host,
    required int port,
    required String username,
    required String password,
    required String topic,
    required String message,
  }) async {
    topics.add(topic);
  }
}

void main() {
  group('HomeAssistant', () {
    test('ping reports the API message', () async {
      final api = HomeAssistant(
        baseUrl: 'http://ha.local:8123',
        token: 'sekret',
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer sekret');
          return http.Response('{"message": "API running."}', 200);
        }),
      );
      expect((await api.ping())['message'], 'API running.');
    });

    test('auth failures explain themselves', () async {
      final api = HomeAssistant(
        baseUrl: 'http://ha.local:8123',
        token: 'bad',
        client: MockClient((_) async => http.Response('Unauthorized', 401)),
      );
      expect(() => api.ping(), throwsA(isA<HomeIntegrationException>()));
    });

    test('states lists and singles', () async {
      final api = HomeAssistant(
        baseUrl: 'http://ha.local:8123/',
        token: 'sekret',
        client: MockClient((request) async {
          if (request.url.path == '/api/states/light.kitchen') {
            return http.Response(
              '{"entity_id":"light.kitchen","state":"on"}',
              200,
            );
          }
          return http.Response(
            jsonEncode([
              {'entity_id': 'light.kitchen', 'state': 'on'},
            ]),
            200,
          );
        }),
      );
      final one = await api.states('light.kitchen') as Map;
      expect(one['state'], 'on');
      final all = await api.states() as List;
      expect(all.length, 1);
    });

    test('bad entity and service names are refused', () async {
      final api = HomeAssistant(
        baseUrl: 'http://ha.local:8123',
        token: 'sekret',
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      expect(
        () => api.states('nope'),
        throwsA(isA<HomeIntegrationException>()),
      );
      expect(
        () => api.callService('li ght', 'turn_on'),
        throwsA(isA<HomeIntegrationException>()),
      );
    });

    test('callService posts domain, service and entity', () async {
      Map<String, Object?>? seen;
      final api = HomeAssistant(
        baseUrl: 'http://ha.local:8123',
        token: 'sekret',
        client: MockClient((request) async {
          seen = {
            'path': request.url.path,
            'body': jsonDecode(request.body) as Map<String, Object?>,
          };
          return http.Response('[{"ok": true}]', 200);
        }),
      );
      final result = await api.callService(
        'light',
        'turn_on',
        entityId: 'light.kitchen',
        data: {'brightness': 128},
      );
      expect(seen!['path'], '/api/services/light/turn_on');
      expect((seen!['body'] as Map)['entity_id'], 'light.kitchen');
      expect(result.length, 1);
    });
  });

  group('MQTT topics', () {
    test('topics resolve under the prefix', () {
      expect(resolveMqttTopic('muse/', 'desk/lamp'), 'muse/desk/lamp');
      expect(resolveMqttTopic('muse', 'desk/lamp'), 'muse/desk/lamp');
    });

    test('escapes and wildcards are refused', () {
      for (final bad in ['', '/abs', 'a/../b', 'sensors/#', 'sensors/+']) {
        expect(
          () => resolveMqttTopic('muse/', bad),
          throwsA(isA<HomeIntegrationException>()),
          reason: bad,
        );
      }
    });
  });

  group('local tools', () {
    LmToolContext ctx({
      HomeIntegrationConfig config = const HomeIntegrationConfig(),
      MqttPublisher? publisher,
    }) => LmToolContext(
      phone: _FakePhone(),
      cameraFacing: 'back',
      homeConfig: () async => config,
      mqttPublisher: publisher,
    );

    test('home_status reports setup state', () async {
      var out = await lmToolNamed('home_status')!.handler({}, ctx());
      expect(out, contains('disabled'));

      const config = HomeIntegrationConfig(
        homeEnabled: true,
        homeBaseUrl: 'http://ha.local:8123',
        homeToken: 'sekret',
        mqttEnabled: true,
        mqttHost: 'broker.local',
      );
      out = await lmToolNamed('home_status')!.handler({}, ctx(config: config));
      expect(out, contains('configured (http://ha.local:8123)'));
      expect(out, isNot(contains('sekret')));
    });

    test('home tools refuse without setup', () async {
      expect(
        await lmToolNamed('home_states')!.handler({}, ctx()),
        startsWith('error:'),
      );
      expect(
        await lmToolNamed('mqtt_publish')!.handler(
          {'topic': 'a', 'message': 'b'},
          ctx(),
        ),
        startsWith('error:'),
      );
    });

    test('mqtt_publish uses the prefix and the seam', () async {
      const config = HomeIntegrationConfig(
        mqttEnabled: true,
        mqttHost: 'broker.local',
      );
      final publisher = _FakeMqttPublisher();
      final out = await lmToolNamed('mqtt_publish')!.handler(
        {'topic': 'desk/lamp/set', 'message': 'on'},
        ctx(config: config, publisher: publisher),
      );
      expect(out, 'Published to muse/desk/lamp/set.');
      expect(publisher.topics, ['muse/desk/lamp/set']);
    });
  });

  group('config status', () {
    test('unconfigured reports without secrets', () {
      const config = HomeIntegrationConfig();
      final status = config.status();
      expect((status['home_assistant'] as Map)['configured'], isFalse);
      expect((status['mqtt'] as Map)['configured'], isFalse);
      expect('$status', isNot(contains('sekret')));
    });
  });
}
