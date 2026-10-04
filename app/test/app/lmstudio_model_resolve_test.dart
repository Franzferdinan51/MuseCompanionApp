import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/lmstudio_client.dart';

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
}
