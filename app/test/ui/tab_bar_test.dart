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

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Menu').first);
    // Several frames: a single long pump leaves the drawer mid-slide.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  bool isDrawerOpen(WidgetTester tester) =>
      tester
          .state<ScaffoldState>(find.byWidgetPredicate(
              (w) => w is Scaffold && w.drawer != null))
          .isDrawerOpen;

  /// Advances past drawer animations. pumpAndSettle is unusable here:
  /// the avatar animates forever, so it would time out.
  Future<void> settleDrawer(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Finder drawerBubble() => find.descendant(
        of: find.byType(Drawer),
        matching: find.byType(MuseBubble),
      );

  testWidgets('drawer lists six destinations, active gets the bubble glow',
      (tester) async {
    final harness = await buildTabs();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Drawer starts closed; hamburger sits top-left on Home.
    expect(isDrawerOpen(tester), isFalse);
    expect(find.byTooltip('Menu'), findsOneWidget);

    await openDrawer(tester);

    expect(isDrawerOpen(tester), isTrue);
    for (final label
        in ['Home', 'Chat', 'Device', 'Activity', 'Media', 'Settings']) {
      expect(
        find.descendant(
            of: find.byType(Drawer),
            matching: find.byKey(ValueKey('drawer_$label'))),
        findsOneWidget,
        reason: 'drawer destination "$label" should exist',
      );
      expect(
        find.descendant(
            of: find.byType(Drawer), matching: find.text(label)),
        findsOneWidget,
        reason: 'drawer destination "$label" should be labeled',
      );
    }

    // Exactly one MuseBubble in the drawer: the active destination.
    expect(drawerBubble(), findsOneWidget);
    expect(
      find.descendant(of: drawerBubble(), matching: find.text('Home')),
      findsOneWidget,
      reason: 'Home is the default tab, so it glows',
    );
  });

  testWidgets('drawer destinations switch tabs and close the drawer',
      (tester) async {
    final harness = await buildTabs();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    await openDrawer(tester);
    await tester.tap(find.byKey(const ValueKey('drawer_Chat')));
    await settleDrawer(tester);

    // Drawer closed; Chat screen is showing.
    expect(isDrawerOpen(tester), isFalse);
    expect(find.text('Message Muse'), findsOneWidget);

    // The glow followed the active tab.
    await openDrawer(tester);
    expect(
      find.descendant(of: drawerBubble(), matching: find.text('Chat')),
      findsOneWidget,
      reason: 'active glow should track the selected tab',
    );
  });

  testWidgets('Settings keeps the back pattern and disables drawer drag',
      (tester) async {
    final harness = await buildTabs();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    Scaffold rootScaffold() => tester.widgetList<Scaffold>(
          find.byWidgetPredicate(
              (w) => w is Scaffold && w.drawer != null),
        ).single;

    // Drawer drag is enabled on the main tabs.
    expect(rootScaffold().drawerEnableOpenDragGesture, isTrue);

    // Navigate in via the drawer.
    await openDrawer(tester);
    await tester.tap(find.byKey(const ValueKey('drawer_Settings')));
    await settleDrawer(tester);

    // We're on the Settings detail page.
    expect(find.text('Companion Settings'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    // No hamburger on the detail page; edge-drag is off.
    expect(find.byTooltip('Menu'), findsNothing);
    expect(rootScaffold().drawerEnableOpenDragGesture, isFalse);

    // Back returns to Home.
    await tester.tap(find.byType(BackButton));
    await settleDrawer(tester);
    expect(find.byType(BackButton), findsNothing);
    expect(find.byTooltip('Menu'), findsOneWidget);
    expect(rootScaffold().drawerEnableOpenDragGesture, isTrue);
  });

  testWidgets('long status text stays visible on Home', (tester) async {
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
    expect(pillRect.right, lessThanOrEqualTo(720),
        reason: 'status pill must not overflow the screen');
    expect(pillRect.left, greaterThanOrEqualTo(0),
        reason: 'status pill must not overflow the screen');
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
