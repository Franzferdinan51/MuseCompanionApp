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
// Shared canvas: documents the agent and the user share beside the chat
// (markdown, HTML, code, SVG, text). Every edit is a new version with a
// diff you can restore; HTML renders sandboxed.
//
// Design ported (concepts, not code) from the MIT-licensed
// hermes-mobile-app canvas plugin by omarqaterge:
// https://github.com/omarqaterge/hermes-mobile-app
// (hermes-plugin/hermes-mobile/canvas.py) — file-per-document JSON,
// atomic writes, ~40 versions per document.
//
// Storage: <app documents>/canvas/<id>.json. Writes are serialized
// through an async mutex (the agent tool handlers and the UI can both
// touch the store) and land atomically: write a temp file, then rename
// over the target. Readers never see a half-written document.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// A problem worth surfacing to the caller (bad id, too big, conflict...).
class CanvasStoreException implements Exception {
  CanvasStoreException(this.message);

  final String message;

  @override
  String toString() => 'CanvasStoreException: $message';
}

/// Document types the canvas knows how to render.
enum CanvasDocType {
  markdown,
  html,
  code,
  text,
  svg;

  /// Parse a user/model-supplied type name; unknown names fall back to
  /// markdown so a typo never loses a document.
  static CanvasDocType fromName(String? name) {
    final n = (name ?? '').trim().toLowerCase();
    for (final t in CanvasDocType.values) {
      if (t.name == n) return t;
    }
    // Aliases the agent may use.
    if (n == 'md') return CanvasDocType.markdown;
    if (n == 'txt' || n == 'plain') return CanvasDocType.text;
    if (n == 'htm') return CanvasDocType.html;
    return CanvasDocType.markdown;
  }
}

/// One exact find/replace edit, applied in order (mirrors the Python
/// plugin's patch semantics).
class CanvasEdit {
  const CanvasEdit({
    required this.find,
    required this.replace,
    this.all = false,
  });

  final String find;
  final String replace;

  /// Replace every occurrence instead of requiring exactly one match.
  final bool all;
}

/// One entry in a document's version history.
class CanvasVersion {
  const CanvasVersion({
    required this.rev,
    required this.at,
    required this.by,
    required this.note,
    required this.content,
  });

  final int rev;
  final DateTime at;
  final String by;
  final String note;
  final String content;

  Map<String, Object?> toJson() => {
    'rev': rev,
    'at': at.toIso8601String(),
    'by': by,
    'note': note,
    'content': content,
  };

  static CanvasVersion? fromJson(Map<String, Object?> json) {
    final rev = json['rev'];
    final at = json['at'];
    final content = json['content'];
    if (rev is! int || at is! String || content is! String) return null;
    return CanvasVersion(
      rev: rev,
      at: DateTime.tryParse(at) ?? DateTime.fromMillisecondsSinceEpoch(0),
      by: json['by'] is String ? json['by'] as String : '',
      note: json['note'] is String ? json['note'] as String : '',
      content: content,
    );
  }
}

/// A full document with its version history.
class CanvasDoc {
  const CanvasDoc({
    required this.id,
    required this.title,
    required this.type,
    required this.lang,
    required this.rev,
    required this.content,
    required this.versions,
    required this.created,
    required this.updated,
    required this.networkAllowed,
  });

  final String id;
  final String title;
  final CanvasDocType type;

  /// Programming language when type == code (e.g. "python", "dart").
  final String lang;
  final int rev;
  final String content;
  final List<CanvasVersion> versions;
  final DateTime created;
  final DateTime updated;

  /// HTML documents render fully offline by default. When true, the
  /// sandboxed WebView may load remote resources (user opt-in per doc).
  final bool networkAllowed;

  CanvasDocMeta get meta => CanvasDocMeta(
    id: id,
    title: title,
    type: type,
    lang: lang,
    rev: rev,
    updated: updated,
    chars: content.length,
    networkAllowed: networkAllowed,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'type': type.name,
    'lang': lang,
    'rev': rev,
    'content': content,
    'versions': [for (final v in versions) v.toJson()],
    'created': created.toIso8601String(),
    'updated': updated.toIso8601String(),
    'networkAllowed': networkAllowed,
  };

  static CanvasDoc? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final title = json['title'];
    final rev = json['rev'];
    final content = json['content'];
    if (id is! String ||
        title is! String ||
        rev is! int ||
        content is! String) {
      return null;
    }
    final versions = <CanvasVersion>[];
    final rawVersions = json['versions'];
    if (rawVersions is List) {
      for (final item in rawVersions) {
        if (item is Map<String, Object?>) {
          final v = CanvasVersion.fromJson(item);
          if (v != null) versions.add(v);
        }
      }
    }
    DateTime stamp(Object? value) {
      if (value is String) {
        return DateTime.tryParse(value) ?? DateTime.now();
      }
      return DateTime.now();
    }

