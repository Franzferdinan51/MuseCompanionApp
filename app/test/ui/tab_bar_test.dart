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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/ble_peripheral.dart';
import 'package:muse_companion/app/chat.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/app/storage.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/service.dart';
import 'package:muse_companion/ui/home_tabs.dart';
import 'package:muse_companion/ui/muse_theme.dart';
import 'package:muse_companion/ui/scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('tab bar matches old _BottomBar aesthetic and switches tabs',
      (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.init();
    final presentation =
        PresentationState(settings: settings.loadSettings());
    final service = GadgetService(
      identity: const Identity('02:aa:bb:cc:dd:ee'),
      commands: const {},
      runCommand: (_, _, _) async => {'ok': true},
      pairingStore: MemoryPairingStore(),
      version: '0.1.0',
    );
    final ble = BlePeripheralManager(
      identity: const Identity('02:aa:bb:cc:dd:ee'),
      pairingStore: MemoryPairingStore(),
      version: '0.1.0',
    );
    final chat = ChatHistory();
    addTearDown(() async {
      await service.stop();
      await ble.dispose();
      chat.close();
      presentation.close();
    });

    await tester.pumpWidget(AppScope(
      service: service,
      presentation: presentation,
      settings: settings,
      ble: ble,
      chat: chat,
      sdkTokens: SecureSdkTokenStore(),
      child: const MaterialApp(
        home: HomeTabs(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Six icon-only tabs with tooltips (no text labels, like the old bar).
    for (final label in ['Home', 'Chat', 'Device', 'Activity', 'Media', 'Settings']) {
      expect(find.byTooltip(label), findsOneWidget,
          reason: 'tab "$label" should exist as a tooltip icon button');
    }
    // The bar itself is icon-only: no text labels inside it.
    final barScope = find.byKey(const ValueKey('tabBarSafeArea'));
    expect(
      find.descendant(
        of: barScope,
        matching: find.byType(Text),
      ),
      findsNothing,
      reason: 'tabs are icon-only, no text labels in the bar',
    );

    // Exactly one MuseBubble in the bottom bar: the active tab indicator.
    final barBubbles = find.descendant(
      of: barScope,
      matching: find.byType(MuseBubble),
    );
    expect(barBubbles, findsOneWidget,
        reason: 'only the active tab gets the MuseBubble treatment');

    // The active tab icon is museBlue at 20px.
    final activeIcon = tester
        .widgetList<Icon>(find.descendant(
          of: barBubbles,
          matching: find.byType(Icon),
        ))
        .single;
    expect(activeIcon.color, museBlue);
    expect(activeIcon.size, 20);
    expect(activeIcon.icon, Icons.pets);

    // Tapping Device switches the IndexedStack without errors.
    await tester.tap(find.byTooltip('Device'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    // Active indicator moved: the bubble now wraps the Device icon.
    final deviceIcon = tester
        .widgetList<Icon>(find.descendant(
          of: find.descendant(
            of: find.byKey(const ValueKey('tabBarSafeArea')),
            matching: find.byType(MuseBubble),
          ),
          matching: find.byType(Icon),
        ))
        .single;
    expect(deviceIcon.icon, Icons.phone_android);
    expect(deviceIcon.color, museBlue);

    // Tapping back to Home works.
    await tester.tap(find.byTooltip('Home'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    final homeIcon = tester
        .widgetList<Icon>(find.descendant(
          of: find.descendant(
            of: find.byKey(const ValueKey('tabBarSafeArea')),
            matching: find.byType(MuseBubble),
          ),
          matching: find.byType(Icon),
        ))
        .single;
    expect(homeIcon.icon, Icons.pets);

    // Tapping Settings switches to the settings screen without errors.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    final settingsIcon = tester
        .widgetList<Icon>(find.descendant(
          of: find.descendant(
            of: find.byKey(const ValueKey('tabBarSafeArea')),
            matching: find.byType(MuseBubble),
          ),
          matching: find.byType(Icon),
        ))
        .single;
    expect(settingsIcon.icon, Icons.settings);
    expect(settingsIcon.color, museBlue);
  });
}
