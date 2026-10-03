import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/chat_events.dart';

void main() {
  test('chat posts include output modality and file items', () {
    final body = buildChatRequest(
      message: '',
      deviceId: 'node-1',
      attachments: [
        ChatAttachment(
          mimeType: 'audio/wav',
          filename: 'voice_note.wav',
          bytes: Uint8List.fromList([9, 8]),
        ),
      ],
    );
    expect(body['output_modality'], 'text');
    expect(body['message'], '');
    expect(body.containsKey('session_id'), isFalse);
    final items = body['items'] as List;
    expect(items.single['type'], 'file');
    expect(items.single['mime_type'], 'audio/wav');
    expect(items.single['data_base64'], base64Encode([9, 8]));
  });

  test('ndjson decoder keeps split lines and skips replays', () {
    final decoder = NdjsonEventDecoder();
    final first = utf8.encode(
        '{"type":"event","seq":1,"event":"delta.text_append","payload":{"text":"Hi"}}\n');
    expect(decoder.add(first.sublist(0, 12)), isEmpty);
    final events = decoder.add(first.sublist(12));
    expect(events, hasLength(1));
    expect(events.single.event, 'delta.text_append');
    expect(events.single.payload['text'], 'Hi');
    final replay = decoder.add(utf8.encode(
        '{"type":"event","seq":1,"event":"delta.text_append","payload":{"text":"Hi"}}\n'));
    expect(replay, isEmpty);
    expect(
        decoder.add(utf8.encode('{"type":"ack"}\n')),
        isEmpty);
  });

  test('identity avatar urls are found on nested maps', () {
    expect(
      avatarUrlFromIdentity({
        'agent': {
          'portrait_url': 'https://cdn.example/face.png',
        },
      }),
      'https://cdn.example/face.png',
    );
    expect(avatarUrlFromIdentity({'name': 'Muse'}), isNull);
    expect(
      avatarUrlFromIdentity({'avatar': 'not a url'}),
      isNull,
    );
  });
}
