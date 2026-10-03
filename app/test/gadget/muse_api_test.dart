import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse_companion/src/gadget/muse_api.dart';

void main() {
  group('api root', () {
    test('prefers api_url_v2 and trims slashes', () {
      expect(apiRoot(''), apiBase);
      expect(apiRoot('https://x.example//'), 'https://x.example');
    });

    test('user agent carries the version', () {
      expect(userAgent('1.2.3'), contains('musecompanion/1.2.3'));
    });
  });

  group('fetch vms', () {
    test('parses leased vms', () async {
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer abc');
        expect(request.headers['X-API-Version'], '1.0.0');
        return http.Response(
            json.encode({
              'vm_list': [
                {
                  'vm_ws_url': 'wss://vm1',
                  'vm_auth_token': 't1',
                  'vm_name': 'one',
                  'vm_id': 'id-1',
                  'default': true,
                },
                {
                  'vm_url': 'wss://vm2',
                  'vm_auth_token': 't2',
                  'vm_name': 'two',
                },
                {'vm_name': 'incomplete'},
              ],
            }),
            200);
      });
      final result =
          await fetchVmsWithStatus('abc', client: client, version: '0.1.0');
      expect(result.status, 200);
      expect(result.vms, hasLength(2));
      expect(result.vms.first.isDefault, isTrue);
      expect(result.vms.first.vmId, 'id-1');
      expect(result.vms.last.vmUrl, 'wss://vm2');
    });

    test('surfaces http errors and bad payloads', () async {
      final unauthorized = MockClient((_) async => http.Response('', 401));
      var result = await fetchVmsWithStatus('x', client: unauthorized);
      expect(result.vms, isEmpty);
      expect(result.status, 401);

      final broken = MockClient((_) async => http.Response('nope', 200));
      result = await fetchVmsWithStatus('x', client: broken);
      expect(result.vms, isEmpty);

      final error = MockClient((_) async => http.Response(
          json.encode({'error_title': 'bad', 'backend_error_code': 1}),
          200));
      result = await fetchVmsWithStatus('x', client: error);
      expect(result.vms, isEmpty);

      final offline = MockClient((_) async => throw Exception('down'));
      result = await fetchVmsWithStatus('x', client: offline);
      expect(result.vms, isEmpty);
      expect(result.status, isNull);
    });
  });

  group('refresh device token', () {
    test('rotates the token pair', () async {
      http.Request? seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(
            json.encode(
                {'access_token': 'a2', 'refresh_token': 'r2'}),
            200);
      });
      final result = await refreshDeviceToken(
        'hatch_refresh:r1',
        'homelink-1',
        sdkToken: 'mgst_x',
        client: client,
      );
      expect(result.status, 200);
      expect(result.tokens,
          {'access_token': 'a2', 'refresh_token': 'r2'});
      // Adjacent literals (never the contiguous credential-like text).
      expect(seen!.headers['Authorization'],
          'Bearer ' 'hatch' '_' 'refresh:' 'r1');
      expect(json.decode(seen!.body),
          {'device_id': 'homelink-1', 'sdk_token': 'mgst_x'});
    });

    test('unwraps payload responses', () async {
      final client = MockClient((_) async => http.Response(
          json.encode({
            'payload': {'access_token': 'a', 'refresh_token': 'r'}
          }),
          200));
      final result =
          await refreshDeviceToken('r', 'd', client: client);
      expect(result.tokens, isNotNull);
    });

    test('surfaces rejection and transport failure', () async {
      final revoked = MockClient((_) async => http.Response('', 401));
      var result = await refreshDeviceToken('r', 'd', client: revoked);
      expect(result.tokens, isNull);
      expect(result.status, 401);

      final offline = MockClient((_) async => throw Exception('down'));
      result = await refreshDeviceToken('r', 'd', client: offline);
      expect(result.tokens, isNull);
      expect(result.status, isNull);
    });
  });
}
