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
// Round-trip coverage for the voice read-aloud preference: map
// serialization, copyWith, and the on-by-default rule for installs that
// predate the setting.

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/model.dart';

void main() {
  group('CompanionSettings.voiceReadAloud', () {
    test('defaults to true', () {
      expect(const CompanionSettings().voiceReadAloud, isTrue);
    });

    test('survives a toMap/fromMap round-trip when true', () {
      const settings = CompanionSettings(voiceReadAloud: true);
      final restored = CompanionSettings.fromMap(settings.toMap());
      expect(restored.voiceReadAloud, isTrue);
    });

    test('survives a toMap/fromMap round-trip when false', () {
      const settings = CompanionSettings(voiceReadAloud: false);
      final restored = CompanionSettings.fromMap(settings.toMap());
      expect(restored.voiceReadAloud, isFalse);
    });

    test('missing key means on (older installs)', () {
      final restored = CompanionSettings.fromMap({'theme': 'dark'});
      expect(restored.voiceReadAloud, isTrue);
    });

    test('copyWith preserves and overrides the flag', () {
      const base = CompanionSettings();
      expect(base.copyWith().voiceReadAloud, isTrue);
      expect(base.copyWith(voiceReadAloud: false).voiceReadAloud, isFalse);
      expect(
        base
            .copyWith(voiceReadAloud: false)
            .copyWith(theme: 'light')
            .voiceReadAloud,
        isFalse,
      );
    });
  });
}
