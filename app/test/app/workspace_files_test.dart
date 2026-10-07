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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/workspace_files.dart';

void main() {
  late Directory root;
  late WorkspaceFiles ws;

  setUp(() {
    root = Directory.systemTemp.createTempSync('workspace_test');
    ws = WorkspaceFiles(root: root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('write then read text round-trips', () async {
    await ws.writeText('notes/todo.txt', 'buy milk');
    expect(await ws.readText('notes/todo.txt'), 'buy milk');
  });

  test('list shows folders first', () async {
    await ws.writeText('b.txt', 'b');
    await ws.writeText('a/file.txt', 'a');
    final entries = await ws.list();
    expect(entries.map((e) => e.name).toList(), ['a', 'b.txt']);
    expect(entries.first.isDirectory, isTrue);
  });

  test('append extends the file', () async {
    await ws.writeText('log.txt', 'one\n');
    await ws.writeText('log.txt', 'two\n', append: true);
    expect(await ws.readText('log.txt'), 'one\ntwo\n');
  });

  test('delete removes files and reports missing', () async {
    await ws.writeText('gone.txt', 'x');
    expect(await ws.delete('gone.txt'), isTrue);
    expect(await ws.delete('gone.txt'), isFalse);
  });

  test('delete refuses non-empty directories', () async {
    await ws.writeText('dir/inner.txt', 'x');
    expect(() => ws.delete('dir'), throwsA(isA<WorkspaceException>()));
  });

  test('traversal and absolute paths are refused', () async {
    for (final bad in ['../escape.txt', '/abs.txt', '..', '.hidden/x']) {
      expect(() => ws.readText(bad), throwsA(isA<WorkspaceException>()));
      expect(() => ws.writeText(bad, 'x'), throwsA(isA<WorkspaceException>()));
    }
  });

  test('missing files report cleanly', () async {
    expect(() => ws.readText('nope.txt'), throwsA(isA<WorkspaceException>()));
    expect(
      () => ws.list('no-dir'),
      throwsA(isA<WorkspaceException>()),
    );
  });

  test('readBytes returns base64 with size', () async {
    await ws.writeText('bin.txt', 'abc');
    final (payload, size) = await ws.readBytes('bin.txt');
    expect(payload.isNotEmpty, isTrue);
    expect(size, 3);
  });
}
