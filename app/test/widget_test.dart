// Smoke test for the home tabs: with a stubbed service scope the
// home screen renders the placeholder, the unpaired state and the
// settings affordance, and settings navigates.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/ble_peripheral.dart';
import 'package:muse_companion/app/chat.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/service.dart';
import 'package:muse_companion/ui/home_tabs.dart';
import 'package:muse_companion/ui/scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:muse_companion/app/storage.dart';

void main() {
  testWidgets('companion screen renders unpaired placeholder',
      (WidgetTester tester) async {
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
    addTearDown(() async {
      await service.stop();
      await ble.dispose();
      chat.close();
      presentation.close();
    });
    // No pairing saved: the loop reports unpaired almost immediately.
    unawaited(service.start());

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
    await tester.pump();
    for (var i = 0;
        i < 20 && find.text('Not paired').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Muse'), findsOneWidget);
    expect(find.text('Waiting for character'), findsOneWidget);
    expect(find.text('Not paired'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Companion Settings'), findsOneWidget);

    // Stop the service inside the body: the binding verifies no timers
    // are pending before addTearDown callbacks run. The tearDown above
    // stays as the failure-path net (all stops are idempotent).
    // Unmount before returning so the character ticker is disposed.
    await service.stop();
    await ble.dispose();
    chat.close();
    presentation.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
