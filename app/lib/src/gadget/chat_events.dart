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
// Chat turns on a Muse gadget session.
//
// POST /chat/stream only acknowledges the user message. The assistant's
// reply arrives as NDJSON on the long-lived POST /chat/subscribe stream
// (the same shape the ESP32 firmware reads: delta.message_start,
// delta.text_append, delta.message_done, message.assistant). Voice notes
// and camera frames ride along as `items` on /chat/stream, matching
// muse_chat_priv.h.

import 'dart:convert';
import 'dart:typed_data';

const String chatSubscribePath = '/chat/subscribe';

/// One file attached to a chat turn (voice note or camera frame).
class ChatAttachment {
  const ChatAttachment({
    required this.mimeType,
    required this.filename,
    required this.bytes,
  });

  final String mimeType;
  final String filename;
  final Uint8List bytes;
}

/// One event from `/chat/subscribe`.
class ChatEvent {
  const ChatEvent({
    required this.event,
    required this.payload,
    required this.raw,
    this.seq,
  });

  final String event;
  final int? seq;
  final Map<String, Object?> payload;
  final Map<String, Object?> raw;
}

/// Body of `POST /chat/stream`.
///
/// Includes `output_modality`, which the Linux SDK and the ESP32 chat
/// session both send. Without it the VM accepts the post and never
/// streams a reply. Attachments use the phone app's file-item shape.
Map<String, Object?> buildChatRequest({
  required String message,
  required String deviceId,
  String? sessionId,
  List<ChatAttachment> attachments = const [],
}) {
  final body = <String, Object?>{
    'message': message,
    'output_modality': 'text',
    'device_id': deviceId,
  };
  if (sessionId != null && sessionId.isNotEmpty) {
    body['session_id'] = sessionId;
  }
  if (attachments.isNotEmpty) {
    body['items'] = [
      for (final item in attachments)
        {
          'type': 'file',
          'mime_type': item.mimeType,
          'filename': item.filename,
          'data_base64': base64Encode(item.bytes),
        },
    ];
  }
  return body;
}

/// Splits a byte stream into chat events, keeping split UTF-8 intact.
class NdjsonEventDecoder {
  final List<int> _bytes = [];
  int _sequence = 0;

  List<ChatEvent> add(List<int> data) {
    _bytes.addAll(data);
    final events = <ChatEvent>[];
    while (true) {
      final newline = _bytes.indexOf(0x0A);
      if (newline < 0) break;
      final line = utf8.decode(_bytes.sublist(0, newline), allowMalformed: true);
      _bytes.removeRange(0, newline + 1);
      final event = parseChatEventLine(line, sequence: _sequence);
      if (event == null) continue;
      if (event.seq != null) _sequence = event.seq!;
      events.add(event);
    }
    if (_bytes.length > 1024 * 1024) {
      _bytes.clear();
      throw StateError('chat event exceeds size limit');
    }
    return events;
  }

  List<ChatEvent> flush() {
    if (_bytes.isEmpty) return const [];
    final line = utf8.decode(_bytes, allowMalformed: true);
    _bytes.clear();
    final event = parseChatEventLine(line, sequence: _sequence);
    if (event == null) return const [];
    if (event.seq != null) _sequence = event.seq!;
    return [event];
  }
}

/// Parses one NDJSON line. Returns null for acks, blanks, and replays.
ChatEvent? parseChatEventLine(String line, {int sequence = 0}) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  Object? decoded;
  try {
    decoded = json.decode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final raw = decoded.map((key, value) => MapEntry(key.toString(), value));
  if (raw['type'] != 'event') return null;
  final seq = raw['seq'];
  int? seqValue;
  if (seq is num) {
    seqValue = seq.toInt();
    if (seqValue > 0 && seqValue <= sequence) return null;
  }
  final name = raw['event'];
  if (name is! String || name.isEmpty) return null;
  final payloadRaw = raw['payload'];
  final payload = payloadRaw is Map
      ? payloadRaw.map((key, value) => MapEntry(key.toString(), value))
      : <String, Object?>{};
  return ChatEvent(
    event: name,
    seq: seqValue,
    payload: payload.cast<String, Object?>(),
    raw: raw.cast<String, Object?>(),
  );
}

const List<String> _avatarKeys = [
  'avatar_url',
  'avatar',
  'image_url',
  'image',
  'portrait_url',
  'portrait',
  'character_url',
  'character_image',
  'picture_url',
  'picture',
  'photo_url',
  'photo',
  'icon_url',
];

/// Pulls a character image URL out of a `GET /identity` result, if any.
String? avatarUrlFromIdentity(Map<String, Object?> result) {
  final direct = _urlForKeys(result);
  if (direct != null) return direct;
  for (final value in result.values) {
    if (value is Map) {
      final nested = _urlForKeys(value.cast<Object?, Object?>());
      if (nested != null) return nested;
    } else if (value is List) {
      for (final item in value) {
        if (item is Map) {
          final nested = _urlForKeys(item.cast<Object?, Object?>());
          if (nested != null) return nested;
        }
      }
    }
  }
  return null;
}

String? _urlForKeys(Map<Object?, Object?> map) {
  for (final entry in map.entries) {
    final key = entry.key?.toString().toLowerCase() ?? '';
    if (!_avatarKeys.contains(key)) continue;
    final url = _asImageUrl(entry.value);
    if (url != null) return url;
  }
  return null;
}

String? _asImageUrl(Object? value) {
  if (value is! String || value.isEmpty) return null;
  if (value.startsWith('https://') || value.startsWith('http://')) {
    return value;
  }
  if (value.startsWith('data:image/') || value.startsWith('data:model/')) {
    return value;
  }
  return null;
}
