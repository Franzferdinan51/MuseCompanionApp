import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/lmstudio_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('LocalAiService.pickForRole', () {
    test('agent prefers a clef decision model', () {
      expect(
        LocalAiService.pickForRole(
          ['cloudflare_clef-flash', 'mimo-v2.6-distill-qwen-9b@q4_k_m'],
          'agent',
        ),
        'cloudflare_clef-flash',
      );
    });

    test('agent prefers clef regardless of list order', () {
      expect(
        LocalAiService.pickForRole(
          ['mimo-v2.6-distill-qwen-9b@q4_k_m', 'cloudflare_clef-flash'],
          'agent',
        ),
        'cloudflare_clef-flash',
      );
    });

    test('agent falls back to first model when no clef is loaded', () {
      expect(
        LocalAiService.pickForRole(
          ['google/gemma-4-12b-qat', 'mimo-v2.6-distill-qwen-9b@q4_k_m'],
          'agent',
        ),
        'google/gemma-4-12b-qat',
      );
    });

    test('chat prefers a non-clef conversational model', () {
      expect(
        LocalAiService.pickForRole(
          ['cloudflare_clef-flash', 'mimo-v2.6-distill-qwen-9b@q4_k_m'],
          'chat',
        ),
        'mimo-v2.6-distill-qwen-9b@q4_k_m',
      );
    });

    test('chat falls back to first model when only clef is loaded', () {
      expect(
        LocalAiService.pickForRole(['cloudflare_clef-flash'], 'chat'),
        'cloudflare_clef-flash',
      );
    });

    test('returns empty string for an empty list', () {
      expect(LocalAiService.pickForRole([], 'agent'), '');
      expect(LocalAiService.pickForRole([], 'chat'), '');
    });

    test('pick is stable for the same sorted list', () {
      const ids = ['cloudflare_clef-flash', 'mimo-v2.6-distill-qwen-9b@q4_k_m'];
      expect(
        LocalAiService.pickForRole(ids, 'agent'),
        LocalAiService.pickForRole(ids, 'agent'),
      );
      expect(
        LocalAiService.pickForRole(ids, 'chat'),
        LocalAiService.pickForRole(ids, 'chat'),
      );
    });
  });

  group('LocalAiService.resolveModel', () {
    setUpAll(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('explicit id is used verbatim even when not in the loaded list',
        () async {
      // Unreachable URL: the explicit path must return before any fetch.
      final result = await LocalAiService.resolveModel(
        baseUrl: 'http://127.0.0.1:9',
        explicit: 'some-unloaded-model-id',
        role: 'agent',
      );
      expect(result, 'some-unloaded-model-id');
    });

    test('explicit id is trimmed', () async {
      final result = await LocalAiService.resolveModel(
        baseUrl: 'http://127.0.0.1:9',
        explicit: '  my-model  ',
        role: 'chat',
      );
      expect(result, 'my-model');
    });

    test('empty explicit auto-picks from the server list', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'data': [
              {'id': 'mimo-v2.6-distill-qwen-9b@q4_k_m'},
              {'id': 'cloudflare_clef-flash'},
            ],
          }))
          ..close();
      });
      try {
        final baseUrl = 'http://127.0.0.1:${server.port}';
        expect(
          await LocalAiService.resolveModel(
              baseUrl: baseUrl, explicit: '', role: 'agent'),
          'cloudflare_clef-flash',
        );
        expect(
          await LocalAiService.resolveModel(
              baseUrl: baseUrl, explicit: '', role: 'chat'),
          'mimo-v2.6-distill-qwen-9b@q4_k_m',
        );
      } finally {
        await server.close();
      }
    });
  });
}
