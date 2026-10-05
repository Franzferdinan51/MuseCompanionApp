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
import 'package:muse_companion/app/chat.dart';
import 'package:muse_companion/app/chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatMeta', () {
    test('defaults are unpinned and unarchived', () {
      const meta = ChatMeta();
      expect(meta.pinned, isFalse);
      expect(meta.archived, isFalse);
    });

    test('json round trip', () {
      const meta = ChatMeta(pinned: true, archived: true);
      final restored = ChatMeta.fromJson(meta.toJson());
      expect(restored.pinned, isTrue);
      expect(restored.archived, isTrue);
    });

    test('fromJson tolerates missing keys', () {
      final restored = ChatMeta.fromJson(const {});
      expect(restored.pinned, isFalse);
      expect(restored.archived, isFalse);
    });
  });

  group('ChatStore pin/archive persistence', () {
    test('flags survive a restore', () async {
      SharedPreferences.setMockInitialValues({});
      final history = ChatHistory();
      final store = ChatStore(history);
      await store.restoreMeta();
      expect(store.meta.pinned, isFalse);
      expect(store.meta.archived, isFalse);

      await store.setPinned(true);
      await store.setArchived(true);
      expect(store.meta.pinned, isTrue);
      expect(store.meta.archived, isTrue);

      // A fresh store over the same prefs sees the flags.
      final store2 = ChatStore(ChatHistory());
      await store2.restoreMeta();
      expect(store2.meta.pinned, isTrue);
      expect(store2.meta.archived, isTrue);

      // Toggling back persists too.
      await store2.setPinned(false);
      final store3 = ChatStore(ChatHistory());
      await store3.restoreMeta();
      expect(store3.meta.pinned, isFalse);
      expect(store3.meta.archived, isTrue);

      history.close();
    });
  });
}
