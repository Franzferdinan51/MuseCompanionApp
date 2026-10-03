import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/src/gadget/chat_events.dart';

void main() {
  test('a voice note sends as text with audio attachment', () {
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
    expect(items.single['filename'], 'voice_note.wav');
    expect(items.single['data_base64'], base64Encode([9, 8]));

    final prompted = buildChatRequest(
      message: 'what did I say?',
      deviceId: 'node-1',
      attachments: [
        ChatAttachment(
          mimeType: 'Audio/WAV',
          filename: 'voice_note.wav',
          bytes: Uint8List.fromList([3]),
        ),
      ],
    );
    expect(prompted['output_modality'], 'text');
    expect(prompted['message'], 'what did I say?');

    final photo = buildChatRequest(
      message: 'What do you see?',
      deviceId: 'node-1',
      attachments: [
        ChatAttachment(
          mimeType: 'image/jpeg',
          filename: 'camera.jpg',
          bytes: Uint8List.fromList([1, 2]),
        ),
      ],
    );
    expect(photo['output_modality'], 'text');
    expect(
      buildChatRequest(message: 'hello', deviceId: 'node-1')['output_modality'],
      'text',
    );
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

  test('a finished reply yields the first https image url', () {
    expect(httpsImageUrlInReply('no picture here'), isNull);
    expect(
      httpsImageUrlInReply('see https://example.com/help first'),
      isNull,
    );
    expect(
      httpsImageUrlInReply('http://cdn.example/a.png is not https'),
      isNull,
    );
    expect(
      httpsImageUrlInReply(
          'portrait: https://cdn.example/me.PNG thanks'),
      'https://cdn.example/me.PNG',
    );
    expect(
      httpsImageUrlInReply(
          '![avatar](https://cdn.example/face.webp)'),
      'https://cdn.example/face.webp',
    );
    expect(
      httpsImageUrlInReply(
          'https://cdn.example/a.jpeg?token=abc&v=1.'),
      'https://cdn.example/a.jpeg?token=abc&v=1',
    );
    expect(
      httpsImageUrlInReply(
          'page https://example.com/docs then https://cdn.example/a.gif'),
      'https://cdn.example/a.gif',
    );
    expect(
      httpsImageUrlInReply('<https://cdn.example/shot.jpg>'),
      'https://cdn.example/shot.jpg',
    );
  });
}
