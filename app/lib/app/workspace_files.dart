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
// Sandboxed workspace file API for the agent and the user.
//
// A single `workspace/` directory inside the app documents directory.
// Everything stays under it: absolute paths, `..` escapes, hidden
// segments, and symlinks are refused, and every resolved path is
// canonical-path checked against the root. Writes are atomic
// (temp file + rename). The agent reaches this through the `file.*`
// commands and the file_* local tools; the user can drop reference
// files here (itineraries, notes, data) for the agent to read.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Thrown for sandbox violations and filesystem failures.
class WorkspaceException implements Exception {
  WorkspaceException(this.message);

  final String message;

  @override
  String toString() => 'WorkspaceException: $message';
}

/// One entry from [WorkspaceFiles.list].
class WorkspaceEntry {
  const WorkspaceEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modified,
  });

  final String name;

  /// Path relative to the workspace root, `/`-separated.
  final String path;
  final bool isDirectory;
  final int sizeBytes;
  final DateTime modified;

  Map<String, Object?> toJson() => {
    'name': name,
    'path': path,
    'type': isDirectory ? 'directory' : 'file',
    'size_bytes': sizeBytes,
    'modified': modified.toIso8601String(),
  };
}

class WorkspaceFiles {
  /// When [root] is set, the documents directory is never touched
  /// (unit tests inject a temp dir).
  WorkspaceFiles({Directory? root}) : _rootOverride = root;

  final Directory? _rootOverride;

  /// Cap on entries returned by [list]; folders first.
  static const int maxListEntries = 500;

  /// Cap on bytes returned by [readBytes].
  static const int maxReadBytes = 10 * 1024 * 1024;

  /// Cap on characters returned by [readText].
  static const int maxReadChars = 64000;

  /// Cap on bytes accepted by [writeText].
  static const int maxWriteBytes = 5 * 1024 * 1024;

  Future<Directory> _root() async {
    if (_rootOverride != null) return _rootOverride;
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/workspace');
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  /// Split [rel] into clean segments, rejecting anything that could
  /// escape the sandbox. Empty string addresses the root itself.
  List<String> _segments(String rel) {
    final normalized = rel.replaceAll('\\', '/').trim();
    if (normalized.isEmpty || normalized == '/') return const [];
    final parts = normalized.split('/');
    final out = <String>[];
    for (final part in parts) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        throw WorkspaceException('path escapes the workspace: $rel');
      }
      if (part.startsWith('.')) {
        throw WorkspaceException('hidden paths are not allowed: $rel');
      }
      out.add(part);
    }
    if (rel.startsWith('/')) {
      throw WorkspaceException('absolute paths are not allowed: $rel');
    }
    return out;
  }

  /// Resolve [rel] under [root], refusing symlinks anywhere on the path.
  Future<String> _resolve(Directory root, String rel) async {
    final segs = _segments(rel);
    var current = root.path;
    for (final seg in segs) {
      current = '$current/$seg';
      final kind = await FileSystemEntity.type(current, followLinks: false);
      if (kind == FileSystemEntityType.link) {
        throw WorkspaceException('symlinks are not allowed: $rel');
      }
    }
    return current;
  }

  /// List [rel] (default root): folders first, then files, capped.
  Future<List<WorkspaceEntry>> list([String rel = '']) async {
    final root = await _root();
    final dirPath = await _resolve(root, rel);
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      throw WorkspaceException('directory not found: $rel');
    }
    final out = <WorkspaceEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final kind = await FileSystemEntity.type(
        entity.path,
        followLinks: false,
      );
      if (kind == FileSystemEntityType.link) continue;
      final isDir = kind == FileSystemEntityType.directory;
      var size = 0;
      if (!isDir) {
        try {
          size = await File(entity.path).length();
        } catch (_) {
          continue;
        }
      }
      final name = entity.path.split('/').last;
      final prefix = rel.replaceAll('\\', '/').trim();
      final cleanPrefix = prefix.isEmpty || prefix == '/'
          ? ''
          : '${prefix.endsWith('/') ? prefix.substring(0, prefix.length - 1) : prefix}/';
      DateTime modified;
      try {
        modified = (await entity.stat()).modified;
      } catch (_) {
        modified = DateTime.fromMillisecondsSinceEpoch(0);
      }
      out.add(
        WorkspaceEntry(
          name: name,
          path: '$cleanPrefix$name',
          isDirectory: isDir,
          sizeBytes: size,
          modified: modified,
        ),
      );
      if (out.length >= maxListEntries) break;
    }
    out.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.compareTo(b.name);
    });
    return out;
  }

  /// Read a text file, capped at [maxReadChars] characters.
  Future<String> readText(String rel, {int maxChars = maxReadChars}) async {
    final root = await _root();
    final file = File(await _resolve(root, rel));
    if (!await file.exists()) {
      throw WorkspaceException('file not found: $rel');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxReadBytes) {
      throw WorkspaceException('file too large to read: $rel');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.length > maxChars ? text.substring(0, maxChars) : text;
  }

  /// Read a file as base64, capped at [maxReadBytes] bytes.
  Future<(String base64, int sizeBytes)> readBytes(String rel) async {
    final root = await _root();
    final file = File(await _resolve(root, rel));
    if (!await file.exists()) {
      throw WorkspaceException('file not found: $rel');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxReadBytes) {
      throw WorkspaceException('file too large to read: $rel');
    }
    return (base64Encode(bytes), bytes.length);
  }

  /// Write raw [bytes] atomically (temp file + rename). Parent folders
  /// are created. This is how binary files (images for vision.analyze)
  /// enter the workspace.
  Future<int> writeBytes(String rel, List<int> bytes) async {
    if (bytes.length > maxWriteBytes) {
      throw WorkspaceException('content exceeds the write cap: $rel');
    }
    final root = await _root();
    final filePath = await _resolve(root, rel);
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final tmp = File('$filePath.tmp.${DateTime.now().microsecondsSinceEpoch}');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(filePath);
    return bytes.length;
  }

  /// Write [content] atomically (temp file + rename). Parent folders
  /// are created. When [append] is true the content is appended instead.
  Future<int> writeText(
    String rel,
    String content, {
    bool append = false,
  }) async {
    final bytes = utf8.encode(content);
    if (bytes.length > maxWriteBytes) {
      throw WorkspaceException('content exceeds the write cap: $rel');
    }
    final root = await _root();
    final filePath = await _resolve(root, rel);
    final file = File(filePath);
    await file.parent.create(recursive: true);
    if (append && await file.exists()) {
      await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
      return file.lengthSync();
    }
    final tmp = File('$filePath.tmp.${DateTime.now().microsecondsSinceEpoch}');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(filePath);
    return bytes.length;
  }

  /// Delete a file or an empty directory. Returns false when missing.
  Future<bool> delete(String rel) async {
    final root = await _root();
    final target = await _resolve(root, rel);
    final kind = await FileSystemEntity.type(target, followLinks: false);
    if (kind == FileSystemEntityType.notFound) return false;
    if (kind == FileSystemEntityType.link) {
      throw WorkspaceException('symlinks are not allowed: $rel');
    }
    if (kind == FileSystemEntityType.directory) {
      final dir = Directory(target);
      if (!await dir.list(followLinks: false).isEmpty) {
        throw WorkspaceException('directory is not empty: $rel');
      }
      await dir.delete();
      return true;
    }
    await File(target).delete();
    return true;
  }
}
