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
import 'package:muse_companion/ui/companion_screen.dart';
import 'package:muse_companion/ui/muse_theme.dart';
import 'package:muse_companion/ui/scope.dart';
import 'package:muse_companion/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  /// Pumps in small increments so implicit animations and ballistic scroll
  /// settle deterministically. A single large pump can leave the slide
  /// transition mid-flight in the test harness even though the animation
  /// targets are correct.
  Future<void> settleBriefly(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

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

  testWidgets(
      'home tab content clears the floating tab bar in portrait and landscape',
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
    addTearDown(tester.view.resetPhysicalSize);

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

    // CompanionScreen carries an INTERNAL bottom spacer (not an outer
    // Padding - that would reveal the scaffold background as a solid
    // strip) at least as tall as the floating tab bar, so its lowest
    // buttons (connection status, Pair) never sit underneath the icons.
    void expectClearance() {
      final barRect =
          tester.getRect(find.byKey(const ValueKey('tabBarSafeArea')));
      // No outer Padding wrapper around CompanionScreen: that regresses
      // the solid-strip look.
      expect(
        find.ancestor(
          of: find.byType(CompanionScreen),
          matching: find.byType(Padding),
        ),
        findsNothing,
        reason: 'no outer Padding may wrap CompanionScreen',
      );
      final spacer = find.descendant(
        of: find.byType(CompanionScreen),
        matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.height == kFloatingTabBarClearance,
        ),
      );
      expect(spacer, findsOneWidget);
      final spacerRect = tester.getRect(spacer.first);
      expect(
        spacerRect.height,
        greaterThanOrEqualTo(barRect.height),
        reason:
            'home tab bottom spacer (${spacerRect.height}) must clear the '
            'floating tab bar (${barRect.height})',
      );
    }

    // Portrait.
    expectClearance();

    // Landscape: the tab bar is still a bottom overlay, so the same
    // clearance must hold.
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expectClearance();
  });

  testWidgets('tab bar auto-hides on scroll-down and recovers', (tester) async {
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

    // Switch to the scrollable Settings tab.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    AnimatedOpacity barOpacity() => tester.widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('tabBarSafeArea')),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        );

    // Bar starts visible; no recovery handle needed.
    expect(barOpacity().opacity, 1.0);
    expect(find.byKey(const ValueKey('tabBarHandle')), findsNothing);

    final list = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(ListView),
        )
        .first;

    // Scroll down (drag up) -> bar slides away and fades, handle appears.
    await tester.drag(list, const Offset(0, -500));
    await settleBriefly(tester);
    expect(barOpacity().opacity, 0.0);
    expect(find.byKey(const ValueKey('tabBarHandle')), findsOneWidget);

    // Scroll up (drag down) -> bar comes back, handle disappears.
    await tester.drag(list, const Offset(0, 500));
    await settleBriefly(tester);
    expect(barOpacity().opacity, 1.0);
    expect(find.byKey(const ValueKey('tabBarHandle')), findsNothing);

    // Hide again, then tap the edge handle -> bar recovers.
    await tester.drag(list, const Offset(0, -500));
    await settleBriefly(tester);
    expect(find.byKey(const ValueKey('tabBarHandle')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tabBarHandle')));
    await settleBriefly(tester);
    expect(barOpacity().opacity, 1.0);
    expect(find.byKey(const ValueKey('tabBarHandle')), findsNothing);

    // Tab switching keeps the bar visible and still works.
    await settleBriefly(tester);
    await tester.tap(find.byTooltip('Home'));
    await settleBriefly(tester);
    expect(barOpacity().opacity, 1.0);
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
  });

  testWidgets('chat composer clears the floating tab bar (portrait+landscape)',
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

    Future<void> pumpTabs() async {
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
      await tester.tap(find.byTooltip('Chat'));
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> expectComposerAboveBar() async {
      await settleBriefly(tester);
      final sendRect = tester.getRect(find.byTooltip('Send'));
      final barRect = tester.getRect(
        find.byKey(const ValueKey('tabBarSafeArea')),
      );
      // The composer (Send button) must sit fully above the tab bar -
      // never obscured by it.
      expect(sendRect.bottom, lessThanOrEqualTo(barRect.top));
    }

    // Portrait (default test surface).
    await pumpTabs();
    await expectComposerAboveBar();

    // Landscape: tight vertical space, same guarantee.
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    await pumpTabs();
    await expectComposerAboveBar();
  });

  testWidgets('tab bar hides while the keyboard is up, restores after',
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

    Future<void> pumpTabs({bool keyboardUp = false}) async {
      await tester.pumpWidget(AppScope(
        service: service,
        presentation: presentation,
        settings: settings,
        ble: ble,
        chat: chat,
        sdkTokens: SecureSdkTokenStore(),
        child: MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                viewInsets: keyboardUp
                    ? const EdgeInsets.only(bottom: 300)
                    : EdgeInsets.zero,
              ),
              child: const HomeTabs(),
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byTooltip('Chat'));
      await tester.pump(const Duration(milliseconds: 500));
    }

    AnimatedOpacity barOpacity() => tester.widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('tabBarSafeArea')),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        );

    // Keyboard up on the Chat tab -> bar hides, no handle (it's behind
    // the keyboard anyway).
    await pumpTabs(keyboardUp: true);
    await settleBriefly(tester);
    expect(barOpacity().opacity, 0.0);
    expect(find.byKey(const ValueKey('tabBarHandle')), findsNothing);

    // Keyboard closed -> the pre-keyboard state restores (bar visible).
    await pumpTabs(keyboardUp: false);
    await settleBriefly(tester);
    expect(barOpacity().opacity, 1.0);
    expect(find.byKey(const ValueKey('tabBarHandle')), findsNothing);
  });

  testWidgets('landscape home tab uses two-column layout and clears the tab bar',
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

    // Portrait keeps the classic stacked layout. (The default test
    // surface is 800x600, which reads as landscape, so set an explicit
    // portrait size first.)
    tester.view.physicalSize = const Size(600, 900);
    addTearDown(tester.view.resetPhysicalSize);
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
    expect(find.byKey(const ValueKey('companion_portrait')), findsOneWidget);
    expect(find.byKey(const ValueKey('companion_landscape')), findsNothing);

    // Landscape: switches to the two-column layout, and the
    // connection-status pill stays fully above the floating tab bar.
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump(const Duration(milliseconds: 500));
    await settleBriefly(tester);
    expect(find.byKey(const ValueKey('companion_landscape')), findsOneWidget);
    expect(find.byKey(const ValueKey('companion_portrait')), findsNothing);
    final pillRect =
        tester.getRect(find.byKey(const ValueKey('connection_status')));
    final barRect = tester.getRect(
      find.byKey(const ValueKey('tabBarSafeArea')),
    );
    expect(pillRect.bottom, lessThanOrEqualTo(barRect.top));
    // No overlap between the pill and the tab bar.
    expect(pillRect.overlaps(barRect), isFalse);
  });
}
