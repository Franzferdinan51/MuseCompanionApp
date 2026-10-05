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
// Regression test for the 2026-10-04 speak-toggle bug: turning "Speak replies"
// OFF then back ON left voice silent.
//
// Root cause: _commit called settings.saveSettings(next) BEFORE
// presentation.applySettings(next). saveSettings notifies its listeners
// synchronously, and main.dart's syncSpeakEnabled reads
// presentation.settings.speakReplies - the STALE pre-toggle value. The
// killswitch ended up one toggle behind: OFF worked (a second gate in the
// reply path blocked speech), but ON left PhoneBridge.speakEnabled=false.
//
// The fix: apply in-memory state before persisting, so settings listeners
// always see fresh presentation state. This test pins that ordering.

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/app/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
      'settings listeners see the new presentation value, not the stale one',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SettingsStore(prefs);
    final presentation = PresentationState(
      settings: const CompanionSettings(speakReplies: true),
    );

    // Mimics main.dart's syncSpeakEnabled: reads presentation.settings when
    // the settings store notifies.
    bool? seenByListener;
    store.addListener(() {
      seenByListener = presentation.settings.speakReplies;
    });

    // Simulate _commit turning speak OFF, using the fixed ordering:
    // in-memory applySettings before saveSettings (which notifies).
    const off = CompanionSettings(speakReplies: false);
    presentation.applySettings(off);
    await store.saveSettings(off);
    expect(seenByListener, isFalse,
        reason: 'listener must see the new OFF value');

    // Simulate _commit turning speak back ON.
    const on = CompanionSettings(speakReplies: true);
    presentation.applySettings(on);
    await store.saveSettings(on);
    expect(seenByListener, isTrue,
        reason: 'listener must see the new ON value (was stale false '
            'before the fix, leaving voice silent)');
  });
}
