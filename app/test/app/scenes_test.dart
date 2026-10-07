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
import 'package:muse_companion/app/scenes.dart';

void main() {
  late Directory dir;
  late SceneStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('scenes_test');
    store = SceneStore(dir: dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Scene scene(String id, [int steps = 2]) => Scene(
    id: id,
    title: 'Title $id',
    steps: [
      for (var i = 0; i < steps; i++)
        SceneStep(command: 'file.list', params: {'n': i}),
    ],
  );

  Future<Map<String, Object?>> okRunner(String c, Map<String, Object?> p) async =>
      {'ok': true, 'payload': <String, Object?>{}};

  test('save, get and list round-trip', () async {
    await store.save(scene('welcome'));
    expect((await store.get('welcome'))?.title, 'Title welcome');
    expect((await store.list()).map((s) => s.id), ['welcome']);
  });

  test('ids are normalized and validated', () async {
    await store.save(scene('  Movie-Night_1 '));
    expect(await store.get('movie-night_1'), isNotNull);
    expect(() => store.save(scene('bad id!')), throwsA(isA<SceneException>()));
    expect(() => store.save(scene('')), throwsA(isA<SceneException>()));
    expect(
      () => store.save(Scene(id: 'x', title: '', steps: const [])),
      throwsA(isA<SceneException>()),
    );
  });

  test('step count is capped', () async {
    final many = Scene(
      id: 'many',
      title: 'too many',
      steps: [
        for (var i = 0; i < SceneStore.maxSteps + 1; i++)
          const SceneStep(command: 'file.list'),
      ],
    );
    expect(() => store.save(many), throwsA(isA<SceneException>()));
  });

  test('delete removes and reports', () async {
    await store.save(scene('temp'));
    expect(await store.delete('temp'), isTrue);
    expect(await store.get('temp'), isNull);
    expect(await store.delete('temp'), isFalse);
  });

  test('run executes steps in order and completes', () async {
    await store.save(scene('run-me'));
    final seen = <String>[];
    final result = await store.runScene('run-me', (c, p) async {
      seen.add(c);
      return okRunner(c, p);
    });
    expect(result.completed, isTrue);
    expect(seen, ['file.list', 'file.list']);
  });

  test('run stops at the first failing step', () async {
    await store.save(scene('flaky'));
    final seen = <String>[];
    var calls = 0;
    final result = await store.runScene('flaky', (c, p) async {
      seen.add(c);
      calls++;
      if (calls == 1) return {'ok': false, 'payload': {'error': 'boom'}};
      return okRunner(c, p);
    });
    expect(result.completed, isFalse);
    expect(seen, ['file.list']);
    expect(result.steps.first.detail, 'boom');
  });

  test('run of an unknown scene throws', () async {
    expect(() => store.runScene('nope', okRunner), throwsA(isA<SceneException>()));
  });

  test('scenes persist across instances', () async {
    await store.save(scene('kept'));
    final again = SceneStore(dir: dir);
    expect((await again.get('kept'))?.title, 'Title kept');
  });
}
