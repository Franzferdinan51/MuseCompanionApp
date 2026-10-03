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
import 'package:muse_companion/ui/diagnostics_screen.dart';
import 'package:muse_companion/ui/scope.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_ble.dart';

void main() {
  testWidgets('diagnostics shows state, identity and the setup log',
      (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final native = MockBleNative()..install();
    addTearDown(native.uninstall);
    PackageInfo.setMockInitialValues(
      appName: 'Muse Companion',
      packageName: 'dev.musecompanion.muse_companion',
      version: '0.1.0',
      buildNumber: '7',
      buildSignature: '',
      installerStore: null,
    );
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

    // A start attempt leaves log lines behind for the tail.
    await ble.start();

    await tester.pumpWidget(AppScope(
      service: service,
      presentation: presentation,
      settings: settings,
      ble: ble,
      chat: chat,
      sdkTokens: SecureSdkTokenStore(),
      child: const MaterialApp(
        home: DiagnosticsScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.text('MuseGadgetCCDDEE'), findsOneWidget);
    expect(find.text('homelink-ccddee'), findsOneWidget);
    expect(find.text('0.1.0+7'), findsOneWidget);
    expect(find.textContaining('advertising as'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    // The clipboard round-trip needs a few frames; pumpAndSettle would
    // overshoot past the 2s 'Copied' confirmation.
    for (var i = 0;
        i < 20 && find.text('Copied').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Copied'), findsOneWidget);
  });
}
