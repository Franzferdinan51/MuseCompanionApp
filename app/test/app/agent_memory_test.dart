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
import 'package:muse_companion/app/agent_memory.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('agent_memory_test');
    PathProviderPlatform.instance = _FakePathProvider(docs.path);
  });

  tearDown(() async {
    await AgentMemory.instance.clear();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  test('remember works with no prior init and round-trips', () async {
    await AgentMemory.instance.remember('Dog Name', 'Biscuit');
    expect(AgentMemory.instance.recall('dog name'), 'Biscuit');
  });

  test('keys are case-insensitive', () async {
    await AgentMemory.instance.remember('Favorite Food', 'ramen');
    expect(AgentMemory.instance.recall('FAVORITE food'), 'ramen');
  });

  test('empty key throws', () async {
    expect(
      () => AgentMemory.instance.remember('   ', 'x'),
      throwsArgumentError,
    );
  });

  test('oversized values are truncated', () async {
    final big = 'v' * 5000;
    await AgentMemory.instance.remember('bio', big);
    expect(AgentMemory.instance.recall('bio')!.length, 4000);
  });

  test('history keeps the newest writes only', () async {
    for (var i = 0; i < 25; i++) {
      await AgentMemory.instance.remember('counter', 'v$i');
    }
    final entry = AgentMemory.instance.entryFor('counter')!;
    expect(entry.history.length, 20);
    expect(entry.value, 'v24');
    expect(entry.history.last.newValue, 'v24');
  });

  test('forget removes and reports', () async {
    await AgentMemory.instance.remember('temp', 'x');
    expect(await AgentMemory.instance.forget('temp'), isTrue);
    expect(AgentMemory.instance.recall('temp'), isNull);
    expect(await AgentMemory.instance.forget('temp'), isFalse);
  });

  test('promptContext lists entries and is empty when cleared', () async {
    expect(AgentMemory.instance.promptContext(), '');
    await AgentMemory.instance.remember('dog name', 'Biscuit');
    final ctx = AgentMemory.instance.promptContext();
    expect(ctx, contains('dog name'));
    expect(ctx, contains('Biscuit'));
  });
}
