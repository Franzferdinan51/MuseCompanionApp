// Concepts inspired by hermes-mobile-app's MemoryScreen and
// phone/hermes_memory_sync.py
// (https://github.com/omarqaterge/hermes-mobile-app — MIT licensed,
// Copyright 2026 Omar Qaterge).
//
// Our v1 is deliberately simpler: a local key-value fact store with a
// per-entry write history, persisted as JSON in the app documents
// directory. No cloud sync, no git — this phone is the only copy.
// Their immutable-file git sync design is noted as a possible future,
// not built here.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'lmstudio_tools.dart';

/// Max characters kept per stored value: keeps entries (and the prompt
/// section built from them) small.
const int _maxValueLength = 4000;

/// How many writes are kept in each entry's history.
const int _maxHistoryPerEntry = 20;

/// How many recent entries are injected into the agent system prompt.
const int _promptEntryLimit = 10;

/// Max characters of a value shown per line in the injected prompt section.
const int _promptValueChars = 200;

/// One write to a memory entry: old value -> new value, with when + who.
class MemoryWrite {
  const MemoryWrite({
    required this.at,
    required this.oldValue,
    required this.newValue,
    required this.source,
  });

  final DateTime at;

  /// Null when the entry was created by this write.
  final String? oldValue;
  final String newValue;

  /// Who wrote it: 'agent' (memory_remember tool) or 'user' (manual edit).
  final String source;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'old': oldValue,
    'new': newValue,
    'source': source,
  };

  static MemoryWrite fromJson(Map<String, Object?> json) => MemoryWrite(
    at: DateTime.tryParse(json['at']?.toString() ?? '') ?? DateTime.now(),
    oldValue: json['old']?.toString(),
    newValue: json['new']?.toString() ?? '',
    source: json['source']?.toString() ?? 'agent',
  );
}

/// One stored fact: key, current value, and its write history.
class MemoryEntry {
  MemoryEntry({
    required this.key,
    required this.value,
    required this.updatedAt,
    required this.source,
    List<MemoryWrite>? history,
  }) : history = history ?? [];

  final String key;
  String value;
  DateTime updatedAt;

  /// Source of the latest write.
  String source;
  final List<MemoryWrite> history;

  Map<String, Object?> toJson() => {
    'key': key,
    'value': value,
    'updatedAt': updatedAt.toIso8601String(),
    'source': source,
    'history': [for (final w in history) w.toJson()],
  };

  static MemoryEntry fromJson(Map<String, Object?> json) {
    final history =
        (json['history'] as List?)
            ?.whereType<Map>()
            .map((m) => MemoryWrite.fromJson(m.cast<String, Object?>()))
            .toList() ??
        const <MemoryWrite>[];
    return MemoryEntry(
      key: json['key']?.toString() ?? '',
      value: json['value']?.toString() ?? '',
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
      source: json['source']?.toString() ?? 'agent',
      history: history,
    );
  }
}

/// Persistent on-device memory for the local agent: facts and preferences
/// as key-value entries with timestamps, sources, and write history.
///
/// Storage is a single JSON file in the app documents directory, written
/// atomically (temp file + rename). The agent gets this through the
/// memory_remember / memory_recall tools and a prompt-context section;
/// the user sees and edits it in the Memory screen. Nothing here ever
/// leaves the phone.
class AgentMemory extends ChangeNotifier {
  AgentMemory._();

  /// Process-wide singleton: the agent, the tools, and the UI share it.
  static final AgentMemory instance = AgentMemory._();

  final Map<String, MemoryEntry> _entries = {};
  bool _loaded = false;

