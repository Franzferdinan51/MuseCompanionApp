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
// Smart-home integrations: Home Assistant and MQTT.
//
// Both are strictly opt-in and configured in Companion Settings —
// credentials (the HA long-lived token, the MQTT password) live in
// encrypted storage and are never readable or writable through commands.
// The agent reaches this through the `home.*` / `mqtt.*` commands and
// the matching local tools. MQTT publishes stay under the configured
// topic prefix; anything outside it is refused.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// Thrown for integration failures and bad arguments.
class HomeIntegrationException implements Exception {
  HomeIntegrationException(this.message);

  final String message;

  @override
  String toString() => 'HomeIntegrationException: $message';
}

/// Everything the home handlers need, loaded from Settings (plus the
/// secrets store) by one async callback. Null means unconfigured.
class HomeIntegrationConfig {
  const HomeIntegrationConfig({
    this.homeEnabled = false,
    this.homeBaseUrl = '',
    this.homeToken = '',
    this.mqttEnabled = false,
    this.mqttHost = '',
    this.mqttPort = 1883,
    this.mqttUsername = '',
    this.mqttPassword = '',
    this.mqttTopicPrefix = 'muse/',
  });

  final bool homeEnabled;
  final String homeBaseUrl;
  final String homeToken;
  final bool mqttEnabled;
  final String mqttHost;
  final int mqttPort;
  final String mqttUsername;
  final String mqttPassword;
  final String mqttTopicPrefix;

  Map<String, Object?> status() => {
    'home_assistant': {
      'enabled': homeEnabled,
      'configured': homeEnabled &&
          homeBaseUrl.isNotEmpty &&
          homeToken.isNotEmpty,
      'base_url': homeBaseUrl,
    },
    'mqtt': {
      'enabled': mqttEnabled,
      'configured': mqttEnabled && mqttHost.isNotEmpty,
      'host': mqttHost,
      'port': mqttPort,
      'username_set': mqttUsername.isNotEmpty,
      'topic_prefix': mqttTopicPrefix,
    },
  };
}

/// Home Assistant REST API over a long-lived token. The [http.Client] is
/// injectable for tests.
class HomeAssistant {
  HomeAssistant({
    required this.baseUrl,
    required this.token,
    http.Client? client,
  }) : _client = client;

  final String baseUrl;
  final String token;
  final http.Client? _client;

  static final RegExp _name = RegExp(r'^[a-z0-9_]+$');

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  String get _base => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  /// GET /api/ — proves the URL + token work.
  Future<Map<String, Object?>> ping() async {
    final response = await _get(Uri.parse('$_base/api/'));
    return {'message': _stringField(response, 'message')};
  }

  /// GET /api/states (capped list) or /api/states/[entityId].
  Future<Object?> states([String? entityId]) async {
    if (entityId != null && entityId.isNotEmpty) {
      _checkEntity(entityId);
      return _get(Uri.parse('$_base/api/states/$entityId'));
    }
    final response = await _get(Uri.parse('$_base/api/states'));
    if (response is! List) {
      throw HomeIntegrationException('unexpected states response');
    }
    return response.take(200).toList();
  }

  /// POST /api/services/[domain]/[service] with an optional entity id
  /// and extra data. Only whitelisted characters reach the URL.
  Future<List<Object?>> callService(
    String domain,
    String service, {
    String? entityId,
    Map<String, Object?>? data,
  }) async {
    if (!_name.hasMatch(domain) || !_name.hasMatch(service)) {
      throw HomeIntegrationException('bad domain or service name');
    }
    final body = <String, Object?>{...(data ?? {})};
    if (entityId != null && entityId.isNotEmpty) {
      _checkEntity(entityId);
      body['entity_id'] = entityId;
    }
    final client = _client ?? http.Client();
    try {
      final response = await client
          .post(
            Uri.parse('$_base/api/services/$domain/$service'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HomeIntegrationException(
          'service call failed: HTTP ${response.statusCode}',
        );
      }
      final decoded = jsonDecode(response.body);
      return decoded is List ? decoded : [decoded];
    } finally {
      if (_client == null) client.close();
    }
  }

  void _checkEntity(String entityId) {
    final parts = entityId.split('.');
    if (parts.length != 2 ||
        !_name.hasMatch(parts[0]) ||
        !_name.hasMatch(parts[1])) {
      throw HomeIntegrationException('bad entity id: $entityId');
    }
  }

  Future<dynamic> _get(Uri uri) async {
    final client = _client ?? http.Client();
    try {
      final response = await client
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw HomeIntegrationException('rejected: check the token (HTTP ${response.statusCode})');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HomeIntegrationException('request failed: HTTP ${response.statusCode}');
      }
      return jsonDecode(response.body);
    } finally {
      if (_client == null) client.close();
    }
  }

  String _stringField(dynamic decoded, String field) {
    if (decoded is Map && decoded[field] is String) {
      return decoded[field] as String;
    }
    return '';
  }
}

/// Publish seam for tests: the real one connects, publishes once, and
/// disconnects (v1 keeps no persistent connection).
abstract class MqttPublisher {
  Future<void> publish({
    required String host,
    required int port,
    required String username,
    required String password,
    required String topic,
    required String message,
  });
}

/// Real MQTT publish over mqtt_client, QoS 1.
class RealMqttPublisher implements MqttPublisher {
  @override
  Future<void> publish({
    required String host,
    required int port,
    required String username,
    required String password,
    required String topic,
    required String message,
  }) async {
    final client = MqttServerClient.withPort(
      host,
      'muse-companion-${DateTime.now().microsecondsSinceEpoch}',
      port,
    );
    client.logging(on: false);
    client.keepAlivePeriod = 20;
    client.secure = port == 8883;
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(client.clientIdentifier)
        .authenticateAs(
          username.isEmpty ? null : username,
          password.isEmpty ? null : password,
        )
        .startClean();
    try {
      await client.connect().timeout(const Duration(seconds: 15));
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        throw HomeIntegrationException(
          'MQTT connect failed: ${client.connectionStatus?.state}',
        );
      }
      final payload = MqttClientPayloadBuilder()..addString(message);
      final bytes = payload.payload;
      if (bytes == null) {
        throw HomeIntegrationException('could not encode MQTT payload');
      }
      client.publishMessage(topic, MqttQos.atLeastOnce, bytes);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      client.disconnect();
    }
  }
}

/// Resolve [topic] under [prefix]. Absolute topics, wildcards, and
/// escapes are refused so the agent cannot publish outside its prefix.
String resolveMqttTopic(String prefix, String topic) {
  final clean = topic.trim();
  if (clean.isEmpty) {
    throw HomeIntegrationException('topic is required');
  }
  if (clean.startsWith('/') ||
      clean.contains('+') ||
      clean.contains('#') ||
      clean.split('/').contains('..')) {
    throw HomeIntegrationException('topic escapes the prefix: $topic');
  }
  final base = prefix.endsWith('/') ? prefix : '$prefix/';
  return '$base$clean';
}
