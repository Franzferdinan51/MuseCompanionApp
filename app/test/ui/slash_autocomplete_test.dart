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
import 'package:muse_companion/ui/slash_autocomplete.dart';

void main() {
  group('slashCommandQuery', () {
    test('bare slash yields empty query', () {
      expect(slashCommandQuery('/', 1), '');
    });

    test('partial command yields query', () {
      expect(slashCommandQuery('/ph', 3), 'ph');
      expect(slashCommandQuery('/local', 6), 'local');
    });

    test('non-leading slash is ignored', () {
      expect(slashCommandQuery('hi /ph', 6), isNull);
    });

    test('whitespace after the command hides the popup', () {
      expect(slashCommandQuery('/local ', 7), isNull);
      expect(slashCommandQuery('/local do x', 11), isNull);
    });

    test('backspacing past the slash hides the popup', () {
      expect(slashCommandQuery('', 0), isNull);
      expect(slashCommandQuery('hello', 5), isNull);
    });

    test('cursor mid-text only matches up to the cursor', () {
      expect(slashCommandQuery('/photo', 3), 'ph');
    });

    test('non-word characters are rejected', () {
      expect(slashCommandQuery('/ph!', 4), isNull);
    });
  });

  group('matchingSlashCommands', () {
    test('empty query returns all commands', () {
      expect(
        matchingSlashCommands('').map((c) => c.name),
        containsAll(['photo', 'voice', 'local', 'speak']),
      );
    });

    test('prefix filter is case-insensitive', () {
      expect(matchingSlashCommands('PH').map((c) => c.name), ['photo']);
      expect(matchingSlashCommands('s').map((c) => c.name), ['speak']);
    });

    test('no match returns empty list', () {
      expect(matchingSlashCommands('zzz'), isEmpty);
    });
  });

  group('kSlashCommands', () {
    test('every command has a trigger and description', () {
      for (final command in kSlashCommands) {
        expect(command.trigger, '/${command.name}');
        expect(command.description, isNotEmpty);
      }
    });
  });
}
