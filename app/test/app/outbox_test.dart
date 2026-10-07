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

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/outbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  OutboxEntry entry(int id, [String text = 'hello']) => OutboxEntry(
    id: id,
    text: text,
    enqueuedAt: DateTime.fromMillisecondsSinceEpoch(id * 1000),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    for (final e in Outbox.instance.entries) {
      await Outbox.instance.removeById(e.id);
    }
  });

  test('enqueue keeps FIFO order', () async {
    await Outbox.instance.enqueue(entry(1, 'first'));
    await Outbox.instance.enqueue(entry(2, 'second'));
    final texts = Outbox.instance.entries.map((e) => e.text).toList();
    expect(texts, ['first', 'second']);
  });

  test('re-enqueueing the same id replaces instead of duplicating', () async {
    await Outbox.instance.enqueue(entry(1, 'original'));
    await Outbox.instance.enqueue(entry(1, 'retry'));
    expect(Outbox.instance.length, 1);
    expect(Outbox.instance.entries.single.text, 'retry');
  });

  test('over-cap enqueue drops the oldest first', () async {
    for (var i = 0; i <= Outbox.maxEntries; i++) {
      await Outbox.instance.enqueue(entry(i));
    }
    expect(Outbox.instance.length, Outbox.maxEntries);
    expect(
      Outbox.instance.entries.any((e) => e.id == 0),
      isFalse,
    );
    expect(Outbox.instance.entries.last.id, Outbox.maxEntries);
  });

  test('flush sends in order and stops at the first failure', () async {
    await Outbox.instance.enqueue(entry(1));
    await Outbox.instance.enqueue(entry(2));
    await Outbox.instance.enqueue(entry(3));
    final sent = <int>[];
    await Outbox.instance.flush((e) async {
      if (e.id == 2) return false;
      sent.add(e.id);
      return true;
    });
    expect(sent, [1]);
    expect(
      Outbox.instance.entries.map((e) => e.id).toList(),
      [2, 3],
    );
  });

  test('flush empties the queue when everything sends', () async {
    await Outbox.instance.enqueue(entry(1));
    await Outbox.instance.enqueue(entry(2));
    await Outbox.instance.flush((_) async => true);
    expect(Outbox.instance.isEmpty, isTrue);
  });

  test('flush treats a throwing sender as failure and keeps the entry',
      () async {
    await Outbox.instance.enqueue(entry(1));
    await Outbox.instance.flush((_) async => throw StateError('offline'));
    expect(Outbox.instance.length, 1);
  });

  test('entry json tolerates corrupt maps', () {
    final garbage = OutboxEntry.fromJson({'id': 'nope', 'text': 42});
    expect(garbage.id, 0);
    expect(garbage.text, '');
    expect(garbage.attachmentBytes, isNull);
  });
}