  /// Serializes all mutations so concurrent remembers can't clobber each
  /// other. Errors reach the caller; the chain itself stays alive.
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() op) {
    final run = _tail.then((_) => op());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Load from disk. Idempotent; safe to call before every use.
  ///
  /// Never calls [_serial] itself: [remember], [forget], and [clear] run
  /// inside their own serial op and await [_initLocked] directly. Routing
  /// those through [init] would chain the loader behind the running op
  /// and deadlock when nothing initialized the store first.
  Future<void> init() => _serial(_initLocked);

  Future<void> _initLocked() async {
    if (_loaded) return;
    _loaded = true;
    final file = await _file();
    if (!await file.exists()) return;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('not a map');
      final entries = decoded['entries'];
      if (entries is! Map) throw const FormatException('no entries map');
      for (final kv in entries.entries) {
        final key = kv.key.toString();
        final v = kv.value;
        if (v is! Map || key.isEmpty) continue;
        _entries[key] = MemoryEntry.fromJson(v.cast<String, Object?>());
      }
    } catch (e) {
      // Never crash on a corrupt file: quarantine it and start fresh.
      debugPrint('AgentMemory: corrupt store, quarantining: $e');
      try {
        final stamp = DateTime.now().millisecondsSinceEpoch;
        await file.rename('${file.path}.corrupt-$stamp');
      } catch (_) {}
      _entries.clear();
    }
  }

  /// Normalize a key: trim + lowercase so agent lookups are stable.
  static String normalizeKey(String key) => key.trim().toLowerCase();

  /// Store [value] under [key], recording the old -> new diff.
  Future<void> remember(String key, String value, {String source = 'agent'}) =>
      _serial(() async {
        await _initLocked();
        final nkey = normalizeKey(key);
        if (nkey.isEmpty) throw ArgumentError('memory key must not be empty');
        final nvalue = value.length > _maxValueLength
            ? value.substring(0, _maxValueLength)
            : value;
        final now = DateTime.now();
        final existing = _entries[nkey];
        final write = MemoryWrite(
          at: now,
          oldValue: existing?.value,
          newValue: nvalue,
          source: source,
        );
        if (existing == null) {
          _entries[nkey] = MemoryEntry(
            key: nkey,
            value: nvalue,
            updatedAt: now,
            source: source,
            history: [write],
          );
        } else {
          existing.value = nvalue;
          existing.updatedAt = now;
          existing.source = source;
          existing.history.add(write);
          if (existing.history.length > _maxHistoryPerEntry) {
            existing.history.removeRange(
              0,
              existing.history.length - _maxHistoryPerEntry,
            );
          }
        }
        await _persist();
        notifyListeners();
      });

  /// The current value for [key], or null when unknown.
  String? recall(String key) => entryFor(key)?.value;

  /// The full entry for [key], or null when unknown.
  MemoryEntry? entryFor(String key) => _entries[normalizeKey(key)];

  /// All entries, newest first.
  List<MemoryEntry> recallAll() {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// The [n] most recently updated entries, newest first.
  List<MemoryEntry> recent(int n) => recallAll().take(n).toList();

  /// Forget [key]. Returns true when something was removed.
  Future<bool> forget(String key) => _serial(() async {
    await _initLocked();
    final removed = _entries.remove(normalizeKey(key)) != null;
    if (removed) {
      await _persist();
      notifyListeners();
    }
    return removed;
  });

  /// Forget everything. The file is rewritten empty (not deleted) so a
  /// later load stays well-defined.
  Future<void> clear() => _serial(() async {
    await _initLocked();
    _entries.clear();
    await _persist();
    notifyListeners();
  });

  /// Formatted "what you remember" section for the agent system prompt.
  /// Empty string when there is nothing to inject — the agent works fine
  /// with empty memory.
  String promptContext({int maxEntries = _promptEntryLimit}) {
    final entries = recent(maxEntries);
    if (entries.isEmpty) return '';
    final buf = StringBuffer(
      '\nThings you remember about the user (from your on-device memory):\n',
    );
    for (final e in entries) {
      var v = e.value.replaceAll(RegExp(r'\s+'), ' ');
      if (v.length > _promptValueChars) {
        v = '${v.substring(0, _promptValueChars)}...';
      }
      buf.writeln('- ${e.key}: $v');
    }
    buf.write(
      'Use memory_recall to look things up and memory_remember to save '
      'new lasting facts.',
    );
    return buf.toString();
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/agent_memory.json');
  }

  Future<void> _persist() async {
    final file = await _file();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'version': 1,
        'entries': {for (final e in _entries.entries) e.key: e.value.toJson()},
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

// ---------------------------------------------------------------------------
// Agent tools: memory_remember / memory_recall.
//
// Built as LmTools (the same registry pattern as the phone tools in
// lmstudio_tools.dart) closing over the AgentMemory instance, so the
// handlers need no LmToolContext plumbing. They run through the same
// phoneToolsToLangChain adapter as every other tool — local only, no
// approval popups (writes are small, reversible, and never leave the
// phone).
// ---------------------------------------------------------------------------

Map<String, Object?> _memStrParam(String description) => {
  'type': 'string',
  'description': description,
};

Map<String, Object?> _memObjectSchema(
  Map<String, Map<String, Object?>> properties, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};

/// The memory tools for the on-device agent, backed by [memory].
List<LmTool> memoryLmTools(AgentMemory memory) => [
  LmTool(
    name: 'memory_remember',
    description:
        'Save a lasting fact or preference about the user to your '
        'on-device long-term memory: their name, likes, routines, '
        'ongoing projects. Stored ONLY on this phone, never sent '
        'anywhere. Overwrites any previous value for the same key.',
    parameters: _memObjectSchema(
      {
        'key': _memStrParam(
          'Short label for the fact, e.g. "favorite food" or "dog name". '
          'Keys are case-insensitive.',
        ),
        'value': _memStrParam('The fact to remember.'),
      },
      ['key', 'value'],
    ),
    handler: (args, ctx) async {
      final key = args['key']?.toString().trim() ?? '';
      final value = args['value']?.toString().trim() ?? '';
      if (key.isEmpty) return 'error: key is required';
      if (value.isEmpty) return 'error: value is required';
      final existed = memory.recall(key) != null;
      await memory.remember(key, value);
      final nkey = AgentMemory.normalizeKey(key);
      return existed ? 'Updated memory "$nkey".' : 'Remembered "$nkey".';
    },
  ),
  LmTool(
    name: 'memory_recall',
    description:
        'Look up facts from your on-device long-term memory. Give a key '
        'to recall one fact, or omit it to list recent memories.',
    parameters: _memObjectSchema({
      'key': _memStrParam(
        'The fact label to look up, e.g. "favorite food". Optional: '
        'omit to list recent memories.',
      ),
    }),
    handler: (args, ctx) async {
      final key = args['key']?.toString().trim() ?? '';
      if (key.isNotEmpty) {
        final entry = memory.entryFor(key);
        if (entry == null) return 'No memory stored for "$key".';
        return '"${entry.key}": ${entry.value}';
      }
      final entries = memory.recent(10);
      if (entries.isEmpty) {
        return 'Memory is empty: nothing has been remembered yet.';
      }
      return entries.map((e) => '"${e.key}": ${e.value}').join('\n');
    },
  ),
];
