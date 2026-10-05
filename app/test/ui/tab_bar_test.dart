// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
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
  Future<_TestHarness> buildTabs() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.init();
    final presentation = PresentationState(settings: settings.loadSettings());
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
    return _TestHarness(
      service: service,
      presentation: presentation,
      settings: settings,
      ble: ble,
      chat: chat,
    );
  }

  testWidgets('side dock shows six destinations, active gets the bubble',
      (tester) async {
    final harness = await buildTabs();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    final dock = find.byKey(const ValueKey('sideDock'));
    expect(dock, findsOneWidget, reason: 'floating side dock must exist');

    // Six icon-only destinations with tooltips.
    for (final label in
        ['Home', 'Chat', 'Device', 'Activity', 'Media', 'Settings']) {
      expect(
        find.descendant(of: dock, matching: find.byTooltip(label)),
        findsOneWidget,
        reason: 'dock destination "$label" should exist',
      );
    }
    // Icon-only: no text labels inside the dock.
    expect(
      find.descendant(of: dock, matching: find.byType(Text)),
      findsNothing,
      reason: 'dock destinations are icon-only',
    );

    // Exactly one MuseBubble: the active destination indicator.
    final dockBubbles = find.descendant(
      of: dock,
      matching: find.byType(MuseBubble),
    );
    expect(dockBubbles, findsOneWidget,
        reason: 'only the active destination gets the MuseBubble');

    // Home is the default tab: bubble wraps the pets icon in museBlue.
    final activeIcon = tester
        .widgetList<Icon>(find.descendant(
          of: dockBubbles,
          matching: find.byType(Icon),
        ))
        .single;
    expect(activeIcon.icon, Icons.pets);
    expect(activeIcon.color, museBlue);
    expect(activeIcon.size, 20);

    // No bottom tab bar remnants anywhere.
    expect(find.byKey(const ValueKey('tabBarSafeArea')), findsNothing);
    expect(find.byKey(const ValueKey('tabBarHandle')), findsNothing);
  });

  testWidgets('tapping dock icons switches tabs and moves the bubble',
      (tester) async {
    final harness = await buildTabs();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    Icon activeDockIcon() => tester
        .widgetList<Icon>(find.descendant(
          of: find.descendant(
            of: find.byKey(const ValueKey('sideDock')),
            matching: find.byType(MuseBubble),
          ),
          matching: find.byType(Icon),
        ))
        .single;

    await tester.tap(find.byTooltip('Device'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(activeDockIcon().icon, Icons.phone_android);

    await tester.tap(find.byTooltip('Chat'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(activeDockIcon().icon, Icons.chat_bubble);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(activeDockIcon().icon, Icons.settings);

    await tester.tap(find.byTooltip('Home'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(activeDockIcon().icon, Icons.pets);
  });

  testWidgets('dock floats on the right edge in portrait and landscape',
      (tester) async {
    final harness = await buildTabs();
    addTearDown(harness.dispose);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    void expectDockRight() {
      final dockRect = tester.getRect(find.byKey(const ValueKey('sideDock')));
      final view = tester.view;
      // getRect is in logical pixels; physicalSize is physical.
      final screenWidth = view.physicalSize.width / view.devicePixelRatio;
      // Dock hugs the right edge (10px padding + safe area).
      expect(dockRect.right, greaterThan(screenWidth - 60));
      // Vertically centered-ish, not glued to the bottom.
      final screenHeight = view.physicalSize.height / view.devicePixelRatio;
      expect(dockRect.top, greaterThan(40));
      expect(dockRect.bottom, lessThan(screenHeight - 40));
    }

    // Portrait: default test view (2400x1800 physical @ 3.0 DPR
    // -> 800x600 logical). Metrics are live from the start.
    expectDockRight();

    // Landscape: resize the view, then pump so the new metrics apply
    // before measuring.
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expectDockRight();
  });
  testWidgets(
      'long status text stays clear of the side dock in portrait',
      (tester) async {
    final harness = await buildTabs();
    addTearDown(harness.dispose);
    // Simulate a long descriptive agent status.
    harness.presentation.applyStatus(
        'Taking a photo of the grow tent canopy with flash…');

    // Portrait phone surface.
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    final statusText = find.textContaining('Taking a photo');
    expect(statusText, findsWidgets,
        reason: 'long status text should be visible on Home');
    final pillRect = tester.getRect(statusText.first);
    final dockRect =
        tester.getRect(find.byKey(const ValueKey('sideDock')));
    expect(pillRect.right, lessThan(dockRect.left),
        reason: 'status pill must not reach the side dock');
  });
}

/// Holds the objects a HomeTabs pump needs so the test can tear them down.
class _TestHarness {
  _TestHarness({
    required this.service,
    required this.presentation,
    required this.settings,
    required this.ble,
    required this.chat,
  });

  final GadgetService service;
  final PresentationState presentation;
  final SettingsStore settings;
  final BlePeripheralManager ble;
  final ChatHistory chat;

  Widget get widget => AppScope(
        service: service,
        presentation: presentation,
        settings: settings,
        ble: ble,
        chat: chat,
        sdkTokens: SecureSdkTokenStore(),
        child: const MaterialApp(
          home: HomeTabs(),
        ),
      );

  Future<void> dispose() async {
    await service.stop();
    await ble.dispose();
    chat.close();
    presentation.close();
  }
}
