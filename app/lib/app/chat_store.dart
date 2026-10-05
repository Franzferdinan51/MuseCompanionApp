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
// On-device conversation persistence: saves chat history to
// SharedPreferences as JSON, restores on launch. Text only — attachment
// bytes are not persisted (voice notes/photos stay in-session). The user
// can clear history from the chat app bar.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'chat.dart';

/// Persists [ChatHistory] messages on-device. Text-only; attachments are
/// session-scoped and dropped on restore (their placeholder text remains).
class ChatStore {
  ChatStore(this._history);

  final ChatHistory _history;

  static const String _key = 'chat_history_v1';
  static const int _maxStored = 200;

  /// Serialize one message. Returns null when the message should not be
  /// stored (e.g. still streaming).
  Map<String, Object?>? _toJson(ChatMessage m) {
    if (m.streaming) return null;
    return {
      'text': m.text,
      'sentAt': m.sentAt.toIso8601String(),
      'status': m.status.name,
      'role': m.role.name,
      'hasAudio': m.hasAudio,
      'hasImage': m.hasImage,
      if (m.canvasDocId != null) 'canvasDocId': m.canvasDocId,
      if (m.canvasTitle != null) 'canvasTitle': m.canvasTitle,
      if (m.canvasUpdated) 'canvasUpdated': true,
    };
  }

  ChatMessage? _fromJson(Map<String, Object?> json) {
    final text = json['text'];
    final sentAt = json['sentAt'];
    if (text is! String || sentAt is! String) return null;
    final at = DateTime.tryParse(sentAt);
    if (at == null) return null;
    final statusName = json['status'];
    final roleName = json['role'];
    final canvasDocId = json['canvasDocId'];
    final canvasTitle = json['canvasTitle'];
    return ChatMessage(
      id: -1, // Reassigned on restore.
      text: text,
      sentAt: at,
      status: ChatStatus.values.firstWhere(
        (v) => v.name == statusName,
        orElse: () => ChatStatus.sent,
      ),
      role: ChatRole.values.firstWhere(
        (v) => v.name == roleName,
        orElse: () => ChatRole.user,
      ),
      canvasDocId: canvasDocId is String ? canvasDocId : null,
      canvasTitle: canvasTitle is String ? canvasTitle : null,
      canvasUpdated: json['canvasUpdated'] == true,
    );
  }

  /// Save the current history. Fire-and-forget safe.
  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final messages = _history.messages;
      final start = messages.length > _maxStored
          ? messages.length - _maxStored
          : 0;
      final json = <Map<String, Object?>>[];
      for (var i = start; i < messages.length; i++) {
        final item = _toJson(messages[i]);
        if (item != null) json.add(item);
      }
      await prefs.setString(_key, jsonEncode(json));
    } catch (_) {
      // Persistence is best-effort; the chat works without it.
    }
  }

  /// Restore saved history into [_history]. Returns the count restored.
  Future<int> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return 0;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return 0;
      var count = 0;
      for (final item in decoded) {
        if (item is! Map<String, Object?>) continue;
        final message = _fromJson(item);
        if (message == null) continue;
        _history.restoreMessage(message);
        count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// Delete the stored history.
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