    return CanvasDoc(
      id: id,
      title: title,
      type: CanvasDocType.fromName(json['type'] as String?),
      lang: json['lang'] is String ? json['lang'] as String : '',
      rev: rev,
      content: content,
      versions: versions,
      created: stamp(json['created']),
      updated: stamp(json['updated']),
      networkAllowed: json['networkAllowed'] == true,
    );
  }
}

/// Lightweight document listing (no content, no version history).
class CanvasDocMeta {
  const CanvasDocMeta({
    required this.id,
    required this.title,
    required this.type,
    required this.lang,
    required this.rev,
    required this.updated,
    required this.chars,
    required this.networkAllowed,
  });

  final String id;
  final String title;
  final CanvasDocType type;
  final String lang;
  final int rev;
  final DateTime updated;
  final int chars;
  final bool networkAllowed;
}

/// What changed, for UI refresh and chat cards.
enum CanvasChangeKind { created, updated, renamed, deleted }

class CanvasChange {
  const CanvasChange({
    required this.kind,
    required this.docId,
    required this.title,
  });

  final CanvasChangeKind kind;
  final String docId;
  final String title;
}

/// Versioned document store for the shared canvas.
///
/// Use [CanvasStore.instance] from app code; tests can point
/// [CanvasStore.forDir] at a temp directory.
class CanvasStore {
  CanvasStore._(this.root);

  /// Open a store rooted at [dir]. Exposed for tests.
  factory CanvasStore.forDir(Directory dir) => CanvasStore._(dir);

  final Directory root;

  static CanvasStore? _instance;

