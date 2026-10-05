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
// Offline outbox for chat sends.
//
// Concept ported from hermes-mobile-app (MIT licensed, Omar Qaterge,
// https://github.com/omarqaterge/hermes-mobile-app — their `web/src/store.ts`
// `queued` field and `gateway.ts` outbox): when a chat send fails, the
// message (text + attachment metadata) is stashed here, persisted to
// SharedPreferences as a JSON list, and flushed in FIFO order once the link
// is back. The outbox never touches the network itself — the chat screen
// drives the flush through the normal `sendChat` path.

import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// One message waiting to be (re)sent.
class OutboxEntry {
  OutboxEntry({
    required this.id,
    required this.text,
    this.attachmentBase64,
    this.attachmentMime,
    this.attachmentName,
    required this.enqueuedAt,
  });

  /// The [ChatMessage] id this send belongs to (best-effort: ids are
  /// reassigned when history is restored, so the flush never depends on it
  /// matching a live message).
  final int id;
  final String text;
  final String? attachmentBase64;
  final String? attachmentMime;
  final String? attachmentName;
  final DateTime enqueuedAt;

  Uint8List? get attachmentBytes =>
      attachmentBase64 == null ? null : base64Decode(attachmentBase64!);

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'attachmentBase64': attachmentBase64,
    'attachmentMime': attachmentMime,
    'attachmentName': attachmentName,
    'enqueuedAt': enqueuedAt.toIso8601String(),
  };

  factory OutboxEntry.fromJson(Map<String, dynamic> json) => OutboxEntry(
    id: (json['id'] as num?)?.toInt() ?? 0,
    text: (json['text'] as String?) ?? '',
    attachmentBase64: json['attachmentBase64'] as String?,
    attachmentMime: json['attachmentMime'] as String?,
    attachmentName: json['attachmentName'] as String?,
    enqueuedAt:
        DateTime.tryParse(json['enqueuedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// Persisted FIFO of unsent chat messages. Single shared instance.
class Outbox {
  Outbox._();

  static final Outbox instance = Outbox._();

  static const String _prefsKey = 'chat_outbox_v1';

  /// Cap on queued messages; oldest entries are dropped first.
  static const int maxEntries = 25;

  /// Attachments bigger than this are not persisted — the entry keeps its
  /// text and the attachment is dropped rather than ballooning the prefs.
  static const int maxAttachmentBytes = 3 * 1024 * 1024;

  final List<OutboxEntry> _entries = <OutboxEntry>[];
  bool _loaded = false;
  bool _flushing = false;

  List<OutboxEntry> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;
  int get length => _entries.length;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          try {
            _entries.add(OutboxEntry.fromJson(item));
          } catch (_) {
            // Skip corrupt entries, keep the rest.
          }
        }
      }
    } catch (_) {
      // A broken outbox must never break startup.
    }
  }

  /// Stash a message. Re-enqueueing the same id replaces the old entry so
  /// manual retries can't duplicate it.
  Future<void> enqueue(OutboxEntry entry) async {
    await load();
    _entries.removeWhere((e) => e.id == entry.id);
    _entries.add(entry);
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    await _save();
  }

  Future<void> removeById(int id) async {
    await load();
    final before = _entries.length;
    _entries.removeWhere((e) => e.id == id);
    if (_entries.length != before) await _save();
  }

  /// Send every entry in FIFO order through [send]. Stops at the first
  /// failure so ordering is preserved; entries stay queued for the next
  /// flush. Re-entrant calls are no-ops.
  Future<void> flush(Future<bool> Function(OutboxEntry entry) send) async {
    if (_flushing) return;
    _flushing = true;
    try {
      await load();
      while (_entries.isNotEmpty) {
        final entry = _entries.first;
        var ok = false;
        try {
          ok = await send(entry);
        } catch (_) {
          ok = false;
        }
        if (!ok) break;
        _entries.removeAt(0);
        await _save();
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // Persistence is best-effort; the in-memory queue still works.
    }
  }
}
