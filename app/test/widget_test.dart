// Smoke test for the companion screen: with a stubbed service scope the
// home screen renders the placeholder, the unpaired state and the
// settings affordance, and settings navigates.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/model.dart';
import 'package:muse_companion/src/gadget/identity.dart';
import 'package:muse_companion/src/gadget/service.dart';
import 'package:muse_companion/ui/companion_screen.dart';
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
    addTearDown(() async {
      await service.stop();
      presentation.close();
    });
    // No pairing saved: the loop reports unpaired almost immediately.
    unawaited(service.start());

    await tester.pumpWidget(MaterialApp(
      home: AppScope(
        service: service,
        presentation: presentation,
        settings: settings,
        child: const CompanionScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Muse'), findsOneWidget);
    expect(find.text('Waiting for character'), findsOneWidget);
    expect(find.text('Not paired'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Companion Settings'), findsOneWidget);
  });
}