  /// Lazily-initialized app-wide store in the app documents directory.
  /// Returns null when the documents directory is unavailable (e.g. a
  /// bare unit-test environment without path_provider).
  static Future<CanvasStore?> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/canvas');
      await dir.create(recursive: true);
      return _instance = CanvasStore._(dir);
    } catch (_) {
      return null;
    }
  }

  /// Reset the cached singleton (tests / sign-out flows).
  static void resetInstance() {
    _instance = null;
  }

  /// Versions kept per document (newest survive).
  static const int maxVersions = 40;

  /// Characters per document.
  static const int maxChars = 400000;

  /// Documents on the canvas.
  static const int maxDocs = 30;

  final StreamController<CanvasChange> _changes =
      StreamController<CanvasChange>.broadcast();

  /// Fires on create/update/rename/delete so list screens stay fresh.
  Stream<CanvasChange> get changes => _changes.stream;

  /// Serializes mutating operations. Dart is single-threaded, but async
  /// gaps between read-modify-write steps would otherwise interleave.
  Future<void> _gate = Future.value();

  Future<T> _serialized<T>(Future<T> Function() work) {
    final next = _gate.then((_) => work());
    // The gate itself must never stay broken: swallow errors here (the
    // caller still sees them via `next`).
    _gate = next.then((_) => null, onError: (_) => null);
    return next;
  }

  final _random = Random.secure();

  String _slug(String title) {
    var s = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.isEmpty) s = 'doc';
    if (s.length > 32) s = s.substring(0, 32);
    final hex = List.generate(
      2,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$s-$hex';
  }

  /// File names must not escape the canvas directory.
  String _safeId(String id) {
    final cleaned = id
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')
        .replaceAll(RegExp(r'^\.+'), '');
    if (cleaned.isEmpty || cleaned.length > 120) {
      throw CanvasStoreException('bad document id');
    }
    return cleaned;
  }

  File _file(String id) => File('${root.path}/${_safeId(id)}.json');

  Future<CanvasDoc> _readLocked(String id) async {
    final file = _file(id);
    if (!await file.exists()) {
      throw CanvasStoreException("no document '$id' on this canvas");
    }
    try {
      final raw = await file.readAsString();
      final decoded = json.decode(raw);
      if (decoded is! Map<String, Object?>) {
        throw CanvasStoreException("document '$id' is corrupted");
      }
      final doc = CanvasDoc.fromJson(decoded);
      if (doc == null) throw CanvasStoreException("document '$id' is corrupted");
      return doc;
    } on CanvasStoreException {
      rethrow;
    } catch (e) {
      throw CanvasStoreException("could not read document '$id': $e");
    }
  }

  /// Atomic write: temp file + rename, so a crash mid-write never leaves
  /// a half-written document behind.
  Future<void> _writeLocked(CanvasDoc doc) async {
    final file = _file(doc.id);
    final tmp = File(
      '${file.path}.$pid.${_random.nextInt(1 << 32)}.tmp',
    );
    await tmp.writeAsString(json.encode(doc.toJson()));
    await tmp.rename(file.path);
  }

  CanvasDoc _commit(
    CanvasDoc doc,
    String content, {
    String by = 'agent',
    String note = '',
    String? title,
    CanvasDocType? type,
    String? lang,
  }) {
    if (content.length > maxChars) {
      throw CanvasStoreException(
        'too large (${content.length} characters, limit $maxChars)',
      );
    }
    final rev = doc.rev + 1;
    final now = DateTime.now();
    final versions = [
      ...doc.versions,
      CanvasVersion(
        rev: rev,
        at: now,
        by: by,
        note: note.length > 120 ? note.substring(0, 120) : note,
        content: content,
      ),
    ];
    final kept = versions.length > maxVersions
        ? versions.sublist(versions.length - maxVersions)
        : versions;
    return CanvasDoc(
      id: doc.id,
      title: title ?? doc.title,
      type: type ?? doc.type,
      lang: lang ?? doc.lang,
      rev: rev,
      content: content,
      versions: kept,
      created: doc.created,
      updated: now,
      networkAllowed: doc.networkAllowed,
    );
  }

  /// Documents on the canvas, oldest first.
  Future<List<CanvasDocMeta>> list() async {
    if (!await root.exists()) return const [];
    final metas = <CanvasDocMeta>[];
    await for (final entity in root.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = await entity.readAsString();
        final decoded = json.decode(raw);
        if (decoded is Map<String, Object?>) {
          final doc = CanvasDoc.fromJson(decoded);
          if (doc != null) metas.add(doc.meta);
        }
      } catch (_) {
        // Skip unreadable files; never fail the whole listing.
      }
    }
    metas.sort((a, b) => a.id.compareTo(b.id));
    return metas;
  }

  /// Create a new document. Returns the stored document (rev 1).
  Future<CanvasDoc> create({
    required String title,
    CanvasDocType type = CanvasDocType.markdown,
    String content = '',
    String lang = '',
    String by = 'agent',
    String note = '',
  }) {
    return _serialized(() async {
      final existing = await list();
      if (existing.length >= maxDocs) {
        throw CanvasStoreException(
          'this canvas already has $maxDocs documents: delete one first',
        );
      }
      final cleanTitle = title.trim().isEmpty ? 'Untitled' : title.trim();
      final doc = CanvasDoc(
        id: _slug(cleanTitle),
        title: cleanTitle.length > 120
            ? cleanTitle.substring(0, 120)
            : cleanTitle,
        type: type,
        lang: lang,
        rev: 0,
        content: '',
        versions: const [],
        created: DateTime.now(),
        updated: DateTime.now(),
        networkAllowed: false,
      );
      final committed = _commit(
        doc,
        content,
        by: by,
        note: note.isEmpty ? 'created' : note,
      );
      await _writeLocked(committed);
      _changes.add(
        CanvasChange(
          kind: CanvasChangeKind.created,
          docId: committed.id,
          title: committed.title,
        ),
      );
      return committed;
    });
  }

  /// Read a document with its version history.
  Future<CanvasDoc> read(String id) => _serialized(() => _readLocked(id));

  /// Replace a document's whole content (new version). Pass [baseRev] to
  /// refuse overwriting a newer version (optimistic concurrency).
  Future<CanvasDoc> update(
    String id, {
    required String content,
    String? title,
    CanvasDocType? type,
    String? lang,
    String by = 'agent',
    String note = '',
    int? baseRev,
  }) {
    return _serialized(() async {
      var doc = await _readLocked(id);
      if (baseRev != null && baseRev != doc.rev) {
        throw CanvasStoreException(
          'conflict: this document changed '
          '(now revision ${doc.rev}, you had $baseRev)',
        );
      }
      final cleanTitle = title?.trim();
      if (cleanTitle != null && cleanTitle.isEmpty) {
        throw CanvasStoreException('title must not be empty');
      }
      if (content == doc.content &&
          cleanTitle == null &&
          type == null &&
          lang == null) {
        return doc;
      }
      doc = _commit(
        doc,
        content,
        by: by,
        note: note,
        title: cleanTitle != null && cleanTitle.length > 120
            ? cleanTitle.substring(0, 120)
            : cleanTitle,
        type: type,
        lang: lang,
      );
      await _writeLocked(doc);
      _changes.add(
        CanvasChange(
          kind: CanvasChangeKind.updated,
          docId: doc.id,
          title: doc.title,
        ),
      );
      return doc;
    });
  }

  /// Exact find/replace edits, applied in order. Each `find` must match
  /// exactly once unless [CanvasEdit.all] is set.
  Future<CanvasDoc> patch(
    String id,
    List<CanvasEdit> edits, {
    String by = 'agent',
    String note = '',
  }) {
    return _serialized(() async {
      if (edits.isEmpty) {
        throw CanvasStoreException('give at least one edit');
      }
      var doc = await _readLocked(id);
      var text = doc.content;
      for (var i = 0; i < edits.length; i++) {
        final edit = edits[i];
        if (edit.find.isEmpty) {
          throw CanvasStoreException('edit ${i + 1}: find text is empty');
        }
        final count = edit.find.allMatches(text).length;
        if (count == 0) {
          throw CanvasStoreException(
            'edit ${i + 1}: text not found '
            '(copy it exactly, or read the document first)',
          );
        }
        if (count > 1 && !edit.all) {
          throw CanvasStoreException(
            'edit ${i + 1}: text appears $count times: '
            'make it longer, or replace all',
          );
        }
        text = edit.all
            ? text.replaceAll(edit.find, edit.replace)
            : text.replaceFirst(edit.find, edit.replace);
      }
      doc = _commit(
        doc,
        text,
        by: by,
        note: note.isEmpty ? '${edits.length} edit(s)' : note,
      );
      await _writeLocked(doc);
      _changes.add(
        CanvasChange(
          kind: CanvasChangeKind.updated,
          docId: doc.id,
          title: doc.title,
        ),
      );
      return doc;
    });
  }

  /// Restore an older revision as a new version (history is append-only;
  /// nothing is ever lost).
  Future<CanvasDoc> restore(String id, int rev, {String by = 'user'}) {
    return _serialized(() async {
      var doc = await _readLocked(id);
      final old = doc.versions.where((v) => v.rev == rev).firstOrNull;
      if (old == null) {
        throw CanvasStoreException('revision $rev is no longer kept');
      }
      doc = _commit(
        doc,
        old.content,
        by: by,
        note: 'restored revision $rev',
      );
      await _writeLocked(doc);
      _changes.add(
        CanvasChange(
          kind: CanvasChangeKind.updated,
          docId: doc.id,
          title: doc.title,
        ),
      );
      return doc;
    });
  }

  /// Rename without creating a new content version.
  Future<CanvasDoc> rename(String id, String title) {
    return _serialized(() async {
      var doc = await _readLocked(id);
      final clean = title.trim();
      if (clean.isEmpty) throw CanvasStoreException('title must not be empty');
      doc = CanvasDoc(
        id: doc.id,
        title: clean.length > 120 ? clean.substring(0, 120) : clean,
        type: doc.type,
        lang: doc.lang,
        rev: doc.rev,
        content: doc.content,
        versions: doc.versions,
        created: doc.created,
        updated: DateTime.now(),
        networkAllowed: doc.networkAllowed,
      );
      await _writeLocked(doc);
      _changes.add(
        CanvasChange(
          kind: CanvasChangeKind.renamed,
          docId: doc.id,
          title: doc.title,
        ),
      );
      return doc;
    });
  }

  /// Allow or deny network access for an HTML document's sandboxed view.
  /// Meta-only: does not create a new version.
  Future<CanvasDoc> setNetworkAllowed(String id, bool allowed) {
    return _serialized(() async {
      final doc = await _readLocked(id);
      if (doc.networkAllowed == allowed) return doc;
      final updated = CanvasDoc(
        id: doc.id,
        title: doc.title,
        type: doc.type,
        lang: doc.lang,
        rev: doc.rev,
        content: doc.content,
        versions: doc.versions,
        created: doc.created,
        updated: DateTime.now(),
        networkAllowed: allowed,
      );
      await _writeLocked(updated);
      return updated;
    });
  }

  /// Delete a document. History goes with it.
  Future<void> delete(String id) {
    return _serialized(() async {
      final file = _file(id);
      final existed = await file.exists();
      if (existed) await file.delete();
      _changes.add(
        CanvasChange(
          kind: CanvasChangeKind.deleted,
          docId: id,
          title: '',
        ),
      );
    });
  }

  /// Fetch one historical revision (null when it aged out).
  Future<CanvasVersion?> version(String id, int rev) async {
    final doc = await _readLocked(id);
    return doc.versions.where((v) => v.rev == rev).firstOrNull;
  }

  /// Close the change stream. The app-wide singleton lives for the
  /// process lifetime, so this is for tests.
  Future<void> close() => _changes.close();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    for (final item in this) {
      return item;
    }
    return null;
  }
}
